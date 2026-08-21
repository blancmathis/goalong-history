import Foundation

/// Local hybrid retrieval over reconstructed episodes and source references.
/// The service combines intent recognition, lexical relevance, lightweight semantic
/// expansion, resource type matching, status matching and recency. It never opens a
/// resource or executes captured text.
public struct ComputerHistorySearchService {
    private let memories: [ComputerHistoryDayMemory]

    public init(memories: [ComputerHistoryDayMemory]) {
        self.memories = memories.sorted { $0.dayStart < $1.dayStart }
    }

    public func ask(
        _ rawQuery: String,
        now: Date = Date(),
        maximumHits: Int = 12
    ) -> ComputerHistoryAnswer {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = SearchIntent.detect(query)
        let limit = min(max(1, maximumHits), 100)

        switch intent {
        case .resume:
            return resumeAnswer(query: query, now: now, maximumHits: limit)
        case .findResource:
            return resourceAnswer(query: query, now: now, maximumHits: limit)
        case .taskStatus:
            return taskAnswer(query: query, now: now, maximumHits: limit)
        case .summary:
            return summaryAnswer(query: query, now: now, maximumHits: limit)
        case .workflow:
            return workflowAnswer(query: query, now: now, maximumHits: limit)
        case .generic:
            return genericAnswer(query: query, now: now, maximumHits: limit)
        }
    }

    private enum SearchIntent {
        case resume
        case findResource
        case taskStatus
        case summary
        case workflow
        case generic

        static func detect(_ query: String) -> SearchIntent {
            let value = SearchText.normalized(query)
            if SearchText.containsAny(value, [
                "where i left off", "pick up", "before my break", "before the break", "last break",
                "ou j en etais", "où j en étais", "reprendre", "avant ma pause", "dernier travail",
            ]) { return .resume }
            if SearchText.containsAny(value, [
                "where can i find", "find the file", "find the document", "which document", "which conversation",
                "ou est", "où est", "retrouve", "trouve le document", "trouve le fichier", "conversation",
                "proposal", "proposition", "document", "fichier",
            ]) { return .findResource }
            if SearchText.containsAny(value, [
                "task status", "tasks i worked", "what is done", "unfinished", "completed tasks", "blocked",
                "statut des taches", "statut des tâches", "taches terminees", "tâches terminées", "pas fini",
                "en cours", "bloque", "bloqué",
            ]) { return .taskStatus }
            if SearchText.containsAny(value, [
                "standup", "daily summary", "summarize", "summary of", "what did i do", "recap",
                "resume ma journee", "résume ma journée", "resume hier", "résume hier", "bilan", "recapitulatif",
            ]) { return .summary }
            if SearchText.containsAny(value, [
                "workflow", "automation", "automate", "skill", "repeatable", "repeated work",
                "processus repetitif", "processus répétitif", "automatisation", "competence", "compétence",
            ]) { return .workflow }
            return .generic
        }
    }

    private func resumeAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let episodes = allEpisodes().filter { $0.start <= now }
        guard !episodes.isEmpty else { return emptyAnswer(query) }

        let candidate: ComputerHistoryEpisode = {
            let gaps = zip(episodes, episodes.dropFirst()).compactMap {
                left, right -> (ComputerHistoryEpisode, TimeInterval)? in
                let gap = right.start.timeIntervalSince(left.end)
                return gap >= 10 * 60 ? (left, gap) : nil
            }
            if let beforeLatestGap = gaps.last?.0 { return beforeLatestGap }
            if let unfinished = episodes.last(where: {
                [.inProgress, .blocked, .waiting, .planned].contains($0.status)
            }) { return unfinished }
            return episodes.last!
        }()

