import Foundation

/// The user's own verdict for an application or a website, applied when Activité
/// reads the journal. Source events are never rewritten: removing a rule restores the
/// automatic classification for every past and future day.
public enum GoalongUsageClass: String, Codable, CaseIterable, Sendable {
    case work, other
}

public struct GoalongUsageClassificationRules: Codable, Equatable, Sendable {
    /// Keyed by bundle identifier when known, otherwise by the application name.
    public var applications: [String: GoalongUsageClass]
    /// Keyed by lowercased host. A rule also covers its subdomains.
    public var websites: [String: GoalongUsageClass]

    public init(applications: [String: GoalongUsageClass] = [:], websites: [String: GoalongUsageClass] = [:]) {
        self.applications = applications
        self.websites = websites
    }

    public var isEmpty: Bool { applications.isEmpty && websites.isEmpty }

    public static func applicationKey(bundleIdentifier: String?, name: String?) -> String? {
        let key = (bundleIdentifier?.isEmpty == false ? bundleIdentifier : name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    public static func websiteKey(_ host: String?) -> String? {
        let key = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key?.isEmpty == false ? key : nil
    }

    /// A website rule wins over its browser's rule; the most specific host wins.
    public func verdict(application: String?, bundleIdentifier: String?, host: String?) -> GoalongUsageClass? {
        if var candidate = Self.websiteKey(host) {
            while true {
                if let verdict = websites[candidate] { return verdict }
                guard let dot = candidate.firstIndex(of: "."),
                      candidate[candidate.index(after: dot)...].contains(".") else { break }
                candidate = String(candidate[candidate.index(after: dot)...])
            }
        }
        if let bundleIdentifier, let verdict = applications[bundleIdentifier] { return verdict }
        if let application, let verdict = applications[application] { return verdict }
        return nil
    }
}

extension GoalongLocalAnalytics.Day {
    /// Re-labels active intervals that match a user rule and merges the neighbours that
    /// become identical. Totals, gaps, idle, private and unobserved time are unchanged.
    public func applying(_ rules: GoalongUsageClassificationRules) -> GoalongLocalAnalytics.Day {
        guard !rules.isEmpty else { return self }
        var result: [GoalongLocalAnalytics.Segment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            var kind = segment.kind
            if kind.isActive, let verdict = rules.verdict(application: segment.application,
                bundleIdentifier: segment.bundleIdentifier, host: segment.host) {
                kind = verdict == .work ? .work : .other
            }
            if let last = result.last, last.end == segment.start, last.kind == kind,
               last.application == segment.application, last.bundleIdentifier == segment.bundleIdentifier,
               last.host == segment.host {
                result[result.count - 1].end = segment.end
            } else {
                result.append(GoalongLocalAnalytics.Segment(start: segment.start, end: segment.end, kind: kind,
                    application: segment.application, bundleIdentifier: segment.bundleIdentifier, host: segment.host))
            }
        }
        return GoalongLocalAnalytics.Day(date: date, end: end, state: state, segments: result,
            eventCount: eventCount, classifierVersions: classifierVersions)
    }
}

extension GoalongLocalAnalytics.Period {
    public func applying(_ rules: GoalongUsageClassificationRules) -> GoalongLocalAnalytics.Period {
        rules.isEmpty ? self : GoalongLocalAnalytics.Period(days: days.map { $0.applying(rules) })
    }
}
