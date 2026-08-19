import Foundation

extension ActivityAnalysisEngine {
    static func isUseful(_ event: HistoryEvent) -> Bool {
        if semanticText(from: event) != nil { return true }
        switch event.kind {
        case .applicationActivated, .windowChanged, .urlChanged, .mouseClick,
            .keyboardShortcut, .keyPressed, .typingBurst, .scrollBurst:
            return true
        case .heartbeat:
            guard let raw = event.metadata?["idle_seconds"], let idle = Double(raw) else { return false }
            return idle < 90
        default:
            return false
        }
    }

    static func representativeScore(_ event: HistoryEvent) -> Int {
        var score = 0
        if event.kind == .heartbeat { score += 1 }
        if event.window?.title != nil { score += 2 }
        if event.url != nil { score += 3 }
        if event.pointer != nil || event.keyboard != nil || event.scroll != nil { score += 4 }
        if semanticText(from: event) != nil { score += 8 }
        return score
    }

    static func semanticText(from event: HistoryEvent) -> String? {
        ActivitySemanticTextSanitizer.clean(
            event.metadata?[ActivitySemanticMetadata.text],
            maximumLength: 6_000
        )
    }

    static func requestCandidates(in semantic: String, event: HistoryEvent) -> [String] {
        let lines = splitSemanticLines(semantic)
        return distinct(
            lines.compactMap { line in
                let rawCandidate = normalizedSpeakerLine(bounded(line, maximum: 280))
                let rawLowered = rawCandidate.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                let noisePrefixes = ["assistant:", "system:", "developer:", "response:"]
                guard !noisePrefixes.contains(where: { rawLowered.hasPrefix($0) }) else { return nil }

                let candidate = strippingUserSpeakerPrefix(rawCandidate)
                guard candidate.count >= 12, candidate.count <= 280 else { return nil }
                let lowered = candidate.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                let prefixes = [
                    "add ", "analyze ", "analyse ", "ameliore ", "ameliorer ", "build ", "check ",
                    "cherche ", "compare ", "create ", "cree ", "crée ", "design ", "dis moi ",
                    "donne ", "explain ", "fais ", "fix ", "help ", "improve ", "optimize ", "optimise ", "il faut ", "je veux ",
                    "look up ", "make ", "peux tu ", "peux-tu ", "please ", "refactor ",
                    "resume ", "résume ", "summarize ", "trouve ", "update ", "verify ", "verifie ",
                    "vérifie ", "write ",
                ]
                let looksLikeRequest = candidate.contains("?")
                    || prefixes.contains(where: { lowered.hasPrefix($0) })
                    || lowered.contains(" i want ")
                    || lowered.contains(" j'aimerais ")
                    || lowered.contains(" we need ")
                guard looksLikeRequest else { return nil }
                return candidate
            },
            maximum: 8,
            maximumLength: 280
        )
    }

    /// Accessibility text from chat products commonly includes speaker labels such as
    /// `User:` or `Human:`. Strip only user-side labels before request detection while
    /// keeping assistant/system turns excluded above.
    static func strippingUserSpeakerPrefix(_ value: String) -> String {
        let prefixes = ["user:", "human:", "utilisateur:", "client:", "me:", "moi:"]
        let lowered = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else { return value }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        return String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedSpeakerLine(_ value: String) -> String {
        let withoutMarkdown = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        let markers = CharacterSet(charactersIn: ">-•*_ ")
        return withoutMarkdown.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(markers)
        )
    }

    static func isAIContext(_ event: HistoryEvent) -> Bool {
        let haystack = [event.app?.name, event.app?.bundleIdentifier, event.url?.host, event.window?.title]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let markers = [
            "chatgpt", "openai", "claude", "anthropic", "perplexity", "copilot", "cursor",
            "codex", "gemini", "grok", "mistral", "deepseek", "windsurf",
        ]
        return markers.contains { haystack.contains($0) }
    }

    static func makeHeadline(
        blocks: [ActivityFocusBlock],
        applications: [ActivityApplicationSummary],
        sites: [ActivitySiteSummary]
    ) -> String {
        if let block = blocks.max(by: { $0.activeSeconds < $1.activeSeconds }) {
            if blocks.count == 1 { return block.title }
            return "Mostly \(block.title.lowercased()), across \(blocks.count) focus blocks"
        }
        if let app = applications.first { return "Activity centered on \(app.name)" }
        if let site = sites.first { return "Browsing centered on \(site.host)" }
        return "No meaningful foreground activity was available"
    }

    static func blockTitle(
        requests: [String],
        context: [String],
        pageTitles: [String],
        hosts: [String],
        applications: [String],
        category: String?
    ) -> String {
        if let request = requests.first { return sentenceTitle(request, maximum: 92) }
        if let title = pageTitles.first, !isGenericTitle(title) { return sentenceTitle(title, maximum: 92) }
        if let context = context.first { return sentenceTitle(context, maximum: 92) }
        if let host = hosts.first { return "Worked on \(host)" }
        if let app = applications.first { return "Worked in \(app)" }
        if let category { return prettyCategory(category) }
        return "Foreground activity"
    }

    static func cleanPageTitle(_ raw: String?, appName: String) -> String? {
        guard var value = ActivitySemanticTextSanitizer.clean(raw, maximumLength: 240) else { return nil }
        let suffixes = [
            " — \(appName)", " - \(appName)", " | \(appName)", " – \(appName)",
            " — Google Chrome", " - Google Chrome", " — Safari", " - Safari",
            " — Mozilla Firefox", " - Mozilla Firefox", " — Microsoft Edge", " - Microsoft Edge",
            " — Brave", " - Brave", " — Arc", " - Arc",
        ]
        for suffix in suffixes where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else { return nil }
        return bounded(value, maximum: 180)
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var value = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    static func workflowCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return ["software_development", "design", "document_productivity", "research"].contains(category)
    }

    static func tokenSimilarity(_ lhs: String?, _ rhs: String?) -> Double {
        let left = Set(tokens(lhs))
        let right = Set(tokens(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    static func tokens(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    static func splitSemanticLines(_ value: String) -> [String] {
        value
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.components(separatedBy: " • ")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedComparable(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func distinct(
        _ values: [String],
        maximum: Int,
        maximumLength: Int
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let boundedValue = bounded(value, maximum: maximumLength)
            let key = normalizedComparable(boundedValue)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(boundedValue)
            if output.count >= maximum { break }
        }
        return output
    }

    static func frequency(_ values: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for value in values where !value.isEmpty { result[value, default: 0] += 1 }
        return result
    }

    static func sortedKeys(_ frequencies: [String: Int], limit: Int) -> [String] {
        frequencies.sorted {
            if $0.value == $1.value { return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            return $0.value > $1.value
        }
        .prefix(limit)
        .map(\.key)
    }

    static func minuteKey(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60.0))
    }

    static func bounded(_ value: String, maximum: Int) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maximum else { return cleaned }
        return String(cleaned.prefix(max(1, maximum - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func sentenceTitle(_ value: String, maximum: Int) -> String {
        var result = bounded(value, maximum: maximum)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-–—•: "))
        guard let first = result.first else { return "Foreground activity" }
        return String(first).uppercased() + result.dropFirst()
    }

    static func isGenericTitle(_ value: String) -> Bool {
        let normalized = normalizedComparable(value)
        return ["new tab", "untitled", "home", "chatgpt", "claude", "google", "safari", "chrome"].contains(normalized)
    }

    static func prettyCategory(_ raw: String) -> String {
        raw.split(separator: "_").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
