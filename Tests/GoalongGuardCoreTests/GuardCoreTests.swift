import Darwin
import Foundation
@testable import GoalongGuardCore
import LocalHistoryCore
import XCTest

final class GuardDecisionTests: XCTestCase {
    private func input(_ change: (inout GuardInput) -> Void = { _ in }) -> GuardInput {
        var value = GuardInput()
        value.armed = true
        value.now = 1_000_000
        value.bootTime = 900_000
        change(&value)
        return value
    }

    func testNotArmedOrBundleGoneExitsZero() {
        XCTAssertEqual(GuardDecision.decide(input { $0.armed = false }), .exit(0))
        XCTAssertEqual(GuardDecision.decide(input { $0.bundlePresent = false; $0.alivePID = 7 }), .exit(0))
    }

    func testAliveAppIsWatched() {
        XCTAssertEqual(GuardDecision.decide(input { $0.alivePID = 42 }), .watch(42))
    }

    func testDeathWithoutTokenRelaunchesNowOrAfterBudget() {
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: 1_000_000) }), .relaunch(after: 0))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: 1_000_000); $0.budgetDelay = 30 }),
                       .relaunch(after: 30))
    }

    func testUserQuitTokenOfTheDeadPidEndsTheGuard() {
        let release = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 999_998, bootTime: 900_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = .init(pid: 42, at: 1_000_000); $0.release = release }), .exit(0))
    }

    func testTokenOfAnotherPidOrTooOldOrUnknownReasonIsIgnored() {
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        for release in [
            GuardRelease(pid: 41, reason: GuardRelease.userQuit, writtenAt: 999_999, bootTime: 900_000),
            GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 999_980, bootTime: 900_000),
            GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 1_000_005, bootTime: 900_000),
            GuardRelease(pid: 42, reason: "please", writtenAt: 999_999, bootTime: 900_000),
        ] {
            XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release }), .relaunch(after: 0), "\(release)")
        }
    }

    func testAtGuardStartOnlyAUserQuitOfThisBootCounts() {
        let thisBoot = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 950_000, bootTime: 900_000.5)
        XCTAssertEqual(GuardDecision.decide(input { $0.release = thisBoot }), .exit(0))
        let previousBoot = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 850_000, bootTime: 800_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.release = previousBoot }), .relaunch(after: 0))
        let sessionEnd = GuardRelease(pid: 42, reason: GuardRelease.sessionEnd, writtenAt: 950_000, bootTime: 900_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.release = sessionEnd }), .relaunch(after: 0))
    }

    func testSessionEndWaitsThenRelaunchesIfTheGuardStillLives() {
        let release = GuardRelease(pid: 42, reason: GuardRelease.sessionEnd, writtenAt: 999_999, bootTime: 900_000)
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release }), .waitForSessionEnd(30))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release; $0.sessionEndWaitOver = true }),
                       .relaunch(after: 0))
    }

    func testLeaseNeedsItsLiveProofAShortWindowAndAQuota() {
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        let lease = GuardLease(pid: 42, reason: GuardLease.update, until: 1_000_060)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease; $0.leaseProofAlive = true }),
                       .waitForLease(until: 1_000_060))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease }), .relaunch(after: 0), "no proof")
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = lease; $0.leaseProofAlive = true; $0.leasesInLastHour = 3 }),
                       .relaunch(after: 0), "quota")
        var long = lease; long.until = 1_000_000 + 181
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = long; $0.leaseProofAlive = true }), .relaunch(after: 0))
        var other = lease; other.pid = 41
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = other; $0.leaseProofAlive = true }), .relaunch(after: 0))
        var expired = lease; expired.until = 999_999
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.lease = expired; $0.leaseProofAlive = true }), .relaunch(after: 0))
        // Guard replaced by the update itself: no death seen, the live proof alone counts.
        XCTAssertEqual(GuardDecision.decide(input { $0.lease = lease; $0.leaseProofAlive = true }), .waitForLease(until: 1_000_060))
    }

    func testArmingKeepsTheHighestEndWhileTheAppIsDead() {
        let wall = Date(timeIntervalSince1970: 1_000_000)
        var arming = GuardArming()
        arming.apply(.date(wall.addingTimeInterval(600)), wall: wall, continuous: 50, appAlive: true)
        XCTAssertEqual(arming.remaining(continuous: 50), 600)
        arming.apply(.absent, wall: wall, continuous: 60, appAlive: false)
        XCTAssertTrue(arming.isArmed(continuous: 60), "removing the marker while the app is dead changes nothing")
        arming.apply(.date(wall.addingTimeInterval(10)), wall: wall, continuous: 60, appAlive: false)
        XCTAssertEqual(arming.remaining(continuous: 60), 590, "a lower end needs the live app")
        // Moving the wall clock forward a year does not end the block: continuous time decides.
        arming.apply(.invalid, wall: wall.addingTimeInterval(365 * 86_400), continuous: 70, appAlive: false)
        XCTAssertEqual(arming.remaining(continuous: 70), 580)
        arming.apply(.absent, wall: wall, continuous: 80, appAlive: true)
        XCTAssertFalse(arming.isArmed(continuous: 80), "the live app ends the block")
        arming.apply(.invalid, wall: wall, continuous: 90, appAlive: false)
        XCTAssertFalse(arming.isArmed(continuous: 90), "fail open without memory")
        XCTAssertFalse({ var fresh = GuardArming(); fresh.apply(.date(wall), wall: wall, continuous: 1, appAlive: false); return fresh.isArmed(continuous: 1) }())
    }
}

