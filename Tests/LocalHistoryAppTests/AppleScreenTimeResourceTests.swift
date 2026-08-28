#if os(macOS)
    import AppleScreenTime
    @testable import AppleSystemScreenTime
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AppleScreenTimeResourceTests: XCTestCase {
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
    }
#endif
