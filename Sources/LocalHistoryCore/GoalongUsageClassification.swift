import Foundation

/// Former per-application / per-website verdicts. Work is now decided from the user's
/// definition (`GoalongWorkDefinition`), because one application can serve work or not.
/// Existing choices are read once to pre-fill that definition; they are no longer applied.
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
