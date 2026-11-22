#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import LocalHistoryApp

/// 2026-11-22: `make perso` left Goalong hung in `terminate`, with no window: the SIGTERM handler ran inside a main-queue
/// block, and AppKit's `.terminateLater` loop could never drain the main queue to receive its reply. Quits and replies go
/// through the main run loop instead. No window, no focus.
final class MainRunLoopQuitTests: XCTestCase {
    private final class Flags: @unchecked Sendable { var runLoop = false, queue = false }

    func testTheRunLoopHopRunsInsideAMainQueueBlockWhereTheQueueCannot() {
        let flags = Flags()
        let done = expectation(description: "outer main-queue block")
        DispatchQueue.main.async {
            // The same nesting as `terminate` called from the SIGTERM source: a run loop spun inside a main-queue block.
            AppDelegate.onMainRunLoop { flags.runLoop = true }
            DispatchQueue.main.async { flags.queue = true }
            let deadline = Date().addingTimeInterval(2)
            while !flags.runLoop, Date() < deadline {
                _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(flags.runLoop, "the run-loop hop must run in AppKit's modal loop nested in a main-queue block")
            XCTAssertFalse(flags.queue, "the main queue cannot drain there: a reply sent through it hangs the quit")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
#endif
