import Foundation

/// Deterministic, local-first reconstruction of computer activity.
///
/// Unlike the legacy minute-level recap, this engine preserves the chronological action
/// sequence, links before/after Accessibility context, resolves reopenable resources and
/// builds task-shaped episodes. Captured text is treated as untrusted evidence only.
public enum ComputerHistoryEngine {
    public static func analyze(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload] = [:],
        day: Date,
        calendar: Calendar = .current,
        priorMemories: [ComputerHistoryDayMemory] = [],
        generatedAt: Date = Date()
    ) -> ComputerHistoryDayMemory {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let inDay = events
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted(by: eventOrder)

        let captured = inDay.filter { $0.suppressionReason == nil }
        let resourceResult = resolveResources(events: captured, semanticSnapshots: semanticSnapshots)
        let interactions = buildInteractions(
            events: captured,
            semanticSnapshots: semanticSnapshots,
            eventResourceIDs: resourceResult.eventResourceIDs
        )
        let episodes = buildEpisodes(
            interactions: interactions,
            events: inDay,
            resources: resourceResult.resources
        )
        let workflowResult = detectWorkflows(
            currentEpisodes: episodes,
            priorMemories: priorMemories
        )

        let integrity = inDay.compactMap(\.integrity)
        let semanticCount = captured.filter {
            semanticText(for: $0, semanticSnapshots: semanticSnapshots) != nil
        }.count
        let coverage = ComputerHistoryCoverage(
            sourceEventCount: inDay.count,
            actionEventCount: captured.filter(isActionEvent).count,
            semanticSnapshotCount: semanticCount,
            linkedInteractionCount: interactions.count,
            interactionsWithBeforeAndAfterContext: interactions.filter {
                $0.beforeContext != nil && $0.afterContext != nil
            }.count,
            resourceCount: resourceResult.resources.count,
            episodeCount: episodes.count,
            suppressedEventCount: inDay.filter { $0.suppressionReason != nil }.count,
            firstSourceSequence: integrity.first?.sequence,
            lastSourceSequence: integrity.last?.sequence,
            lastSourceEventHash: integrity.last?.eventHash
        )

        let title = makeDayTitle(episodes: episodes, dayStart: dayStart)
        let executiveSummary = makeExecutiveSummary(
            episodes: episodes,
            resources: resourceResult.resources,
            suggestions: workflowResult.suggestions,
            suppressedEventCount: coverage.suppressedEventCount
        )
        let base = ComputerHistoryDayMemory(
            dayStart: dayStart,
            dayEnd: dayEnd.addingTimeInterval(-0.001),
            generatedAt: generatedAt,
            title: title,
            executiveSummary: executiveSummary,
            episodes: episodes,
            resources: resourceResult.resources,
            workflowPatterns: workflowResult.patterns,
            suggestions: workflowResult.suggestions,
            coverage: coverage,
            markdown: ""
        )
        return ComputerHistoryDayMemory(
            schemaVersion: base.schemaVersion,
            dayStart: base.dayStart,
            dayEnd: base.dayEnd,
            generatedAt: base.generatedAt,
            title: base.title,
            executiveSummary: base.executiveSummary,
            episodes: base.episodes,
            resources: base.resources,
            workflowPatterns: base.workflowPatterns,
            suggestions: base.suggestions,
            coverage: base.coverage,
            markdown: ComputerHistoryMarkdownRenderer.render(base),
            securityNotice: base.securityNotice
        )
    }

    private struct ResourceResolutionResult {
        let resources: [ComputerHistoryResourceReference]
        let eventResourceIDs: [String: [String]]
    }

    private struct MutableResource {
        var kind: ComputerHistoryResourceKind
        var title: String
        var canonicalURI: String?
        var localPath: String?
        var host: String?
        var application: String?
        var bundleIdentifier: String?
        var locatorConfidence: Double
        var firstSeen: Date
        var lastSeen: Date
        var events: [HistoryEvent]
    }

    private struct ResourceCandidate {
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

    private static func resolveResources(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> ResourceResolutionResult {
        var builders: [String: MutableResource] = [:]
        var keysByEvent: [String: [String]] = [:]

        for event in events {
            let semantic = semanticText(for: event, semanticSnapshots: semanticSnapshots)
            let candidates = resourceCandidates(for: event, semantic: semantic)
            var eventKeys: [String] = []
            for candidate in candidates {
                eventKeys.append(candidate.key)
                var builder = builders[candidate.key] ?? MutableResource(
                    kind: candidate.kind,
                    title: candidate.title,
                    canonicalURI: candidate.canonicalURI,
                    localPath: candidate.localPath,
                    host: candidate.host,
                    application: candidate.application,
                    bundleIdentifier: candidate.bundleIdentifier,
                    locatorConfidence: candidate.confidence,
                    firstSeen: event.timestamp,
                    lastSeen: event.timestamp,
                    events: []
                )
                builder.firstSeen = min(builder.firstSeen, event.timestamp)
                builder.lastSeen = max(builder.lastSeen, event.timestamp)
                builder.locatorConfidence = max(builder.locatorConfidence, candidate.confidence)
                if builder.title.isEmpty || isGenericTitle(builder.title) {
                    builder.title = candidate.title
                }
                if builder.canonicalURI == nil { builder.canonicalURI = candidate.canonicalURI }
                if builder.localPath == nil { builder.localPath = candidate.localPath }
                if builder.host == nil { builder.host = candidate.host }
                if builder.application == nil { builder.application = candidate.application }
                if builder.bundleIdentifier == nil { builder.bundleIdentifier = candidate.bundleIdentifier }
                builder.events.append(event)
                builders[candidate.key] = builder
            }
            keysByEvent[event.id] = distinct(eventKeys)
        }

        let keyToID = Dictionary(uniqueKeysWithValues: builders.keys.map { key in
            (key, stableIdentifier("resource|\(key)"))
        })
        let resources = builders.map { key, builder in
            ComputerHistoryResourceReference(
                id: keyToID[key]!,
                kind: builder.kind,
                title: bounded(builder.title, maximum: 300),
                canonicalURI: builder.canonicalURI,
                localPath: builder.localPath,
                host: builder.host,
                application: builder.application,
                bundleIdentifier: builder.bundleIdentifier,
                locatorConfidence: builder.locatorConfidence,
                firstSeen: builder.firstSeen,
                lastSeen: builder.lastSeen,
                provenance: provenance(for: builder.events)
            )
        }
        .sorted {
            if $0.firstSeen == $1.firstSeen { return $0.title < $1.title }
            return $0.firstSeen < $1.firstSeen
        }
        let eventResourceIDs = keysByEvent.mapValues { keys in
            keys.compactMap { keyToID[$0] }
        }
        return ResourceResolutionResult(resources: resources, eventResourceIDs: eventResourceIDs)
    }

    private static func resourceCandidates(
        for event: HistoryEvent,
        semantic: String?
    ) -> [ResourceCandidate] {
        let application = event.app?.name
        let bundle = event.app?.bundleIdentifier
        let windowTitle = cleanedTitle(event.window?.title, application: application)
        var output: [ResourceCandidate] = []

        if let rawURL = event.url?.value,
            let candidate = URLResourceParser.candidate(
                rawURL: rawURL,
                host: event.url?.host,
                title: windowTitle,
                application: application,
                bundleIdentifier: bundle
            )
        {
            output.append(candidate)
        }

        let pathCandidates = extractLocalPaths(from: [windowTitle, semantic].compactMap { $0 }.joined(separator: "\n"))
        for path in pathCandidates.prefix(4) {
            let title = URL(fileURLWithPath: path).lastPathComponent
            let key = "file:\(path.standardizedPathKey)"
            output.append(
                ResourceCandidate(
                    key: key,
                    kind: .file,
                    title: title.isEmpty ? path : title,
                    canonicalURI: URL(fileURLWithPath: path).absoluteString,
                    localPath: path,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundle,
                    confidence: 0.94
                )
            )
        }

        if output.isEmpty, let title = windowTitle, looksLikeDocumentTitle(title, application: application) {
            let kind: ComputerHistoryResourceKind = isTerminal(application: application, bundleIdentifier: bundle)
                ? .terminalSession
                : .document
            let key = [kind.rawValue, bundle ?? application ?? "", normalized(title)].joined(separator: "|")
            output.append(
                ResourceCandidate(
                    key: key,
                    kind: kind,
                    title: title,
                    canonicalURI: nil,
                    localPath: nil,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundle,
                    confidence: kind == .terminalSession ? 0.72 : 0.62
                )
            )
        }

        if output.isEmpty, let application {
            let key = "app:\(bundle ?? normalized(application))"
            output.append(
                ResourceCandidate(
                    key: key,
                    kind: .application,
                    title: application,
                    canonicalURI: nil,
                    localPath: nil,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundle,
                    confidence: 0.45
                )
            )
        }
        return deduplicateCandidates(output)
    }

    private enum URLResourceParser {
        static func candidate(
            rawURL: String,
            host rawHost: String?,
            title rawTitle: String?,
            application: String?,
            bundleIdentifier: String?
        ) -> ResourceCandidate? {
            let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            if value.lowercased().hasPrefix("file://"), let URL = URL(string: value) {
                let path = URL.path
                return ResourceCandidate(
                    key: "file:\(path.standardizedPathKey)",
                    kind: .file,
                    title: URL.lastPathComponent.isEmpty ? path : URL.lastPathComponent,
                    canonicalURI: URL.absoluteString,
                    localPath: path,
                    host: nil,
                    application: application,
                    bundleIdentifier: bundleIdentifier,
                    confidence: 0.99
                )
            }

            let host = normalizedHost(rawHost ?? URL(string: value)?.host)
            let title = rawTitle.flatMap { isGenericTitle($0) ? nil : $0 }
                ?? host
                ?? bounded(value, maximum: 180)
            let lowerHost = host?.lowercased() ?? ""
            let lowerURL = value.lowercased()
            let kind: ComputerHistoryResourceKind
            if isConversationHost(lowerHost) || containsConversationPath(lowerURL) {
                kind = .conversation
            } else if isIssueURL(host: lowerHost, URL: lowerURL) {
                kind = .issue
            } else if isDocumentHost(lowerHost) {
                kind = .document
            } else {
                kind = .webPage
            }
            let canonical = canonicalizeURL(value)
            let key = "url:\(canonical ?? value)"
            return ResourceCandidate(
                key: key,
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
    }

    private struct SemanticObservation {
        let event: HistoryEvent
        let text: String
        let interactionID: String?
        let phase: String?
    }

    private static func buildInteractions(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload],
        eventResourceIDs: [String: [String]]
    ) -> [ComputerHistoryInteraction] {
        let ordered = events.sorted(by: eventOrder)
        let semantic = ordered.compactMap { event -> SemanticObservation? in
            guard let text = semanticText(for: event, semanticSnapshots: semanticSnapshots) else { return nil }
            return SemanticObservation(
                event: event,
                text: bounded(text, maximum: 6_000),
                interactionID: event.metadata?[ComputerHistoryMetadata.interactionID],
                phase: event.metadata?[ComputerHistoryMetadata.interactionPhase]
            )
        }
        let linked = Dictionary(grouping: semantic.compactMap { observation -> (String, SemanticObservation)? in
            guard let interactionID = observation.interactionID else { return nil }
            return (interactionID, observation)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        var interactions: [ComputerHistoryInteraction] = []
        for event in ordered where isActionEvent(event) {
            let interactionID = event.metadata?[ComputerHistoryMetadata.interactionID] ?? event.id
            let explicit = linked[interactionID] ?? []
            let before = explicit.last(where: { $0.phase == ComputerHistoryMetadata.Phase.before })
                ?? nearestSemantic(before: event, observations: semantic)
            let after = explicit.last(where: {
                $0.phase == ComputerHistoryMetadata.Phase.settled
                    || $0.phase == ComputerHistoryMetadata.Phase.after
            }) ?? nearestSemantic(after: event, observations: semantic)
            let beforeText = before?.text
            let afterText = after?.text
            let directDelta = event.metadata?[ComputerHistoryMetadata.semanticDelta]
                .map(splitSemanticLines)
                ?? []
            let delta = directDelta.isEmpty
                ? semanticDelta(before: beforeText, after: afterText)
                : directDelta
            let linkedEvents = distinctEvents(
                [event] + [before?.event, after?.event].compactMap { $0 }
            )
            let end = max(event.timestamp, after?.event.timestamp ?? event.timestamp)
            let pairConfidence: Double
            if beforeText != nil && afterText != nil { pairConfidence = 0.98 }
            else if beforeText != nil || afterText != nil { pairConfidence = 0.82 }
            else { pairConfidence = 0.66 }

            interactions.append(
                ComputerHistoryInteraction(
                    id: stableIdentifier("interaction|\(interactionID)"),
                    start: event.timestamp,
                    end: end,
                    action: actionKind(for: event),
                    label: actionLabel(for: event),
                    application: event.app?.name,
                    bundleIdentifier: event.app?.bundleIdentifier,
                    host: normalizedHost(event.url?.host),
                    resourceIDs: eventResourceIDs[event.id] ?? [],
                    beforeContext: beforeText.map { bounded($0, maximum: 1_800) },
                    afterContext: afterText.map { bounded($0, maximum: 1_800) },
                    semanticDelta: delta.map { bounded($0, maximum: 500) }.prefixArray(10),
                    confidence: pairConfidence,
                    provenance: provenance(for: linkedEvents)
                )
            )
        }
        return interactions.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
    }

    private static func nearestSemantic(
        before event: HistoryEvent,
        observations: [SemanticObservation]
    ) -> SemanticObservation? {
        observations
            .filter {
                $0.event.timestamp <= event.timestamp
                    && event.timestamp.timeIntervalSince($0.event.timestamp) <= 20
                    && sameApplication($0.event, event)
            }
            .max(by: { $0.event.timestamp < $1.event.timestamp })
    }

    private static func nearestSemantic(
        after event: HistoryEvent,
        observations: [SemanticObservation]
    ) -> SemanticObservation? {
        observations
            .filter {
                $0.event.timestamp >= event.timestamp
                    && $0.event.timestamp.timeIntervalSince(event.timestamp) <= 20
                    && sameApplication($0.event, event)
            }
            .min(by: { $0.event.timestamp < $1.event.timestamp })
    }

    private struct EpisodeBuilder {
        var interactions: [ComputerHistoryInteraction]

        var first: ComputerHistoryInteraction { interactions[0] }
        var last: ComputerHistoryInteraction { interactions[interactions.count - 1] }

        mutating func append(_ interaction: ComputerHistoryInteraction) {
            interactions.append(interaction)
        }
    }

    private static func buildEpisodes(
        interactions: [ComputerHistoryInteraction],
        events: [HistoryEvent],
        resources: [ComputerHistoryResourceReference]
    ) -> [ComputerHistoryEpisode] {
        guard !interactions.isEmpty else { return [] }
        let suppressed = events.filter { $0.suppressionReason != nil }.map(\.timestamp)
        var builders: [EpisodeBuilder] = []
        for interaction in interactions {
            guard var previous = builders.popLast() else {
                builders.append(EpisodeBuilder(interactions: [interaction]))
                continue
            }
            if shouldMerge(previous, interaction, suppressedTimestamps: suppressed) {
                previous.append(interaction)
                builders.append(previous)
            } else {
                builders.append(previous)
                builders.append(EpisodeBuilder(interactions: [interaction]))
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        return builders.map { builder in
            finishEpisode(builder, events: events, resources: byID)
        }
    }

    private static func shouldMerge(
        _ builder: EpisodeBuilder,
        _ next: ComputerHistoryInteraction,
        suppressedTimestamps: [Date]
    ) -> Bool {
        let previous = builder.last
        let gap = next.start.timeIntervalSince(previous.end)
        guard gap >= -1, gap <= 20 * 60 else { return false }
        if suppressedTimestamps.contains(where: { $0 > previous.end && $0 < next.start }) {
            return false
        }

        let sharedResources = !Set(previous.resourceIDs).isDisjoint(with: Set(next.resourceIDs))
        if sharedResources { return gap <= 20 * 60 }
        if let left = previous.host, let right = next.host, left == right { return gap <= 10 * 60 }
        if let left = previous.bundleIdentifier, let right = next.bundleIdentifier, left == right {
            return gap <= 8 * 60
        }
        if previous.application == next.application, previous.application != nil { return gap <= 8 * 60 }

        let contextSimilarity = tokenSimilarity(
            [previous.label] + previous.semanticDelta,
            [next.label] + next.semanticDelta
        )
        if contextSimilarity >= 0.18 { return gap <= 6 * 60 }
        if gap <= 90 { return true }
        return false
    }

    private static func finishEpisode(
        _ builder: EpisodeBuilder,
        events: [HistoryEvent],
        resources: [String: ComputerHistoryResourceReference]
    ) -> ComputerHistoryEpisode {
        let interactions = builder.interactions
        let start = interactions.first?.start ?? Date()
        let end = interactions.last?.end ?? start
        let scopedEvents = events.filter { $0.timestamp >= start && $0.timestamp <= end.addingTimeInterval(1) }
        let resourceIDs = distinct(interactions.flatMap(\.resourceIDs))
        let episodeResources = resourceIDs.compactMap { resources[$0] }
        let applications = rankedDistinct(interactions.compactMap(\.application))
        let sites = rankedDistinct(interactions.compactMap(\.host))
        let semanticLines = interactions.flatMap { interaction in
            interaction.semanticDelta
                + interaction.afterContext.map(splitSemanticLines) ?? []
        }
        let requests = distinct(
            semanticLines.filter(looksLikeRequestOrIntention),
            maximum: 12,
            maximumLength: 360
        )
        let outcomes = observableOutcomes(interactions: interactions, semanticLines: semanticLines)
        let statusResult = inferStatus(
            interactions: interactions,
            semanticLines: semanticLines,
            requests: requests
        )
        let title = episodeTitle(
            requests: requests,
            outcomes: outcomes,
            resources: episodeResources,
            interactions: interactions,
            applications: applications
        )
        let summary = episodeSummary(
            title: title,
            interactions: interactions,
            resources: episodeResources,
            requests: requests,
            outcomes: outcomes,
            status: statusResult.status
        )
        let fingerprint = workflowFingerprint(interactions: interactions, resources: resources)
        let sourceIDs = Set(interactions.flatMap { $0.provenance.sourceEventIDs })
        let sourceSequences = Set(interactions.flatMap { $0.provenance.sourceSequences })
        let episodeEvents = scopedEvents.filter { event in
            sourceIDs.contains(event.id)
                || event.integrity.map { sourceSequences.contains($0.sequence) } == true
                || (event.timestamp >= start && event.timestamp <= end)
        }
        return ComputerHistoryEpisode(
            id: stableIdentifier("episode|\(start.timeIntervalSince1970)|\(fingerprint)"),
            start: start,
            end: end,
            title: title,
            summary: summary,
            status: statusResult.status,
            statusConfidence: statusResult.confidence,
            applications: applications,
            sites: sites,
            resourceIDs: resourceIDs,
            requestsOrIntentions: requests,
            observableOutcomes: outcomes,
            interactions: interactions,
            eventCount: episodeEvents.count,
            semanticSnapshotCount: episodeEvents.filter { $0.kind == .semanticSnapshot }.count,
            workflowFingerprint: fingerprint,
            provenance: provenance(for: episodeEvents)
        )
    }

    private struct WorkflowResult {
        let patterns: [ComputerHistoryWorkflowPattern]
        let suggestions: [ComputerHistorySuggestion]
    }

    private static func detectWorkflows(
        currentEpisodes: [ComputerHistoryEpisode],
        priorMemories: [ComputerHistoryDayMemory]
    ) -> WorkflowResult {
        let historical = priorMemories.flatMap(\.episodes)
        let all = historical + currentEpisodes
        var clusters: [[ComputerHistoryEpisode]] = []
        for episode in all where episode.interactions.count >= 3 {
            if let index = clusters.firstIndex(where: { cluster in
                guard let representative = cluster.first else { return false }
                return representative.workflowFingerprint == episode.workflowFingerprint
                    || workflowSimilarity(representative, episode) >= 0.72
            }) {
                clusters[index].append(episode)
            } else {
                clusters.append([episode])
            }
        }

        let repeated = clusters.filter { cluster in
            Set(cluster.map(\.id)).count >= 2
        }
        let patterns = repeated.map { cluster -> ComputerHistoryWorkflowPattern in
            let representative = cluster.sorted { $0.interactions.count > $1.interactions.count }.first!
            let actionSequence = compactActionSequence(representative.interactions)
            let occurrenceCount = Set(cluster.map(\.id)).count
            let applications = rankedDistinct(cluster.flatMap(\.applications))
            let fingerprint = representative.workflowFingerprint
            return ComputerHistoryWorkflowPattern(
                id: stableIdentifier("workflow|\(fingerprint)"),
                fingerprint: fingerprint,
                title: sentenceTitle(representative.title, maximum: 100),
                occurrenceCount: occurrenceCount,
                episodeIDs: distinct(cluster.map(\.id)),
                actionSequence: actionSequence,
                applications: applications,
                confidence: min(0.98, 0.65 + Double(occurrenceCount) * 0.08)
            )
        }
        .sorted {
            if $0.occurrenceCount == $1.occurrenceCount { return $0.title < $1.title }
            return $0.occurrenceCount > $1.occurrenceCount
        }

        let suggestions = patterns.prefix(8).map { pattern -> ComputerHistorySuggestion in
            let crossApp = pattern.applications.count >= 2
            let kind: ComputerHistorySuggestionKind = pattern.occurrenceCount >= 3 && crossApp
                ? .automation
                : .skill
            let titlePrefix = kind == .automation ? "Automate" : "Create a skill for"
            let title = "\(titlePrefix) \(pattern.title.lowercased())"
            let sequence = pattern.actionSequence.prefix(8).joined(separator: " → ")
            let rationale = "Observed \(pattern.occurrenceCount) similar workflow occurrences"
                + (sequence.isEmpty ? "." : ": \(sequence).")
            let prompt: String
            if kind == .automation {
                prompt = "Create an automation that reproduces this reviewed workflow: \(sequence). Ask before any destructive, external or irreversible step."
            } else {
                prompt = "Create a reusable skill from this reviewed workflow: \(sequence). Preserve the observed order, required inputs and verification steps."
            }
            return ComputerHistorySuggestion(
                id: stableIdentifier("suggestion|\(kind.rawValue)|\(pattern.id)"),
                kind: kind,
                title: sentenceTitle(title, maximum: 120),
                rationale: rationale,
                suggestedPrompt: prompt,
                workflowID: pattern.id,
                episodeIDs: pattern.episodeIDs,
                confidence: pattern.confidence
            )
        }
        return WorkflowResult(patterns: patterns, suggestions: suggestions)
    }

    private static func makeDayTitle(episodes: [ComputerHistoryEpisode], dayStart: Date) -> String {
        guard let primary = episodes.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }) else {
            return "Computer history — \(dayFormatter.string(from: dayStart))"
        }
        if episodes.count == 1 { return primary.title }
        return "\(primary.title) and \(episodes.count - 1) other work episode\(episodes.count == 2 ? "" : "s")"
    }

    private static func makeExecutiveSummary(
        episodes: [ComputerHistoryEpisode],
        resources: [ComputerHistoryResourceReference],
        suggestions: [ComputerHistorySuggestion],
        suppressedEventCount: Int
    ) -> String {
        guard !episodes.isEmpty else {
            return suppressedEventCount > 0
                ? "No inspectable activity episode was available; some source events were intentionally suppressed."
                : "No inspectable activity episode was available."
        }
        let completed = episodes.filter { $0.status == .completed }.count
        let unfinished = episodes.filter { [.inProgress, .blocked, .waiting, .planned].contains($0.status) }.count
        var parts = [
            "Reconstructed \(episodes.count) chronological work episode\(episodes.count == 1 ? "" : "s") from the full interaction sequence",
            "linked \(resources.count) identifiable resource\(resources.count == 1 ? "" : "s")",
        ]
        if completed > 0 { parts.append("found \(completed) episode\(completed == 1 ? "" : "s") with observable completion signals") }
        if unfinished > 0 { parts.append("kept \(unfinished) unfinished or waiting episode\(unfinished == 1 ? "" : "s") explicit") }
        if !suggestions.isEmpty { parts.append("detected \(suggestions.count) repeatable-work suggestion\(suggestions.count == 1 ? "" : "s")") }
        if suppressedEventCount > 0 { parts.append("preserved \(suppressedEventCount) suppressed event\(suppressedEventCount == 1 ? "" : "s") as coverage gaps") }
        return parts.joined(separator: "; ") + "."
    }

    private static func actionKind(for event: HistoryEvent) -> ComputerHistoryActionKind {
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

    private static func actionLabel(for event: HistoryEvent) -> String {
        let target = [event.element?.title, event.element?.label, event.element?.identifier]
            .compactMap { cleanOptional($0, maximum: 220) }
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
            return keys.isEmpty ? "Used a keyboard shortcut" : "Used shortcut \(keys.joined(separator: "+"))"
        case .keyPressed:
            return event.keyboard?.key.map { "Pressed \($0)" } ?? "Pressed a navigation key"
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
            return event.window?.title.map { "Opened or focused window \(bounded($0, maximum: 220))" }
                ?? "Changed window"
        case .urlChanged:
            return event.window?.title.map { "Opened page \(bounded($0, maximum: 220))" }
                ?? event.url?.value.map { "Opened \(bounded($0, maximum: 220))" }
                ?? "Changed page"
        case .focusChanged:
            return target.map { "Focused \($0)" } ?? "Changed focused control"
        default:
            return "Observed \(event.kind.rawValue)"
        }
    }

    private static func isActionEvent(_ event: HistoryEvent) -> Bool {
        switch event.kind {
        case .mouseClick, .typingBurst, .keyboardShortcut, .keyPressed, .scrollBurst,
            .applicationActivated, .windowChanged, .urlChanged, .focusChanged:
            return true
        default:
            return false
        }
    }

    private static func semanticText(
        for event: HistoryEvent,
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> String? {
        SemanticContextResolver.text(
            for: event,
            semanticSnapshots: semanticSnapshots
        ).flatMap { ActivitySemanticTextSanitizer.clean($0, maximumLength: 6_000) }
    }

    private static func semanticDelta(before: String?, after: String?) -> [String] {
        guard let after else { return [] }
        let beforeLines = splitSemanticLines(before ?? "")
        let afterLines = splitSemanticLines(after)
        return afterLines.filter { line in
            !beforeLines.contains(where: { tokenSimilarity([$0], [line]) >= 0.88 })
        }
        .filter { $0.count >= 3 }
        .prefixArray(10)
    }

    private static func observableOutcomes(
        interactions: [ComputerHistoryInteraction],
        semanticLines: [String]
    ) -> [String] {
        let completionMarkers = [
            "saved", "sent", "submitted", "published", "merged", "closed", "resolved",
            "deployed", "passed", "success", "completed", "done", "created", "updated",
            "enregistr", "envoy", "publi", "fusionn", "fermé", "résolu", "réussi", "terminé",
        ]
        var output: [String] = []
        for line in semanticLines where containsAny(normalized(line), markers: completionMarkers) {
            output.append(bounded(line, maximum: 360))
        }
        if output.isEmpty, let lastDelta = interactions.reversed().flatMap(\.semanticDelta).first {
            output.append("Last observable change: \(bounded(lastDelta, maximum: 320))")
        } else if output.isEmpty, let last = interactions.last {
            output.append("Last observable action: \(last.label)")
        }
        return distinct(output, maximum: 8, maximumLength: 360)
    }

    private static func inferStatus(
        interactions: [ComputerHistoryInteraction],
        semanticLines: [String],
        requests: [String]
    ) -> (status: ComputerHistoryTaskStatus, confidence: Double) {
        let text = normalized((semanticLines + interactions.map(\.label)).joined(separator: " "))
        let blocked = [" error ", " failed ", " failure ", " blocked ", " cannot ", " impossible ", " erreur ", " échoué ", " bloqué "]
        let waiting = [" waiting ", " pending ", " awaiting ", " review requested ", " en attente ", " attend "]
        let completed = [" saved ", " sent ", " submitted ", " published ", " merged ", " closed ", " resolved ", " deployed ", " tests passed ", " success ", " completed ", " done ", " enregistré ", " envoyé ", " publié ", " fusionné ", " fermé ", " résolu ", " réussi ", " terminé "]
        let padded = " \(text) "
        if containsAny(padded, markers: blocked) { return (.blocked, 0.82) }
        if containsAny(padded, markers: waiting) { return (.waiting, 0.78) }
        if containsAny(padded, markers: completed), !padded.contains(" not completed "), !padded.contains(" pas terminé ") {
            return (.completed, 0.78)
        }
        let productiveActions = interactions.filter {
            [.click, .typing, .shortcut, .navigationKey].contains($0.action)
        }
        if productiveActions.isEmpty, !requests.isEmpty { return (.planned, 0.68) }
        if !productiveActions.isEmpty { return (.inProgress, 0.72) }
        return (.unknown, 0.45)
    }

    private static func episodeTitle(
        requests: [String],
        outcomes: [String],
        resources: [ComputerHistoryResourceReference],
        interactions: [ComputerHistoryInteraction],
        applications: [String]
    ) -> String {
        if let request = requests.first { return sentenceTitle(request, maximum: 100) }
        if let resource = resources.first(where: { $0.kind != .application }) {
            return "Worked on \(bounded(resource.title, maximum: 86))"
        }
        if let outcome = outcomes.first, !outcome.hasPrefix("Last observable") {
            return sentenceTitle(outcome, maximum: 100)
        }
        if let delta = interactions.flatMap(\.semanticDelta).first {
            return sentenceTitle(delta, maximum: 100)
        }
        if let application = applications.first { return "Worked in \(application)" }
        return "Foreground computer activity"
    }

    private static func episodeSummary(
        title: String,
        interactions: [ComputerHistoryInteraction],
        resources: [ComputerHistoryResourceReference],
        requests: [String],
        outcomes: [String],
        status: ComputerHistoryTaskStatus
    ) -> String {
        var parts: [String] = []
        if !resources.isEmpty {
            parts.append("Resources: " + resources.prefix(4).map(\.title).joined(separator: ", "))
        }
        let meaningful = interactions.filter {
            ![.scroll, .focusChange, .contextObservation].contains($0.action)
        }
        let sequence = meaningful.prefix(10).map(\.label)
        if !sequence.isEmpty { parts.append("Observed sequence: " + sequence.joined(separator: " → ")) }
        if let request = requests.first { parts.append("Observed intention: \(request)") }
        if let outcome = outcomes.first { parts.append(outcome) }
        parts.append("Status: \(status.rawValue)")
        let summary = parts.joined(separator: ". ")
        return summary.isEmpty ? title : summary + "."
    }

    private static func workflowFingerprint(
        interactions: [ComputerHistoryInteraction],
        resources: [String: ComputerHistoryResourceReference]
    ) -> String {
        let sequence = interactions.compactMap { interaction -> String? in
            guard ![.scroll, .focusChange, .contextObservation].contains(interaction.action) else { return nil }
            let application = interaction.bundleIdentifier ?? normalized(interaction.application ?? "unknown")
            let kind = interaction.resourceIDs.compactMap { resources[$0]?.kind.rawValue }.first ?? "none"
            return "\(application):\(interaction.action.rawValue):\(kind)"
        }
        let compact = collapseConsecutive(sequence).prefixArray(12)
        return stableIdentifier("workflow|" + compact.joined(separator: "→"))
    }

    private static func compactActionSequence(_ interactions: [ComputerHistoryInteraction]) -> [String] {
        let values = interactions.compactMap { interaction -> String? in
            guard ![.scroll, .focusChange, .contextObservation].contains(interaction.action) else { return nil }
            let app = interaction.application.map { " in \($0)" } ?? ""
            return interaction.action.rawValue + app
        }
        return collapseConsecutive(values).prefixArray(12)
    }

    private static func workflowSimilarity(
        _ left: ComputerHistoryEpisode,
        _ right: ComputerHistoryEpisode
    ) -> Double {
        let leftSequence = Set(compactActionSequence(left.interactions).map(normalized))
        let rightSequence = Set(compactActionSequence(right.interactions).map(normalized))
        guard !leftSequence.isEmpty, !rightSequence.isEmpty else { return 0 }
        let actionScore = Double(leftSequence.intersection(rightSequence).count)
            / Double(leftSequence.union(rightSequence).count)
        let appScore = jaccard(Set(left.applications.map(normalized)), Set(right.applications.map(normalized)))
        let titleScore = tokenSimilarity([left.title], [right.title])
        return actionScore * 0.55 + appScore * 0.25 + titleScore * 0.20
    }

    private static func resourceKind(
        host: String?,
        URL: String
    ) -> ComputerHistoryResourceKind {
        let lowerHost = host?.lowercased() ?? ""
        let lowerURL = URL.lowercased()
        if isConversationHost(lowerHost) || containsConversationPath(lowerURL) { return .conversation }
        if isIssueURL(host: lowerHost, URL: lowerURL) { return .issue }
        if isDocumentHost(lowerHost) { return .document }
        return .webPage
    }

    private static func isConversationHost(_ host: String) -> Bool {
        [
            "slack.com", "discord.com", "teams.microsoft.com", "chatgpt.com", "chat.openai.com",
            "claude.ai", "gemini.google.com", "perplexity.ai", "messages.google.com",
        ].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func containsConversationPath(_ URL: String) -> Bool {
        ["/messages/", "/thread/", "/archives/", "/conversation/", "/chat/", "/c/"].contains {
            URL.contains($0)
        }
    }

    private static func isIssueURL(host: String, URL: String) -> Bool {
        let issueHost = host.contains("github") || host.contains("gitlab") || host.contains("linear")
            || host.contains("atlassian") || host.contains("jira")
        return issueHost && ["/issues/", "/pull/", "/merge_requests/", "/browse/", "/issue/"].contains {
            URL.contains($0)
        }
    }

    private static func isDocumentHost(_ host: String) -> Bool {
        [
            "docs.google.com", "notion.so", "notion.site", "figma.com", "dropbox.com",
            "office.com", "sharepoint.com", "onedrive.live.com", "coda.io", "airtable.com",
        ].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func canonicalizeURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.fragment = nil
        let sensitiveNames = ["token", "key", "auth", "session", "code", "secret", "password"]
        components.queryItems = components.queryItems?.map { item in
            if sensitiveNames.contains(where: { item.name.lowercased().contains($0) }) {
                return URLQueryItem(name: item.name, value: "[REDACTED]")
            }
            return item
        }
        return components.string
    }

    private static func extractLocalPaths(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let patterns = [
            #"(?:file://)?/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\n\r\t\"'<>]{2,500}"#,
            #"~/(?:[^\n\r\t\"'<>]{2,500})"#,
        ]
        var output: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                var value = String(text[swiftRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;()[]{}"))
                if value.hasPrefix("file://"), let URL = URL(string: value) { value = URL.path }
                if value.hasPrefix("~/") {
                    value = NSString(string: value).expandingTildeInPath
                }
                guard value.hasPrefix("/"), value.count <= 1_024 else { continue }
                output.append(value)
            }
        }
        return distinct(output)
    }

    private static func looksLikeDocumentTitle(_ title: String, application: String?) -> Bool {
        guard !isGenericTitle(title) else { return false }
        let lower = title.lowercased()
        let extensions = [
            ".md", ".txt", ".pdf", ".doc", ".docx", ".pages", ".key", ".ppt", ".pptx",
            ".xls", ".xlsx", ".csv", ".swift", ".py", ".ts", ".tsx", ".js", ".json", ".yaml", ".yml",
        ]
        if extensions.contains(where: { lower.contains($0) }) { return true }
        let app = application?.lowercased() ?? ""
        return ["notes", "notion", "word", "pages", "preview", "xcode", "code", "textedit", "terminal"].contains {
            app.contains($0)
        }
    }

    private static func isTerminal(application: String?, bundleIdentifier: String?) -> Bool {
        let value = [application, bundleIdentifier].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["terminal", "iterm", "warp", "alacritty", "kitty", "wezterm"].contains {
            value.contains($0)
        }
    }

    private static func cleanedTitle(_ raw: String?, application: String?) -> String? {
        guard var value = ActivitySemanticTextSanitizer.clean(raw, maximumLength: 300) else { return nil }
        if let application {
            let suffixes = [" — \(application)", " - \(application)", " | \(application)", " – \(application)"]
            for suffix in suffixes where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.isEmpty ? nil : value
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        let key = normalized(value)
        return [
            "new tab", "untitled", "home", "window", "document", "chatgpt", "claude",
            "google", "safari", "chrome", "firefox", "finder", "terminal",
        ].contains(key)
    }

    private static func looksLikeRequestOrIntention(_ value: String) -> Bool {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 10, cleaned.count <= 500 else { return false }
        let lower = normalized(cleaned)
        let prefixes = [
            "add ", "analyze ", "analyse ", "build ", "check ", "cherche ", "compare ", "create ",
            "cree ", "crée ", "design ", "dis moi ", "donne ", "explain ", "fais ", "fix ",
            "help ", "improve ", "je veux ", "j aimerais ", "make ", "optimize ", "optimise ",
            "please ", "prepare ", "refactor ", "resume ", "résume ", "summarize ", "trouve ",
            "update ", "verify ", "verifie ", "vérifie ", "write ", "we need ", "i want ",
        ]
        return cleaned.contains("?") || prefixes.contains(where: { lower.hasPrefix($0) })
    }

    private static func splitSemanticLines(_ value: String) -> [String] {
        value
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: " • ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func sameApplication(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        if let leftBundle = left.app?.bundleIdentifier, let rightBundle = right.app?.bundleIdentifier {
            return leftBundle == rightBundle
        }
        return left.app?.name == right.app?.name
    }

    private static func eventOrder(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        if left.timestamp == right.timestamp { return left.id < right.id }
        return left.timestamp < right.timestamp
    }

    private static func provenance(for events: [HistoryEvent]) -> ActivityProvenance {
        let ordered = distinctEvents(events.sorted(by: eventOrder))
        return ActivityProvenance(
            sourceEventIDs: ordered.map(\.id),
            sourceSequences: distinct(ordered.compactMap { $0.integrity?.sequence }),
            sourceEventHashes: distinct(ordered.compactMap { $0.integrity?.eventHash })
        )
    }

    private static func distinctEvents(_ events: [HistoryEvent]) -> [HistoryEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }
    }

    private static func deduplicateCandidates(_ candidates: [ResourceCandidate]) -> [ResourceCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.key).inserted }
    }

    private static func rankedDistinct(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var first: [String: Int] = [:]
        for (index, value) in values.enumerated() where !value.isEmpty {
            counts[value, default: 0] += 1
            if first[value] == nil { first[value] = index }
        }
        return counts.keys.sorted {
            let left = counts[$0] ?? 0
            let right = counts[$1] ?? 0
            if left == right { return (first[$0] ?? 0) < (first[$1] ?? 0) }
            return left > right
        }
    }

    private static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func distinct(
        _ values: [String],
        maximum: Int,
        maximumLength: Int
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let cleaned = bounded(value, maximum: maximumLength)
            let key = normalized(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(cleaned)
            if output.count >= maximum { break }
        }
        return output
    }

    private static func collapseConsecutive(_ values: [String]) -> [String] {
        var output: [String] = []
        for value in values where output.last != value { output.append(value) }
        return output
    }

    private static func tokenSimilarity(_ left: [String], _ right: [String]) -> Double {
        let leftTokens = Set(left.flatMap(tokens))
        let rightTokens = Set(right.flatMap(tokens))
        return jaccard(leftTokens, rightTokens)
    }

    private static func jaccard<T: Hashable>(_ left: Set<T>, _ right: Set<T>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func tokens(_ value: String) -> [String] {
        normalized(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var value = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    private static func cleanOptional(_ value: String?, maximum: Int) -> String? {
        ActivitySemanticTextSanitizer.clean(value, maximumLength: maximum)
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maximum else { return cleaned }
        return String(cleaned.prefix(max(1, maximum - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func sentenceTitle(_ value: String, maximum: Int) -> String {
        var output = bounded(value, maximum: maximum)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—•: "))
        guard let first = output.first else { return "Foreground computer activity" }
        output = String(first).uppercased() + output.dropFirst()
        return output
    }

    private static func containsAny(_ value: String, markers: [String]) -> Bool {
        markers.contains { value.contains($0) }
    }

    private static func stableIdentifier(_ value: String) -> String {
        String(SHA256Digest.hashHex(value).prefix(24))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public enum ComputerHistoryMarkdownRenderer {
    public static func render(_ memory: ComputerHistoryDayMemory) -> String {
        var lines: [String] = [
            "# \(memory.title)",
            "",
            memory.executiveSummary,
            "",
            "> \(memory.securityNotice)",
        ]

        if memory.episodes.isEmpty {
            lines.append(contentsOf: ["", "## Timeline", "", "No inspectable episodes were reconstructed."])
        } else {
            lines.append(contentsOf: ["", "## Timeline"])
            let resources = Dictionary(uniqueKeysWithValues: memory.resources.map { ($0.id, $0) })
            for episode in memory.episodes {
                lines.append("")
                lines.append("### \(timeFormatter.string(from: episode.start))–\(timeFormatter.string(from: episode.end)) — \(episode.title)")
                lines.append("")
                lines.append("- Status: `\(episode.status.rawValue)` (confidence \(Int((episode.statusConfidence * 100).rounded()))%)")
                if !episode.applications.isEmpty { lines.append("- Apps: \(episode.applications.joined(separator: ", "))") }
                if !episode.sites.isEmpty { lines.append("- Sites: \(episode.sites.joined(separator: ", "))") }
                let resourceRows = episode.resourceIDs.compactMap { resources[$0] }
                if !resourceRows.isEmpty {
                    lines.append("- Resources:")
                    for resource in resourceRows {
                        let locator = resource.localPath ?? resource.canonicalURI ?? "locator unavailable"
                        lines.append("  - [\(resource.kind.rawValue)] \(resource.title) — `\(locator)`")
                    }
                }
                lines.append("- Summary: \(episode.summary)")
                if !episode.requestsOrIntentions.isEmpty {
                    lines.append("- Requests or intentions:")
                    for value in episode.requestsOrIntentions { lines.append("  - \(value)") }
                }
                if !episode.observableOutcomes.isEmpty {
                    lines.append("- Observable outcomes:")
                    for value in episode.observableOutcomes { lines.append("  - \(value)") }
                }
                lines.append("- Action sequence:")
                for interaction in episode.interactions {
                    var detail = "  - \(timeFormatter.string(from: interaction.start)) — \(interaction.label)"
                    if !interaction.semanticDelta.isEmpty {
                        detail += " | change: " + interaction.semanticDelta.prefix(3).joined(separator: " · ")
                    }
                    lines.append(detail)
                }
                lines.append("- Evidence: events=\(episode.eventCount), semantic_snapshots=\(episode.semanticSnapshotCount), workflow=\(episode.workflowFingerprint)")
            }
        }

        if !memory.resources.isEmpty {
            lines.append(contentsOf: ["", "## Source index"])
            for resource in memory.resources {
                let locator = resource.localPath ?? resource.canonicalURI ?? "locator unavailable"
                lines.append("- [\(resource.kind.rawValue)] \(resource.title) — `\(locator)` — confidence \(Int((resource.locatorConfidence * 100).rounded()))%")
            }
        }

        if !memory.workflowPatterns.isEmpty {
            lines.append(contentsOf: ["", "## Repeatable workflows"])
            for workflow in memory.workflowPatterns {
                lines.append("- \(workflow.title) — \(workflow.occurrenceCount) occurrences — \(workflow.actionSequence.joined(separator: " → "))")
            }
        }

        if !memory.suggestions.isEmpty {
            lines.append(contentsOf: ["", "## Suggested skills and automations"])
            for suggestion in memory.suggestions {
                lines.append("- **\(suggestion.title)** (`\(suggestion.kind.rawValue)`): \(suggestion.rationale)")
                lines.append("  - Suggested request: \(suggestion.suggestedPrompt)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Coverage and uncertainty",
            "",
            "- Source events: \(memory.coverage.sourceEventCount)",
            "- Action events: \(memory.coverage.actionEventCount)",
            "- Semantic snapshots: \(memory.coverage.semanticSnapshotCount)",
            "- Linked interactions: \(memory.coverage.linkedInteractionCount)",
            "- Before/after semantic pairs: \(memory.coverage.interactionsWithBeforeAndAfterContext)",
            "- Suppressed events: \(memory.coverage.suppressedEventCount)",
            "- Foreground observations do not prove attention, identity, authorship, productivity or completion. Statuses are bounded interpretations of observable evidence.",
        ])
        if let first = memory.coverage.firstSourceSequence, let last = memory.coverage.lastSourceSequence {
            lines.append("- Source integrity sequence: \(first)–\(last)")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension Array {
    func prefixArray(_ maximum: Int) -> [Element] {
        Array(prefix(max(0, maximum)))
    }
}

private extension String {
    var standardizedPathKey: String {
        NSString(string: self).standardizingPath
    }
}
