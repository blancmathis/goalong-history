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

        func launch(_ completion: @escaping (Int32?, Error?) -> Void) {
            lock.withLock { launches.append(Date()) }
            do { completion(try spawn(), nil) } catch { completion(nil, error) }
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

    private func startEngine(stopCheck: TimeInterval = 0.3) {
        var environment = GuardEnvironment(locateApp: { [app] in app!.current }, launch: { [app] in app!.launch($0) })
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
            if let pid = app.current { kill(pid, SIGKILL) }
        }
        usleep(1_500_000)
        XCTAssertEqual(app.launchCount, 3, "three early deaths: 30 s back-off")
        XCTAssertNotNil(waitUntil(1) { files.readState()?.budget == "backoff" })
    }

    private func snapshot() -> GuardSnapshot? {
        guard let engine else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: GuardSnapshot?
        engine.snapshot { result = $0; semaphore.signal() }
        return semaphore.wait(timeout: .now() + 1) == .success ? result : nil
    }
}
