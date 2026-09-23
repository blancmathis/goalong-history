import Foundation

/// An explicitly entered work reference, not a projection of private history or inferred projects.
public struct JevWorkContext: Codable, Equatable, Sendable {
    public static let maximumBytes = 100
    public static let empty = try! JevWorkContext(summary: "")
    public let schemaVersion: Int
    public let summary: String
    public init(summary: String) throws {
        let normalized = summary.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard normalized.utf8.count <= Self.maximumBytes,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JevWorkContextError.tooLong
        }
        self.schemaVersion = 1; self.summary = normalized
    }
    public var isValid: Bool {
        schemaVersion == 1 && summary.utf8.count <= Self.maximumBytes
            && !summary.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
public enum JevWorkContextError: Error, LocalizedError {
    case tooLong
    public var errorDescription: String? {
        "Description trop longue. Indiquez les noms des projets et quelques mots sur le travail prévu."
    }
}

/// Do not turn missing topic evidence into a punishment, even if the model is overconfident.
/// This can only abstain; it never manufactures a positive or productive classification.
public enum JevEvidencePolicy {
    public static func reviewed(_ verdict: JevVerdict, work: JevWorkContext, window: JevWindow) -> JevVerdict {
        let placeholders: Set<String> = ["", "untitled", "sans titre", "new tab", "nouvel onglet", "home", "accueil", "google search", "recherche google"]
        let hasTopic = window.samples.contains {
            let title = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !placeholders.contains(title) && title != $0.resource.lowercased()
        }
        let consumption = window.samples.contains { ["social-feed", "video"].contains($0.surface) && $0.isActivity }
        if !hasTopic && !consumption { return .unknown }
        if verdict == .productive && (work.summary.isEmpty || !hasTopic) { return .unknown }
        if verdict == .procrastination && work.summary.isEmpty && !consumption { return .unknown }
        return verdict
    }
}
