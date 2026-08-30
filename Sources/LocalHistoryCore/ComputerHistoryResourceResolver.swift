import Foundation

struct ComputerHistoryResourceResolution {
    let resources: [ComputerHistoryResourceReference]
    let eventResourceIDs: [String: [String]]
    let semanticSnapshotCount: Int
    /// Sanitized semantic text aligned with the input event array. Values retain the
    /// sanitizer's 6,000-character inference window and are transferred once into
    /// the interaction builder so a second validation, hash and redaction pass is
    /// unnecessary.
    private(set) var interactionSemanticTexts: [String?]

    /// Transfers ownership of the transient inference cache without copying its
    /// backing buffer. The resolution keeps only resources and identifiers after
    /// interaction construction.
    mutating func takeInteractionSemanticTexts() -> [String?] {
        let values = interactionSemanticTexts
        interactionSemanticTexts = []
        return values
    }
}

enum ComputerHistoryResourceResolver {
    private static let largeDayEventThreshold = 1_024
    private static let maximumLargeDayProvenanceReferences = 8
    private static let localPathExpressions: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern:
                #"(?:file://)?/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\n\r\t\"'<>]{2,500}"#
        ),
        try! NSRegularExpression(pattern: #"~/[^\n\r\t\"'<>]{2,500}"#),
    ]
    private static let recognizedFileExtension = try! NSRegularExpression(
        pattern:
            #"\.(?:md|txt|pdf|docx?|pages|key|pptx?|xlsx?|csv|swift|py|tsx?|jsx?|json|ya?ml|toml|heic|mov|mp4|png|jpe?g)\b"#,
        options: [.caseInsensitive]
    )

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

    /// Keeps only the fields needed to reopen source evidence. Retaining complete
    /// `HistoryEvent` values here used to multiply the transient working set for
    /// resources observed many times before the final representative projection.
    private struct SourceReference {
        let timestamp: Date
        let eventID: String
        let sequence: UInt64?
        let eventHash: String?

        init(event: HistoryEvent) {
            timestamp = event.timestamp
            eventID = event.id
            sequence = event.integrity?.sequence
            eventHash = event.integrity?.eventHash
        }
    }

    private struct Builder {
        let resourceID: String
        var candidate: Candidate
        var firstSeen: Date
        var lastSeen: Date
        var firstSource: SourceReference
        var additionalSources: [SourceReference]?

        init(candidate: Candidate, event: HistoryEvent) {
            resourceID = ComputerHistorySupport.stableIdentifier(
                "resource|\(candidate.key)"
            )
            self.candidate = candidate
            firstSeen = event.timestamp
            lastSeen = event.timestamp
            firstSource = SourceReference(event: event)
            additionalSources = nil
        }

        mutating func record(
            event: HistoryEvent,
            maximumReferences: Int?
        ) {
            firstSeen = min(firstSeen, event.timestamp)
            lastSeen = max(lastSeen, event.timestamp)
            let reference = SourceReference(event: event)

            guard let maximumReferences else {
                if additionalSources == nil { additionalSources = [] }
                additionalSources?.append(reference)
                return
            }

            let maximum = max(1, maximumReferences)
            var references = [firstSource]
            references.append(contentsOf: additionalSources ?? [])
            references.append(reference)
            references.sort(by: Self.sourceOrder)

            var seenEventIDs = Set<String>()
            references = references.filter {
                seenEventIDs.insert($0.eventID).inserted
            }
            if references.count > maximum {
                let leadingCount = (maximum + 1) / 2
                let trailingCount = maximum - leadingCount
                references =
                    Array(references.prefix(leadingCount))
                    + Array(references.suffix(trailingCount))
            }

            firstSource = references[0]
            additionalSources =
                references.count > 1
                ? Array(references.dropFirst())
                : nil
        }

        func provenance(maximumReferences: Int?) -> ActivityProvenance {
            var references = [firstSource]
            references.append(contentsOf: additionalSources ?? [])
            references.sort(by: Self.sourceOrder)

            var seenEventIDs = Set<String>()
            references = references.filter {
                seenEventIDs.insert($0.eventID).inserted
            }
            if let maximumReferences, references.count > maximumReferences {
                references = ComputerHistorySupport.representativeElements(
                    references,
                    maximum: maximumReferences
                )
            }
            return ActivityProvenance(
                sourceEventIDs: references.map(\.eventID),
                sourceSequences: ComputerHistorySupport.distinct(
                    references.compactMap(\.sequence)
                ),
                sourceEventHashes: ComputerHistorySupport.distinct(
                    references.compactMap(\.eventHash)
                )
            )
        }

        private static func sourceOrder(
            _ left: SourceReference,
            _ right: SourceReference
        ) -> Bool {
            if left.timestamp == right.timestamp {
                return left.eventID < right.eventID
            }
            return left.timestamp < right.timestamp
        }
    }

    static func resolve(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> ComputerHistoryResourceResolution {
        var builders: [String: Builder] = [:]
        var eventResourceIDs: [String: [String]] = [:]
        eventResourceIDs.reserveCapacity(events.count)
        var semanticSnapshotCount = 0
        var interactionSemanticTexts: [String?] = []
        interactionSemanticTexts.reserveCapacity(events.count)
        let maximumProvenanceReferences =
            events.count > largeDayEventThreshold
            ? maximumLargeDayProvenanceReferences
            : nil

        for event in events {
            autoreleasepool {
                let semantic = ComputerHistorySupport.semanticText(
                    for: event,
                    semanticSnapshots: semanticSnapshots
                )
                if semantic != nil { semanticSnapshotCount += 1 }
                interactionSemanticTexts.append(semantic)
                let candidates = candidates(for: event, semantic: semantic)
                var resourceIDs: [String] = []
                resourceIDs.reserveCapacity(candidates.count)

                for candidate in candidates {
                    if var existing = builders[candidate.key] {
                        resourceIDs.append(existing.resourceID)
                        existing.record(
                            event: event,
                            maximumReferences: maximumProvenanceReferences
                        )
                        if candidate.confidence > existing.candidate.confidence
                            || ComputerHistorySupport.isGenericTitle(existing.candidate.title)
                        {
                            existing.candidate = candidate
                        }
                        builders[candidate.key] = existing
                    } else {
                        let builder = Builder(candidate: candidate, event: event)
                        resourceIDs.append(builder.resourceID)
                        builders[candidate.key] = builder
                    }
                }
                if !resourceIDs.isEmpty {
                    eventResourceIDs[event.id] = ComputerHistorySupport.distinct(
                        resourceIDs
                    )
                }
            }
        }

        var resources = builders.map { _, builder in
            let candidate = builder.candidate
            return ComputerHistoryResourceReference(
                id: builder.resourceID,
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
                provenance: builder.provenance(
                    maximumReferences: maximumProvenanceReferences
                )
            )
        }
        resources.sort {
            if $0.firstSeen == $1.firstSeen {
                if $0.title == $1.title { return $0.id < $1.id }
                return $0.title < $1.title
            }
            return $0.firstSeen < $1.firstSeen
        }
        return ComputerHistoryResourceResolution(
            resources: resources,
            eventResourceIDs: eventResourceIDs,
            semanticSnapshotCount: semanticSnapshotCount,
            interactionSemanticTexts: interactionSemanticTexts
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
        // Internal application and browser URLs (`app://-/…`, `chrome://…`,
        // extension pages, and similar pseudo-locators) cannot reopen a useful web
        // resource. Retain the foreground app/window evidence, but do not surface
        // these implementation details as sites such as “-” or “newtab”.
        guard let scheme = parsed?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        let host = ComputerHistorySupport.normalizedHost(rawHost ?? parsed?.host)
        guard host != nil else { return nil }
        let kind = resourceKind(host: host, URL: value)
        let title =
            rawTitle.flatMap {
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
        let issueHost =
            host.contains("github")
            || host.contains("gitlab")
            || host.contains("linear")
            || host.contains("atlassian")
            || host.contains("jira")
        return issueHost
            && [
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
        var output: [String] = []
        for expression in localPathExpressions {
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                var value = String(text[swiftRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;()[]{}"))
                let valueRange = NSRange(value.startIndex..., in: value)
                if let extensionMatch = recognizedFileExtension.firstMatch(
                    in: value,
                    range: valueRange
                ), extensionMatch.range.location != NSNotFound,
                    extensionMatch.range.upperBound < valueRange.upperBound,
                    let extensionRange = Range(extensionMatch.range, in: value)
                {
                    let suffix = value[extensionRange.upperBound...]
                    if suffix.first?.isWhitespace == true {
                        value = String(value[..<extensionRange.upperBound])
                    }
                }
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
