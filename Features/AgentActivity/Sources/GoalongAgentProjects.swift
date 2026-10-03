import Foundation
import LocalHistoryCore

public struct GoalongAgentProjectDay: Equatable, Sendable, Identifiable {
    public var project: GoalongDeveloperProject
    public var id: String { project.id }
    public var sessions = 0
    public var providers: Set<String> = []
    /// Conversation bounds, not execution time or human attention.
    public var documentIntervals: [DateInterval] = []
    public var documentSpanSeconds: TimeInterval { GoalongDeveloperIntervals.unionSeconds(documentIntervals) }
    public var tokens: Int64? = nil
    public var toolCalls: Int? = nil
    public var errors: Int? = nil
    public var partial = false
    public var t3: T3CodeProjectDay? = nil
}
public struct GoalongAgentProjectsDay: Equatable, Sendable {
    public let day: Date
    public let status: GoalongDeveloperLaneStatus
    public let projects: [GoalongAgentProjectDay]
    public let unassignedSessions: Int
}

public enum GoalongAgentProjectGrouping {
    public static func group(_ overview: AgentActivityOverview, t3: T3CodeDay? = nil,
                             enabled: Bool = true, calendar: Calendar = .current) -> GoalongAgentProjectsDay {
        let start = calendar.startOfDay(for: overview.day)
        guard enabled else { return .init(day: start, status: .disabled, projects: [], unassignedSessions: 0) }
        guard let day = calendar.dateInterval(of: .day, for: start) else { return .init(day: start, status: .failed("Date invalide."), projects: [], unassignedSessions: 0) }
        var groups: [String: GoalongAgentProjectDay] = [:], seen = Set<String>(), seenTokens = Set<String>(), unassigned = 0
        for capture in overview.captures where seen.insert(capture.id).inserted {
            guard let path = capture.summary.projectPath, path.hasPrefix("/"), path.utf8.count <= 4096 else { unassigned += 1; continue }
            let project = GoalongDeveloperProject(root: URL(fileURLWithPath: path))
            var group = groups[project.id] ?? .init(project: project)
            group.project = GoalongDeveloperProject.combining([group.project, project])!
            let beginning = capture.summary.startedAt ?? capture.index.conversationStartedAt
            let ending = capture.summary.endedAt ?? capture.index.conversationEndedAt
            if let beginning, let ending, ending >= beginning,
               let interval = GoalongDeveloperIntervals.clipped(.init(start: beginning, end: ending), to: day) { group.documentIntervals.append(interval) }
            else { group.partial = true }
            group.sessions += 1
            group.providers.insert(capture.provider.displayName)
            // Lifetime counters cannot be assigned to a day without the day-scoped projection.
            if capture.analysisInterval?.start == day.start && capture.analysisInterval?.end == day.end {
                group.toolCalls = (group.toolCalls ?? 0) + max(0, capture.summary.toolCallCount)
                group.errors = (group.errors ?? 0) + max(0, capture.summary.errorCount)
            } else { group.partial = true }
            if !capture.projectionIsComplete || capture.summary.tokenUsage.partial { group.partial = true }
            for event in capture.summary.tokenUsage.events where event.date >= day.start && event.date < day.end {
                guard seenTokens.insert(project.id + "|" + capture.provider.rawValue + "|" + event.id).inserted else { continue }
                if let total = event.total, total >= 0 {
                    let (sum, overflow) = (group.tokens ?? 0).addingReportingOverflow(total)
                    if overflow { group.partial = true } else { group.tokens = sum }
                } else { group.partial = true }
            }
            groups[project.id] = group
        }
        for source in t3?.projects ?? [] {
            var group = groups[source.id] ?? .init(project: source.project)
            group.project = GoalongDeveloperProject.combining([group.project, source.project])!
            group.t3 = source; group.providers.insert("T3 Code")
            if t3?.status == .partial { group.partial = true }
            groups[source.id] = group
        }
        let partial = unassigned > 0 || groups.values.contains(where: \.partial) || t3?.status == .partial
        let status: GoalongDeveloperLaneStatus = partial ? .partial : (groups.isEmpty ? (t3?.status ?? .noData) : .ready)
        return .init(day: start, status: status, projects: groups.values.sorted { $0.id < $1.id }, unassignedSessions: unassigned)
    }
}