extension GuardDecisionTests {
    /// K1-kill-03: an unchanged marker keeps its end whatever the wall clock does, even from the live app.
    func testAWallClockJumpDoesNotMoveAnUnchangedMarker() {
        let wall = Date(timeIntervalSince1970: 1_000_000)
        let end = wall.addingTimeInterval(7200)
        var arming = GuardArming()
        arming.apply(.date(end), wall: wall, continuous: 100, appAlive: true)
        XCTAssertEqual(arming.remaining(continuous: 100), 7200)
        arming.apply(.date(end), wall: wall.addingTimeInterval(86_400), continuous: 110, appAlive: true)
        XCTAssertEqual(arming.remaining(continuous: 110), 7190, "the healthy app has not rewritten the marker yet")
        arming.apply(.date(end), wall: wall.addingTimeInterval(-86_400), continuous: 120, appAlive: false)
        XCTAssertEqual(arming.remaining(continuous: 120), 7180)
        // The app rewrites the end after the jump: a new value is read against the new wall clock.
        arming.apply(.date(end.addingTimeInterval(86_400)), wall: wall.addingTimeInterval(86_400), continuous: 130, appAlive: true)
        XCTAssertEqual(arming.remaining(continuous: 130), 7200)
        arming.apply(.absent, wall: wall, continuous: 140, appAlive: true)
        XCTAssertNil(arming.markerDate)
    }

