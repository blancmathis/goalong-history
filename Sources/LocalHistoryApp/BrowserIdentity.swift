#if os(macOS)
import Foundation
import LocalHistoryCore

/// One answer to "is this app a browser?" for the history reader and the
/// foreground probe. Bundle identifiers match exactly or by a known vendor
/// prefix; names match whole words only, so "Archive Utility", "Hedge" or
/// "Diarly" are not browsers while "Arc", "Microsoft Edge" or "Dia" are.
enum BrowserIdentity {
    private static let bundlePrefixes = [
        "com.google.chrome", "org.chromium.", "com.microsoft.edgemac", "com.brave.browser",
        "company.thebrowser.", "org.mozilla.", "com.operasoftware.", "com.vivaldi.",
        "app.zen-browser.", "com.kagi.kagimacos", "com.duckduckgo.macos.browser",
        "com.sigmaos.", "com.apple.safari", "com.openai.atlas", "ai.perplexity.comet",
        "com.naver.whale",
    ]
    private static let nameTokens: Set<String> = [
        "safari", "chrome", "chromium", "firefox", "librewolf", "floorp", "edge", "brave",
        "arc", "opera", "vivaldi", "orion", "duckduckgo", "dia", "sigmaos", "waterfox", "thorium",
        "ladybird",
    ]

    static func isNamedBrowser(name: String, bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            if RecorderConfig.default.browserBundleIdentifiers.contains(bundleIdentifier)
                || BlockingRules.otherBrowsers.contains(bundleIdentifier)
            {
                return true
            }
            let lower = bundleIdentifier.lowercased()
            if bundlePrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        }
        let tokens = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if tokens.contains(where: nameTokens.contains) { return true }
        // "Zen Browser", "Tor Browser": a bare "browser" word alone is not enough.
        if tokens.contains("browser") && (tokens.contains("zen") || tokens.contains("tor")) { return true }
        // Bare "atlas", "comet" or "whale" name ordinary apps; their bundle prefixes cover the real browsers.
        return (tokens.contains("chatgpt") && tokens.contains("atlas"))
            || (tokens.contains("naver") && tokens.contains("whale"))
            || (tokens.contains("perplexity") && tokens.contains("comet"))
    }

    /// True only for a web page address: an http(s) URL with a host, or an
    /// address-bar value such as "example.com/page". A file:// document, an
    /// about: page or a custom scheme is not proof that an app is a browser.
    static func isWebPageEvidence(_ raw: String?) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty, !trimmed.contains(" ")
        else { return false }
        if let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
            trimmed.contains("://") || ["about", "file", "data", "javascript"].contains(scheme)
        {
            guard scheme == "http" || scheme == "https" else { return false }
            return URLComponents(string: trimmed)?.host?.isEmpty == false
        }
        guard let host = URLComponents(string: "https://" + trimmed)?.host else { return false }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
#endif
