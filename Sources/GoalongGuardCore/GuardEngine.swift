import Darwin
import Foundation

/// Everything the engine touches outside its own files. The real guard wires Darwin and NSWorkspace;
/// tests wire a fake app (`/bin/sleep`) and a temporary data root.
public struct GuardEnvironment {
    /// Pid of this copy's app when it runs (exact executable path, never a name or a bundle id alone).
    public var locateApp: () -> Int32?
    /// Opens this copy's app hidden; reports the new pid or an error.
    public var launch: (@escaping (Int32?, Error?) -> Void) -> Void
    public var wall: () -> Date = Date.init
    public var continuous: () -> TimeInterval = GuardSystem.continuousSeconds
    public var isAlive: (Int32) -> Bool = GuardProcesses.isAlive
    public var isStopped: (Int32) -> Bool = GuardProcesses.isStopped
    public var resume: (Int32) -> Void = { _ = kill($0, SIGCONT) }
    /// The proof process of a lease reason is alive (Autoupdate or goalong-relauncher of this bundle).
    public var proofAlive: (String) -> Bool = { _ in false }
    /// False once the app bundle is gone (Info.plist missing): the guard ends for good.
    public var bundlePresent: () -> Bool = { true }
    /// True when the guard's own executable was replaced (update): exit 75 so launchd starts the new one.
    public var binaryReplaced: () -> Bool = { false }
    public var bootTime: () -> Double = GuardSystem.bootTime
    public var bootSession: () -> String = GuardSystem.bootSession
    public var log: (String) -> Void = { _ in }
    public var build: String = "unknown"
    /// Delay before a retry when LaunchServices still returns the dying instance (relauncher model).
    public var retryDelay: TimeInterval = 0.35
    /// Interval of the SIGSTOP check while the app runs.
    public var stopCheckInterval: TimeInterval = 2
    /// Wait after an honoured `session_end` (tests shorten it).
    public var sessionEndWait: TimeInterval = GuardDecision.sessionEndWait
    /// Wait before the relaunch after a `session_end` refused by the cooldown (tests shorten it).
    public var refusedSessionEndDelay: TimeInterval = GuardDecision.refusedSessionEndDelay

    public init(locateApp: @escaping () -> Int32?, launch: @escaping (@escaping (Int32?, Error?) -> Void) -> Void) {
        self.locateApp = locateApp; self.launch = launch
    }
}

/// Snapshot answered to the app's wake-up ping.
public struct GuardSnapshot: Equatable, Sendable {
    public var build: String
    public var armed: Bool
    public var watchingPID: Int32?
    public var state: String
}

/// Event loop of the guard: kqueue exit watch on the app, file watch on `Blocking/`, timers only while armed.
public final class GuardEngine {
    public let files: GuardFiles
    public let queue: DispatchQueue
    private var environment: GuardEnvironment
    private var onFinish: ((Int32) -> Void)?

    private var arming = GuardArming()
    private var budget = RelaunchBudget()
    private var watchedPID: Int32?
    private var watchedSince: TimeInterval = 0
    private var exitSource: DispatchSourceProcess?
    private var directorySource: DispatchSourceFileSystemObject?
    private var stopTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
    private var wake: DispatchWorkItem?
    private var death: GuardInput.Death?
    private var deathContinuous: TimeInterval = 0
    /// Wall time of the last death, until the relaunched app reports health (M1 gap).
    private var gapStart: Double?
    private var gapMs: Int?
    private var lastRelaunch: Double?
    private var relaunching = false
    private var leaseTimes: [TimeInterval] = []
    private var leaseHonoured = false
    /// Last honoured `session_end`: the dead pid and the continuous time of that death.
    private var sessionEndHonoured: (pid: Int32, at: TimeInterval)?
    private var finished = false
    private var lastState: GuardState?
    private var started = false

