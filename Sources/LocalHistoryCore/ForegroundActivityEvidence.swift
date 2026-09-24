import Foundation

/// Positive, foreground-scoped evidence collected on the Mac. Input silence is
/// not absence: a call, a playing video or a presentation needs no keystrokes.
/// This is observation, not a claim that the person is attentive/productive.
public enum ForegroundActivityEvidence: String, CaseIterable, Sendable {
    case mediaPlayback = "media_playback"
    case call = "call"
    case displayAssertion = "display_assertion"

    public static let metadataKey = "activity.foreground_evidence"
    public static let inputIdleThreshold: TimeInterval = 90

    public static func evidence(in event: HistoryEvent) -> Self? {
        guard event.suppressionReason == nil, event.element?.isSecure != true,
              !event.isObservationContinuityBoundary, event.app?.name.isEmpty == false,
              let raw = event.metadata?[metadataKey] else { return nil }
        return Self(rawValue: raw)
    }

    /// A process-wide display assertion cannot establish which website is in use.
    public static func supportsWebsiteAttribution(_ event: HistoryEvent) -> Bool {
        guard evidence(in: event) == .displayAssertion else { return true }
        // Recent input remains valid tab evidence; only passive process-only
        // intervals need to withhold the website attribution.
        guard let raw = event.metadata?["idle_seconds"], let seconds = Double(raw),
              seconds.isFinite, seconds >= 0 else { return false }
        return seconds < inputIdleThreshold
    }

    public static func isInputIdle(_ event: HistoryEvent) -> Bool {
        guard evidence(in: event) == nil,
              let raw = event.metadata?["idle_seconds"], let seconds = Double(raw) else { return false }
        return !seconds.isFinite || seconds >= inputIdleThreshold
    }

    /// All duration projections must use the same heartbeat policy. Old journals
    /// keep their input-only semantics: never backfill meetings from app names.
    public static func isActiveUsageEvidence(_ event: HistoryEvent) -> Bool {
        guard event.suppressionReason == nil, event.element?.isSecure != true else { return false }
        if evidence(in: event) != nil { return true }
        guard event.kind == .heartbeat else { return true }
        guard let raw = event.metadata?["idle_seconds"], let seconds = Double(raw),
              seconds.isFinite, seconds >= 0 else { return false }
        return seconds < inputIdleThreshold
    }
}
