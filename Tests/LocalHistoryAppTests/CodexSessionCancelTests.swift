#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// bugs-concurrence-01: a cancel (logical close) must never let a reader or writer touch a closed `FileHandle`.
/// Before the fix these tests ended the run with `NSFileHandleOperationException` (uncatchable from Swift).
final class CodexSessionCancelTests: XCTestCase {
    private func makeSession() throws -> (CodexAppServerSession, URL) {
        // The Codex home must sit on a path without symlinks (/var → /private/var).
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        let temporary = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let container = temporary.appendingPathComponent("goalong-codex-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let codexHome = container.appendingPathComponent("codex-home", isDirectory: true)
        let executable = container.appendingPathComponent("codex-fixture")
        // Answers the handshake, then reads every request and never answers.
        let script = """
            #!/bin/sh
            IFS= read -r initialize_request
            printf '%s\\n' '{"id":1,"result":{"codexHome":"\(codexHome.path)"}}'
            exec cat >/dev/null
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (try CodexAppServerSession(executableURL: executable, codexHomeURL: codexHome), container)
    }

    func testRequestAfterCloseFailsWithoutTouchingClosedHandles() throws {
        let (session, container) = try makeSession()
        defer { try? FileManager.default.removeItem(at: container) }
        session.close()
        XCTAssertTrue(session.ioHandlesClosedForTesting)
        XCTAssertNil(session.readAccountLimits(), "a cancelled session answers nil, never an exception")
    }

    func testCloseDuringPendingReadDefersPhysicalCloseAndNeverBlocks() throws {
        let (session, container) = try makeSession()
        defer { try? FileManager.default.removeItem(at: container) }
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let once = NSLock()
        var held = false
        // Hold the reader between its poll and its read, the window the audit found.
        session.afterPollForTesting = {
            once.lock(); let first = !held; held = true; once.unlock()
            guard first else { return }
            reached.signal()
            _ = resume.wait(timeout: .now() + 10)
        }
        let finished = expectation(description: "reader returns")
        DispatchQueue.global().async {
            XCTAssertNil(session.readAccountLimits())
            finished.fulfill()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 10), .success)
        let started = Date()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "close() must not wait for the reader")
        XCTAssertFalse(session.ioHandlesClosedForTesting, "a handle in use stays open until its access ends")
        resume.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(session.ioHandlesClosedForTesting, "the last access out closes the handles")
    }
}
#endif
