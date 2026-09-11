import Foundation

/// Version 1 reads every eligible journal timestamp before any minute digest.
/// App-to-project associations are supplied by the owner, never inferred as attention.
public struct GoalongSessionRhythm {
    public static let maximumGapMS = 120_000
    public static let briefConsultationMS = 120_000
    public struct Episode: Codable, Equatable {
        public var offset_ms: Int
        public var duration_ms: Int
        public var relation: String
        public var application: String?
    }
    public struct Result: Codable {
        public let version: Int
        public let method: String
        public let project: String
        public let window_ms: Int
        public let observed_ms: Int
        public let project_ms: Int
        public let longest_project_ms: Int
        public let brief_consultations: Int
        public let max_gap_ms: Int
        public let brief_threshold_ms: Int
        public let coverage: String
        public var start: String?
        public var episodes: [Episode]?
        public var interpretation: String?
    }
    private var first: Date?
    private var previous: Date?
    private var previousApp: String?
    private var episodes: [Episode] = []
    private var invalid = false
    private let project: String
    private let projectApps: Set<String>
    public init(project: String, applications: [String]) {
        self.project = project
        self.projectApps = Set(applications.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }
    public mutating func ingest(_ event: HistoryEvent) {
        guard !invalid else { return }
        guard event.isDerivedAnalysisEvidence else { return }
        if let previous {
            guard event.timestamp >= previous else { invalid = true; return }
            // Quantize positions on one shared clock, not each interval independently.
            let offset = Int((previous.timeIntervalSince(first!) * 1000).rounded())
            let end = Int((event.timestamp.timeIntervalSince(first!) * 1000).rounded())
            let delta = end - offset
            if delta > 0 {
                let known = delta <= Self.maximumGapMS && previousApp != nil && event.metadata?["observation_gap"] != "true"
                let app = known ? previousApp : nil
                let relation = app.map { projectApps.contains($0.lowercased()) ? "project" : "other" } ?? "unknown"
                if let last = episodes.last, last.application == app, last.relation == relation,
                   last.offset_ms + last.duration_ms == offset {
                    episodes[episodes.count - 1].duration_ms += delta
                } else {
                    episodes.append(Episode(offset_ms: offset, duration_ms: delta, relation: relation, application: app))
                }
                if episodes.count > 1500 { invalid = true; return }
            }
        } else { first = event.timestamp }
        previous = event.timestamp
        if event.isObservationContinuityBoundary { previousApp = nil }
        else if let app = event.app?.name, !app.isEmpty { previousApp = String(app.prefix(100)) }
    }
    public func result(includeTimeline: Bool, includeTimes: Bool) -> Result? {
        guard !invalid, !projectApps.isEmpty, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.count <= 100, let first, let previous, previous > first, !episodes.isEmpty else { return nil }
        var projectMS = 0, observed = 0, longest = 0, run = 0, brief = 0
        var groups: [(String, Int)] = []
        for episode in episodes {
            if episode.relation != "unknown" { observed += episode.duration_ms }
            if episode.relation == "project" { projectMS += episode.duration_ms; run += episode.duration_ms; longest = max(longest, run) }
            else { run = 0 }
            if groups.last?.0 == episode.relation { groups[groups.count - 1].1 += episode.duration_ms }
            else { groups.append((episode.relation, episode.duration_ms)) }
        }
        if groups.count >= 3 {
            for index in 1..<(groups.count - 1) where groups[index].0 == "other" && groups[index].1 <= Self.briefConsultationMS && groups[index - 1].0 == "project" && groups[index + 1].0 == "project" { brief += 1 }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Result(version: 1, method: "foreground-project-v1", project: project,
                      window_ms: Int((previous.timeIntervalSince(first) * 1000).rounded()), observed_ms: observed,
                      project_ms: projectMS, longest_project_ms: longest, brief_consultations: brief,
                      max_gap_ms: Self.maximumGapMS, brief_threshold_ms: Self.briefConsultationMS, coverage: "partial",
                      start: includeTimes ? formatter.string(from: first) : nil,
                      episodes: includeTimeline ? episodes : nil, interpretation: nil)
    }
}
