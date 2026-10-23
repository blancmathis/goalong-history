import Darwin
import Foundation
@testable import GoalongGuardCore
import XCTest

/// Real kqueue, real files, real processes: `/bin/sleep` plays the app. Nothing touches launchd,
/// LaunchServices or any Goalong copy; tearDown kills only the processes this test started.
final class GuardEngineIntegrationTests: XCTestCase {
    private final class FakeApp {
        private let lock = NSLock()
        private var processes: [Process] = []
        private(set) var launches: [Date] = []
        var current: Int32? { lock.withLock { processes.last.map { $0.isRunning && GuardProcesses.isAlive($0.processIdentifier) ? $0.processIdentifier : nil } ?? nil } }
        var launchCount: Int { lock.withLock { launches.count } }

        @discardableResult func spawn() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["600"]
            try process.run()
            lock.withLock { processes.append(process) }
            return process.processIdentifier
        }

        /// Counted once the process exists, timed at the call: `launchCount` never runs ahead of `current`.
        func launch(_ completion: @escaping (Int32?, Error?) -> Void) {
            let calledAt = Date()
            do {
                let pid = try spawn()
                lock.withLock { launches.append(calledAt) }
                completion(pid, nil)
            } catch {
                lock.withLock { launches.append(calledAt) }
                completion(nil, error)
            }
        }

