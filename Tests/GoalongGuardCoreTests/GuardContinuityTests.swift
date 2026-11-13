import Foundation
@testable import GoalongGuardCore
import XCTest

/// T-059 lot 5: `guard-continuity` arms the guard outside a severe block. kill → relaunch; an allowed « Quitter »
/// (`user_quit`) → exit 0; another boot, a stale or a too far file → nothing.
final class GuardContinuityTests: XCTestCase {
    private let now: Double = 1_000_000, boot: Double = 900_000

    private func input(_ change: (inout GuardInput) -> Void = { _ in }) -> GuardInput {
        var value = GuardInput()
        value.continuity = true
        value.now = now
        value.bootTime = boot
        value.bootSession = "boot-a"
        change(&value)
        return value
    }

    func testContinuityAloneWatchesAndRelaunchesAKilledApp() {
        XCTAssertEqual(GuardDecision.decide(input { $0.alivePID = 42 }), .watch(42))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: now) }), .relaunch(after: 0))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: now); $0.budgetDelay = 30 }), .relaunch(after: 30))
        XCTAssertEqual(GuardDecision.decide(input { $0.continuity = false; $0.death = .init(pid: 42, at: now) }), .exit(0),
                       "neither a block nor continuity: the guard ends")
    }

    func testAnAllowedQuitEndsTheGuardWithoutALoop() {
        let quit = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: now - 1, bootTime: boot, bootSession: "boot-a")
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: now); $0.release = quit }), .exit(0))
        XCTAssertEqual(GuardDecision.decide(input { $0.release = quit }), .exit(0), "a guard started after the quit")
    }

    func testAPlannedRelaunchIsAwaitedLikeDuringABlock() {
        let lease = GuardLease(pid: 42, reason: GuardLease.update, until: now + 60)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: now); $0.lease = lease; $0.leaseProofAlive = true }),
                       .waitForLease(until: now + 60))
    }

    func testTheFileCountsOnlyForThisBootAndAShortFutureHorizon() {
        func valid(_ value: GuardContinuity) -> Bool { value.isValid(now: now, bootTime: boot, bootSession: "boot-a") }
        XCTAssertTrue(valid(GuardContinuity(pid: 1, until: now + GuardContinuity.horizon, bootTime: boot, bootSession: "boot-a")))
        XCTAssertFalse(valid(GuardContinuity(pid: 1, until: now + 600, bootTime: boot, bootSession: "boot-b")), "another boot")
        XCTAssertFalse(valid(GuardContinuity(pid: 1, until: now + 600, bootTime: boot - 3600)), "older file: another boot time")
        XCTAssertTrue(valid(GuardContinuity(pid: 1, until: now + 600, bootTime: boot + 1)), "older file of this boot")
        XCTAssertFalse(valid(GuardContinuity(pid: 1, until: now - 1, bootTime: boot, bootSession: "boot-a")), "stale")
        XCTAssertFalse(valid(GuardContinuity(pid: 1, until: now + GuardContinuity.maximumHorizon + 1, bootTime: boot,
                                             bootSession: "boot-a")), "a forged far end arms nothing")
    }

    func testTheFileIsPrivateAndRemovable() throws {
        let root = GuardSystem.realPath(FileManager.default.temporaryDirectory)
            .appendingPathComponent("guard-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = GuardFiles(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        XCTAssertFalse(files.continuityExists())
        let value = GuardContinuity(pid: 7, until: now + 60, bootTime: boot, bootSession: "boot-a")
        XCTAssertTrue(files.writeContinuity(value))
        XCTAssertEqual(files.readContinuity(), value)
        let mode = try FileManager.default.attributesOfItem(atPath: files.directory.appendingPathComponent(GuardFiles.continuity).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(files.readMarker(now: Date(timeIntervalSince1970: now)), .absent, "never the severe marker")
        XCTAssertTrue(files.removeContinuity())
        XCTAssertFalse(files.continuityExists())
    }
}