    /// K2-kill-02 + K3-safe-01: one honoured session end per cooldown. The next death with a session_end
    /// token is relaunched, but only 5 s after the death: it may be a real logout after a cancelled one.
    func testASessionEndOutsideItsAllowanceIsRelaunchedAfterAShortWait() {
        let release = GuardRelease(pid: 42, reason: GuardRelease.sessionEnd, writtenAt: 999_999, bootTime: 900_000)
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release; $0.sessionEndAllowed = false }),
                       .relaunch(after: 5))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release; $0.sessionEndAllowed = false; $0.sinceDeath = 3 }),
                       .relaunch(after: 2), "the wait counts from the death, not from each evaluation")
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release; $0.sessionEndAllowed = false; $0.sinceDeath = 6 }),
                       .relaunch(after: 0))
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = release; $0.sessionEndAllowed = false; $0.budgetDelay = 30 }),
                       .relaunch(after: 30), "the crash budget still wins")
        XCTAssertEqual(GuardDecision.refusedSessionEndDelay, 5)
        XCTAssertLessThanOrEqual(GuardDecision.refusedSessionEndDelay, 10, "within the §12.3 hole")
        let userQuit = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 999_999, bootTime: 900_000)
        XCTAssertEqual(GuardDecision.decide(input { $0.death = death; $0.release = userQuit; $0.sessionEndAllowed = false }),
                       .exit(0), "a user quit is never limited")
        XCTAssertEqual(GuardDecision.sessionEndCooldown, 600)
    }

    /// K3-safe-01: a real logout after a cancelled one (cooldown running) is never met by a relaunch at
    /// once: every evaluation before the short delay waits, whatever the crash budget says.
    func testARefusedSessionEndNeverRelaunchesBeforeTheShortDelay() {
        let release = GuardRelease(pid: 42, reason: GuardRelease.sessionEnd, writtenAt: 999_999, bootTime: 900_000)
        let death = GuardInput.Death(pid: 42, at: 1_000_000)
        for tenth in 0..<Int(GuardDecision.refusedSessionEndDelay * 10) {
            let since = TimeInterval(tenth) / 10
            for budget in [0.0, 1, 30] {
                let action = GuardDecision.decide(input {
                    $0.death = death; $0.release = release; $0.sessionEndAllowed = false
                    $0.sinceDeath = since; $0.budgetDelay = budget
                })
                guard case .relaunch(let after) = action else { return XCTFail("\(action) at \(since) s") }
                XCTAssertGreaterThan(after, 0, "no relaunch at once \(since) s after a session_end death")
                XCTAssertGreaterThanOrEqual(since + after, GuardDecision.refusedSessionEndDelay - 1e-9)
            }
        }
    }

    /// K3-kill-01: the cooldown counts from the last honoured session_end, restored or not; the honoured
    /// death itself keeps its wait.
    func testTheSessionEndCooldownAllowsOneWaitPerTenMinutes() {
        XCTAssertTrue(GuardDecision.sessionEndAllowed(lastHonoured: nil, deathPID: 42, deathContinuous: 100))
        XCTAssertTrue(GuardDecision.sessionEndAllowed(lastHonoured: (42, 100), deathPID: 42, deathContinuous: 100))
        XCTAssertFalse(GuardDecision.sessionEndAllowed(lastHonoured: (42, 100), deathPID: 43, deathContinuous: 160))
        XCTAssertFalse(GuardDecision.sessionEndAllowed(lastHonoured: (42, 100), deathPID: 43, deathContinuous: 699))
        XCTAssertTrue(GuardDecision.sessionEndAllowed(lastHonoured: (42, 100), deathPID: 43, deathContinuous: 700))
        // A new guard (kill -9 of the old one) starts from the state file: the same answer.
        let state = GuardState(build: "b", armed: true, bootTime: 42, bootSession: "A", sessionEndPID: 42, sessionEndContinuous: 100)
        let restored = GuardDecision.restoredSessionEnd(from: state, bootTime: 42, bootSession: "A", continuous: 160)
        XCTAssertFalse(GuardDecision.sessionEndAllowed(lastHonoured: restored, deathPID: 43, deathContinuous: 160))
    }

    /// K3-kill-01: the session_end cooldown survives a guard restart of the same boot, and only while it runs.
    func testTheSessionEndCooldownIsRestoredFromTheGuardState() {
        let state = GuardState(build: "b", armed: true, bootTime: 42, bootSession: "A", sessionEndPID: 7, sessionEndContinuous: 1000)
        let restored = GuardDecision.restoredSessionEnd(from: state, bootTime: 42 + 3600, bootSession: "A", continuous: 1200)
        XCTAssertEqual(restored?.pid, 7)
        XCTAssertEqual(restored?.at, 1000)
        XCTAssertNil(GuardDecision.restoredSessionEnd(from: state, bootTime: 42, bootSession: "B", continuous: 1200), "another boot")
        XCTAssertNil(GuardDecision.restoredSessionEnd(from: state, bootTime: 42, bootSession: "A", continuous: 1600), "cooldown over")
        XCTAssertNil(GuardDecision.restoredSessionEnd(from: state, bootTime: 42, bootSession: "A", continuous: 900), "in the future")
        XCTAssertNil(GuardDecision.restoredSessionEnd(from: GuardState(build: "b", armed: true, bootTime: 42, bootSession: "A"),
                                                      bootTime: 42, bootSession: "A", continuous: 1200))
        XCTAssertNil(GuardDecision.restoredSessionEnd(from: nil, bootTime: 42, bootSession: "A", continuous: 1200))
    }

    /// K2-kill-04: the boot session id decides; boot times only when one side lacks it.
    func testTheBootSessionIdNamesTheBootWhateverTheClockDoes() {
        XCTAssertTrue(GuardDecision.sameBoot(42, "A", 7242, "A"), "boot time shifted by a clock change")
        XCTAssertFalse(GuardDecision.sameBoot(42, "A", 42, "B"), "another boot at the same second")
        XCTAssertTrue(GuardDecision.sameBoot(42, nil, 42.5, "B"), "older file: boot time fallback")
        XCTAssertFalse(GuardDecision.sameBoot(42, "", 900, "B"))
        let state = GuardState(build: "b", armed: true, endContinuous: 500, markerDate: 1_000_000, bootTime: 42, bootSession: "A")
        XCTAssertNotNil(GuardArming.restored(from: state, bootTime: 42 + 7200, bootSession: "A", continuous: 100))
        XCTAssertNil(GuardArming.restored(from: state, bootTime: 42, bootSession: "B", continuous: 100))
        let token = GuardRelease(pid: 42, reason: GuardRelease.userQuit, writtenAt: 950_000, bootTime: 900_000, bootSession: "A")
        XCTAssertEqual(GuardDecision.decide(input { $0.release = token; $0.bootTime = 907_200; $0.bootSession = "A" }), .exit(0))
        XCTAssertEqual(GuardDecision.decide(input { $0.release = token; $0.bootSession = "B" }), .relaunch(after: 0))
        let session = GuardSystem.bootSession()
        XCTAssertEqual(session.count, 36, "kern.bootsessionuuid is a UUID")
        XCTAssertEqual(session, GuardSystem.bootSession())
    }

    /// K2-kill-03: the app's SIGSTOP check of its guard runs on its own timer, only while active.
    func testAPeriodicCheckRunsOnlyWhileActive() {
        let counter = Counter()
        let check = GuardPeriodicCheck(queue: DispatchQueue(label: "periodic-test"), interval: 0.05) { counter.add() }
        XCTAssertFalse(check.isActive)
        check.setActive(true)
        check.setActive(true)
        XCTAssertTrue(check.isActive)
        usleep(400_000)
        XCTAssertGreaterThanOrEqual(counter.value, 3)
        check.setActive(false)
        XCTAssertFalse(check.isActive)
        let stopped = counter.value
        usleep(200_000)
        XCTAssertEqual(counter.value, stopped)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    func testAPreviousGuardsMemoryIsRestoredOnlyForThisBootAndAFutureEnd() {
        let state = GuardState(build: "b", armed: true, endContinuous: 500, markerDate: 1_000_000, bootTime: 42)
        XCTAssertEqual(GuardArming.restored(from: state, bootTime: 42.5, continuous: 100),
                       GuardArming(endContinuous: 500, markerDate: Date(timeIntervalSince1970: 1_000_000)))
        XCTAssertNil(GuardArming.restored(from: state, bootTime: 900, continuous: 100), "another boot")
        XCTAssertNil(GuardArming.restored(from: state, bootTime: 42, continuous: 600), "already over")
        XCTAssertNil(GuardArming.restored(from: GuardState(build: "b", armed: false), bootTime: 42, continuous: 100))
        XCTAssertNil(GuardArming.restored(from: nil, bootTime: 42, continuous: 100))
        var far = state; far.endContinuous = 100 + GuardFiles.maximumArming + 1
        XCTAssertNil(GuardArming.restored(from: far, bootTime: 42, continuous: 100))
    }
}