    public init(files: GuardFiles, environment: GuardEnvironment, queue: DispatchQueue = .main,
                onFinish: @escaping (Int32) -> Void) {
        self.files = files; self.environment = environment; self.queue = queue; self.onFinish = onFinish
    }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            // A previous guard process of this boot was killed while armed: keep its memory (clock changes).
            if let memory = GuardArming.restored(from: files.readState(), bootTime: environment.bootTime(),
                                                 bootSession: environment.bootSession(),
                                                 continuous: environment.continuous()) {
                arming = memory
                environment.log("armed window restored from the previous guard")
            }
            // Its session_end cooldown too: killing the guard must not reopen a 30 s hole.
            sessionEndHonoured = GuardDecision.restoredSessionEnd(from: files.readState(), bootTime: environment.bootTime(),
                                                                  bootSession: environment.bootSession(),
                                                                  continuous: environment.continuous())
            watchDirectory(); evaluate()
        }
    }
    /// Stops every source without calling `onFinish` (tests, shutdown).
    public func cancel() { queue.sync { [self] in onFinish = nil; finish(0) } }
    /// Wake-up from the app's ping or a workspace launch notification: re-read everything.
    public func poke() { queue.async { [self] in evaluate() } }
    public func snapshot(_ reply: @escaping (GuardSnapshot) -> Void) {
        queue.async { [self] in
            let armed = arming.isArmed(continuous: environment.continuous())
            reply(GuardSnapshot(build: environment.build, armed: armed, watchingPID: watchedPID,
                                state: finished ? "finished" : !armed ? "idle" : watchedPID != nil ? "watching" : "relaunching"))
        }
    }

    // MARK: Decision loop

    private func evaluate() {
        guard !finished else { return }
        if environment.binaryReplaced() { environment.log("guard binary replaced: exit 75"); return finish(GuardIdentity.replacedExitCode) }
        let wall = environment.wall(), continuous = environment.continuous()
        // A kill and a marker change can land together: settle the death first, so a marker removed by
        // whoever killed the app is never read as the live app's decision.
        if let pid = watchedPID, !environment.isAlive(pid) { return appDied(pid) }
        if watchedPID == nil, !relaunching, let pid = environment.locateApp(), pid != death?.pid { startWatching(pid) }
        // The app speaks for the block only once it has reported health: its blocking runtime then has
        // already rewritten the marker. A freshly relaunched app cannot disarm by not having written it yet.
        let appSpeaks = watchedPID.map { pid in files.readHealth()?.pid == pid } ?? false
        arming.apply(files.readMarker(now: wall), wall: wall, continuous: continuous, appAlive: appSpeaks)
        noteHealth()
        var input = GuardInput()
        input.bundlePresent = environment.bundlePresent()
        input.armed = arming.isArmed(continuous: continuous)
        input.alivePID = watchedPID
        input.death = death
        input.release = death == nil && watchedPID != nil ? nil : files.readRelease()
        input.lease = watchedPID != nil ? nil : files.readLease()
        if let lease = input.lease { input.leaseProofAlive = environment.proofAlive(lease.reason) }
        leaseTimes.removeAll { continuous - $0 >= 3600 }
        input.leasesInLastHour = leaseTimes.count - (leaseHonoured ? 1 : 0)
        input.sessionEndWaitOver = death != nil && continuous - deathContinuous >= environment.sessionEndWait
        input.sessionEndAllowed = GuardDecision.sessionEndAllowed(lastHonoured: sessionEndHonoured, deathPID: death?.pid,
                                                                  deathContinuous: deathContinuous)
        input.sinceDeath = death == nil ? 0 : continuous - deathContinuous
        input.refusedSessionEndDelay = environment.refusedSessionEndDelay
        input.budgetDelay = budget.delay(at: continuous)
        input.bootTime = environment.bootTime()
        input.bootSession = environment.bootSession()
        input.now = wall.timeIntervalSince1970
        let action = GuardDecision.decide(input)
        switch action {
        case .exit(let code):
            environment.log(input.armed ? "app quit with a release token: guard ends" : "not armed: guard ends")
            return finish(code)
        case .watch:
            cancelWake(); stopPolling(); scheduleStopCheck(); scheduleEnd(continuous: continuous)
        case .relaunch(let delay):
            startPolling()
            if delay <= 0 { relaunch() } else { scheduleWake(after: delay) }
        case .waitForSessionEnd:
            if let pid = death?.pid, sessionEndHonoured?.pid != pid {
                sessionEndHonoured = (pid, deathContinuous)
                environment.log("session end announced: waiting \(environment.sessionEndWait) s")
            }
            startPolling()
            scheduleWake(after: deathContinuous + environment.sessionEndWait - continuous)
        case .waitForLease(let until):
            if !leaseHonoured { leaseHonoured = true; leaseTimes.append(continuous); environment.log("waiting for a planned relaunch") }
            startPolling()
            scheduleWake(after: until - wall.timeIntervalSince1970)
        }
        writeState(armed: input.armed)
    }

    private func startWatching(_ pid: Int32) {
        exitSource?.cancel()
        watchedPID = pid
        watchedSince = environment.continuous()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.appDied(pid) }
        exitSource = source
        source.activate()
        // Registered after a death that already happened: kqueue would never fire.
        if !environment.isAlive(pid) { appDied(pid) }
    }

    private func appDied(_ pid: Int32) {
        guard pid == watchedPID, !finished else { return }
        exitSource?.cancel(); exitSource = nil
        stopTimer?.cancel(); stopTimer = nil
        let wall = environment.wall(), continuous = environment.continuous()
        let healthy = files.readHealth()?.pid == pid
        budget.recordDeath(healthy: healthy, lifetime: continuous - watchedSince)
        watchedPID = nil
        death = GuardInput.Death(pid: pid, at: wall.timeIntervalSince1970)
        deathContinuous = continuous
        leaseHonoured = false
        gapStart = wall.timeIntervalSince1970
        environment.log("app \(pid) ended (healthy: \(healthy))")
        evaluate()
    }

    private func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        attemptLaunch(attempt: 0)
    }

    private func attemptLaunch(attempt: Int) {
        let dead = death?.pid
        environment.launch { [weak self] pid, error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if error == nil, let pid, pid > 0, pid != dead, self.environment.isAlive(pid) {
                    self.relaunching = false
                    self.budget.recordRelaunch(at: self.environment.continuous())
                    self.lastRelaunch = self.environment.wall().timeIntervalSince1970
                    self.death = nil
                    self.environment.log("app relaunched as \(pid)")
                    self.startWatching(pid)
                    self.evaluate()
                } else if attempt < 2 {
                    self.queue.asyncAfter(deadline: .now() + self.environment.retryDelay) { self.attemptLaunch(attempt: attempt + 1) }
                } else {
                    self.relaunching = false
                    self.budget.recordRelaunch(at: self.environment.continuous())
                    self.budget.recordDeath(healthy: false, lifetime: nil)
                    self.environment.log("relaunch failed 3 times: \(error.map { String(describing: $0) } ?? "no live process")")
                    self.evaluate()
                }
            }
        }
    }

    /// Records the M1 gap and forgives early deaths once the app has been healthy long enough.
    private func noteHealth() {
        guard let pid = watchedPID, let health = files.readHealth(), health.pid == pid else { return }
        if let start = gapStart {
            gapMs = max(0, Int(((health.at - start) * 1000).rounded()))
            gapStart = nil
        }
        if environment.continuous() - watchedSince >= RelaunchBudget.healthyReset { budget.recordHealthyLife() }
    }

    // MARK: Timers and sources

    private func watchDirectory() {
        directorySource?.cancel(); directorySource = nil
        let fd = open(files.directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let mask = source?.data, !mask.isDisjoint(with: [.delete, .rename]) { self.watchDirectory() }
            self.evaluate()
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.activate()
    }

    private func scheduleStopCheck() {
        guard stopTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = environment.stopCheckInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 500)))
        timer.setEventHandler { [weak self] in
            guard let self, let pid = self.watchedPID else { return }
            if self.environment.isStopped(pid) { self.environment.log("app \(pid) was stopped: resumed"); self.environment.resume(pid) }
            // Timers pause during sleep: the continuous clock decides whether the block is over.
            if !self.arming.isArmed(continuous: self.environment.continuous()) { self.evaluate() } else { self.noteHealth() }
        }
        stopTimer = timer
        timer.activate()
    }

    private func scheduleEnd(continuous: TimeInterval) {
        guard let remaining = arming.remaining(continuous: continuous) else { return }
        scheduleWake(after: remaining + 0.05)
    }

    private func scheduleWake(after delay: TimeInterval) {
        wake?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.wake = nil; self?.evaluate() }
        wake = item
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
    }

    private func cancelWake() { wake?.cancel(); wake = nil }

    /// While the app is dead and the block armed: notices a manual or planned relaunch within a second.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.evaluate() }
        pollTimer = timer
        timer.activate()
    }

    private func stopPolling() { pollTimer?.cancel(); pollTimer = nil }

    private func writeState(armed: Bool) {
        var state = GuardState(build: environment.build, armed: armed, lastRelaunch: lastRelaunch, gapMs: gapMs, budget: budget.label)
        if armed, !finished, let end = arming.endContinuous {
            state.endContinuous = end
            state.markerDate = arming.markerDate?.timeIntervalSince1970
        }
        if let honoured = sessionEndHonoured {
            state.sessionEndPID = honoured.pid
            state.sessionEndContinuous = honoured.at
        }
        if state.endContinuous != nil || state.sessionEndContinuous != nil {
            state.bootTime = environment.bootTime()
            let session = environment.bootSession()
            state.bootSession = session.isEmpty ? nil : session
        }
        guard state != lastState else { return }
        lastState = state
        files.writeState(state)
    }

    private func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        exitSource?.cancel(); exitSource = nil
        directorySource?.cancel(); directorySource = nil
        stopTimer?.cancel(); stopTimer = nil
        stopPolling(); cancelWake()
        writeState(armed: false)
        let handler = onFinish; onFinish = nil
        handler?(code)
    }
}

