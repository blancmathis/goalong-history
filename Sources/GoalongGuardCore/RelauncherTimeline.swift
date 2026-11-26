import Foundation

/// Deadlines of the one-shot `goalong-relauncher`, one per phase (audit 2026-11-26, installation-04).
/// The parent's quit deadline ends when the parent exits: a parent that quits at 44.8 s (permission) or
/// 119.8 s (perso) is still reopened, and a perso health check started late still gets its full delay.
/// Times are monotonic seconds; the caller injects them, so the thresholds are unit-tested.
public struct RelauncherTimeline: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case waitingForParent, reopening, awaitingHealth, finished }
    /// What ran out. After a perso swap every expiry rolls back: none is a silent exit.
    public enum Expiry: Equatable, Sendable { case parentDidNotQuit, reopenTimedOut, healthTimedOut }

    public static let parentQuitPermission: TimeInterval = 45
    public static let parentQuitPerso: TimeInterval = 120
    /// From the parent's exit to a launched app: three attempts one second apart, plus a slow LaunchServices.
    public static let reopenWindow: TimeInterval = 30

    public let perso: Bool
    public private(set) var phase: Phase = .waitingForParent
    /// Monotonic seconds at which the current phase expires.
    public private(set) var deadline: TimeInterval

    public init(perso: Bool, now: TimeInterval) {
        self.perso = perso
        deadline = now + (perso ? Self.parentQuitPerso : Self.parentQuitPermission)
    }

    /// The parent's exit cancels its quit deadline and starts the reopen one.
    public mutating func parentExited(now: TimeInterval) {
        guard phase == .waitingForParent else { return }
        phase = .reopening
        deadline = now + Self.reopenWindow
    }

    /// The app was launched. A perso swap then waits for health with its own full delay.
    public mutating func appOpened(now: TimeInterval) {
        guard phase == .reopening else { return }
        if perso {
            phase = .awaitingHealth
            deadline = now + PersoUpdate.healthTimeout
        } else {
            phase = .finished
        }
    }

    /// Health seen, rollback started or launch given up: later callbacks and ticks do nothing.
    public mutating func finish() { phase = .finished }

    public var isFinished: Bool { phase == .finished }

    /// What expired at `now`, at most once. A parent already gone at its deadline counts as exited
    /// (its exit event may still be queued), never as a timeout.
    public mutating func expiry(now: TimeInterval, parentGone: Bool) -> Expiry? {
        guard phase != .finished, now >= deadline else { return nil }
        switch phase {
        case .waitingForParent:
            if parentGone { parentExited(now: now); return nil }
            phase = .finished
            return .parentDidNotQuit
        case .reopening:
            phase = .finished
            return .reopenTimedOut
        case .awaitingHealth:
            phase = .finished
            return .healthTimedOut
        case .finished:
            return nil
        }
    }
}

/// The perso health declaration (installation-03): written only after a complete, successful launch,
/// never after a fatal start, even if the run loop goes on behind a report window.
public struct PersoStartupHealth: Equatable, Sendable {
    public private(set) var failed = false
    public private(set) var declared = false
    public init() {}

    /// A required component failed: health is never declared by this process.
    public mutating func startupFailed() { failed = true }

    /// True once, when the caller must write `health.json` now.
    public mutating func startupSucceeded() -> Bool {
        guard !failed, !declared else { return false }
        declared = true
        return true
    }
}

/// Who asked for the "relaunching for an update" state (sparkle-didAbort). Sparkle's abort ends only
/// its own state and lease, never a perso swap already done.
public struct UpdateRelaunchOwnership: Equatable, Sendable {
    public enum Owner: Equatable, Sendable { case sparkle, perso }
    public private(set) var owner: Owner?
    public init() {}

    public var isRelaunching: Bool { owner != nil }

    public mutating func mark(_ owner: Owner) {
        // A perso swap is final: Sparkle never takes it over.
        if self.owner == .perso { return }
        self.owner = owner
    }

    /// True when the caller must also remove Sparkle's lease.
    public mutating func sparkleAborted() -> Bool {
        guard owner == .sparkle else { return false }
        owner = nil
        return true
    }
}
