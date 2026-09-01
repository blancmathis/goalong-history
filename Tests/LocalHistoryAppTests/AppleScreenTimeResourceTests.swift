#if os(macOS)
    import AppleScreenTime
    @testable import AppleSystemScreenTime
    import Combine
    import Foundation
    import SQLite3
    import XCTest
    @testable import LocalHistoryApp

    final class AppleScreenTimeResourceTests: XCTestCase {
        func testRemoteAppleApplicationsUseReadableNamesWithoutBeingInstalledOnThisMac() {
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.google.ios.youtube"),
                "YouTube"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.apple.mobileslideshow"),
                "Photos"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.burbn.instagram"),
                "Instagram"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.apple.MobileSMS"),
                "Messages"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.openai.sky.CUAService"),
                "Codex Computer Use"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.openai.sky.CUAService.cli"),
                "Codex Computer Use Helper"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("com.openai.codex"),
                "ChatGPT"
            )
            XCTAssertEqual(
                AppleSystemScreenTimeSource.applicationDisplayName("ai.goalong.localhistory"),
                "Goalong History"
            )
        }

        func testDashboardDefaultRefreshIntervalAvoidsAggressiveAppleStorePolling() {
            XCTAssertEqual(AppleScreenTimeDashboardModel.defaultRefreshInterval, 30)
        }

        @MainActor
        func testDashboardModelRefreshesOnlyWhileActive() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-lifecycle-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let firstCollection = expectation(description: "first visible collection")
            let unexpectedCollection = expectation(description: "no hidden collection")
            unexpectedCollection.isInverted = true
            let lock = NSLock()
            var collectionCount = 0
            let empty = AppleSystemScreenTimeCollection(
                storedExport: nil,
                availableDevices: [],
                status: AppleSystemScreenTimeStatus(
                    kind: .noAppleData,
                    title: "No data",
                    message: "Test"
                ),
                deviceSourceLabels: [:],
                latestAppleUpdate: nil,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )
            let model = AppleScreenTimeDashboardModel(
                rootDirectory: root,
                deviceID: "test-device",
                refreshInterval: 60
            ) { _ in
                lock.lock()
                collectionCount += 1
                let count = collectionCount
                lock.unlock()
                if count == 1 {
                    firstCollection.fulfill()
                } else {
                    unexpectedCollection.fulfill()
                }
                return empty
            }

            XCTAssertFalse(model.hasActiveRefreshTimerForTesting)
            lock.lock()
            XCTAssertEqual(collectionCount, 0)
            lock.unlock()

            model.setActive(true)
            XCTAssertTrue(model.hasActiveRefreshTimerForTesting)
            wait(for: [firstCollection], timeout: 1)

            model.setActive(false)
            XCTAssertFalse(model.hasActiveRefreshTimerForTesting)
            model.refresh()
            wait(for: [unexpectedCollection], timeout: 0.1)
            lock.lock()
            XCTAssertEqual(collectionCount, 1)
            lock.unlock()
        }

        @MainActor
        func testTemporaryEmptyDiscoveryDoesNotEraseSelectedDeviceConfiguration() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-selection-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let refreshed = expectation(description: "empty collection applied")
            let model = AppleScreenTimeDashboardModel(
                rootDirectory: root,
                deviceID: "test-device",
                refreshInterval: 60
            ) { _ in
                DispatchQueue.main.async {
                    DispatchQueue.main.async { refreshed.fulfill() }
                }
                return AppleSystemScreenTimeCollection(
                    storedExport: nil,
                    availableDevices: [],
                    status: AppleSystemScreenTimeStatus(
                        kind: .partial,
                        title: "Temporarily unavailable",
                        message: "Test"
                    ),
                    deviceSourceLabels: [:],
                    latestAppleUpdate: nil,
                    knowledgeIntervalCount: 0,
                    biomeIntervalCount: 0
                )
            }
            let selectedID = "trusted-ipad-peer"
            model.configuration.scope = AppleScreenTimeScope(
                mode: .selectedDevices,
                selectedDeviceIDs: [selectedID]
            )

            model.setActive(true)
            wait(for: [refreshed], timeout: 1)
            model.setActive(false)

            XCTAssertEqual(model.configuration.scope.mode, .selectedDevices)
            XCTAssertEqual(model.configuration.scope.selectedDeviceIDs, [selectedID])
        }

        @MainActor
        func testDashboardPublishesDefaultAndAllReportedApplicationSummariesFromOneCollection() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-visibility-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let calendar = Calendar(identifier: .gregorian)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            let mac = AppleScreenTimeDevice(
                id: "apple-system-current-mac:test-device",
                name: "MacBook Pro",
                kind: .mac
            )
            let segments = [
                AppleScreenTimeSegment(
                    start: day,
                    end: day.addingTimeInterval(8 * 3_600),
                    totalScreenOnDuration: 8 * 3_600,
                    applications: [
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: "com.apple.loginwindow",
                            displayName: "loginwindow",
                            duration: 8 * 3_600
                        )
                    ]
                ),
                AppleScreenTimeSegment(
                    start: day.addingTimeInterval(8 * 3_600),
                    end: day.addingTimeInterval(8 * 3_600 + 20 * 60),
                    totalScreenOnDuration: 20 * 60,
                    applications: [
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: "com.apple.Safari",
                            displayName: "Safari",
                            duration: 20 * 60
                        )
                    ]
                ),
            ]
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: day,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: AppleScreenTimeProvenance(
                        collectorBundleIdentifier: "test",
                        collectorVersion: "1",
                        collectorPlatform: "test",
                        authorization: .approvedWithDataAccess,
                        fetchPolicy: .live,
                        euCustomerRequirementAcknowledged: true
                    ),
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: end,
                            segments: segments
                        )
                    ]
                )
            )
            let applied = expectation(description: "both summaries applied")
            let providerLock = NSLock()
            var providerCallCount = 0
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac],
                status: AppleSystemScreenTimeStatus(kind: .ready, title: "Ready", message: "Test"),
                deviceSourceLabels: [mac.id: "Apple system usage"],
                latestAppleUpdate: end,
                knowledgeIntervalCount: 2,
                biomeIntervalCount: 0
            )
            let model = AppleScreenTimeDashboardModel(
                rootDirectory: root,
                deviceID: "test-device",
                selectedDay: day,
                refreshInterval: 60,
                includesUnfilteredSummary: true
            ) { _ in
                providerLock.lock()
                providerCallCount += 1
                providerLock.unlock()
                return collection
            }
            var summaryObservation: AnyCancellable?
            summaryObservation = model.$unfilteredSummary
                .compactMap { $0 }
                .sink { _ in
                    guard model.summary != nil else { return }
                    applied.fulfill()
                    summaryObservation?.cancel()
                }

            model.setActive(true)
            wait(for: [applied], timeout: 1)
            model.setActive(false)

            XCTAssertEqual(model.summary?.totalScreenOnDuration ?? -1, 20 * 60, accuracy: 0.001)
            XCTAssertEqual(model.summary?.topApplications.map(\.resolvedName), ["Safari"])
            XCTAssertEqual(
                model.unfilteredSummary?.totalScreenOnDuration ?? -1,
                8 * 3_600 + 20 * 60,
                accuracy: 0.001
            )
            XCTAssertEqual(
                Set(model.unfilteredSummary?.topApplications.map(\.resolvedName) ?? []),
                ["Safari", "loginwindow"]
            )
            XCTAssertEqual(model.summary?.scope, .allDevices)
            XCTAssertEqual(model.unfilteredSummary?.scope, .allDevices)
            XCTAssertEqual(model.summary?.provenance, stored.envelope.provenance)
            XCTAssertEqual(model.unfilteredSummary?.provenance, stored.envelope.provenance)
            XCTAssertEqual(model.summary?.latestDataUpdate, end)
            XCTAssertEqual(model.unfilteredSummary?.latestDataUpdate, end)
            providerLock.lock()
            XCTAssertEqual(providerCallCount, 1)
            providerLock.unlock()
        }

        func testBiomeCacheEvictsByLRUAndByteBudgetAndPurgesMissingFiles() {
            var cache = AppleBiomeFileCache(
                limits: AppleBiomeFileCacheLimits(maximumEntries: 2, maximumBytes: 80)
            )
            let fingerprint = AppleBiomeFileFingerprint(size: 40, modifiedAt: .distantPast)
            let event = AppleBiomeFocusEvent(
                bundleIdentifier: "com.example.app",
                isForeground: true,
                timestamp: .distantPast
            )

            cache.insert(path: "/source/a", fingerprint: fingerprint, events: [event], retainedBytes: 40)
            cache.insert(path: "/source/b", fingerprint: fingerprint, events: [event], retainedBytes: 40)
            XCTAssertNotNil(cache.events(for: "/source/a", fingerprint: fingerprint))
            cache.insert(path: "/source/c", fingerprint: fingerprint, events: [event], retainedBytes: 40)

            var snapshot = cache.snapshot
            XCTAssertEqual(snapshot.entryCount, 2)
            XCTAssertLessThanOrEqual(snapshot.retainedBytes, 80)
            XCTAssertEqual(snapshot.paths, Set(["/source/a", "/source/c"]))

            cache.removeMissingFiles { $0 == "/source/c" }
            snapshot = cache.snapshot
            XCTAssertEqual(snapshot.entryCount, 1)
            XCTAssertEqual(snapshot.retainedBytes, 40)
            XCTAssertEqual(snapshot.paths, Set(["/source/c"]))

            cache.insert(
                path: "/source/oversized",
                fingerprint: fingerprint,
                events: [event],
                retainedBytes: 81
            )
            XCTAssertEqual(cache.snapshot, snapshot)
        }

        func testOverlappingAppleApplicationRowsKeepEveryAppButUnionPhysicalScreenTime() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-overlapping-apps-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let knowledge = root.appendingPathComponent("knowledgeC.db")
            let calendar = Calendar(identifier: .gregorian)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
            let hour: TimeInterval = 3_600
            try createKnowledgeDatabase(
                at: knowledge,
                day: day,
                rows: [
                    ("ai.goalong.localhistory", 9 * hour, 11 * hour + 57 * 60),
                    ("at.studio.AsideBrowser", 9 * hour + 15 * 60, 13 * hour + 15 * 60),
                    ("com.openai.sky.CUAService", 9 * hour + 30 * 60, 13 * hour + 15 * 60),
                    // A repeated Apple row for the same application must not inflate its duration.
                    ("com.openai.sky.CUAService", 10 * hour, 12 * hour),
                ]
            )
            let missing = root.appendingPathComponent("missing", isDirectory: true)
            let source = AppleSystemScreenTimeSource(
                deviceID: "test-device",
                paths: AppleSystemScreenTimePaths(
                    knowledgeDatabase: knowledge,
                    biomeSyncDatabase: missing.appendingPathComponent("sync.db"),
                    biomeLocalDirectory: missing.appendingPathComponent("local", isDirectory: true),
                    biomeRemoteDirectory: missing.appendingPathComponent("remote", isDirectory: true),
                    appleAccountDeviceDatabase: missing.appendingPathComponent("devicelist.db")
                ),
                calendar: calendar,
                nowProvider: { day.addingTimeInterval(14 * hour) }
            )

            let collection = source.collect(for: day)
            let stored = try XCTUnwrap(collection.storedExport)
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: day))
            let summary = try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .allDevices)
            )
            let applications = try XCTUnwrap(summary.deviceSummaries.first).applications
            let durationByBundle = Dictionary(uniqueKeysWithValues: applications.compactMap { application in
                application.bundleIdentifier.map { ($0, application.duration) }
            })

            XCTAssertEqual(collection.knowledgeIntervalCount, 4)
            XCTAssertEqual(summary.totalScreenOnDuration, 4 * hour + 15 * 60, accuracy: 0.001)
            XCTAssertEqual(durationByBundle["ai.goalong.localhistory"] ?? -1, 2 * hour + 57 * 60, accuracy: 0.001)
            XCTAssertEqual(durationByBundle["at.studio.AsideBrowser"] ?? -1, 4 * hour, accuracy: 0.001)
            XCTAssertEqual(durationByBundle["com.openai.sky.CUAService"] ?? -1, 3 * hour + 45 * 60, accuracy: 0.001)
            XCTAssertEqual(
                applications.first { $0.bundleIdentifier == "com.openai.sky.CUAService" }?.resolvedName,
                "Codex Computer Use"
            )
        }

        func testScreenTimeAppUsageReplacesConflictingMacFallbackAttribution() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-app-usage-priority-\(UUID().uuidString)", isDirectory: true)
            let appUsageDirectory = root.appendingPathComponent("ScreenTime.AppUsage", isDirectory: true)
            try FileManager.default.createDirectory(at: appUsageDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let knowledge = root.appendingPathComponent("knowledgeC.db")
            let calendar = Calendar(identifier: .gregorian)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
            let hour: TimeInterval = 3_600
            try createKnowledgeDatabase(
                at: knowledge,
                day: day,
                rows: [
                    // This spans beyond every healthy AppUsage row. None of it may leak
                    // back into the final Mac ranking or physical total.
                    ("ai.goalong.localhistory", 8 * hour, 14 * hour),
                ]
            )
            let appUsageFile = makeScreenTimeAppUsageV1([
                (
                    bundle: "at.studio.AsideBrowser",
                    parentBundle: nil,
                    starting: true,
                    timestamp: day.addingTimeInterval(9 * hour + 15 * 60)
                ),
                (
                    bundle: "com.openai.sky.CUAService.cli",
                    parentBundle: "com.openai.sky.CUAService",
                    starting: true,
                    timestamp: day.addingTimeInterval(9 * hour + 30 * 60)
                ),
                (
                    bundle: "com.openai.sky.CUAService.cli",
                    parentBundle: "com.openai.sky.CUAService",
                    starting: false,
                    timestamp: day.addingTimeInterval(13 * hour + 15 * 60)
                ),
                (
                    bundle: "at.studio.AsideBrowser",
                    parentBundle: nil,
                    starting: false,
                    timestamp: day.addingTimeInterval(13 * hour + 15 * 60)
                ),
            ])
            try appUsageFile.write(
                to: appUsageDirectory.appendingPathComponent("fixture.segb"),
                options: .atomic
            )
            let tombstoneDirectory = appUsageDirectory.appendingPathComponent("tombstone", isDirectory: true)
            try FileManager.default.createDirectory(at: tombstoneDirectory, withIntermediateDirectories: true)
            try Data("not-segb".utf8).write(
                to: tombstoneDirectory.appendingPathComponent("removed.segb")
            )

            let missing = root.appendingPathComponent("missing", isDirectory: true)
            let source = AppleSystemScreenTimeSource(
                deviceID: "test-device",
                paths: AppleSystemScreenTimePaths(
                    knowledgeDatabase: knowledge,
                    biomeSyncDatabase: missing.appendingPathComponent("sync.db"),
                    biomeLocalDirectory: missing.appendingPathComponent("local", isDirectory: true),
                    biomeRemoteDirectory: missing.appendingPathComponent("remote", isDirectory: true),
                    appleAccountDeviceDatabase: missing.appendingPathComponent("devicelist.db"),
                    biomeScreenTimeAppUsageDirectory: appUsageDirectory
                ),
                calendar: calendar,
                nowProvider: { day.addingTimeInterval(14 * hour) }
            )

            let collection = source.collect(for: day)
            let stored = try XCTUnwrap(collection.storedExport)
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: day))
            let summary = try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .allDevices)
            )
            let applications = try XCTUnwrap(summary.deviceSummaries.first).applications
            let durationByBundle = Dictionary(uniqueKeysWithValues: applications.compactMap { application in
                application.bundleIdentifier.map { ($0, application.duration) }
            })

            XCTAssertEqual(collection.screenTimeAppUsageIntervalCount, 2)
            XCTAssertEqual(summary.totalScreenOnDuration, 4 * hour, accuracy: 0.001)
            XCTAssertEqual(durationByBundle["at.studio.AsideBrowser"] ?? -1, 4 * hour, accuracy: 0.001)
            XCTAssertEqual(durationByBundle["com.openai.sky.CUAService"] ?? -1, 3 * hour + 45 * 60, accuracy: 0.001)
            XCTAssertNil(durationByBundle["ai.goalong.localhistory"])
            XCTAssertNotEqual(collection.status.kind, .partial)
            XCTAssertEqual(
                collection.deviceSourceLabels[source.currentMacDevice.id],
                "Apple ScreenTime.AppUsage"
            )
        }

        func testPartialScreenTimeAppUsageKeepsConcurrentFallbackAttribution() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-app-usage-partial-\(UUID().uuidString)", isDirectory: true)
            let appUsageDirectory = root.appendingPathComponent("ScreenTime.AppUsage", isDirectory: true)
            try FileManager.default.createDirectory(at: appUsageDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let knowledge = root.appendingPathComponent("knowledgeC.db")
            let calendar = Calendar(identifier: .gregorian)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
            let hour: TimeInterval = 3_600
            try createKnowledgeDatabase(
                at: knowledge,
                day: day,
                rows: [("ai.goalong.localhistory", 9 * hour, 10 * hour)]
            )
            let appUsageFile = makeScreenTimeAppUsageV1([
                (
                    bundle: "com.openai.sky.CUAService.cli",
                    parentBundle: "com.openai.sky.CUAService",
                    starting: true,
                    timestamp: day.addingTimeInterval(9 * hour)
                ),
                (
                    bundle: "com.openai.sky.CUAService.cli",
                    parentBundle: "com.openai.sky.CUAService",
                    starting: false,
                    timestamp: day.addingTimeInterval(10 * hour)
                ),
            ])
            try appUsageFile.write(to: appUsageDirectory.appendingPathComponent("valid.segb"))
            try Data("not-segb".utf8).write(
                to: appUsageDirectory.appendingPathComponent("malformed.segb")
            )

            let missing = root.appendingPathComponent("missing", isDirectory: true)
            let source = AppleSystemScreenTimeSource(
                deviceID: "test-device",
                paths: AppleSystemScreenTimePaths(
                    knowledgeDatabase: knowledge,
                    biomeSyncDatabase: missing.appendingPathComponent("sync.db"),
                    biomeLocalDirectory: missing.appendingPathComponent("local", isDirectory: true),
                    biomeRemoteDirectory: missing.appendingPathComponent("remote", isDirectory: true),
                    appleAccountDeviceDatabase: missing.appendingPathComponent("devicelist.db"),
                    biomeScreenTimeAppUsageDirectory: appUsageDirectory
                ),
                calendar: calendar,
                nowProvider: { day.addingTimeInterval(11 * hour) }
            )

            let collection = source.collect(for: day)
            let stored = try XCTUnwrap(collection.storedExport)
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: day))
            let summary = try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .allDevices)
            )
            let applications = try XCTUnwrap(summary.deviceSummaries.first).applications
            let bundles = Set(applications.compactMap(\.bundleIdentifier))

            XCTAssertEqual(collection.status.kind, .partial)
            XCTAssertEqual(collection.screenTimeAppUsageIntervalCount, 1)
            XCTAssertEqual(summary.totalScreenOnDuration, hour, accuracy: 0.001)
            XCTAssertTrue(bundles.contains("com.openai.sky.CUAService"))
            XCTAssertTrue(bundles.contains("ai.goalong.localhistory"))
            XCTAssertEqual(
                collection.deviceSourceLabels[source.currentMacDevice.id],
                "Apple ScreenTime.AppUsage + knowledgeC"
            )
        }

        func testSystemSourcePreservesExplicitIdleRowsWhileDefaultSummaryFiltersThem() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-screen-time-idle-filter-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let knowledge = root.appendingPathComponent("knowledgeC.db")
            let calendar = Calendar(identifier: .gregorian)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
            try createKnowledgeDatabase(at: knowledge, day: day)
            let before = try Data(contentsOf: knowledge)
            let beforeAttributes = try FileManager.default.attributesOfItem(atPath: knowledge.path)
            let missing = root.appendingPathComponent("missing", isDirectory: true)
            let source = AppleSystemScreenTimeSource(
                deviceID: "test-device",
                paths: AppleSystemScreenTimePaths(
                    knowledgeDatabase: knowledge,
                    biomeSyncDatabase: missing.appendingPathComponent("sync.db"),
                    biomeLocalDirectory: missing.appendingPathComponent("local", isDirectory: true),
                    biomeRemoteDirectory: missing.appendingPathComponent("remote", isDirectory: true),
                    appleAccountDeviceDatabase: missing.appendingPathComponent("devicelist.db")
                ),
                calendar: calendar,
                nowProvider: { day.addingTimeInterval(12 * 3_600) }
            )

            let collection = source.collect(for: day)
            let stored = try XCTUnwrap(collection.storedExport)
            let applications = stored.envelope.reports
                .flatMap(\.segments)
                .flatMap(\.applications)

            XCTAssertEqual(collection.knowledgeIntervalCount, 3)
            XCTAssertEqual(
                Set(applications.compactMap(\.bundleIdentifier)),
                ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.Safari"]
            )
            XCTAssertEqual(
                stored.envelope.reports.flatMap(\.segments).reduce(0) {
                    $0 + $1.totalScreenOnDuration
                },
                9 * 3_600 + 20 * 60,
                accuracy: 0.001
            )

            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: day))
            let defaultSummary = try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .allDevices)
            )
            XCTAssertEqual(defaultSummary.totalScreenOnDuration, 20 * 60, accuracy: 0.001)
            XCTAssertEqual(defaultSummary.topApplications.map(\.resolvedName), ["Safari"])

            let unfilteredSummary = try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(
                    from: stored,
                    interval: interval,
                    scope: .allDevices,
                    includingSystemInactivity: true
                )
            )
            XCTAssertEqual(
                unfilteredSummary.totalScreenOnDuration,
                9 * 3_600 + 20 * 60,
                accuracy: 0.001
            )
            XCTAssertTrue(unfilteredSummary.topApplications.contains { $0.resolvedName == "loginwindow" })

            let after = try Data(contentsOf: knowledge)
            let afterAttributes = try FileManager.default.attributesOfItem(atPath: knowledge.path)
            XCTAssertEqual(after, before)
            XCTAssertEqual(afterAttributes[.size] as? NSNumber, beforeAttributes[.size] as? NSNumber)
            XCTAssertEqual(
                afterAttributes[.modificationDate] as? Date,
                beforeAttributes[.modificationDate] as? Date
            )
        }

        private func createKnowledgeDatabase(at url: URL, day: Date) throws {
            let hour: TimeInterval = 3_600
            try createKnowledgeDatabase(
                at: url,
                day: day,
                rows: [
                    ("com.apple.loginwindow", 0.0, 8.5 * hour),
                    ("com.apple.ScreenSaver.Engine", 8.5 * hour, 9 * hour),
                    ("com.apple.Safari", 9 * hour, 9 * hour + 20 * 60),
                ]
            )
        }

        private func createKnowledgeDatabase(
            at url: URL,
            day: Date,
            rows: [(bundleIdentifier: String, start: TimeInterval, end: TimeInterval)]
        ) throws {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            guard let database else { throw NSError(domain: "SQLiteTest", code: 1) }
            defer { sqlite3_close(database) }

            try execute(
                database,
                """
                CREATE TABLE ZOBJECT (
                  ZVALUESTRING TEXT,
                  ZSTARTDATE REAL,
                  ZENDDATE REAL,
                  ZSOURCE INTEGER,
                  ZSTREAMNAME TEXT
                );
                CREATE TABLE ZSOURCE (Z_PK INTEGER, ZDEVICEID TEXT);
                CREATE TABLE ZSYNCPEER (ZDEVICEID TEXT, ZMODEL TEXT);
                """
            )
            let appleEpochOffset: TimeInterval = 978_307_200
            func appleTime(_ offset: TimeInterval) -> TimeInterval {
                day.addingTimeInterval(offset).timeIntervalSince1970 - appleEpochOffset
            }
            for row in rows {
                try execute(
                    database,
                    "INSERT INTO ZOBJECT VALUES ('\(row.bundleIdentifier)',\(appleTime(row.start)),\(appleTime(row.end)),NULL,'/app/usage');"
                )
            }
        }

        private typealias AppUsageFixtureEvent = (
            bundle: String,
            parentBundle: String?,
            starting: Bool,
            timestamp: Date
        )

        private func makeScreenTimeAppUsageV1(_ events: [AppUsageFixtureEvent]) -> Data {
            var output = Data(repeating: 0, count: 56)
            output.replaceSubrange(52 ..< 56, with: Data("SEGB".utf8))
            for event in events {
                let payload = makeScreenTimeAppUsagePayload(event)
                var header = Data(repeating: 0, count: 32)
                header.replaceSubrange(0 ..< 4, with: uint32LE(UInt32(payload.count)))
                header.replaceSubrange(4 ..< 8, with: uint32LE(1))
                output.append(header)
                output.append(payload)
                while output.count % 8 != 0 { output.append(0) }
            }
            output.replaceSubrange(0 ..< 4, with: uint32LE(UInt32(output.count)))
            return output
        }

        private func makeScreenTimeAppUsagePayload(_ event: AppUsageFixtureEvent) -> Data {
            var output = Data()
            appendVarint(UInt64((1 << 3) | 0), to: &output)
            appendVarint(event.starting ? 1 : 0, to: &output)
            appendVarint(UInt64((2 << 3) | 1), to: &output)
            output.append(uint64LE(event.timestamp.timeIntervalSince1970.bitPattern))
            appendString(event.bundle, field: 3, to: &output)
            if let parentBundle = event.parentBundle {
                appendString(parentBundle, field: 4, to: &output)
            }
            appendVarint(UInt64((5 << 3) | 0), to: &output)
            appendVarint(1, to: &output)
            return output
        }

        private func appendString(_ value: String, field: Int, to data: inout Data) {
            let valueData = Data(value.utf8)
            appendVarint(UInt64((field << 3) | 2), to: &data)
            appendVarint(UInt64(valueData.count), to: &data)
            data.append(valueData)
        }

        private func appendVarint(_ value: UInt64, to data: inout Data) {
            var remaining = value
            repeat {
                var byte = UInt8(remaining & 0x7f)
                remaining >>= 7
                if remaining != 0 { byte |= 0x80 }
                data.append(byte)
            } while remaining != 0
        }

        private func uint32LE(_ value: UInt32) -> Data {
            Data([
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff),
            ])
        }

        private func uint64LE(_ value: UInt64) -> Data {
            Data((0 ..< 8).map { UInt8((value >> UInt64($0 * 8)) & 0xff) })
        }

        private func execute(_ database: OpaquePointer, _ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else {
                throw NSError(
                    domain: "SQLiteTest",
                    code: Int(result),
                    userInfo: [
                        NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "SQLite error"
                    ]
                )
            }
        }
    }
#endif