        func killAll() { lock.withLock { processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) } } }
    }

    private var root: URL!
    private var files: GuardFiles!
    private var app: FakeApp!
    private var engine: GuardEngine?
    private var exitCode: Int32?
    private let exited = NSLock()
    private var proofAlive = false

    override func setUpWithError() throws {
        root = GuardSystem.realPath(FileManager.default.temporaryDirectory)
            .appendingPathComponent("guard-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        files = GuardFiles(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        app = FakeApp()
    }

    override func tearDownWithError() throws {
        engine?.cancel()
        engine = nil
        app.killAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func startEngine(stopCheck: TimeInterval = 0.3, wall: (() -> Date)? = nil, bootTime: (() -> Double)? = nil,
                             sessionEndWait: TimeInterval? = nil, refusedSessionEndDelay: TimeInterval? = nil) {
        var environment = GuardEnvironment(locateApp: { [app] in app!.current }, launch: { [app] in app!.launch($0) })
        if let wall { environment.wall = wall }
        if let bootTime { environment.bootTime = bootTime }
        if let sessionEndWait { environment.sessionEndWait = sessionEndWait }
        if let refusedSessionEndDelay { environment.refusedSessionEndDelay = refusedSessionEndDelay }
        environment.proofAlive = { [weak self] _ in self?.proofAlive ?? false }
        environment.stopCheckInterval = stopCheck
        environment.retryDelay = 0.05
        environment.build = "test"
        environment.log = { message in if ProcessInfo.processInfo.environment["GUARD_TEST_LOG"] != nil { FileHandle.standardError.write(Data("[guard] \(Date().timeIntervalSince1970) \(message)\n".utf8)) } }
        let engine = GuardEngine(files: files, environment: environment, queue: DispatchQueue(label: "guard-test")) { [weak self] code in
            guard let self else { return }
            self.exited.withLock { self.exitCode = code }
        }
        self.engine = engine
        engine.start()
    }

    private var code: Int32? { exited.withLock { exitCode } }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            usleep(10_000)
        }
        return nil
    }

    private func arm(_ seconds: TimeInterval = 600) { XCTAssertTrue(files.writeMarker(until: Date().addingTimeInterval(seconds))) }

    private func markHealthy(_ pid: Int32) { XCTAssertTrue(files.writeHealth(GuardHealth(pid: pid, at: Date().timeIntervalSince1970))) }

    func testNotArmedExitsZeroAtOnceAndLaunchesNothing() throws {
        try app.spawn()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { code == 0 })
        XCTAssertEqual(app.launchCount, 0)
    }

    func testKillNineIsRelaunchedWithinTwoHundredMilliseconds() throws {
        let first = try app.spawn()
        arm()
        startEngine()
        markHealthy(first)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == first })
        let killedAt = Date()
        kill(first, SIGKILL)
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 })
        guard app.launchCount == 1 else { return }
        XCTAssertLessThan(app.launches[0].timeIntervalSince(killedAt), 0.2)
        let second = try XCTUnwrap(app.current)
        XCTAssertNotEqual(second, first)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == second })
        XCTAssertNil(code)
        markHealthy(second)
        // Killed again and again: it keeps coming back, at least one second apart.
        kill(second, SIGKILL)
        XCTAssertNotNil(waitUntil(3) { app.launchCount == 2 })
        guard app.launchCount == 2 else { return }
        XCTAssertGreaterThanOrEqual(app.launches[1].timeIntervalSince(app.launches[0]), 0.95)
        XCTAssertNotNil(waitUntil(1) { files.readState()?.lastRelaunch != nil })
        XCTAssertEqual(files.readState()?.armed, true)
    }

    func testUserQuitTokenEndsTheGuardWithoutRelaunch() throws {
        let pid = try app.spawn()
        arm()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        XCTAssertTrue(files.writeRelease(GuardRelease(pid: pid, reason: GuardRelease.userQuit,
                                                      writtenAt: Date().timeIntervalSince1970, bootTime: GuardSystem.bootTime())))
        kill(pid, SIGTERM)
        XCTAssertNotNil(waitUntil(1) { code == 0 })
        XCTAssertEqual(app.launchCount, 0)
    }

    func testRemovingTheMarkerWhileTheAppRunsEndsTheGuardQuickly() throws {
        let pid = try app.spawn()
        arm()
        markHealthy(pid)
        startEngine()
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        XCTAssertTrue(files.writeMarker(until: nil))
        let elapsed = waitUntil(1) { code == 0 }
        XCTAssertNotNil(elapsed)
        XCTAssertLessThan(elapsed ?? 1, 0.2)
        XCTAssertEqual(files.readState()?.armed, false)
    }

    func testRemovingTheMarkerWhileTheAppIsDeadChangesNothing() throws {
        let pid = try app.spawn()
        arm()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        // An attacker kills the app and deletes the marker in the same instant.
        kill(pid, SIGKILL)
        XCTAssertTrue(files.writeMarker(until: nil))
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 })
        usleep(300_000)
        XCTAssertNil(code, "the relaunched app has not reported health yet: it cannot disarm")
        // Once healthy, the app is the authority again: its own refresh would rewrite or remove the marker.
        if let pid = app.current { markHealthy(pid) }
        XCTAssertNotNil(waitUntil(1) { code == 0 })
    }

    func testTheEndOfTheBlockEndsTheGuard() throws {
        try app.spawn()
        arm(1.2)
        startEngine()
        XCTAssertNil(code)
        XCTAssertNotNil(waitUntil(4) { code == 0 })
    }

    func testAStoppedAppIsResumed() throws {
        let pid = try app.spawn()
        arm()
        startEngine(stopCheck: 0.3)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        kill(pid, SIGSTOP)
        XCTAssertNotNil(waitUntil(0.5) { GuardProcesses.isStopped(pid) })
        XCTAssertNotNil(waitUntil(3) { !GuardProcesses.isStopped(pid) })
        XCTAssertEqual(app.launchCount, 0)
    }

    func testAPlannedRelaunchIsAwaitedOnlyWhileItsProofLives() throws {
        let pid = try app.spawn()
        arm()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        proofAlive = true
        XCTAssertTrue(files.writeLease(GuardLease(pid: pid, reason: GuardLease.update, until: Date().timeIntervalSince1970 + 1.5)))
        kill(pid, SIGKILL)
        usleep(800_000)
        XCTAssertEqual(app.launchCount, 0, "Sparkle reopens the app itself")
        XCTAssertNotNil(waitUntil(3) { app.launchCount == 1 }, "the lease ran out: the guard relaunches")
    }

    func testAnEarlyDeathLoopBacksOff() throws {
        arm()
        startEngine()
        // No app at start: the guard opens it at once. Each new app dies before reporting health.
        for round in 1...3 {
            XCTAssertNotNil(waitUntil(3) { app.launchCount == round }, "round \(round)")
            // `launches` grows just before the spawn: wait until the guard watches this round's live app,
            // or the kill can miss it and the app of that round survives.
            var watched: Int32?
            XCTAssertNotNil(waitUntil(2) {
                guard let pid = app.current, snapshot()?.watchingPID == pid else { return false }
                watched = pid
                return true
            }, "round \(round) watched")
            if let watched { kill(watched, SIGKILL) }
        }
        usleep(1_500_000)
        XCTAssertEqual(app.launchCount, 3, "three early deaths: 30 s back-off")
        XCTAssertNotNil(waitUntil(1) { files.readState()?.budget == "backoff" })
    }

    /// K1-kill-03: the clock moves forward a day while the healthy app has not rewritten the marker yet.
    func testAClockJumpWithTheAppAliveDoesNotDisarm() throws {
        let pid = try app.spawn()
        arm()
        markHealthy(pid)
        var wallOffset: TimeInterval = 0
        let lock = NSLock()
        startEngine(wall: { lock.withLock { Date().addingTimeInterval(wallOffset) } })
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == pid })
        lock.withLock { wallOffset = 86_400 }
        // Any write in the folder makes the guard read the unchanged marker again (locked-until, the store).
        XCTAssertTrue(files.writeHealth(GuardHealth(pid: pid, at: Date().timeIntervalSince1970)))
        usleep(300_000)
        XCTAssertNil(code, "an unchanged marker keeps its end")
        XCTAssertEqual(snapshot()?.armed, true)
    }

    /// K1-kill-03: guard and app killed, clock moved, then a new guard starts: its predecessor's memory holds.
    func testANewGuardAfterAClockJumpKeepsThePreviousGuardsWindow() throws {
        let pid = try app.spawn()
        arm()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { files.readState()?.endContinuous != nil })
        // The guard is killed (no finish): only its state file remains. The app is killed too.
        let saved = try XCTUnwrap(files.readState())
        engine?.cancel()
        engine = nil
        XCTAssertTrue(files.writeState(saved), "a killed guard leaves its last state, not the armed:false of a clean finish")
        kill(pid, SIGKILL)
        startEngine(wall: { Date().addingTimeInterval(86_400) })
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 }, "the new guard reopens the app")
        XCTAssertNil(code)
    }

    /// K2-kill-04: XNU shifts `kern.boottime` with the clock. The boot session id still names this boot,
    /// so the new guard keeps its predecessor's window.
    func testANewGuardKeepsTheWindowWhenBootTimeMovesWithTheClock() throws {
        let pid = try app.spawn()
        arm()
        startEngine()
        XCTAssertNotNil(waitUntil(1) { files.readState()?.endContinuous != nil })
        let saved = try XCTUnwrap(files.readState())
        XCTAssertEqual(saved.bootSession, GuardSystem.bootSession())
        engine?.cancel()
        engine = nil
        XCTAssertTrue(files.writeState(saved))
        kill(pid, SIGKILL)
        // Clock two hours ahead, boot time shifted by the same amount: the marker (10 min) looks past.
        startEngine(wall: { Date().addingTimeInterval(7200) }, bootTime: { GuardSystem.bootTime() + 7200 })
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 }, "the new guard reopens the app")
        XCTAssertNil(code)
    }

    private func quitForSessionEnd(_ pid: Int32) {
        XCTAssertTrue(files.writeRelease(GuardRelease(pid: pid, reason: GuardRelease.sessionEnd,
                                                      writtenAt: Date().timeIntervalSince1970, bootTime: GuardSystem.bootTime(),
                                                      bootSession: GuardSystem.bootSession())))
        kill(pid, SIGKILL)
    }

    /// K2-kill-02 + K3-safe-01: a logout cancelled by another app gives one session-end wait, not one per
    /// quit. The next one is relaunched after the short refused delay (a real logout may follow a cancelled one).
    func testASecondSessionEndSoonAfterTheFirstIsRelaunchedAfterTheShortDelay() throws {
        let first = try app.spawn()
        arm()
        markHealthy(first)
        startEngine(sessionEndWait: 0.6, refusedSessionEndDelay: 0.3)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == first })
        let firstQuit = Date()
        quitForSessionEnd(first)
        usleep(300_000)
        XCTAssertEqual(app.launchCount, 0, "the first session end is honoured: the guard waits")
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 }, "the session went on: relaunch after the wait")
        guard app.launchCount == 1 else { return }
        XCTAssertGreaterThanOrEqual(app.launches[0].timeIntervalSince(firstQuit), 0.55)
        let second = try XCTUnwrap(app.current)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == second })
        markHealthy(second)
        usleep(1_100_000)  // the healthy-kill spacing (1 s) is not what this test measures
        let secondQuit = Date()
        quitForSessionEnd(second)
        usleep(150_000)
        XCTAssertEqual(app.launchCount, 1, "not at once: loginwindow may be ending the session")
        XCTAssertNotNil(waitUntil(1) { app.launchCount == 2 })
        guard app.launchCount == 2 else { return }
        let delay = app.launches[1].timeIntervalSince(secondQuit)
        XCTAssertGreaterThanOrEqual(delay, 0.25)
        XCTAssertLessThan(delay, 0.55, "the short delay, not a second session-end wait")
        XCTAssertNil(code)
    }

    /// K3-kill-01: killing the guard after an honoured session end does not reset its cooldown.
    func testAGuardRestartedAfterASessionEndKeepsTheCooldown() throws {
        let first = try app.spawn()
        arm()
        markHealthy(first)
        startEngine(sessionEndWait: 0.4, refusedSessionEndDelay: 0.2)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == first })
        quitForSessionEnd(first)
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 1 && app.current != nil })
        let second = try XCTUnwrap(app.current)
        XCTAssertNotNil(waitUntil(1) { files.readState()?.sessionEndContinuous != nil && snapshot()?.watchingPID == second })
        XCTAssertEqual(files.readState()?.sessionEndPID, first)
        // The guard is killed (no finish): only its state file remains. launchd starts a new one.
        let saved = try XCTUnwrap(files.readState())
        engine?.cancel()
        engine = nil
        XCTAssertTrue(files.writeState(saved))
        markHealthy(second)
        startEngine(sessionEndWait: 5, refusedSessionEndDelay: 0.2)
        XCTAssertNotNil(waitUntil(1) { snapshot()?.watchingPID == second })
        let secondQuit = Date()
        quitForSessionEnd(second)
        XCTAssertNotNil(waitUntil(2) { app.launchCount == 2 }, "no new 5 s session-end wait")
        guard app.launchCount == 2 else { return }
        let delay = app.launches[1].timeIntervalSince(secondQuit)
        XCTAssertGreaterThanOrEqual(delay, 0.15, "the refused session end keeps its short delay (0.2 s), not at once")
        XCTAssertLessThan(delay, 1.5)
        XCTAssertNil(code)
    }

    private func snapshot() -> GuardSnapshot? {
        guard let engine else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: GuardSnapshot?
        engine.snapshot { result = $0; semaphore.signal() }
        return semaphore.wait(timeout: .now() + 1) == .success ? result : nil
    }
}