final class RelaunchBudgetTests: XCTestCase {
    func testHealthyKillsComeBackOneSecondApartForever() {
        var budget = RelaunchBudget()
        for index in 0..<50 {
            let now = Double(index) * 5
            budget.recordDeath(healthy: true, lifetime: 5)
            XCTAssertEqual(budget.delay(at: now), 0)
            budget.recordRelaunch(at: now)
            XCTAssertEqual(budget.delay(at: now + 0.4), 0.6, accuracy: 1e-9)
        }
        XCTAssertEqual(budget.label, "normal")
    }

    func testEarlyDeathsBackOffThenSlowDownButNeverStop() {
        var budget = RelaunchBudget()
        for _ in 0..<3 { budget.recordDeath(healthy: false, lifetime: 0.5) }
        XCTAssertEqual(budget.spacing, 30); XCTAssertEqual(budget.label, "backoff")
        XCTAssertEqual(budget.delay(at: 100), 30)
        budget.recordRelaunch(at: 100)
        XCTAssertEqual(budget.delay(at: 110), 20, accuracy: 1e-9)
        for _ in 0..<7 { budget.recordDeath(healthy: false, lifetime: 0.5) }
        XCTAssertEqual(budget.spacing, 120); XCTAssertEqual(budget.label, "slow")
        budget.recordDeath(healthy: true, lifetime: 30)
        XCTAssertEqual(budget.spacing, 120, "a short healthy life forgives nothing")
        budget.recordDeath(healthy: true, lifetime: 121)
        XCTAssertEqual(budget.spacing, 1)
        for _ in 0..<5 { budget.recordDeath(healthy: false, lifetime: nil) }
        budget.recordHealthyLife()
        XCTAssertEqual(budget.label, "normal")
    }
}