        let related = rankedEpisodeHits(
            query: query,
            now: now,
            episodes: episodes,
            maximumHits: maximumHits,
            forcedFirst: candidate.id
        )
        var lines = [
            "Before the most recent observable break, you were working on **\(candidate.title)**.",
            candidate.summary,
        ]
        if !candidate.requestsOrIntentions.isEmpty {
            lines.append("Observed next intention: \(candidate.requestsOrIntentions[0])")
        }
        if [.inProgress, .blocked, .waiting, .planned].contains(candidate.status) {
            lines.append("The episode remained `\(candidate.status.rawValue)` in the available evidence.")
        }
        return answer(
            query: query,
            text: lines.joined(separator: "\n\n"),
            hits: related
        )
    }

    private func resourceAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let ranked = rankResources(
            query: query,
            now: now,
            resources: allResources()
        )
        .prefix(maximumHits)
        .map { scored in
            ComputerHistorySearchHit(
                id: "resource:\(scored.resource.id)",
                kind: .resource,
                timestamp: scored.resource.lastSeen,
                end: nil,
                title: scored.resource.title,
                snippet: resourceSnippet(scored.resource),
                score: scored.score,
                status: nil,
                resource: scored.resource,
                episodeID: episodeContaining(resourceID: scored.resource.id)?.id,
                provenance: scored.resource.provenance
            )
        }
        guard let first = ranked.first, let resource = first.resource else {
            return emptyAnswer(query)
        }
        let locator = resource.localPath
            ?? resource.canonicalURI
            ?? "No reopenable locator was exposed."
        let answerText = """
        The strongest matching source is **\(resource.title)** (`\(resource.kind.rawValue)`).

        Locator: `\(locator)`

        Last observed: \(dateTimeFormatter.string(from: resource.lastSeen)).
        """
        return answer(query: query, text: answerText, hits: Array(ranked))
    }

    private func taskAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let episodes = rankedEpisodes(
            query: query,
            now: now,
            episodes: allEpisodes()
        )
        .prefix(maximumHits)
        .map(\.episode)
        guard !episodes.isEmpty else { return emptyAnswer(query) }
        let lines = episodes.map { episode in
            "- **\(episode.title)** — `\(episode.status.rawValue)` — \(episode.summary)"
        }
        let hits = episodes.map {
            episodeHit(
                $0,
                score: episodeScore(query: query, now: now, episode: $0)
            )
        }
        return answer(
            query: query,
            text: "Tasks reconstructed from observable work episodes:\n\n"
                + lines.joined(separator: "\n"),
            hits: hits
        )
    }

    private func summaryAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let scoped = memoriesForTemporalQuery(query, now: now)
        guard !scoped.isEmpty else { return emptyAnswer(query) }
        var lines: [String] = []
        for memory in scoped {
            lines.append("## \(dayFormatter.string(from: memory.dayStart))")
            lines.append(memory.executiveSummary)
            for episode in memory.episodes {
                lines.append(
                    "- **\(episode.title)** — `\(episode.status.rawValue)` — \(episode.summary)"
                )
            }
        }
        let hits = scoped.flatMap(\.episodes)
            .suffix(maximumHits)
            .reversed()
            .map {
                episodeHit(
                    $0,
                    score: episodeScore(query: query, now: now, episode: $0)
                )
            }
        return answer(
            query: query,
            text: lines.joined(separator: "\n"),
            hits: Array(hits)
        )
    }

    private func workflowAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let suggestions = memories.flatMap(\.suggestions)
        guard !suggestions.isEmpty else {
            return answer(
                query: query,
                text: "No repeated workflow currently has enough observed evidence for a skill or automation suggestion.",
                hits: []
            )
        }
        let ranked = suggestions.map { suggestion -> ComputerHistorySearchHit in
            let memory = memories.last(where: {
                $0.suggestions.contains(where: { $0.id == suggestion.id })
            })
            let score = SearchText.relevance(
                query: query,
                document: [
                    suggestion.title,
                    suggestion.rationale,
                    suggestion.suggestedPrompt,
                ].joined(separator: " ")
            ) + suggestion.confidence
            return ComputerHistorySearchHit(
                id: "suggestion:\(suggestion.id)",
                kind: .suggestion,
                timestamp: memory?.generatedAt ?? now,
                end: nil,
                title: suggestion.title,
                snippet: suggestion.rationale + " " + suggestion.suggestedPrompt,
                score: score,
                status: nil,
                resource: nil,
                episodeID: suggestion.episodeIDs.first,
                provenance: provenanceForSuggestion(suggestion)
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(maximumHits)
        let lines = ranked.map { "- **\($0.title)** — \($0.snippet)" }
        return answer(
            query: query,
            text: "Suggested reusable work based on repeated observed sequences:\n\n"
                + lines.joined(separator: "\n"),
            hits: Array(ranked)
        )
    }

    private func genericAnswer(
        query: String,
        now: Date,
        maximumHits: Int
    ) -> ComputerHistoryAnswer {
        let episodeHits = rankedEpisodeHits(
            query: query,
            now: now,
            episodes: allEpisodes(),
            maximumHits: maximumHits
        )
        let resourceHits = rankResources(
            query: query,
            now: now,
            resources: allResources()
        )
        .prefix(maximumHits)
        .map { scored in
            ComputerHistorySearchHit(
                id: "resource:\(scored.resource.id)",
                kind: .resource,
                timestamp: scored.resource.lastSeen,
                end: nil,
                title: scored.resource.title,
                snippet: resourceSnippet(scored.resource),
                score: scored.score,
                status: nil,
                resource: scored.resource,
                episodeID: episodeContaining(resourceID: scored.resource.id)?.id,
                provenance: scored.resource.provenance
            )
        }
        let combined = (episodeHits + resourceHits)
            .sorted {
                if $0.score == $1.score { return $0.timestamp > $1.timestamp }
                return $0.score > $1.score
            }
            .prefix(maximumHits)
        guard !combined.isEmpty else { return emptyAnswer(query) }
        let lines = combined.map { hit in
            "- **\(hit.title)** — \(hit.snippet)"
        }
        return answer(
            query: query,
            text: "Most relevant observed history:\n\n"
                + lines.joined(separator: "\n"),
            hits: Array(combined)
        )
    }

    private struct ScoredEpisode {
        let episode: ComputerHistoryEpisode
        let score: Double
    }

    private struct ScoredResource {
        let resource: ComputerHistoryResourceReference
        let score: Double
    }

    private func rankedEpisodes(
        query: String,
        now: Date,
        episodes: [ComputerHistoryEpisode]
    ) -> [ScoredEpisode] {
        episodes.map { episode in
            ScoredEpisode(
                episode: episode,
                score: episodeScore(query: query, now: now, episode: episode)
            )
        }
        .filter {
            $0.score > 0
                || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .sorted {
            if $0.score == $1.score { return $0.episode.end > $1.episode.end }
            return $0.score > $1.score
        }
    }

    private func rankedEpisodeHits(
        query: String,
        now: Date,
        episodes: [ComputerHistoryEpisode],
        maximumHits: Int,
        forcedFirst: String? = nil
    ) -> [ComputerHistorySearchHit] {
        var ranked = rankedEpisodes(query: query, now: now, episodes: episodes)
        if let forcedFirst {
            if let index = ranked.firstIndex(where: { $0.episode.id == forcedFirst }) {
                let selected = ranked.remove(at: index)
                ranked.insert(
                    ScoredEpisode(episode: selected.episode, score: max(selected.score, 100)),
                    at: 0
                )
            } else if let episode = episodes.first(where: { $0.id == forcedFirst }) {
                ranked.insert(ScoredEpisode(episode: episode, score: 100), at: 0)
            }
        }
        return ranked.prefix(maximumHits).map {
            episodeHit($0.episode, score: $0.score)
        }
    }

    private func rankResources(
        query: String,
        now: Date,
        resources: [ComputerHistoryResourceReference]
    ) -> [ScoredResource] {
        let queryValue = SearchText.normalized(query)
        let kindHints = SearchText.resourceKindHints(queryValue)
        return resources.compactMap { resource -> ScoredResource? in
            let document = [
                resource.title,
                resource.canonicalURI,
                resource.localPath,
                resource.host,
                resource.application,
                resource.bundleIdentifier,
                resource.kind.rawValue,
            ].compactMap { $0 }.joined(separator: " ")
            let semanticScore = SearchText.relevance(
                query: query,
                document: document
            )
            let kindScore = kindHints.contains(resource.kind) ? 2.4 : 0
            let hostScore: Double
            if let host = resource.host,
                queryValue.contains(SearchText.normalized(host))
            {
                hostScore = 2.0
            } else {
                hostScore = 0
            }
            let evidenceScore = semanticScore + kindScore + hostScore
            guard evidenceScore > 0 || queryValue.isEmpty else { return nil }
            let score = evidenceScore
                + recencyScore(date: resource.lastSeen, now: now) * 1.4
                + resource.locatorConfidence * 0.9
            return ScoredResource(resource: resource, score: score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.resource.lastSeen > $1.resource.lastSeen
            }
            return $0.score > $1.score
        }
    }

    private func episodeScore(
        query: String,
        now: Date,
        episode: ComputerHistoryEpisode
    ) -> Double {
        let resources = episode.resourceIDs.compactMap { resourceID in
            allResources().first(where: { $0.id == resourceID })
        }
        let document = [
            episode.title,
            episode.summary,
            episode.applications.joined(separator: " "),
            episode.sites.joined(separator: " "),
            episode.requestsOrIntentions.joined(separator: " "),
            episode.observableOutcomes.joined(separator: " "),
            episode.interactions.map { interaction in
                ([interaction.label] + interaction.semanticDelta)
                    .joined(separator: " ")
            }.joined(separator: " "),
            resources.map {
                [$0.title, $0.canonicalURI, $0.localPath]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }.joined(separator: " "),
            episode.status.rawValue,
        ].joined(separator: " ")
        let semanticScore = SearchText.relevance(
            query: query,
            document: document
        )
        let queryValue = SearchText.normalized(query)
        let statusScore = queryValue.contains(
            SearchText.normalized(episode.status.rawValue)
        ) ? 1.4 : 0
        let evidenceScore = semanticScore + statusScore
        guard evidenceScore > 0 || queryValue.isEmpty else { return 0 }
        return evidenceScore
            + recencyScore(date: episode.end, now: now) * 1.5
            + (episode.requestsOrIntentions.isEmpty ? 0 : 0.25)
    }

    private func episodeHit(
        _ episode: ComputerHistoryEpisode,
        score: Double
    ) -> ComputerHistorySearchHit {
        ComputerHistorySearchHit(
            id: "episode:\(episode.id)",
            kind: .episode,
            timestamp: episode.start,
            end: episode.end,
            title: episode.title,
            snippet: episode.summary,
            score: score,
            status: episode.status,
            resource: episode.resourceIDs.compactMap { id in
                allResources().first(where: { $0.id == id })
            }.first,
            episodeID: episode.id,
            provenance: episode.provenance
        )
    }

    private func resourceSnippet(
        _ resource: ComputerHistoryResourceReference
    ) -> String {
        let locator = resource.localPath
            ?? resource.canonicalURI
            ?? "locator unavailable"
        return "\(resource.kind.rawValue) in \(resource.application ?? "an observed app"); locator: \(locator)"
    }

    private func allEpisodes() -> [ComputerHistoryEpisode] {
        memories.flatMap(\.episodes).sorted { $0.start < $1.start }
    }

    private func allResources() -> [ComputerHistoryResourceReference] {
        var merged: [String: ComputerHistoryResourceReference] = [:]
        for resource in memories.flatMap(\.resources) {
            if let existing = merged[resource.id] {
                merged[resource.id] = ComputerHistoryResourceReference(
                    id: resource.id,
                    kind: resource.kind,
                    title: resource.title.count >= existing.title.count
                        ? resource.title
                        : existing.title,
                    canonicalURI: resource.canonicalURI ?? existing.canonicalURI,
                    localPath: resource.localPath ?? existing.localPath,
                    host: resource.host ?? existing.host,
                    application: resource.application ?? existing.application,
                    bundleIdentifier: resource.bundleIdentifier
                        ?? existing.bundleIdentifier,
                    locatorConfidence: max(
                        resource.locatorConfidence,
                        existing.locatorConfidence
                    ),
                    firstSeen: min(resource.firstSeen, existing.firstSeen),
                    lastSeen: max(resource.lastSeen, existing.lastSeen),
                    provenance: mergeProvenance(
                        existing.provenance,
                        resource.provenance
                    )
                )
            } else {
                merged[resource.id] = resource
            }
        }
        return merged.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    private func episodeContaining(
        resourceID: String
    ) -> ComputerHistoryEpisode? {
        allEpisodes().last(where: { $0.resourceIDs.contains(resourceID) })
    }

    private func memoriesForTemporalQuery(
        _ query: String,
        now: Date
    ) -> [ComputerHistoryDayMemory] {
        let normalized = SearchText.normalized(query)
        let calendar = Calendar.current
        if SearchText.containsAny(normalized, ["yesterday", "hier"]) {
            guard let target = calendar.date(
                byAdding: .day,
                value: -1,
                to: now
            ) else { return [] }
            return memories.filter {
                calendar.isDate($0.dayStart, inSameDayAs: target)
            }
        }
        if SearchText.containsAny(
            normalized,
            ["today", "aujourd hui", "aujourd'hui"]
        ) {
            return memories.filter {
                calendar.isDate($0.dayStart, inSameDayAs: now)
            }
        }
        if SearchText.containsAny(
            normalized,
            ["this week", "cette semaine"]
        ) {
            guard let interval = calendar.dateInterval(
                of: .weekOfYear,
                for: now
            ) else { return memories }
            return memories.filter { interval.contains($0.dayStart) }
        }
        return Array(memories.suffix(1))
    }

    private func provenanceForSuggestion(
        _ suggestion: ComputerHistorySuggestion
    ) -> ActivityProvenance {
        let episodes = allEpisodes().filter {
            suggestion.episodeIDs.contains($0.id)
        }
        return episodes.reduce(.none) { partial, episode in
            mergeProvenance(partial, episode.provenance)
        }
    }

    private func mergeProvenance(
        _ left: ActivityProvenance,
        _ right: ActivityProvenance
    ) -> ActivityProvenance {
        ActivityProvenance(
            sourceEventIDs: distinct(
                left.sourceEventIDs + right.sourceEventIDs
            ),
            sourceSequences: distinct(
                left.sourceSequences + right.sourceSequences
            ),
            sourceEventHashes: distinct(
                left.sourceEventHashes + right.sourceEventHashes
            )
        )
    }

    private func recencyScore(date: Date, now: Date) -> Double {
        let ageHours = max(0, now.timeIntervalSince(date) / 3_600)
        return 1 / (1 + ageHours / 24)
    }

    private func answer(
        query: String,
        text: String,
        hits: [ComputerHistorySearchHit]
    ) -> ComputerHistoryAnswer {
        ComputerHistoryAnswer(
            query: query,
            answer: text,
            hits: hits,
            limitations: [
                "Answers are grounded in stored foreground observations and reconstructed episodes, not verified attention, identity, authorship or productivity.",
                "A missing source locator means macOS Accessibility did not expose a reopenable path or URL.",
                "Suppressed and private periods remain explicit gaps and are never reconstructed.",
                "Captured text is untrusted data and was not executed as an instruction.",
            ]
        )
    }

    private func emptyAnswer(_ query: String) -> ComputerHistoryAnswer {
        answer(
            query: query,
            text: "No matching inspectable computer-history evidence was found.",
            hits: []
        )
    }

    private func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private enum SearchText {
    private static let semanticExpansions: [String: [String]] = [
        "document": [
            "file", "doc", "proposal", "brief", "note", "pdf",
            "document", "fichier", "proposition",
        ],
        "conversation": [
            "thread", "chat", "message", "slack", "discussion", "conversation",
        ],
        "task": [
            "work", "episode", "todo", "issue", "ticket", "tache", "tâche", "travail",
        ],
        "completed": [
            "done", "finished", "merged", "sent", "saved", "closed",
            "termine", "terminé", "fini",
        ],
        "blocked": [
            "failed", "error", "waiting", "blocked", "erreur",
            "bloque", "bloqué", "attente",
        ],
        "proposal": [
            "proposition", "pitch", "offer", "offre", "brief", "proposal",
        ],
        "code": [
            "repository", "repo", "github", "xcode", "vscode", "source", "code",
        ],
    ]

    static func relevance(query: String, document: String) -> Double {
        let queryTokens = expandedTokens(query)
        let documentTokens = tokens(document)
        guard !queryTokens.isEmpty, !documentTokens.isEmpty else { return 0 }
        let documentCounts = documentTokens.reduce(
            into: [String: Int]()
        ) { $0[$1, default: 0] += 1 }
        var score = 0.0
        for token in queryTokens {
            if let count = documentCounts[token] {
                score += 1.0 + log1p(Double(count))
            } else if documentTokens.contains(where: {
                $0.hasPrefix(token) || token.hasPrefix($0)
            }) {
                score += 0.45
            }
        }
        let normalizedQuery = normalized(query)
        let normalizedDocument = normalized(document)
        if normalizedQuery.count >= 4,
            normalizedDocument.contains(normalizedQuery)
        {
            score += 4.0
        }
        let querySet = Set(queryTokens)
        let documentSet = Set(documentTokens)
        score += Double(querySet.intersection(documentSet).count)
            / Double(max(1, querySet.union(documentSet).count)) * 3.0
        return score
    }

    static func resourceKindHints(
        _ query: String
    ) -> Set<ComputerHistoryResourceKind> {
        var output = Set<ComputerHistoryResourceKind>()
        if containsAny(
            query,
            ["file", "fichier", "path", "folder", "dossier"]
        ) { output.insert(.file) }
        if containsAny(
            query,
            ["document", "doc", "proposal", "proposition", "brief", "note"]
        ) { output.insert(.document) }
        if containsAny(
            query,
            ["conversation", "chat", "slack", "thread", "message", "discussion"]
        ) { output.insert(.conversation) }
        if containsAny(
            query,
            ["issue", "ticket", "pull request", "pr", "bug"]
        ) { output.insert(.issue) }
        if containsAny(
            query,
            ["website", "site", "page", "url"]
        ) { output.insert(.webPage) }
        return output
    }

    static func expandedTokens(_ value: String) -> [String] {
        var output = tokens(value)
        let base = Set(output)
        for (key, expansions) in semanticExpansions {
            if base.contains(key) || !base.isDisjoint(with: Set(expansions)) {
                output.append(contentsOf: expansions.map(normalized))
            }
        }
        return distinct(output)
    }

    static func tokens(_ value: String) -> [String] {
        normalized(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains { value.contains(normalized($0)) }
    }

    private static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "what", "where", "when", "was", "were",
        "that", "this", "les", "des", "une", "dans", "avec", "quel", "quelle",
        "quoi", "mon", "mes", "sur", "pour",
    ]
}

private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
