import Foundation

/// Shared deterministic helpers for the causal Computer History pipeline.
enum ComputerHistorySupport {
    static func semanticText(
        for event: HistoryEvent,
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> String? {
        SemanticContextResolver.text(
            for: event,
            semanticSnapshots: semanticSnapshots
        ).flatMap { ActivitySemanticTextSanitizer.clean($0, maximumLength: 6_000) }
    }

    static func eventOrder(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        if left.timestamp == right.timestamp { return left.id < right.id }
        return left.timestamp < right.timestamp
    }

    static func isActionEvent(_ event: HistoryEvent) -> Bool {
        switch event.kind {
        case .mouseClick, .typingBurst, .keyboardShortcut, .keyPressed, .scrollBurst,
            .applicationActivated, .windowChanged, .urlChanged, .focusChanged:
            return true
        default:
            return false
        }
    }

    static func actionKind(for event: HistoryEvent) -> ComputerHistoryActionKind {
        switch event.kind {
        case .mouseClick: return .click
        case .typingBurst: return .typing
        case .keyboardShortcut: return .shortcut
        case .keyPressed: return .navigationKey
        case .scrollBurst: return .scroll
        case .applicationActivated: return .applicationSwitch
        case .windowChanged: return .windowChange
        case .urlChanged: return .pageChange
        case .focusChanged: return .focusChange
        default: return .contextObservation
        }
    }

    static func actionLabel(for event: HistoryEvent) -> String {
        let target = [event.element?.title, event.element?.label, event.element?.identifier]
            .compactMap { ActivitySemanticTextSanitizer.clean($0, maximumLength: 220) }
            .first

        switch event.kind {
        case .mouseClick:
            let button = event.pointer?.button ?? "pointer"
            let count = event.pointer?.clickCount ?? 1
            let suffix = count > 1 ? " (\(count)-click sequence)" : ""
            if let target { return "Clicked \(target) with the \(button) button\(suffix)" }
            if let pointer = event.pointer {
                return "Clicked at \(Int(pointer.x.rounded())), \(Int(pointer.y.rounded())) with the \(button) button\(suffix)"
            }
            return "Clicked with the \(button) button\(suffix)"

        case .typingBurst:
            let count = event.metadata?["keystroke_count"].flatMap(Int.init)
            if let target, let count { return "Typed \(count) key events in \(target)" }
            if let target { return "Typed in \(target)" }
            if let count { return "Typed \(count) key events" }
            return "Typed text activity"

        case .keyboardShortcut:
            let keys = (event.keyboard?.modifiers ?? []) + [event.keyboard?.key].compactMap { $0 }
            return keys.isEmpty
                ? "Used a keyboard shortcut"
                : "Used shortcut \(keys.joined(separator: "+"))"

        case .keyPressed:
            if let key = event.keyboard?.key { return "Pressed \(key)" }
            return "Pressed a navigation key"

        case .scrollBurst:
            guard let scroll = event.scroll else { return "Scrolled" }
            let direction: String
            if abs(scroll.deltaY) >= abs(scroll.deltaX) {
                direction = scroll.deltaY < 0 ? "down" : "up"
            } else {
                direction = scroll.deltaX < 0 ? "right" : "left"
            }
            return "Scrolled \(direction) (\(scroll.eventCount) grouped events)"

        case .applicationActivated:
            return "Switched to \(event.app?.name ?? "an application")"

        case .windowChanged:
            if let title = event.window?.title {
                return "Opened or focused window \(bounded(title, maximum: 220))"
            }
            return "Changed window"

        case .urlChanged:
            if let title = event.window?.title {
                return "Opened page \(bounded(title, maximum: 220))"
            }
            if let value = event.url?.value {
                return "Opened \(bounded(value, maximum: 220))"
            }
            return "Changed page"

        case .focusChanged:
            if let target { return "Focused \(target)" }
            return "Changed focused control"

        default:
            return "Observed \(event.kind.rawValue)"
        }
    }

    static func sameApplication(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        if let leftBundle = left.app?.bundleIdentifier,
            let rightBundle = right.app?.bundleIdentifier
        {
            return leftBundle == rightBundle
        }
        return left.app?.name == right.app?.name
    }

    static func provenance(for events: [HistoryEvent]) -> ActivityProvenance {
        let ordered = distinctEvents(events.sorted(by: eventOrder))
        return ActivityProvenance(
            sourceEventIDs: ordered.map(\.id),
            sourceSequences: distinct(ordered.compactMap { $0.integrity?.sequence }),
            sourceEventHashes: distinct(ordered.compactMap { $0.integrity?.eventHash })
        )
    }

    static func distinctEvents(_ events: [HistoryEvent]) -> [HistoryEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }
    }