final class GuardFilesTests: XCTestCase {
    private var root: URL!
    private var files: GuardFiles!

    override func setUpWithError() throws {
        root = GuardSystem.realPath(FileManager.default.temporaryDirectory)
            .appendingPathComponent("guard-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        files = GuardFiles(directory: root.appendingPathComponent("Blocking", isDirectory: true))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var until: URL { files.directory.appendingPathComponent(GuardFiles.until) }

    func testMarkerRoundTripAndRemoval() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(files.readMarker(now: now), .absent)
        XCTAssertFalse(files.markerExists())
        XCTAssertTrue(files.writeMarker(until: now.addingTimeInterval(3600.2)))
        XCTAssertEqual(try String(contentsOf: until), "1800003601\n")
        XCTAssertEqual(files.readMarker(now: now), .date(Date(timeIntervalSince1970: 1_800_003_601)))
        let mode = try FileManager.default.attributesOfItem(atPath: until.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(files.markerExists())
        XCTAssertTrue(files.writeMarker(until: nil))
        XCTAssertEqual(files.readMarker(now: now), .absent)
    }

    func testCorruptHugeFarSymlinkedOrOpenMarkersArmNothing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(files.writeMarker(until: now))
        for content in ["abc\n", "", "12345678901234567\n", "-5\n", "\(1_800_000_000 + 401 * 86_400)\n"] {
            try Data(content.utf8).write(to: until)
            chmod(until.path, 0o600)
            XCTAssertEqual(files.readMarker(now: now), .invalid, content)
        }
        try Data("1800000100\n".utf8).write(to: until)
        chmod(until.path, 0o644)
        XCTAssertEqual(files.readMarker(now: now), .invalid, "group-readable file")
        try FileManager.default.removeItem(at: until)
        let target = root.appendingPathComponent("target")
        try Data("1800000100\n".utf8).write(to: target)
        chmod(target.path, 0o600)
        try FileManager.default.createSymbolicLink(at: until, withDestinationURL: target)
        XCTAssertEqual(files.readMarker(now: now), .invalid, "symlink")
        XCTAssertFalse(files.writeMarker(until: now), "never writes through a link")
    }

    func testTokensRoundTripAndAreClearedTogether() {
        let release = GuardRelease(pid: 9, reason: GuardRelease.userQuit, writtenAt: 1, bootTime: 2)
        let lease = GuardLease(pid: 9, reason: GuardLease.update, until: 3)
        XCTAssertTrue(files.writeRelease(release)); XCTAssertTrue(files.writeLease(lease))
        XCTAssertTrue(files.writeHealth(GuardHealth(pid: 9, at: 4)))
        XCTAssertEqual(files.readRelease(), release); XCTAssertEqual(files.readLease(), lease)
        XCTAssertEqual(files.readHealth(), GuardHealth(pid: 9, at: 4))
        files.clearTokens()
        XCTAssertNil(files.readRelease()); XCTAssertNil(files.readLease())
        XCTAssertNotNil(files.readHealth())
    }

    func testStateIsNeverWrittenIntoAMissingFolder() {
        let missing = GuardFiles(directory: root.appendingPathComponent("absent/Blocking", isDirectory: true))
        XCTAssertFalse(missing.writeState(GuardState(build: "1", armed: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }

    func testSystemClocks() {
        XCTAssertGreaterThan(GuardSystem.bootTime(), 1_500_000_000)
        XCTAssertLessThan(GuardSystem.bootTime(), Date().timeIntervalSince1970)
        let first = GuardSystem.continuousSeconds()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(GuardSystem.continuousSeconds(), first)
    }
}

final class GuardIdentityTests: XCTestCase {
    func testIdentitiesMatchTheAppFamilyAndItsDataFolders() throws {
        XCTAssertEqual(GuardIdentity.releaseBundleIdentifier, GoalongBundleIdentity.release)
        XCTAssertEqual(GuardIdentity.developmentBundleIdentifier, GoalongBundleIdentity.development)
        XCTAssertEqual(GuardIdentity.channelKey, GoalongBuildChannel.channelKey)
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        let release = try XCTUnwrap(GuardIdentity(bundleIdentifier: GoalongBundleIdentity.release))
        XCTAssertEqual(release.dataRoot(base: base), GoalongBuildChannel(info: [:]).dataRoot(base: base))
        XCTAssertEqual(release.label, "ai.goalong.localhistory.blocking-guard")
        XCTAssertEqual(release.plistName, "ai.goalong.localhistory.blocking-guard.plist")
        let dev = try XCTUnwrap(GuardIdentity(bundleIdentifier: GoalongBundleIdentity.development, channel: "dev"))
        XCTAssertEqual(dev.dataRoot(base: base), GoalongBuildChannel(info: ["GoalongBuildChannel": "dev"]).dataRoot(base: base))
        XCTAssertEqual(dev.blockingDirectory(base: base).path, "/Users/x/Library/Application Support/LocalHistory-Dev/Blocking")
        XCTAssertNotEqual(dev.label, release.label)
        XCTAssertNil(GuardIdentity(bundleIdentifier: GoalongBundleIdentity.development), "dev id without the dev channel")
        XCTAssertNil(GuardIdentity(bundleIdentifier: GoalongBundleIdentity.release, channel: "dev"))
        XCTAssertNil(GuardIdentity(bundleIdentifier: "com.getcoldturkey.blocker"))
        XCTAssertNil(GuardIdentity(bundleIdentifier: nil))
    }

    func testBundleIsDerivedFromTheGuardsOwnPathOnly() throws {
        let info: (URL) -> [String: Any]? = { url in
            url.path == "/Applications/Goalong History.app/Contents/Info.plist"
                ? ["CFBundleIdentifier": GoalongBundleIdentity.release, "CFBundleExecutable": "LocalHistory"] : nil
        }
        let bundle = try XCTUnwrap(GuardBundle(
            guardExecutable: URL(fileURLWithPath: "/Applications/Goalong History.app/Contents/MacOS/goalong-blocking-guard"), info: info))
        XCTAssertEqual(bundle.appExecutable.path, "/Applications/Goalong History.app/Contents/MacOS/LocalHistory")
        XCTAssertEqual(bundle.proofPath(for: GuardLease.permissionRestart), "/Applications/Goalong History.app/Contents/MacOS/goalong-relauncher")
        XCTAssertEqual(bundle.proofPath(for: GuardLease.update),
                       "/Applications/Goalong History.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate")
        XCTAssertNil(bundle.proofPath(for: "other"))
        XCTAssertNil(GuardBundle(guardExecutable: URL(fileURLWithPath: "/Applications/Goalong History.app/Contents/MacOS/other"), info: info))
        XCTAssertNil(GuardBundle(guardExecutable: URL(fileURLWithPath: "/tmp/goalong-blocking-guard"), info: info))
        XCTAssertNil(GuardBundle(
            guardExecutable: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Goalong History.app/Contents/MacOS/goalong-blocking-guard"),
            info: { _ in ["CFBundleIdentifier": GoalongBundleIdentity.release, "CFBundleExecutable": "LocalHistory"] }))
    }
}