/// Darwin process facts, by pid or exact executable path. Never by name.
public enum GuardProcesses {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    public static func isStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    public static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Pids whose executable is exactly `path` (resolved), excluding `excluding`.
    public static func pids(executable: String, excluding: Int32 = getpid()) -> [Int32] {
        let wanted = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { pid in
            pid > 0 && pid != excluding && (path(of: pid).map { $0 == wanted || $0 == executable } ?? false) && isAlive(pid)
        }
    }
}

/// A repeating check on its own queue, on only while asked (the app's SIGSTOP check of its guard while
/// armed). `setActive` may be called from any thread; the timer lives on `queue`.
public final class GuardPeriodicCheck: @unchecked Sendable {
    public let interval: TimeInterval
    private let queue: DispatchQueue
    private let check: @Sendable () -> Void
    /// Touched on `queue` only.
    private var timer: DispatchSourceTimer?

    public init(queue: DispatchQueue, interval: TimeInterval, check: @escaping @Sendable () -> Void) {
        self.queue = queue; self.interval = interval; self.check = check
    }

    deinit { timer?.cancel() }

    public func setActive(_ active: Bool) {
        queue.async { [self] in
            if active {
                guard timer == nil else { return }
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 500)))
                source.setEventHandler { [check] in check() }
                timer = source
                source.activate()
            } else {
                timer?.cancel(); timer = nil
            }
        }
    }

    public var isActive: Bool { queue.sync { timer != nil } }
}