    static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    static func distinctText(
        _ values: [String],
        maximum: Int,
        maximumLength: Int
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let clean = bounded(value, maximum: maximumLength)
            let key = normalized(clean)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(clean)
            if output.count >= maximum { break }
        }
        return output
    }

    static func rankedDistinct(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, value) in values.enumerated() where !value.isEmpty {
            counts[value, default: 0] += 1
            if firstIndex[value] == nil { firstIndex[value] = index }
        }
        return counts.keys.sorted {
            let left = counts[$0] ?? 0
            let right = counts[$1] ?? 0
            if left == right {
                return (firstIndex[$0] ?? 0) < (firstIndex[$1] ?? 0)
            }
            return left > right
        }
    }

    static func cleanTitle(_ raw: String?, application: String?) -> String? {
        guard var value = ActivitySemanticTextSanitizer.clean(raw, maximumLength: 300) else {
            return nil
        }
        if let application {
            for suffix in [
                " — \(application)", " - \(application)",
                " | \(application)", " – \(application)",
            ] where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.isEmpty ? nil : value
    }

    static func isGenericTitle(_ value: String) -> Bool {
        [
            "new tab", "untitled", "home", "window", "document", "chatgpt", "claude",
            "google", "safari", "chrome", "firefox", "finder", "terminal",
        ].contains(normalized(value))
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var value = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    static func canonicalURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.fragment = nil
        let sensitive = ["token", "key", "auth", "session", "code", "secret", "password"]
        components.queryItems = components.queryItems?.map { item in
            guard sensitive.contains(where: { item.name.lowercased().contains($0) }) else {
                return item
            }
            return URLQueryItem(name: item.name, value: "[REDACTED]")
        }
        return components.string
    }

    static func splitSemanticLines(_ value: String) -> [String] {
        value
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: " • ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func semanticDelta(before: String?, after: String?) -> [String] {
        guard let after else { return [] }
        let beforeLines = splitSemanticLines(before ?? "")
        let candidates = splitSemanticLines(after).filter { line in
            !beforeLines.contains(where: { tokenSimilarity([$0], [line]) >= 0.88 })
        }
        return Array(candidates.filter { $0.count >= 3 }.prefix(10))
    }

    static func looksLikeRequestOrIntention(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 10, clean.count <= 500 else { return false }
        let lower = normalized(clean)
        let prefixes = [
            "add ", "analyze ", "analyse ", "build ", "check ", "cherche ", "compare ",
            "create ", "cree ", "crée ", "design ", "dis moi ", "donne ", "explain ",
            "fais ", "fix ", "help ", "improve ", "je veux ", "j aimerais ", "make ",
            "optimize ", "optimise ", "please ", "prepare ", "refactor ", "resume ",
            "résume ", "summarize ", "trouve ", "update ", "verify ", "verifie ",
            "vérifie ", "write ", "we need ", "i want ",
        ]
        return clean.contains("?") || prefixes.contains(where: { lower.hasPrefix($0) })
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func tokens(_ value: String) -> [String] {
        normalized(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    static func tokenSimilarity(_ left: [String], _ right: [String]) -> Double {
        jaccard(Set(left.flatMap(tokens)), Set(right.flatMap(tokens)))
    }

    static func jaccard<T: Hashable>(_ left: Set<T>, _ right: Set<T>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    static func collapseConsecutive(_ values: [String]) -> [String] {
        var output: [String] = []
        for value in values where output.last != value { output.append(value) }
        return output
    }

    static func bounded(_ value: String, maximum: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maximum else { return clean }
        return String(clean.prefix(Swift.max(1, maximum - 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func sentenceTitle(_ value: String, maximum: Int) -> String {
        let boundedValue = bounded(value, maximum: maximum)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—•: "))
        guard let first = boundedValue.first else { return "Foreground computer activity" }
        return String(first).uppercased() + boundedValue.dropFirst()
    }

    static func containsAny(_ value: String, markers: [String]) -> Bool {
        markers.contains { value.contains($0) }
    }

    static func stableIdentifier(_ value: String) -> String {
        String(SHA256Digest.hashHex(value).prefix(24))
    }
}
