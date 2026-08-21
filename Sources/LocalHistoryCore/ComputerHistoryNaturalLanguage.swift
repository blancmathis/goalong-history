import Foundation

/// Canonicalizes harmless punctuation differences before local intent detection.
/// This is deliberately not a semantic rewrite: it only prevents apostrophes,
/// typographic dashes, and repeated whitespace from changing query behavior.
public enum ComputerHistoryNaturalLanguage {
    public static func canonicalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "’", with: " ")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
