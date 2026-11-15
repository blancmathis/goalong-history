#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-064: the developer file monitor never blocks the main thread and never syncs on its own queue.
    final class GoalongDeveloperMonitorQueueTests: XCTestCase {
        private func root() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dev-monitor-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        func testBackgroundRestartAndStopReturnWhileTheQueueIsBusy() throws {
            let monitor = GoalongDeveloperFileMonitor(root: try root())
            let release = DispatchSemaphore(value: 0)
            monitor.queueForTesting.async { release.wait() }
            let started = Date()
            monitor.restartInBackground(replayHistory: false)
            monitor.stopInBackground(discardOffline: true)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
            release.signal()
            XCTAssertEqual(monitor.snapshotStatus(), .disabled)
        }

        func testDeinitOnTheMonitorQueueDoesNotSyncOnItself() throws {
            var monitor: GoalongDeveloperFileMonitor? = GoalongDeveloperFileMonitor(root: try root())
            let queue = monitor!.queueForTesting
            let done = expectation(description: "released on its own queue")
            queue.async {
                monitor = nil  // last strong reference dropped on the monitor queue
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }
#endif
