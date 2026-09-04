#if os(macOS)
    import AppleScreenTime
    import AppleSystemScreenTime
    import Foundation
    import XCTest

    final class AppleScreenTimeDailyArchiveTests: XCTestCase {
        func testCompletedDayLoadsFromSingleLocalRecordWithoutReopeningApple() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            var now = day
            var sourceReadCount = 0
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { now },
                liveCollectionProvider: { requestedDay in
                    sourceReadCount += 1
                    return self.collection(day: requestedDay, device: mac, seconds: 600, calendar: calendar)
                }
            )

            let live = repository.collect(for: day)
            XCTAssertEqual(live.storageState, .liveCurrentDayStored)
            XCTAssertEqual(sourceReadCount, 1)

            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("days", isDirectory: true),
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(files.map(\.lastPathComponent), ["2026-09-04.json"])

            now = try date(2026, 9, 5, hour: 8, calendar: calendar)
            let completed = repository.collect(for: day)
            XCTAssertEqual(completed.storageState, .completedDayStored)
            XCTAssertEqual(sourceReadCount, 1, "A completed day must never trigger another Apple source read")
            XCTAssertEqual(
                summaryDuration(completed, day: day, calendar: calendar),
                600,
                accuracy: 0.001
            )

            let persisted = try Data(contentsOf: files[0])
            let record = try AppleScreenTimeJSON.decode(
                AppleSystemScreenTimeDailyArchiveRecord.self,
                from: persisted
            )
            XCTAssertEqual(record.state, .completed)
            XCTAssertEqual(record.collection.storageState, .completedDayStored)
        }

        func testActiveDayUpdatesInPlaceAndDoesNotCreateVersions() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            var seconds: TimeInterval = 300
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { day },
                liveCollectionProvider: { requestedDay in
                    self.collection(day: requestedDay, device: mac, seconds: seconds, calendar: calendar)
                }
            )

            _ = repository.collect(for: day)
            seconds = 900
            let updated = repository.collect(for: day)
            XCTAssertEqual(summaryDuration(updated, day: day, calendar: calendar), 900, accuracy: 0.001)

            let days = root.appendingPathComponent("days", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: days,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files[0].lastPathComponent, "2026-09-04.json")
            let size = try XCTUnwrap(try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertLessThan(size, 16 * 1_024)
            let permissions =
                try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }

        func testMissingCompletedDayIsExplicitAndNeverReadsApple() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let today = try date(2026, 9, 5, hour: 12, calendar: calendar)
            let yesterday = try date(2026, 9, 4, hour: 12, calendar: calendar)
            var sourceReadCount = 0
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { today },
                liveCollectionProvider: { requestedDay in
                    sourceReadCount += 1
                    return self.collection(day: requestedDay, device: mac, seconds: 60, calendar: calendar)
                }
            )

            let missing = repository.collect(for: yesterday)
            XCTAssertEqual(sourceReadCount, 0)
            XCTAssertEqual(missing.storageState, .missingCompletedDay)
            XCTAssertEqual(missing.status.kind, .noAppleData)
            XCTAssertTrue(missing.status.message.contains("never reopens Apple history"))
        }

        func testArchiveRejectsSymlinkedStorageDirectory() throws {
            let root = temporaryRoot()
            let external = temporaryRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: external)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let linkedRoot = root.appendingPathComponent("apple-screen-time", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: external)

            XCTAssertThrowsError(
                try AppleSystemScreenTimeDailyArchive(
                    rootDirectory: linkedRoot,
                    createIfMissing: false
                )
            )
        }

        func testFailedCurrentReadFallsBackToLastStoredActiveDay() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            var succeeds = true
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { day },
                liveCollectionProvider: { requestedDay in
                    if succeeds {
                        return self.collection(day: requestedDay, device: mac, seconds: 420, calendar: calendar)
                    }
                    return AppleSystemScreenTimeCollection(
                        storedExport: nil,
                        availableDevices: [],
                        status: AppleSystemScreenTimeStatus(
                            kind: .fullDiskAccessRequired,
                            title: "Unavailable",
                            message: "Test source denied"
                        ),
                        deviceSourceLabels: [:],
                        latestAppleUpdate: nil,
                        knowledgeIntervalCount: 0,
                        biomeIntervalCount: 0
                    )
                }
            )

            _ = repository.collect(for: day)
            succeeds = false
            let fallback = repository.collect(for: day)
            XCTAssertEqual(fallback.storageState, .activeDayStoredFallback)
            XCTAssertEqual(fallback.status.kind, .partial)
            XCTAssertEqual(summaryDuration(fallback, day: day, calendar: calendar), 420, accuracy: 0.001)
        }

        func testCompletedDaySurvivesRepositoryRecreationWithoutSourceRead() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 3, hour: 12, calendar: calendar)
            var now = day
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let writer = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { now },
                liveCollectionProvider: { requestedDay in
                    self.collection(day: requestedDay, device: mac, seconds: 720, calendar: calendar)
                }
            )
            XCTAssertEqual(writer.collect(for: day).storageState, .liveCurrentDayStored)

            now = try date(2026, 9, 4, hour: 9, calendar: calendar)
            var reopenedSourceReads = 0
            let reader = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { now },
                liveCollectionProvider: { requestedDay in
                    reopenedSourceReads += 1
                    return self.collection(day: requestedDay, device: mac, seconds: 1, calendar: calendar)
                }
            )
            let completed = reader.collect(for: day)
            XCTAssertEqual(completed.storageState, .completedDayStored)
            XCTAssertEqual(reopenedSourceReads, 0)
            XCTAssertEqual(summaryDuration(completed, day: day, calendar: calendar), 720, accuracy: 0.001)
        }

        func testSubsecondSegmentsRemainValidAfterJSONRoundTrip() throws {
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let original = collection(
                day: day,
                device: mac,
                seconds: 0.125,
                calendar: calendar
            )

            let data = try AppleScreenTimeJSON.encode(original, prettyPrinted: false)
            let decoded = try AppleScreenTimeJSON.decode(
                AppleSystemScreenTimeCollection.self,
                from: data
            )
            let stored = try XCTUnwrap(decoded.storedExport)

            XCTAssertNoThrow(try AppleScreenTimeValidator.validate(stored.envelope))
            XCTAssertEqual(
                stored.envelope.reports[0].segments[0].end.timeIntervalSince(
                    stored.envelope.reports[0].segments[0].start
                ),
                0.125,
                accuracy: 0.001
            )
        }

        func testValidCurrentRefreshAtomicallyReplacesMalformedActiveRecord() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let archive = try AppleSystemScreenTimeDailyArchive(
                rootDirectory: root,
                calendar: calendar
            )
            let invalidCollection = collection(
                day: day,
                device: mac,
                seconds: 0.125,
                calendar: calendar
            )
            let invalidStored = try XCTUnwrap(invalidCollection.storedExport)
            let segment = try XCTUnwrap(invalidStored.envelope.reports.first?.segments.first)
            let malformedSegment = AppleScreenTimeSegment(
                start: segment.start,
                end: segment.start,
                totalScreenOnDuration: segment.totalScreenOnDuration,
                applications: segment.applications
            )
            let malformedExport = AppleScreenTimeStoredExport(
                importedAt: invalidStored.importedAt,
                verification: invalidStored.verification,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: invalidStored.envelope.createdAt,
                    requestedStart: invalidStored.envelope.requestedStart,
                    requestedEnd: invalidStored.envelope.requestedEnd,
                    requestedScope: invalidStored.envelope.requestedScope,
                    provenance: invalidStored.envelope.provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: segment.end,
                            segments: [malformedSegment]
                        )
                    ]
                )
            )
            let malformedCollection = AppleSystemScreenTimeCollection(
                storedExport: malformedExport,
                availableDevices: [mac],
                status: invalidCollection.status,
                deviceSourceLabels: invalidCollection.deviceSourceLabels,
                latestAppleUpdate: invalidCollection.latestAppleUpdate,
                knowledgeIntervalCount: invalidCollection.knowledgeIntervalCount,
                biomeIntervalCount: invalidCollection.biomeIntervalCount
            )
            let dayFile = archive.daysDirectory.appendingPathComponent("2026-09-04.json")
            let malformedRecord = AppleSystemScreenTimeDailyArchiveRecord(
                dayStart: calendar.startOfDay(for: day),
                dayEnd: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!,
                timeZoneIdentifier: calendar.timeZone.identifier,
                state: .active,
                storedAt: day,
                collection: malformedCollection
            )
            try AppleScreenTimeJSON.encode(malformedRecord, prettyPrinted: false).write(to: dayFile)

            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { day },
                liveCollectionProvider: { requestedDay in
                    self.collection(day: requestedDay, device: mac, seconds: 60, calendar: calendar)
                }
            )
            let refreshed = repository.collect(for: day)

            XCTAssertEqual(refreshed.storageState, .liveCurrentDayStored)
            let repairedData = try Data(contentsOf: dayFile)
            let repaired = try AppleScreenTimeJSON.decode(
                AppleSystemScreenTimeDailyArchiveRecord.self,
                from: repairedData
            )
            let repairedExport = try XCTUnwrap(repaired.collection.storedExport)
            XCTAssertNoThrow(try AppleScreenTimeValidator.validate(repairedExport.envelope))
            XCTAssertEqual(summaryDuration(repaired.collection, day: day, calendar: calendar), 60)
        }

        func testInvalidLiveCollectionIsNeverPersisted() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = testCalendar()
            let day = try date(2026, 9, 4, hour: 12, calendar: calendar)
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let valid = collection(day: day, device: mac, seconds: 60, calendar: calendar)
            let stored = try XCTUnwrap(valid.storedExport)
            let segment = try XCTUnwrap(stored.envelope.reports.first?.segments.first)
            let invalidExport = AppleScreenTimeStoredExport(
                importedAt: stored.importedAt,
                verification: stored.verification,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: stored.envelope.createdAt,
                    requestedStart: stored.envelope.requestedStart,
                    requestedEnd: stored.envelope.requestedEnd,
                    requestedScope: stored.envelope.requestedScope,
                    provenance: stored.envelope.provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: segment.end,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: segment.start,
                                    end: segment.start,
                                    totalScreenOnDuration: 60,
                                    applications: segment.applications
                                )
                            ]
                        )
                    ]
                )
            )
            let invalid = AppleSystemScreenTimeCollection(
                storedExport: invalidExport,
                availableDevices: [mac],
                status: valid.status,
                deviceSourceLabels: valid.deviceSourceLabels,
                latestAppleUpdate: valid.latestAppleUpdate,
                knowledgeIntervalCount: valid.knowledgeIntervalCount,
                biomeIntervalCount: valid.biomeIntervalCount
            )
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root,
                currentMacDevice: mac,
                calendar: calendar,
                nowProvider: { day },
                liveCollectionProvider: { _ in invalid }
            )

            let result = repository.collect(for: day)

            XCTAssertEqual(result.storageState, .directAppleRead)
            XCTAssertEqual(result.status.kind, .partial)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("days/2026-09-04.json").path
                )
            )
        }

        private func collection(
            day: Date,
            device: AppleScreenTimeDevice,
            seconds: TimeInterval,
            calendar: Calendar
        ) -> AppleSystemScreenTimeCollection {
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let segmentEnd = start.addingTimeInterval(seconds)
            let provenance = AppleScreenTimeProvenance(
                collectorBundleIdentifier: "test",
                collectorVersion: "1",
                collectorPlatform: "test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let stored = AppleScreenTimeStoredExport(
                importedAt: segmentEnd,
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: segmentEnd,
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: device,
                            lastUpdatedAt: segmentEnd,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: start,
                                    end: segmentEnd,
                                    totalScreenOnDuration: seconds,
                                    applications: [
                                        AppleScreenTimeApplicationUsage(
                                            bundleIdentifier: "com.example.work",
                                            displayName: "Work",
                                            duration: seconds
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                )
            )
            return AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [device],
                status: AppleSystemScreenTimeStatus(kind: .ready, title: "Ready", message: "Ready"),
                deviceSourceLabels: [device.id: "Test"],
                latestAppleUpdate: segmentEnd,
                knowledgeIntervalCount: 1,
                biomeIntervalCount: 0
            )
        }

        private func summaryDuration(
            _ collection: AppleSystemScreenTimeCollection,
            day: Date,
            calendar: Calendar
        ) -> TimeInterval {
            guard let stored = collection.storedExport,
                let interval = calendar.dateInterval(of: .day, for: day)
            else { return -1 }
            return AppleScreenTimeAnalyzer.summary(
                from: stored,
                interval: interval,
                scope: .allDevices
            )?.totalScreenOnDuration ?? -1
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-screen-time-daily-\(UUID().uuidString)", isDirectory: true)
        }

        private func testCalendar() -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }

        private func date(
            _ year: Int,
            _ month: Int,
            _ day: Int,
            hour: Int,
            calendar: Calendar
        ) throws -> Date {
            try XCTUnwrap(
                calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
            )
        }
    }
#endif
