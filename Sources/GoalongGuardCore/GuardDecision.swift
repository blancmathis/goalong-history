import Foundation

/// End of the armed window, kept in continuous time so changing the Mac's clock changes nothing.
/// Only the running app may lower or remove it: it is the one that decides (timer, password).
public struct GuardArming: Equatable, Sendable {
    /// `mach_continuous_time` seconds at which the block ends; nil when nothing is armed.
    public private(set) var endContinuous: TimeInterval?

    public init(endContinuous: TimeInterval? = nil) { self.endContinuous = endContinuous }

    /// Applies one read of `guard-until`. A higher end always wins; a lower, removed or unreadable
    /// marker is accepted only while the app is alive. Without any memory, an unreadable marker arms nothing.
    public mutating func apply(_ marker: GuardMarker, wall: Date, continuous: TimeInterval, appAlive: Bool) {
        switch marker {
        case .date(let date):
            let end = continuous + date.timeIntervalSince(wall)
            if appAlive || endContinuous.map({ end > $0 }) ?? true { endContinuous = end }
        case .absent, .invalid:
            if appAlive || endContinuous == nil { endContinuous = nil }
        }
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
    /// Delay the relaunch budget imposes, in seconds from now.
    public var budgetDelay: TimeInterval = 0
    public var bootTime: Double = 0
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
    /// A token counts only if written at most this long before the death.
    public static let tokenFreshness: TimeInterval = 10
    public static let leasesPerHour = 3

    public static func decide(_ input: GuardInput) -> GuardAction {
        guard input.bundlePresent, input.armed else { return .exit(0) }
        if let pid = input.alivePID { return .watch(pid) }
        if let release = validRelease(input) {
            if release.reason == GuardRelease.userQuit { return .exit(0) }
            if release.reason == GuardRelease.sessionEnd, !input.sessionEndWaitOver { return .waitForSessionEnd(sessionEndWait) }
        }
        if let lease = validLease(input) { return .waitForLease(until: lease.until) }
        return .relaunch(after: max(0, input.budgetDelay))
    }

    /// At the guard's own start only a `user_quit` of this boot counts; after an observed death the
    /// token must name that pid and have been written just before it.
    static func validRelease(_ input: GuardInput) -> GuardRelease? {
        guard let release = input.release else { return nil }
        guard let death = input.death else {
            return release.reason == GuardRelease.userQuit && sameBoot(release.bootTime, input.bootTime) ? release : nil
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
}
