import Foundation

public enum GoalongCoverageReason: String, Codable, CaseIterable, Sendable {
    case beforeFirstObservation, afterLastObservation, gap, observationGap
    case recorderStopped, paused, sleep, locked, accessibility, sessionUnavailable
    case noVisibleForeground, privateBrowsing, excludedApplication, excludedDomain, secureInput, historyCleared
    case notRecorded, unreadable, purgedWithoutSummary

    static func opening(_ event: HistoryEvent) -> Self {
        if let reason = event.suppressionReason {
            switch reason {
            case .privateBrowserWindow: return .privateBrowsing
            case .excludedApplication: return .excludedApplication
            case .excludedDomain: return .excludedDomain
            case .secureInput: return .secureInput
            case .manualPause: return .paused
            case .sessionUnavailable: return .sessionUnavailable
            case .accessibilityUnavailable: return .accessibility
            }
        }
        switch event.kind {
        case .recorderStopped: return .recorderStopped
        case .recordingPaused: return .paused
        case .systemSleep: return .sleep
        case .sessionLocked: return .locked
        case .secureInputSuppressed: return .secureInput
        case .historyCleared: return .historyCleared
        case .permissionStatus where event.metadata?["accessibility"] == "false": return .accessibility
        default: return event.metadata?["observation_gap"] == "true" ? .observationGap : .noVisibleForeground
        }
    }
}

public enum GoalongDayOrigin: String, Codable, Sendable { case journal, summary }

public struct GoalongDayCoverage: Equatable, Sendable {
    public let observedSeconds: TimeInterval
    public let activeSeconds: TimeInterval
    public let idleSeconds: TimeInterval
    public let concealedSeconds: TimeInterval
    public let unobservedSeconds: TimeInterval
    /// Reasons account only for concealed/unobserved time, never for active or idle time.
    public let secondsByReason: [GoalongCoverageReason: TimeInterval]
    public let concealedSecondsByReason: [GoalongCoverageReason: TimeInterval]
    public let unobservedSecondsByReason: [GoalongCoverageReason: TimeInterval]
    public let firstObservation: Date?
    public let lastObservation: Date?
    /// nil for a period mixing journals and summaries.
    public let origin: GoalongDayOrigin?
    public let summaryDays: Int

    init(days: [GoalongLocalAnalytics.Day]) {
        observedSeconds = days.reduce(0) { $0 + $1.observedSeconds }
        activeSeconds = days.reduce(0) { $0 + $1.activeSeconds }
        idleSeconds = days.reduce(0) { $0 + $1.seconds(.idle) }
        concealedSeconds = days.reduce(0) { $0 + $1.seconds(.concealed) }
        unobservedSeconds = days.reduce(0) { $0 + $1.seconds(.unobserved) }
        var reasons: [GoalongCoverageReason: TimeInterval] = [:]
        var concealed: [GoalongCoverageReason: TimeInterval] = [:], unobserved: [GoalongCoverageReason: TimeInterval] = [:]
        for segment in days.flatMap(\.segments) where segment.kind == .unobserved || segment.kind == .concealed {
            if let reason = segment.coverageReason {
                reasons[reason, default: 0] += segment.seconds
                if segment.kind == .concealed { concealed[reason, default: 0] += segment.seconds }
                else { unobserved[reason, default: 0] += segment.seconds }
            }
        }
        secondsByReason = reasons
        concealedSecondsByReason = concealed
        unobservedSecondsByReason = unobserved
        firstObservation = days.compactMap(\.firstObservation).min()
        lastObservation = days.compactMap(\.lastObservation).max()
        let origins = Set(days.map(\.origin))
        origin = origins.count == 1 ? origins.first : nil
        summaryDays = days.filter { $0.origin == .summary }.count
    }
}

extension GoalongLocalAnalytics.Day {
    public var coverage: GoalongDayCoverage { GoalongDayCoverage(days: [self]) }
}
extension GoalongLocalAnalytics.Period {
    public var coverage: GoalongDayCoverage { GoalongDayCoverage(days: days) }
}
