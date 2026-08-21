import Foundation

struct ComputerHistoryResourceResolution {
    let resources: [ComputerHistoryResourceReference]
    let eventResourceIDs: [String: [String]]
}

enum ComputerHistoryResourceResolver {
    private struct Candidate {
        let key: String
        let kind: ComputerHistoryResourceKind
        let title: String
        let canonicalURI: String?
        let localPath: String?
        let host: String?
        let application: String?
        let bundleIdentifier: String?
        let confidence: Double
    }

    private struct Builder {
        var candidate: Candidate
        var firstSeen: Date
        var lastSeen: Date
        var sourceEvents: [HistoryEvent]
    }

    static func resolve(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> ComputerHistoryResourceResolution {
        var builders: [String: Builder] = [:]
        var candidateKeysByEvent: [String: [String]] = [:]

        for event in events {
            let semantic = ComputerHistorySupport.semanticText(
                for: event,
                semanticSnapshots: semanticSnapshots
            )
            let candidates = candidates(for: event, semantic: semantic)
            candidateKeysByEvent[event.id] = ComputerHistorySupport.distinct(candidates.map(\.key))

            for candidate in candidates {
                if var existing = builders[candidate.key] {
                    existing.firstSeen = min(existing.firstSeen, event.timestamp)
                    existing.lastSeen = max(existing.lastSeen, event.timestamp)
                    existing.sourceEvents.append(event)
                    if candidate.confidence > existing.candidate.confidence
                        || ComputerHistorySupport.isGenericTitle(existing.candidate.title)
                    {
                        existing.candidate = candidate
                    }
                    builders[candidate.key] = existing
                } else {
                    builders[candidate.key] = Builder(
                        candidate: candidate,
                        firstSeen: event.timestamp,
                        lastSeen: event.timestamp,
                        sourceEvents: [event]
                    )
                }
            }
        }

        let IDs = Dictionary(uniqueKeysWithValues: builders.keys.map { key in
            (key, ComputerHistorySupport.stableIdentifier("resource|\(key)"))
        })
        let resources = builders.map { key, builder in
            let candidate = builder.candidate
            return ComputerHistoryResourceReference(
                id: IDs[key]!,
                kind: candidate.kind,
                title: ComputerHistorySupport.bounded(candidate.title, maximum: 300),
                canonicalURI: candidate.canonicalURI,
                localPath: candidate.localPath,
                host: candidate.host,
                application: candidate.application,
                bundleIdentifier: candidate.bundleIdentifier,
                locatorConfidence: candidate.confidence,
                firstSeen: builder.firstSeen,
                lastSeen: builder.lastSeen,
                provenance: ComputerHistorySupport.provenance(for: builder.sourceEvents)
            )
        }
        .sorted {
            if $0.firstSeen == $1.firstSeen { return $0.title < $1.title }
            return $0.firstSeen < $1.firstSeen
        }
        let eventResourceIDs = candidateKeysByEvent.mapValues { keys in
            keys.compactMap { IDs[$0] }
        }
        return ComputerHistoryResourceResolution(
            resources: resources,
            eventResourceIDs: eventResourceIDs
        )
    }

    private static func candidates(
        for event: HistoryEvent,
        semantic: String?
    ) -> [Candidate] {
        let application = event.app?.name
        let bundleIdentifier = event.app?.bundleIdentifier
        let title = ComputerHistorySupport.cleanTitle(
            event.window?.title,
            application: application
        )
        var output: [Candidate] = []

        if let rawURL = event.url?.value,
            let URLCandidate = URLCandidate(
                rawURL: rawURL,
                rawHost: event.url?.host,
                title: title,
                application: application,
                bundleIdentifier: bundleIdentifier
            )
        {
            output.append(URLCandidate)
        }

        let pathText = [title, semantic].compactMap { $0 }.joined(separator: "\n")
        for path in extractLocalPaths(from: pathText).prefix(4) {
            let fileURL = Foundation.URL(fileURLWithPath: path)
            output.append(
                Candidate(
                    key: "file:\(NSString(string: path).standardizingPath)",
                    kind: .file,
                    title: fileURL.lastPathComponent.isEmpty ? path : fileURL.lastPathComponent,
                    canonicalURI: fileURL.absoluteString,
                    localPath: path,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundleIdentifier,
                    confidence: 0.94
                )
            )
        }

        if output.isEmpty,
            let title,
            looksLikeDocumentTitle(title, application: application)
        {
            let terminal = isTerminal(
                application: application,
                bundleIdentifier: bundleIdentifier
            )
            let kind: ComputerHistoryResourceKind = terminal ? .terminalSession : .document
            output.append(
                Candidate(
                    key: [
                        kind.rawValue,
                        bundleIdentifier ?? application ?? "unknown",
                        ComputerHistorySupport.normalized(title),
                    ].joined(separator: "|"),
                    kind: kind,
                    title: title,
                    canonicalURI: nil,
                    localPath: nil,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundleIdentifier,
                    confidence: terminal ? 0.72 : 0.62
                )
            )
        }

        if output.isEmpty, let application {
            output.append(
                Candidate(
                    key: "app:\(bundleIdentifier ?? ComputerHistorySupport.normalized(application))",
                    kind: .application,
                    title: application,
                    canonicalURI: nil,
                    localPath: nil,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundleIdentifier,
                    confidence: 0.45
                )
            )
        }

        var seen = Set<String>()
        return output.filter { seen.insert($0.key).inserted }
    }

    private static func URLCandidate(
        rawURL: String,
        rawHost: String?,
        title rawTitle: String?,
        application: String?,
        bundleIdentifier: String?
    ) -> Candidate? {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.lowercased().hasPrefix("file://"),
            let parsed = Foundation.URL(string: value)
        {
            let path = parsed.path
            return Candidate(
                key: "file:\(NSString(string: path).standardizingPath)",
                kind: .file,
                title: parsed.lastPathComponent.isEmpty ? path : parsed.lastPathComponent,
                canonicalURI: parsed.absoluteString,
                localPath: path,
                host: nil,
                application: application,
                bundleIdentifier: bundleIdentifier,
                confidence: 0.99
            )
        }

        let parsed = Foundation.URL(string: value)
        let host = ComputerHistorySupport.normalizedHost(rawHost ?? parsed?.host)
        let kind = resourceKind(host: host, URL: value)
        let title = rawTitle.flatMap {
            ComputerHistorySupport.isGenericTitle($0) ? nil : $0
        } ?? host ?? ComputerHistorySupport.bounded(value, maximum: 180)
        let canonical = ComputerHistorySupport.canonicalURL(value)
        return Candidate(
            key: "url:\(canonical ?? value)",
            kind: kind,
            title: title,
            canonicalURI: canonical ?? value,
            localPath: nil,
            host: host,
            application: application,
            bundleIdentifier: bundleIdentifier,
            confidence: canonical == nil ? 0.78 : 0.96
        )
    }

    private static func resourceKind(
        host: String?,
        URL rawURL: String
    ) -> ComputerHistoryResourceKind {
        let host = host?.lowercased() ?? ""
        let URL = rawURL.lowercased()
        if isConversationHost(host) || containsConversationPath(URL) { return .conversation }
        if isIssueURL(host: host, URL: URL) { return .issue }
        if isDocumentHost(host) { return .document }
        return .webPage
    }

    private static func isConversationHost(_ host: String) -> Bool {
        [
            "slack.com", "discord.com", "teams.microsoft.com", "chatgpt.com",
            "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai",
        ].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func containsConversationPath(_ URL: String) -> Bool {
        ["/messages/", "/thread/", "/archives/", "/conversation/", "/chat/", "/c/"]
            .contains { URL.contains($0) }
    }

    private static func isIssueURL(host: String, URL: String) -> Bool {
        let issueHost = host.contains("github")
            || host.contains("gitlab")
            || host.contains("linear")
            || host.contains("atlassian")
            || host.contains("jira")
        return issueHost && [
            "/issues/", "/pull/", "/merge_requests/", "/browse/", "/issue/",
        ].contains { URL.contains($0) }
    }

    private static func isDocumentHost(_ host: String) -> Bool {
        [
            "docs.google.com", "notion.so", "notion.site", "figma.com", "dropbox.com",
            "office.com", "sharepoint.com", "onedrive.live.com", "coda.io", "airtable.com",
        ].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func looksLikeDocumentTitle(
        _ title: String,
        application: String?
    ) -> Bool {
        guard !ComputerHistorySupport.isGenericTitle(title) else { return false }
        let lower = title.lowercased()
        if [
            ".md", ".txt", ".pdf", ".doc", ".docx", ".pages", ".key", ".ppt",
            ".pptx", ".xls", ".xlsx", ".csv", ".swift", ".py", ".ts", ".tsx",
            ".js", ".json", ".yaml", ".yml",
        ].contains(where: { lower.contains($0) }) {
            return true
        }
        let app = application?.lowercased() ?? ""
        return [
            "notes", "notion", "word", "pages", "preview", "xcode", "code",
            "textedit", "terminal",
        ].contains { app.contains($0) }
    }

    private static func isTerminal(
        application: String?,
        bundleIdentifier: String?
    ) -> Bool {
        let identity = [application, bundleIdentifier]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return ["terminal", "iterm", "warp", "alacritty", "kitty", "wezterm"]
            .contains { identity.contains($0) }
    }

    private static func extractLocalPaths(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let patterns = [
            #"(?:file://)?/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\n\r\t\"'<>]{2,500}"#,
            #"~/[^\n\r\t\"'<>]{2,500}"#,
        ]
        var output: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                var value = String(text[swiftRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;()[]{}"))
                if value.hasPrefix("file://"),
                    let parsed = Foundation.URL(string: value)
                {
                    value = parsed.path
                }
                if value.hasPrefix("~/") {
                    value = NSString(string: value).expandingTildeInPath
                }
                guard value.hasPrefix("/"), value.count <= 1_024 else { continue }
                output.append(value)
            }
        }
        return ComputerHistorySupport.distinct(output)
    }
}
