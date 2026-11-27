import Darwin
import Foundation
@testable import GoalongGuardCore
import XCTest

/// L1L2-03 / L1L2-06: the perso rollback stops every candidate before it restores, and reopens the old app
/// for real, after a parent that was still quitting has ended. Real processes (`/bin/sleep`) play the apps.
final class PersoRollbackTests: XCTestCase {
    private var processes: [Process] = []
    private var log: [String] = []
    private let lock = NSLock()

    override func tearDown() {
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL); $0.waitUntilExit() }
    }

    private func note(_ entry: String) { lock.withLock { log.append(entry) } }
    private var entries: [String] { lock.withLock { log } }

    private func spawn() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        lock.withLock { processes.append(process) }
        return process.processIdentifier
    }

    private func isAlive(_ pid: Int32) -> Bool {
        // Our own children stay zombies until reaped: reap them so "dead" is seen at once.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return GuardProcesses.isAlive(pid)
    }

    private func rollback(parent: Int32, candidates: @escaping () -> [Int32], parentAlive: @escaping () -> Bool = { false },
                          open: @escaping () -> Int32?) -> PersoRollback {
        var rollback = PersoRollback(
            parentPID: parent, candidates: candidates,
            holdLease: { [unowned self] in note("hold \($0)"); return true },
            terminate: { [unowned self] in note("terminate \($0)"); kill($0, SIGKILL) },
            isAlive: { [unowned self] in isAlive($0) },
            restore: { [unowned self] in note("restore"); return true },
            parentAlive: parentAlive,
            endLease: { [unowned self] in note("endLease") },
            report: { [unowned self] in note("report \($0)") },
            open: { [unowned self] in note("open"); return open() })
        rollback.scanInterval = 0.02
        rollback.pause = { Thread.sleep(forTimeInterval: min($0, 0.02)) }
        return rollback
    }

    /// L1L2-03: LaunchServices answers late. The candidate it started (unknown to the relauncher) is stopped and
    /// confirmed dead before the old bundle is restored, and the old app really starts.
    func testALateLaunchIsStoppedBeforeTheRestore() throws {
        let parent: Int32 = 999_999
        var late: Int32?
        var oldApp: Int32?
        var deadAtRestore = false
        var subject = rollback(parent: parent, candidates: { late.map { [$0] } ?? [] }, open: {
            oldApp = try? self.spawn(); return oldApp
        })
        subject.settleOpen = { [unowned self] in late = try? spawn(); note("settled") }
        let restore = subject.restore
        subject.restore = { [unowned self] in deadAtRestore = late.map { !isAlive($0) } ?? false; return restore() }
        let outcome = subject.run()
        let candidate = try XCTUnwrap(late)
        XCTAssertTrue(deadAtRestore, "the candidate was dead when the old bundle came back")
        XCTAssertEqual(outcome, .reopened(try XCTUnwrap(oldApp)))
        XCTAssertEqual(Array(entries.prefix(4)), ["settled", "hold \(candidate)", "terminate \(candidate)", "restore"])
        XCTAssertEqual(Array(entries.suffix(3)), ["open", "endLease", "report true"])
    }

    /// L1L2-06: the parent still lives at the rollback (its quit was accepted). The result is written at once,
    /// but the old app is opened only after the parent ended, and a new process is required.
    func testAParentEndingAfterTheRollbackStillGetsItsSuccessor() throws {
        let parent = try spawn()
        var oldApp: Int32?
        let subject = rollback(parent: parent, candidates: { [] }, parentAlive: { [unowned self] in isAlive(parent) }, open: {
            oldApp = try? self.spawn(); return oldApp
        })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [unowned self] in note("parent ends"); kill(parent, SIGKILL) }
        let outcome = subject.run()
        XCTAssertEqual(outcome, .reopened(try XCTUnwrap(oldApp)))
        XCTAssertEqual(entries, ["restore", "endLease", "report true", "parent ends", "open"])
    }

    /// An open that only finds the dying parent (reuse of an instance) does not count: a real new process is
    /// required, three tries at most.
    func testReopeningTheParentIsNotASuccessor() throws {
        let subject = rollback(parent: 42, candidates: { [] }, open: { 42 })
        XCTAssertEqual(subject.run(), .openFailed)
        XCTAssertEqual(entries.filter { $0 == "open" }.count, 3)
    }

    func testACandidateThatCannotBeStoppedBlocksTheRestore() throws {
        var subject = rollback(parent: 1, candidates: { [4242] }, open: { nil })
        subject.terminate = { _ in }
        subject.isAlive = { _ in true }
        subject.maximumScans = 5
        XCTAssertEqual(subject.run(), .candidateSurvived)
        XCTAssertFalse(entries.contains("restore"))
        XCTAssertEqual(entries.suffix(2), ["endLease", "report false"])
    }

    /// bugs-mise-a-jour-06: without its lease the armed guard would reopen the candidate the rollback stops. A
    /// lease not written means no stop on that scan; a later scan that holds it stops the candidate.
    func testACandidateIsStoppedOnlyUnderAHeldLease() throws {
        let candidate = try spawn()
        var refusals = 2
        var subject = rollback(parent: 1, candidates: { [candidate] }, open: { try? self.spawn() })
        subject.holdLease = { [unowned self] pid in
            note("hold \(pid)")
            if refusals > 0 { refusals -= 1; return false }
            return true
        }
        guard case .reopened = subject.run() else { return XCTFail("rollback did not finish: \(entries)") }
        XCTAssertEqual(Array(entries.prefix(4)), ["hold \(candidate)", "hold \(candidate)", "hold \(candidate)", "terminate \(candidate)"])
    }

    func testALeaseNeverHeldLeavesTheCandidateAndTheTargetAlone() throws {
        var subject = rollback(parent: 1, candidates: { [4242] }, open: { nil })
        subject.holdLease = { _ in false }
        subject.isAlive = { _ in true }
        subject.maximumScans = 5
        XCTAssertEqual(subject.run(), .candidateSurvived)
        XCTAssertFalse(entries.contains { $0.hasPrefix("terminate") || $0 == "restore" })
    }
}
