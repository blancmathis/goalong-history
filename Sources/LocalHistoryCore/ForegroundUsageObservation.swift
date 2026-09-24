import Foundation

/// A content-free, short-lived observation of the visible foreground, distinct
/// from keyboard activity and from a claim of attention or productivity.
/// Persist the chosen policy with each observation: changing a setting must not
/// silently reinterpret old journals or turn old idle periods into meetings.
public struct ForegroundUsageObservation: Equatable, Sendable {
    public static let policyKey = "activity.presence_policy"
    public static let policyVersion = "foreground-v1"
    public static let idleLimitKey = "activity.idle_limit_seconds"
    public static let visibleKey = "activity.foreground_visible"
    public static let metadataKeys: Set<String> = [policyKey, idleLimitKey, visibleKey]
    public static let defaultIdleLimit = 300
    public static let maximumObservationGap: TimeInterval = 120
    public static let heartbeatInterval: TimeInterval = 30

    public let observedAt: Date
    public let idleSeconds: TimeInterval
    public let idleLimitSeconds: Int
    public let isForegroundVisible: Bool
    public let evidence: ForegroundActivityEvidence?

    /// Zero is the explicitly selected screen-on mode, never the default.
    public static func normalizedIdleLimit(_ value: Int?) -> Int {
        guard let value else { return defaultIdleLimit }
        if value == 0 { return 0 }
        if value < 0 { return defaultIdleLimit }
        return min(1_800, max(120, value))
    }

    public init(observedAt: Date, idleSeconds: TimeInterval, idleLimitSeconds: Int = defaultIdleLimit,
                isForegroundVisible: Bool, evidence: ForegroundActivityEvidence? = nil) {
        self.observedAt = observedAt
        self.idleSeconds = idleSeconds
        self.idleLimitSeconds = Self.normalizedIdleLimit(idleLimitSeconds)
        self.isForegroundVisible = isForegroundVisible
        self.evidence = evidence
    }

    public var isActive: Bool {
        isForegroundVisible && (evidence != nil || idleLimitSeconds == 0
            || (idleSeconds.isFinite && idleSeconds >= 0 && idleSeconds < Double(idleLimitSeconds)))
    }

    public func metadata(at date: Date, directInput: Bool = false) -> [String: String] {
        let age = date.timeIntervalSince(observedAt)
        // Input bursts can be persisted later, but their observation timestamp
        // remains authoritative. Never reuse a stale window for a new interval.
        let fresh = age.isFinite && age >= -1 && age <= Self.heartbeatInterval * 2
        let visible = fresh && isForegroundVisible
        let idle = directInput ? 0 : idleSeconds + max(0, age)
        var result = [
            Self.policyKey: Self.policyVersion,
            Self.idleLimitKey: String(idleLimitSeconds),
            Self.visibleKey: visible ? "true" : "false",
            "idle_seconds": idle.isFinite && idle >= 0 ? String(format: "%.3f", idle) : "unknown",
        ]
        // Playback evidence has its own stricter expiry, independent of reading.
        if visible, age <= 15, let evidence {
            result[ForegroundActivityEvidence.metadataKey] = evidence.rawValue
        }
        return result
    }

    public static func usesPresencePolicy(_ event: HistoryEvent) -> Bool {
        event.metadata?[policyKey] != nil
    }

    public static func hasVisibleForeground(_ event: HistoryEvent) -> Bool {
        event.metadata?[policyKey] == policyVersion
            && event.metadata?[visibleKey] == "true"
            && event.suppressionReason == nil && event.element?.isSecure != true
            && !event.isObservationContinuityBoundary && event.app?.name.isEmpty == false
    }

    /// nil means a legacy row. Zero means an observed idle/invalid/hidden row.
    /// A finite budget expires exactly at last input + the recorded reading limit.
    public static func remainingActiveSeconds(_ event: HistoryEvent) -> TimeInterval? {
        guard usesPresencePolicy(event) else { return nil }
        guard hasVisibleForeground(event) else { return 0 }
        if ForegroundActivityEvidence.evidence(in: event) != nil { return .infinity }
        return remainingReadingSeconds(event)
    }

    public static func remainingReadingSeconds(_ event: HistoryEvent) -> TimeInterval {
        guard hasVisibleForeground(event), let raw = event.metadata?[idleLimitKey],
              let limit = Int(raw), limit == normalizedIdleLimit(limit) else { return 0 }
        if limit == 0 { return .infinity }
        guard let rawIdle = event.metadata?["idle_seconds"], let idle = Double(rawIdle),
              idle.isFinite, idle >= 0 else { return 0 }
        return max(0, Double(limit) - idle)
    }

    public static func websiteDuration(after event: HistoryEvent, until end: Date,
                                       nextEvent: HistoryEvent? = nil, isTail: Bool = false) -> TimeInterval {
        let active = activeDuration(after: event, until: end, nextEvent: nextEvent, isTail: isTail)
        guard ForegroundActivityEvidence.supportsWebsiteAttribution(event) else { return 0 }
        if usesPresencePolicy(event), ForegroundActivityEvidence.evidence(in: event) == .displayAssertion {
            return min(active, remainingReadingSeconds(event))
        }
        return active
    }

    /// Shared by app totals, websites and local analytics. Modern observations
    /// never extrapolate a final sample or bridge missing/failed observations.
    public static func activeDuration(after event: HistoryEvent, until end: Date,
                                      nextEvent: HistoryEvent? = nil, isTail: Bool = false) -> TimeInterval {
        let duration = end.timeIntervalSince(event.timestamp)
        guard duration.isFinite, duration > 0 else { return 0 }
        if let remaining = remainingActiveSeconds(event) {
            guard !isTail, duration <= maximumObservationGap,
                  nextEvent?.metadata?["observation_gap"] != "true" else { return 0 }
            return min(duration, remaining)
        }
        // Preserve the historical duration convention for unversioned journals.
        guard ForegroundActivityEvidence.isActiveUsageEvidence(event) else { return 0 }
        return min(75, duration)
    }
}
