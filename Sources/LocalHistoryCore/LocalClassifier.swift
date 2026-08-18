import Foundation

/// Conservative, versioned, deterministic local classifier.
/// Important: ambiguous apps (especially browsers) are intentionally NOT automatically counted as work.
public enum LocalClassifier {
    public static let version = "rules-2026.08-v1"

    public static func classify(
        app: AppSnapshot?,
        url: URLSnapshot?,
        suppressionReason: SuppressionReason?
    ) -> LocalClassification {
        if let suppressionReason {
            switch suppressionReason {
            case .privateBrowserWindow:
                return LocalClassification(category: "private_browsing", isWork: nil, confidence: 1.0, classifierVersion: version)
            case .manualPause:
                return LocalClassification(category: "paused", isWork: nil, confidence: 1.0, classifierVersion: version)
            case .secureInput:
                return LocalClassification(category: "secure_input", isWork: nil, confidence: 1.0, classifierVersion: version)
            case .excludedApplication, .excludedDomain:
                return LocalClassification(category: "excluded", isWork: nil, confidence: 1.0, classifierVersion: version)
            case .sessionUnavailable:
                return LocalClassification(category: "session_unavailable", isWork: nil, confidence: 1.0, classifierVersion: version)
            case .accessibilityUnavailable:
                return LocalClassification(category: "accessibility_unavailable", isWork: nil, confidence: 1.0, classifierVersion: version)
            }
        }

        let bundle = (app?.bundleIdentifier ?? "").lowercased()
        let name = (app?.name ?? "").lowercased()
        let host = (url?.host ?? "").lowercased()

        if matches(bundle, name, any: [
            "com.microsoft.vscode", "visual studio code", "com.apple.dt.xcode", "xcode",
            "com.jetbrains", "jetbrains", "cursor", "zed", "sublime", "nova",
            "terminal", "iterm", "warp", "ghostty",
        ]) {
            return LocalClassification(category: "software_development", isWork: true, confidence: 0.96, classifierVersion: version)
        }

        if matches(bundle, name, any: [
            "figma", "sketch", "adobe illustrator", "adobe photoshop", "affinity designer",
        ]) {
            return LocalClassification(category: "design", isWork: true, confidence: 0.88, classifierVersion: version)
        }

        if matches(bundle, name, any: [
            "microsoft word", "microsoft excel", "microsoft powerpoint", "pages", "numbers", "keynote",
            "notion", "obsidian", "craft",
        ]) {
            return LocalClassification(category: "document_productivity", isWork: true, confidence: 0.84, classifierVersion: version)
        }

        if matches(bundle, name, any: [
            "slack", "microsoft teams", "discord", "mail", "outlook", "zoom", "meet",
        ]) {
            return LocalClassification(category: "communication", isWork: nil, confidence: 0.78, classifierVersion: version)
        }

        if bundle.contains("safari") || bundle.contains("chrome") || bundle.contains("firefox") || bundle.contains("browser") || bundle.contains("edge") || bundle.contains("brave") || bundle.contains("opera") || bundle.contains("vivaldi") || bundle.contains("arc") {
            // A few domains are strongly work/tool-oriented, but most web activity is deliberately ambiguous.
            if host == "github.com" || host.hasSuffix(".github.com") || host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
                return LocalClassification(category: "software_development", isWork: true, confidence: 0.82, classifierVersion: version)
            }
            if host.contains("docs.") || host == "developer.apple.com" || host == "stackoverflow.com" || host == "learn.microsoft.com" {
                return LocalClassification(category: "research", isWork: nil, confidence: 0.72, classifierVersion: version)
            }
            return LocalClassification(category: "web", isWork: nil, confidence: 0.95, classifierVersion: version)
        }

        if matches(bundle, name, any: ["youtube", "netflix", "spotify", "twitch"]) {
            return LocalClassification(category: "media", isWork: nil, confidence: 0.82, classifierVersion: version)
        }

        return LocalClassification(category: "other", isWork: nil, confidence: 0.55, classifierVersion: version)
    }

    private static func matches(_ bundle: String, _ name: String, any needles: [String]) -> Bool {
        needles.contains { needle in
            let n = needle.lowercased()
            return bundle.contains(n) || name.contains(n)
        }
    }
}
