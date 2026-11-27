import Foundation
@testable import GoalongGuardCore
import XCTest

/// Audit 2026-11-26, installation-04: one deadline per relauncher phase (injected monotonic clock).
final class GoalongRelauncherTests: XCTestCase {
    func testPermissionParentQuittingAt44_8sIsStillReopened() {
        var timeline = RelauncherTimeline(perso: false, now: 0)
        timeline.parentExited(now: 44.8)
        // The old global timer fired here and exited 70 before the reopen planned at 45.15 s.
        XCTAssertNil(timeline.expiry(now: 45, parentGone: true))
        XCTAssertEqual(timeline.phase, .reopening)
        timeline.appOpened(now: 45.15)
        XCTAssertTrue(timeline.isFinished)
        XCTAssertNil(timeline.expiry(now: 500, parentGone: true))
    }

    func testPersoParentQuittingAt119_8sIsStillReopenedAndGetsItsHealthDelay() {
        var timeline = RelauncherTimeline(perso: true, now: 0)
        timeline.parentExited(now: 119.8)
        XCTAssertNil(timeline.expiry(now: 120, parentGone: true))
        timeline.appOpened(now: 120.15)
        XCTAssertEqual(timeline.phase, .awaitingHealth)
        XCTAssertNil(timeline.expiry(now: 120.15 + PersoUpdate.healthTimeout - 0.01, parentGone: true))
        XCTAssertEqual(timeline.expiry(now: 120.15 + PersoUpdate.healthTimeout, parentGone: true), .healthTimedOut)
    }

    func testPersoParentQuittingAt80sKeepsTheFullHealthCheck() {
        var timeline = RelauncherTimeline(perso: true, now: 0)
        timeline.parentExited(now: 80)
        timeline.appOpened(now: 80.4)
        // The old 120 s timer killed the health check in progress: neither result nor rollback.
        XCTAssertNil(timeline.expiry(now: 120, parentGone: true))
        XCTAssertNil(timeline.expiry(now: 125, parentGone: true))
        timeline.finish() // health seen at 100 s
        XCTAssertNil(timeline.expiry(now: 200, parentGone: true))
    }

    func testAParentGoneBeforeItsExitEventCountsAsExitedNotAsATimeout() {
        var timeline = RelauncherTimeline(perso: true, now: 0)
        XCTAssertNil(timeline.expiry(now: 120, parentGone: true))
        XCTAssertEqual(timeline.phase, .reopening)
        XCTAssertNil(timeline.expiry(now: 120 + RelauncherTimeline.reopenWindow - 0.1, parentGone: true))
        XCTAssertEqual(timeline.expiry(now: 120 + RelauncherTimeline.reopenWindow, parentGone: true), .reopenTimedOut)
    }

    func testAParentThatNeverQuitsExpiresOnceAtItsOwnDeadline() {
        var permission = RelauncherTimeline(perso: false, now: 10)
        XCTAssertNil(permission.expiry(now: 54.9, parentGone: false))
        XCTAssertEqual(permission.expiry(now: 55, parentGone: false), .parentDidNotQuit)
        XCTAssertNil(permission.expiry(now: 56, parentGone: false), "at most once")
        var perso = RelauncherTimeline(perso: true, now: 0)
        XCTAssertNil(perso.expiry(now: 119.9, parentGone: false))
        XCTAssertEqual(perso.expiry(now: 120, parentGone: false), .parentDidNotQuit)
    }

    func testFailedStartupNeverReportsHealthSoTheRelauncherRollsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relauncher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PersoUpdateFiles(root: root)
        var health = PersoStartupHealth()
        var timeline = RelauncherTimeline(perso: true, now: 0)
        timeline.parentExited(now: 5)
        timeline.appOpened(now: 6)
        // The new app's launch throws; « Signaler le problème… » keeps the run loop alive afterwards.
        health.startupFailed()
        if health.startupSucceeded() { files.writeHealth(.init(pid: 77, builtAt: "2026-11-26T10:00:00Z")) }
        XCTAssertFalse(files.healthMatches(pid: 77, builtAt: "2026-11-26T10:00:00Z"))
        XCTAssertEqual(timeline.expiry(now: 6 + PersoUpdate.healthTimeout, parentGone: true), .healthTimedOut)
    }
}

/// installation-05 and sparkle-didAbort: the perso swap's guard lease and the update relaunch owner.
final class PersoGuardLeaseTests: XCTestCase {
    private var root: URL!
    private var files: GuardFiles!

