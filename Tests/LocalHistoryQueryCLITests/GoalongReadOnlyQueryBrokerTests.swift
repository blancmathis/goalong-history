#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    import AppleScreenTime
    import AppleSystemScreenTime
    @testable import LocalHistoryQueryCLI

    final class GoalongReadOnlyQueryBrokerTests: XCTestCase {
        func testScreenTimeCLIExposesPrivateAggregateAssuranceWithoutParityClaim() throws {
            let calendar = Calendar.current
            let start = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: start,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: start,
                                    end: end,
                                    totalScreenOnDuration: 600,
                                    applications: []
                                )
                            ]
                        )
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac],
                status: AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: "Apple Screen Time aggregate for this Mac",
                    message: "Private aggregate; parity is not certified."
                ),
                deviceSourceLabels: [mac.id: "Apple Screen Time aggregate (private format)"],
                latestAppleUpdate: start,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let payload = try GoalongQueryCLI.screenTimePayload(
                day: "2026-09-02",
                macOnly: false,
                collectionProvider: { _ in collection },
                currentMacProvider: { mac }
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )

            XCTAssertEqual(json["sourceAssurance"] as? String, "privateAppleAggregateStore")
            XCTAssertEqual(
                json["freshness"] as? String,
                "collectedOnDemandForThisRequest"
            )
            XCTAssertTrue(
                (json["limitation"] as? String)?.contains("exact parity is not certified") == true
            )
        }

        func testIndirectScreenTimeIntentRecognizesUsageQuestionsWithoutOvermatchingWorkQuestions() {
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Combien de temps ai-je passé sur mes applications hier ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Quelle était ma productivité et mon temps perdu sur l'ordinateur ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Combien de temps ai-je passé sur ChatGPT ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "What was my Screen Time across my iPhone and iPad?"
                )
            )
            XCTAssertFalse(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Sur quoi ai-je travaillé hier ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionUsesOnlyFreshScreenTime(
                    "What was my Screen Time across all devices during the last 30 days?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionUsesOnlyFreshScreenTime(
                    "Combien de temps ai-je passe sur mes applications hier ?"
                )
            )
            XCTAssertFalse(
                GoalongQueryCLI.questionUsesOnlyFreshScreenTime(
                    "Combien d'heures productives et perdues ai-je eues hier ?"
                )
            )
            XCTAssertFalse(
                GoalongQueryCLI.questionUsesOnlyFreshScreenTime(
                    "Resume ma journee avec Screen Time et mes conversations agent"
                )
            )
        }

        func testIndirectScreenTimeContextUsesOneBrokerRequestForStoredAndActiveDays() throws {
            let calendar = Calendar(identifier: .gregorian)
            let firstDay = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: firstDay))
            var requestedDays: [String] = []
            var requestCount = 0

            let context = GoalongQueryCLI.freshScreenTimeContext(
                root: URL(fileURLWithPath: "/unused", isDirectory: true),
                question: "Quel était mon temps d'écran sur mes appareils ?",
                firstDay: firstDay,
                endExclusive: end,
                maximumDays: 2,
                requestProvider: { _, days in
                    requestCount += 1
                    requestedDays = days
                    let generatedAt = Date(timeIntervalSince1970: 1_788_436_800)
                    let payload = ScreenTimeRangeEnvelope(
                        schemaVersion: 1,
                        generatedAt: generatedAt,
                        freshness: "singleOnDemandAppleRangeReadForThisRequest",
                        sourceAssurance: nil,
                        status: ScreenTimeStatusEnvelope(
                            kind: "ready",
                            title: "Ready",
                            message: "Fresh"
                        ),
                        days: days.map {
                            ScreenTimeAskDay(
                                day: $0,
                                totalScreenOnDuration: nil,
                                devices: [],
                                applicationCount: 0,
                                applications: [],
                                omittedApplicationCount: 0,
                                latestAppleUpdate: nil
                            )
                        },
                        limitation: "Test fixture"
                    )
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return try encoder.encode(payload)
                }
            )

            XCTAssertTrue(context.requested)
            XCTAssertEqual(
                context.refreshPolicy,
                "completedDaysFromLocalStoreCurrentDayFromApple"
            )
            XCTAssertEqual(context.days.map(\.day), requestedDays)
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(requestedDays.count, 2)
            XCTAssertEqual(context.status?.kind, "ready")
            XCTAssertEqual(context.limitation, "Test fixture")
            XCTAssertTrue(context.issues.isEmpty)
        }

        func testScreenTimeRangePayloadReadsSourceOnceAndSplitsExactDailyTotals() throws {
            let calendar = Calendar(identifier: .gregorian)
            let firstDay = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            )
            let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
            let rangeEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: secondDay))
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: firstDay,
                    requestedEnd: rangeEnd,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: rangeEnd,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: firstDay,
                                    end: secondDay,
                                    totalScreenOnDuration: 600,
                                    applications: [
                                        AppleScreenTimeApplicationUsage(
                                            bundleIdentifier: "com.example.first",
                                            displayName: "First",
                                            duration: 600
                                        )
                                    ]
                                ),
                                AppleScreenTimeSegment(
                                    start: secondDay,
                                    end: rangeEnd,
                                    totalScreenOnDuration: 900,
                                    applications: [
                                        AppleScreenTimeApplicationUsage(
                                            bundleIdentifier: "com.example.second",
                                            displayName: "Second",
                                            duration: 900
                                        )
                                    ]
                                ),
                            ]
                        )
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac],
                status: AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: "Apple Screen Time aggregate for this Mac",
                    message: "Private aggregate; parity is not certified."
                ),
                deviceSourceLabels: [mac.id: "Apple Screen Time aggregate (private format)"],
                latestAppleUpdate: rangeEnd,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )
            var collectionCount = 0
            var collectedInterval: DateInterval?

            let payload = try GoalongQueryCLI.screenTimeRangePayload(
                days: ["2026-09-01", "2026-09-02"],
                collectionProvider: { interval in
                    collectionCount += 1
                    collectedInterval = interval
                    return collection
                },
                currentMacProvider: { mac }
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ScreenTimeRangeEnvelope.self, from: payload)

            XCTAssertEqual(collectionCount, 1)
            XCTAssertEqual(collectedInterval?.start, firstDay)
            XCTAssertEqual(collectedInterval?.end, rangeEnd)
            XCTAssertEqual(envelope.days.map(\.day), ["2026-09-01", "2026-09-02"])
            XCTAssertEqual(envelope.days.map(\.totalScreenOnDuration), [600, 900])
            XCTAssertEqual(envelope.days[0].applications.map(\.name), ["First"])
            XCTAssertEqual(envelope.days[1].applications.map(\.name), ["Second"])
            XCTAssertEqual(envelope.sourceAssurance, "privateAppleAggregateStore")
            XCTAssertEqual(envelope.status.kind, "localOnly")
        }

        func testScreenTimeRangePayloadLabelsStoredCompletedDaysAndLiveCurrentDay() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let provenance = AppleScreenTimeProvenance(
                collectorBundleIdentifier: "test",
                collectorVersion: "1",
                collectorPlatform: "test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            func collection(
                for day: Date,
                state: AppleSystemScreenTimeStorageState
            ) -> AppleSystemScreenTimeCollection {
                let end = calendar.date(byAdding: .day, value: 1, to: day)!
                let stored = AppleScreenTimeStoredExport(
                    verification: .unsigned,
                    envelope: AppleScreenTimeExportEnvelope(
                        requestedStart: day,
                        requestedEnd: end,
                        requestedScope: .allDevices,
                        provenance: provenance,
                        reports: [
                            AppleScreenTimeDeviceReport(
                                device: mac,
                                lastUpdatedAt: end,
                                segments: [
                                    AppleScreenTimeSegment(
                                        start: day,
                                        end: day.addingTimeInterval(60),
                                        totalScreenOnDuration: 60
                                    )
                                ]
                            )
                        ]
                    )
                )
                return AppleSystemScreenTimeCollection(
                    storedExport: stored,
                    availableDevices: [mac],
                    status: AppleSystemScreenTimeStatus(kind: .ready, title: "Ready", message: "Ready"),
                    deviceSourceLabels: [mac.id: "Test"],
                    latestAppleUpdate: end,
                    knowledgeIntervalCount: 1,
                    biomeIntervalCount: 0,
                    storageState: state
                )
            }
            let dailyStates: [AppleSystemScreenTimeStorageState] = [
                .completedDayStored,
                .liveCurrentDayStored,
            ]
            var requestedDays: [Date] = []

            let payload = try GoalongQueryCLI.screenTimeRangePayload(
                days: ["2026-09-03", "2026-09-04"],
                dailyCollectionProvider: { day in
                    requestedDays.append(day)
                    return collection(for: day, state: dailyStates[requestedDays.count - 1])
                },
                currentMacProvider: { mac }
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ScreenTimeRangeEnvelope.self, from: payload)

            XCTAssertEqual(requestedDays.count, 2)
            XCTAssertEqual(envelope.freshness, "storedCompletedDaysPlusLiveCurrentDay")
            XCTAssertEqual(envelope.days[0].freshness, "storedCompletedDayNoAppleHistoryRead")
            XCTAssertEqual(envelope.days[1].freshness, "liveCurrentDayReadAndStored")
            XCTAssertEqual(envelope.days.map(\.totalScreenOnDuration), [60, 60])
        }

        func testStoredScreenTimeRangeReadsCompletedDayWithoutBrokerOrArchiveWrite() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(
                """
                {"schemaVersion":1,"policyVersion":1,"capabilities":{"appleScreenTime":{"enabled":true}}}
                """.utf8
            ).write(to: root.appendingPathComponent("capability-consent.json"))
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let completedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: completedDay))
            let mac = AppleScreenTimeDevice(
                id: "apple-system-current-mac:test",
                name: "Mac",
                kind: .mac
            )
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: completedDay,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: AppleScreenTimeProvenance(
                        collectorBundleIdentifier: "test",
                        collectorVersion: "1",
                        collectorPlatform: "test",
                        authorization: .unknown,
                        fetchPolicy: .live,
                        euCustomerRequirementAcknowledged: false
                    ),
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: end,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: completedDay,
                                    end: completedDay.addingTimeInterval(480),
                                    totalScreenOnDuration: 480,
                                    applications: [
                                        AppleScreenTimeApplicationUsage(
                                            bundleIdentifier: "com.example.work",
                                            displayName: "Work",
                                            duration: 480
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                )
            )
            let archive = try AppleSystemScreenTimeDailyArchive(
                rootDirectory: root.appendingPathComponent("apple-screen-time", isDirectory: true)
            )
            _ = try archive.storeActiveDay(
                AppleSystemScreenTimeCollection(
                    storedExport: stored,
                    availableDevices: [mac],
                    status: AppleSystemScreenTimeStatus(kind: .ready, title: "Ready", message: "Ready"),
                    deviceSourceLabels: [mac.id: "Test"],
                    latestAppleUpdate: end,
                    knowledgeIntervalCount: 1,
                    biomeIntervalCount: 0
                ),
                for: completedDay,
                storedAt: completedDay.addingTimeInterval(600)
            )
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let dayString = formatter.string(from: completedDay)
            let record = archive.daysDirectory.appendingPathComponent("\(dayString).json")
            let before = try FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate] as? Date

            let payload = try GoalongQueryCLI.storedScreenTimeRangePayload(
                root: root,
                days: [dayString],
                now: today
            )
            let after = try FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate] as? Date
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ScreenTimeRangeEnvelope.self, from: payload)

            XCTAssertEqual(before, after, "A completed-day CLI read must not rewrite its archive record")
            XCTAssertEqual(envelope.freshness, "storedCompletedDaysOnly")
            XCTAssertEqual(envelope.days.first?.freshness, "storedCompletedDayNoAppleHistoryRead")
            XCTAssertEqual(envelope.days.first?.totalScreenOnDuration, 480)
        }

        func testScreenTimeRangePayloadRejectsSparseUnboundedIntervalsBeforeReadingSource() throws {
            var collectionCount = 0

            XCTAssertThrowsError(
                try GoalongQueryCLI.screenTimeRangePayload(
                    days: ["2026-01-01", "2026-09-01"],
                    collectionProvider: { _ in
                        collectionCount += 1
                        fatalError("An unbounded range must be rejected before source access")
                    },
                    currentMacProvider: {
                        AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
                    }
                )
            )
            XCTAssertEqual(collectionCount, 0)
        }

        func testScreenTimeRangePayloadBoundsAgentRowsAndEncodedBytesAtThirtyOneDays() throws {
            let calendar = Calendar(identifier: .gregorian)
            let firstDay = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))
            )
            let rangeEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 31, to: firstDay))
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let days = try (0..<31).map { offset -> String in
                formatter.string(
                    from: try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: firstDay))
                )
            }
            let segments = try (0..<31).map { dayOffset -> AppleScreenTimeSegment in
                let start = try XCTUnwrap(
                    calendar.date(byAdding: .day, value: dayOffset, to: firstDay)
                )
                return AppleScreenTimeSegment(
                    start: start,
                    end: start.addingTimeInterval(15 * 60),
                    totalScreenOnDuration: 15 * 60,
                    applications: (0..<100).map { applicationIndex in
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: "com.example.day\(dayOffset).app\(applicationIndex)",
                            displayName: "Application \(applicationIndex)",
                            duration: 1
                        )
                    }
                )
            }
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: firstDay,
                    requestedEnd: rangeEnd,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: rangeEnd,
                            segments: segments
                        )
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac],
                status: AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: "Apple Screen Time aggregate for this Mac",
                    message: "Private aggregate; parity is not certified."
                ),
                deviceSourceLabels: [:],
                latestAppleUpdate: rangeEnd,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let payload = try GoalongQueryCLI.screenTimeRangePayload(
                days: days,
                collectionProvider: { _ in collection },
                currentMacProvider: { mac }
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ScreenTimeRangeEnvelope.self, from: payload)
            XCTAssertEqual(envelope.days.count, 31)
            XCTAssertTrue(envelope.days.allSatisfy { $0.applicationCount == 100 })
            XCTAssertTrue(envelope.days.allSatisfy { $0.applications.count == 24 })
            XCTAssertTrue(envelope.days.allSatisfy { $0.omittedApplicationCount == 76 })
            XCTAssertLessThan(payload.count, 256 * 1_024)
            XCTAssertLessThan(
                payload.count,
                GoalongReadOnlyQueryBroker.maximumScreenTimeRangeResponseBytes
            )
        }

        func testScreenTimeCLIUsesAppleAggregateWhenEveryPhysicalDeviceIsSelected() throws {
            let calendar = Calendar.current
            let start = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let iPhone = AppleScreenTimeDevice(id: "iphone", name: "iPhone", kind: .iPhone)
            let aggregate = AppleScreenTimeDevice(
                id: AppleScreenTimeProvenance.appleSettingsAllDevicesReportID,
                name: "All Devices",
                kind: .unknown
            )
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.appleSettingsAccessibilityAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            func report(
                _ device: AppleScreenTimeDevice,
                duration: TimeInterval
            ) -> AppleScreenTimeDeviceReport {
                AppleScreenTimeDeviceReport(
                    device: device,
                    lastUpdatedAt: start,
                    segments: [
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: duration,
                            applications: []
                        )
                    ]
                )
            }
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        report(mac, duration: 5_220),
                        report(iPhone, duration: 245),
                        report(aggregate, duration: 5_460),
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac, iPhone],
                status: AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Matches Apple Screen Time",
                    message: "Visible values"
                ),
                deviceSourceLabels: [:],
                latestAppleUpdate: start,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let payload = try GoalongQueryCLI.screenTimePayload(
                day: "2026-09-03",
                macOnly: false,
                selectedDeviceIDs: [mac.id, iPhone.id],
                collectionProvider: { _ in collection },
                currentMacProvider: { mac }
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            let summary = try XCTUnwrap(json["summary"] as? [String: Any])
            let reports = try XCTUnwrap(json["reports"] as? [[String: Any]])

            XCTAssertEqual(summary["totalScreenOnDuration"] as? Double, 5_460)
            XCTAssertEqual(reports.count, 2)
        }

        func testBrokerReturnsTransientScreenTimePayloadAndRemovesSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let expected = Data("{\"schemaVersion\":1,\"status\":{\"kind\":\"ready\"}}\n".utf8)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { day, macOnly, selectedDeviceIDs in
                    XCTAssertEqual(day, "2026-08-31")
                    XCTAssertTrue(macOnly)
                    XCTAssertEqual(selectedDeviceIDs, ["mac", "phone"])
                    return expected
                }
            )

            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

            let actual = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-08-31",
                macOnly: true,
                selectedDeviceIDs: ["mac", "phone"]
            )
            XCTAssertEqual(actual, expected)

            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        }

        func testBrokerRefusesToReplaceUnexpectedPath() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let marker = Data("do-not-replace".utf8)
            try marker.write(to: socketURL, options: .withoutOverwriting)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in Data() }
            )

            XCTAssertThrowsError(try server.start())
            XCTAssertThrowsError(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
            XCTAssertEqual(try Data(contentsOf: socketURL), marker)
        }

        func testConsentOffCleanupRemovesOnlyOwnedSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in Data() }
            )
            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

            try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)

            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            server.stop()
            XCTAssertNoThrow(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
        }

        func testCapabilityConsentFailsClosedAndRequiresExactCurrentDocument() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            let consent = root.appendingPathComponent("capability-consent.json")
            try Data(
                """
                {"schemaVersion":1,"policyVersion":1,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent)
            XCTAssertTrue(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            try Data(
                """
                {"schemaVersion":1,"policyVersion":999,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent, options: .atomic)
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )
        }

        func testBrokerBuildsFreshScreenTimeForEveryRequest() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var buildCount = 0
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in
                    buildCount += 1
                    return Data("{\"generation\":\(buildCount)}".utf8)
                }
            )
            try server.start()
            defer { server.stop() }

            let first = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-09-01",
                macOnly: false
            )
            let second = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-09-01",
                macOnly: false
            )

            XCTAssertEqual(first, Data("{\"generation\":1}".utf8))
            XCTAssertEqual(second, Data("{\"generation\":2}".utf8))
            XCTAssertEqual(buildCount, 2)
        }

        func testBrokerUsesOneHandlerInvocationForMultiDayScreenTimeRange() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let expected = Data("{\"schemaVersion\":1,\"days\":[]}".utf8)
            var rangeBuildCount = 0
            var receivedDays: [String] = []
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in Data() },
                screenTimeRangeHandler: { days in
                    rangeBuildCount += 1
                    receivedDays = days
                    return expected
                }
            )
            try server.start()
            defer { server.stop() }

            let actual = try GoalongReadOnlyQueryBroker.requestScreenTimeRange(
                rootDirectory: root,
                days: ["2026-09-01", "2026-09-02", "2026-09-03"]
            )

            XCTAssertEqual(actual, expected)
            XCTAssertEqual(rangeBuildCount, 1)
            XCTAssertEqual(receivedDays, ["2026-09-01", "2026-09-02", "2026-09-03"])
        }

        private func temporaryRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
                "goalong-broker-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
#endif
