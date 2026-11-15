#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-064: a `codex app-server` that ignores SIGTERM is killed after the grace delay.
final class CodexProcessTerminatorTests: XCTestCase {
    func testProcessIgnoringTermIsKilledAfterGrace() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        let exited = expectation(description: "exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        Thread.sleep(forTimeInterval: 0.2) // let the shell install its trap

        let start = Date()
        CodexProcessTerminator.terminate(process, grace: 0.5)
        wait(for: [exited], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }
}
#endif