    override func setUpWithError() throws {
        root = GuardSystem.realPath(FileManager.default.temporaryDirectory)
            .appendingPathComponent("perso-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        files = GuardFiles(directory: root.appendingPathComponent("Blocking", isDirectory: true))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func input(_ change: (inout GuardInput) -> Void) -> GuardInput {
        var value = GuardInput()
        value.armed = true; value.now = 1_000_000; value.bootTime = 900_000
        change(&value)
        return value
    }

    func testPersoLeaseWaitsOnlyWithItsLiveProofMatchingPidAndWindow() {
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        let lease = GuardLease(pid: 42, reason: GuardLease.persoUpdate, until: 1_000_060, request: "r1")
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease; $0.leaseProofAlive = true }),
                       .waitForLease(until: 1_000_060))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease }), .relaunch(after: 0), "relauncher dead")
        var other = lease; other.pid = 41
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = other; $0.leaseProofAlive = true }), .relaunch(after: 0))
        var long = lease; long.until = 1_000_181
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = long; $0.leaseProofAlive = true }), .relaunch(after: 0))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease; $0.leaseProofAlive = true; $0.leasesInLastHour = 3 }),
                       .relaunch(after: 0), "quota")
        var unknown = lease; unknown.reason = "perso_other"
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = unknown; $0.leaseProofAlive = true }), .relaunch(after: 0))
        // A lease never stops the guard: not armed and no continuity still ends it, an alive app is watched.
        XCTAssertEqual(GuardDecision.decide(input { $0.alivePID = 7; $0.lease = lease; $0.leaseProofAlive = true }), .watch(7))
    }

    func testPersoLeaseProofIsTheRelauncherAtTheInstalledPathOrInItsOwnStage() throws {
        let info: (URL) -> [String: Any]? = { _ in ["CFBundleIdentifier": GuardIdentity.releaseBundleIdentifier, "CFBundleExecutable": "LocalHistory"] }
        let bundle = try XCTUnwrap(GuardBundle(
            guardExecutable: URL(fileURLWithPath: "/Applications/Goalong History.app/Contents/MacOS/goalong-blocking-guard"), info: info))
        let lease = GuardLease(pid: 1, reason: GuardLease.persoUpdate, until: 2, request: "r-1")
        XCTAssertEqual(bundle.proofPaths(for: lease), [
            "/Applications/Goalong History.app/Contents/MacOS/goalong-relauncher",
            "/Applications/.goalong-perso-stage-r-1/Goalong History.app/Contents/MacOS/goalong-relauncher",
        ])
        var noRequest = lease; noRequest.request = nil
        XCTAssertEqual(bundle.proofPaths(for: noRequest), [], "a perso lease without its request proves nothing")
        var bad = lease; bad.request = "../x"
        XCTAssertEqual(bundle.proofPaths(for: bad), [])
        XCTAssertEqual(bundle.proofPaths(for: GuardLease(pid: 1, reason: GuardLease.permissionRestart, until: 2, request: "r-1")),
                       ["/Applications/Goalong History.app/Contents/MacOS/goalong-relauncher"])
        XCTAssertEqual(bundle.proofPaths(for: GuardLease(pid: 1, reason: "other", until: 2)), [])
    }

    func testLaunchKeepsOnlyThePersoLeaseAndTheRelauncherEndsOnlyItsOwn() throws {
        XCTAssertFalse(files.holdPersoLease(pid: 5, request: "r1", now: 100), "guard not armed: no lease")
        XCTAssertTrue(files.writeMarker(until: Date().addingTimeInterval(3600)))
        XCTAssertTrue(files.holdPersoLease(pid: 5, request: "r1", now: 100))
        XCTAssertEqual(files.readLease(), GuardLease(pid: 5, reason: GuardLease.persoUpdate, until: 280, request: "r1"))
        XCTAssertTrue(files.writeRelease(GuardRelease(pid: 5, reason: GuardRelease.userQuit, writtenAt: 1, bootTime: 2)))
        files.clearTokensAtLaunch()
        XCTAssertNil(files.readRelease())
        XCTAssertNotNil(files.readLease(), "the candidate's launch keeps the swap's lease")
        XCTAssertFalse(files.removeLease(reason: GuardLease.update), "Sparkle's abort never ends a perso lease")
        XCTAssertFalse(files.removeLease(reason: GuardLease.persoUpdate, request: "r2"))
        XCTAssertTrue(files.removeLease(reason: GuardLease.persoUpdate, request: "r1"))
        XCTAssertNil(files.readLease())
        XCTAssertTrue(files.writeLease(GuardLease(pid: 5, reason: GuardLease.update, until: 3)))
        files.clearTokensAtLaunch()
        XCTAssertNil(files.readLease(), "other leases still belong to the process that wrote them")
    }

    func testOldLeaseFilesWithoutRequestStillDecode() throws {
        let data = Data(#"{"pid":3,"reason":"update","until":9}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(GuardLease.self, from: data), GuardLease(pid: 3, reason: GuardLease.update, until: 9))
    }

    func testSparkleAbortEndsOnlySparklesOwnRelaunch() {
        var ownership = UpdateRelaunchOwnership()
        XCTAssertFalse(ownership.sparkleAborted())
        ownership.mark(.perso)
        XCTAssertFalse(ownership.sparkleAborted(), "« no update » after a perso swap")
        XCTAssertTrue(ownership.isRelaunching)
        ownership.mark(.sparkle)
        XCTAssertFalse(ownership.sparkleAborted(), "Sparkle never takes over a perso swap")
        var sparkle = UpdateRelaunchOwnership()
        XCTAssertTrue(sparkle.mark(.sparkle))
        XCTAssertFalse(sparkle.mark(.perso), "one installation at a time (L1L2-08)")
        XCTAssertTrue(sparkle.sparkleAborted())
        XCTAssertFalse(sparkle.isRelaunching)
    }

    /// bugs-mise-a-jour-05: a Sparkle cycle already past `mayPerform` would still install after a perso swap.
    func testPersoSwapNeverStartsWhileASparkleCycleIsOpen() {
        var ownership = UpdateRelaunchOwnership()
        XCTAssertFalse(ownership.markPerso(sparkleCycleOpen: true), "Sparkle downloading or waiting: no swap")
        XCTAssertFalse(ownership.isRelaunching, "a refusal takes nothing")
        XCTAssertTrue(ownership.markPerso(sparkleCycleOpen: false))
        XCTAssertEqual(ownership.owner, .perso)
        XCTAssertTrue(ownership.markPerso(sparkleCycleOpen: true), "already the perso swap's own: unchanged")
        var sparkle = UpdateRelaunchOwnership()
        sparkle.mark(.sparkle)
        XCTAssertFalse(sparkle.markPerso(sparkleCycleOpen: false), "one installation at a time (L1L2-08)")
    }
}
