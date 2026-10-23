import Foundation

/// Anti-loop budget. It never gives up before the end of the block: a healthy app killed again and
/// again comes back each time (≥ 1 s apart); an app that dies before it is healthy backs off
/// (3 in a row → 30 s, 10 in a row → 2 min) so a crash at launch cannot become a dialog storm.
public struct RelaunchBudget: Equatable, Sendable {
    public static let healthySpacing: TimeInterval = 1
    public static let earlySpacing: TimeInterval = 30
    public static let longSpacing: TimeInterval = 120
    public static let earlyThreshold = 3
    public static let longThreshold = 10
    /// Healthy life after which the early-death count is forgiven.
    public static let healthyReset: TimeInterval = 120

    public private(set) var consecutiveEarlyDeaths = 0
    public private(set) var lastRelaunch: TimeInterval?

    public init() {}

    /// `healthy`: the dead app had written `guard-health` for its pid. `lifetime`: seconds it lived.
    public mutating func recordDeath(healthy: Bool, lifetime: TimeInterval?) {
        if healthy {
            if (lifetime ?? 0) >= Self.healthyReset { consecutiveEarlyDeaths = 0 }
        } else {
            consecutiveEarlyDeaths += 1
        }
    }

    /// The app ran healthy long enough while watched.
    public mutating func recordHealthyLife() { consecutiveEarlyDeaths = 0 }

    public mutating func recordRelaunch(at now: TimeInterval) { lastRelaunch = now }

    public var spacing: TimeInterval {
        consecutiveEarlyDeaths >= Self.longThreshold ? Self.longSpacing
            : consecutiveEarlyDeaths >= Self.earlyThreshold ? Self.earlySpacing : Self.healthySpacing
    }

    /// Seconds to wait from `now` (continuous time) before the next relaunch.
    public func delay(at now: TimeInterval) -> TimeInterval {
        guard let lastRelaunch else { return consecutiveEarlyDeaths >= Self.earlyThreshold ? spacing : 0 }
        return max(0, lastRelaunch + spacing - now)
    }

    public var label: String {
        consecutiveEarlyDeaths >= Self.longThreshold ? "slow" : consecutiveEarlyDeaths >= Self.earlyThreshold ? "backoff" : "normal"
    }
}
