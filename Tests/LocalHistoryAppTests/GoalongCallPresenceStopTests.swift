#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-064: stopping call presence (history deletion) never waits on the main thread
/// for a CoreAudio-busy queue; the deletion continues once the queue answers.
final class GoalongCallPresenceStopTests: XCTestCase {
    func testStopReturnsAtOnceWhileQueueIsBusyThenCompletes() {
        let queue = DispatchQueue(label: "test.call-presence")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = GoalongCallPresenceMonitor(root: root, queue: queue)
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }

        let completed = expectation(description: "stopped")
        var returned = false
        monitor.stop { XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(returned); completed.fulfill() }
        returned = true
        release.signal()
        wait(for: [completed], timeout: 3)
    }
}
#endif
