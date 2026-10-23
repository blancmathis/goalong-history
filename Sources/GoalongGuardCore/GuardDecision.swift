import Foundation

/// End of the armed window, kept in continuous time so changing the Mac's clock changes nothing.
/// Only the running app may lower or remove it: it is the one that decides (timer, password).
public struct GuardArming: Equatable, Sendable {
    /// `mach_continuous_time` seconds at which the block ends; nil when nothing is armed.
    public private(set) var endContinuous: TimeInterval?
    /// The marker value that set `endContinuous`. Read again unchanged, it keeps the end: a wall clock
    /// jump between two reads of the same file can neither end nor stretch the block.
    public private(set) var markerDate: Date?

    public init(endContinuous: TimeInterval? = nil, markerDate: Date? = nil) {
        self.endContinuous = endContinuous; self.markerDate = markerDate
    }

    /// Applies one read of `guard-until`. A higher end always wins; a lower, removed or unreadable
    /// marker is accepted only while the app is alive. Without any memory, an unreadable marker arms nothing.
    public mutating func apply(_ marker: GuardMarker, wall: Date, continuous: TimeInterval, appAlive: Bool) {
        switch marker {
        case .date(let date):
            if endContinuous != nil, date == markerDate { return }
            let end = continuous + date.timeIntervalSince(wall)
            if appAlive || endContinuous.map({ end > $0 }) ?? true { endContinuous = end; markerDate = date }
        case .absent, .invalid:
            if appAlive || endContinuous == nil { endContinuous = nil; markerDate = nil }
        }
    }

    /// Memory of a previous guard process of this boot (`guard-state.json`), when it still lies ahead.
    /// The boot is named by `kern.bootsessionuuid` when both sides have it: a clock change shifts
    /// `kern.boottime` by the same amount and must not erase the memory.
    public static func restored(from state: GuardState?, bootTime: Double, bootSession: String = "",
                                continuous: TimeInterval) -> GuardArming? {
        guard let state, let end = state.endContinuous, let boot = state.bootTime,
              GuardDecision.sameBoot(boot, state.bootSession, bootTime, bootSession),
              end > continuous, end <= continuous + GuardFiles.maximumArming
        else { return nil }
        return GuardArming(endContinuous: end, markerDate: state.markerDate.map { Date(timeIntervalSince1970: $0) })
    }

    public func isArmed(continuous: TimeInterval) -> Bool { endContinuous.map { $0 > continuous } ?? false }
    public func remaining(continuous: TimeInterval) -> TimeInterval? {
        guard let endContinuous, endContinuous > continuous else { return nil }
        return endContinuous - continuous
    }
}

/// What the guard knows when it decides. Times are Unix seconds unless named `continuous`.
public struct GuardInput: Equatable, Sendable {
    public var bundlePresent = true
    public var armed = false
    /// The app's pid when it runs.
    public var alivePID: Int32?
    /// The app's last observed death; nil at the guard's own start (no death seen).
    public var death: Death?
    public var release: GuardRelease?
    public var lease: GuardLease?
    /// The lease's proof process (Autoupdate or goalong-relauncher of this bundle) is alive.
    public var leaseProofAlive = false
    /// Leases already honoured in the last hour.
    public var leasesInLastHour = 0
    /// The 30 s session-end wait for this death is over and the guard still lives.
    public var sessionEndWaitOver = false
    /// False when another death's `session_end` was honoured less than `sessionEndCooldown` ago: a logout
    /// cancelled by another app must not open a 30 s hole again and again.
    public var sessionEndAllowed = true
    /// Delay the relaunch budget imposes, in seconds from now.
    public var budgetDelay: TimeInterval = 0
    public var bootTime: Double = 0
    public var bootSession = ""
    public var now: Double = 0

    public struct Death: Equatable, Sendable {
        public var pid: Int32
        public var at: Double
        public init(pid: Int32, at: Double) { self.pid = pid; self.at = at }
    }

    public init() {}
}

public enum GuardAction: Equatable, Sendable {
    case exit(Int32)
    case watch(Int32)
    /// Relaunch after this many seconds (0 = now).
    case relaunch(after: TimeInterval)
    /// A logout or shutdown is under way: wait for the guard's own end, then decide again.
    case waitForSessionEnd(TimeInterval)
    /// Sparkle or the relauncher will reopen the app: wait until this Unix time, then decide again.
    case waitForLease(until: Double)
}

public enum GuardDecision {
    public static let sessionEndWait: TimeInterval = 30
    /// At most one honoured `session_end` per this many seconds (continuous time) in one guard process.
    public static let sessionEndCooldown: TimeInterval = 600
    /// A token counts only if written at most this long before the death.
    public static let tokenFreshness: TimeInterval = 10
    public static let leasesPerHour = 3

    public static func decide(_ input: GuardInput) -> GuardAction {
        guard input.bundlePresent, input.armed else { return .exit(0) }
        if let pid = input.alivePID { return .watch(pid) }
        if let release = validRelease(input) {
            if release.reason == GuardRelease.userQuit { return .exit(0) }
            if release.reason == GuardRelease.sessionEnd, input.sessionEndAllowed, !input.sessionEndWaitOver {
                return .waitForSessionEnd(sessionEndWait)
            }
        }
        if let lease = validLease(input) { return .waitForLease(until: lease.until) }
        return .relaunch(after: max(0, input.budgetDelay))
    }

    /// At the guard's own start only a `user_quit` of this boot counts; after an observed death the
    /// token must name that pid and have been written just before it.
    static func validRelease(_ input: GuardInput) -> GuardRelease? {
        guard let release = input.release else { return nil }
        guard let death = input.death else {
            return release.reason == GuardRelease.userQuit
                && sameBoot(release.bootTime, release.bootSession, input.bootTime, input.bootSession) ? release : nil
        }
        guard release.pid == death.pid, release.writtenAt <= death.at + 1,
              death.at - release.writtenAt <= tokenFreshness,
              [GuardRelease.userQuit, GuardRelease.sessionEnd].contains(release.reason) else { return nil }
        return release
    }

    static func validLease(_ input: GuardInput) -> GuardLease? {
        // At the guard's own start (no death seen, e.g. after an update replaced it) the proof alone counts.
        guard let lease = input.lease, input.death.map({ lease.pid == $0.pid }) ?? true, input.leaseProofAlive,
              input.leasesInLastHour < leasesPerHour, lease.until > input.now,
              lease.until <= input.now + GuardLease.maximumDuration,
              [GuardLease.update, GuardLease.permissionRestart].contains(lease.reason) else { return nil }
        return lease
    }

    static func sameBoot(_ a: Double, _ b: Double) -> Bool { a > 0 && b > 0 && abs(a - b) < 2 }

    /// The boot session id decides when both sides have one; older files fall back to `kern.boottime`.
    static func sameBoot(_ timeA: Double, _ sessionA: String?, _ timeB: Double, _ sessionB: String) -> Bool {
        if let sessionA, !sessionA.isEmpty, !sessionB.isEmpty { return sessionA == sessionB }
        return sameBoot(timeA, timeB)
    }
}
