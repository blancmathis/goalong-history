#if os(macOS)
    import AppleScreenTime
    @testable import AppleSystemScreenTime
    import Combine
    import Foundation
    import SQLite3
    import XCTest
    @testable import LocalHistoryApp

    final class AppleScreenTimeResourceTests: XCTestCase {
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
            let rows: [(String, TimeInterval, TimeInterval)] = [
                ("com.apple.loginwindow", 0.0, 8.5 * 3_600),
                ("com.apple.ScreenSaver.Engine", 8.5 * 3_600, 9 * 3_600),
                ("com.apple.Safari", 9 * 3_600, 9 * 3_600 + 20 * 60),
            ]
            for row in rows {
                try execute(
                    database,
                    "INSERT INTO ZOBJECT VALUES ('\(row.0)',\(appleTime(row.1)),\(appleTime(row.2)),NULL,'/app/usage');"
                )
            }
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
