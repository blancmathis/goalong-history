import Foundation

/// Explicit owner-entered productivity criteria. Never inferred from private history.
public struct JevWorkContext: Codable, Equatable, Sendable {
    public static let maximumBytes = 800
    public static let empty = try! JevWorkContext(summary: "")
    public let schemaVersion: Int
    /// Kept under its original key so an existing project description is not lost.
    public let summary: String
    public let applications: String
    public let content: String
    public var isEmpty: Bool { summary.isEmpty && applications.isEmpty && content.isEmpty }
    public var byteCount: Int { summary.utf8.count + applications.utf8.count + content.utf8.count }

    public init(summary: String, applications: String = "", content: String = "") throws {
        self.schemaVersion = 2
        self.summary = Self.normalize(summary)
        self.applications = Self.normalize(applications)
        self.content = Self.normalize(content)
        guard isValid else { throw JevWorkContextError.tooLong }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, summary, applications, content }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        summary = try values.decode(String.self, forKey: .summary)
        applications = try values.decodeIfPresent(String.self, forKey: .applications) ?? ""
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        if version == 1 {
            // v1 had only a 100-byte summary; refuse malformed legacy content.
            guard summary.utf8.count <= 100, applications.isEmpty, content.isEmpty else {
                throw JevWorkContextError.tooLong
            }
            schemaVersion = 2
        } else { schemaVersion = version }
    }
    public var isValid: Bool {
        schemaVersion == 2 && byteCount <= Self.maximumBytes
            && [summary, applications, content].allSatisfy {
                !($0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            }
    }
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
public enum JevWorkContextError: Error, LocalizedError {
    case tooLong
    public var errorDescription: String? {
        "Raccourcissez les critères : gardez les noms et les usages importants, sans longues listes d’exemples. Les trois rubriques doivent tenir dans 800 octets UTF-8."
    }
}

/// Missing topic evidence must not become a punishment, even with an overconfident model.
/// This only abstains; it never manufactures a positive or productive classification.
public enum JevEvidencePolicy {
    public static func reviewed(_ verdict: JevVerdict, work: JevWorkContext, window: JevWindow) -> JevVerdict {
        guard work.isValid else { return .unknown }
        let placeholders: Set<String> = ["", "untitled", "sans titre", "new tab", "nouvel onglet", "home", "accueil", "google search", "recherche google"]
        let hasTopic = window.samples.contains {
            let title = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !placeholders.contains(title) && title != $0.resource.lowercased()
        }
        let consumption = window.samples.contains { ["social-feed", "video"].contains($0.surface) && $0.isActivity }
        if !hasTopic && !consumption { return .unknown }
        if verdict == .productive && (work.isEmpty || !hasTopic) { return .unknown }
        if verdict == .procrastination && work.isEmpty && !consumption { return .unknown }
        return verdict
    }
}
