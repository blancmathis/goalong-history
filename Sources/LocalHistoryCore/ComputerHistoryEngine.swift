import Foundation

/// Reconstructs the computer's chronological activity as causal interactions and
/// task-shaped episodes. The raw event journal remains the source of truth; every
/// derived object carries source-event provenance.
public enum ComputerHistoryEngine {
    public static func analyze(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload] = [:],
        day: Date,
        calendar: Calendar = .current,
        priorMemories: [ComputerHistoryDayMemory] = [],
        sourceJournalSummary: ComputerHistorySourceJournalSummary? = nil,
        generatedAt: Date = Date()
    ) -> ComputerHistoryDayMemory {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd =
            calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        // The raw journal intentionally contains recorder lifecycle, health and
        // Agent Activity maintenance events. They remain available to lower-level
        // diagnostics, but are not evidence of something the user did on the
        // computer. Keeping them out here prevents background maintenance from
        // creating resources, episode provenance or misleading coverage volume.
        // Suppressed observations remain model-facing because they represent an
        // explicit gap in what could be observed, even though they are not actions.
        let eventIndices = events.indices
        let eventsAreAlreadyScopedAndOrdered =
            events.allSatisfy {
                $0.timestamp >= dayStart && $0.timestamp < dayEnd
            }
            && zip(eventIndices, eventIndices.dropFirst()).allSatisfy {
                left, right in
                !ComputerHistorySupport.eventOrder(events[right], events[left])
            }
        let dayEvents =
            eventsAreAlreadyScopedAndOrdered
            ? events
            : events
                .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
                .sorted(by: ComputerHistorySupport.eventOrder)
        let evidence =
            dayEvents.allSatisfy(\.isComputerHistoryEvidence)
            ? dayEvents
            : dayEvents.filter(\.isComputerHistoryEvidence)
        let captured = evidence.filter {
            $0.suppressionReason == nil && !$0.isObservationContinuityBoundary
        }

        var resolution = ComputerHistoryResourceResolver.resolve(
            events: captured,
            semanticSnapshots: semanticSnapshots
        )
        let interactions: [ComputerHistoryInteraction]
        do {
            let semanticTexts = resolution.takeInteractionSemanticTexts()
            interactions = ComputerHistoryInteractionBuilder.build(
                events: captured,
                semanticSnapshots: semanticSnapshots,
                eventResourceIDs: resolution.eventResourceIDs,
                precomputedSemanticTexts: semanticTexts
            )
        }
        let episodes = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: evidence,
            resources: resolution.resources,
            provenanceReferenceLimit: evidence.count > 1_024 ? 16 : nil
        )
        let workflows = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: priorMemories
        )
        // Status, workflow and coverage inference above always sees the complete
        // ordered interaction sequence. Only the returned/persisted derived memory
        // is projected; the raw journal remains the exact reopenable source.
        let projection = representativeProjection(
            episodes: episodes,
            resources: resolution.resources,
            workflowPatterns: workflows.patterns,
            suggestions: workflows.suggestions
        )

        let integrity = dayEvents.compactMap(\.integrity)
        let journalSummary =
            sourceJournalSummary
            ?? ComputerHistorySourceJournalSummary(
                eventCount: dayEvents.count,
                continuityBoundaryCount: dayEvents.filter(\.isObservationContinuityBoundary).count,
                firstSourceSequence: integrity.first?.sequence,
                lastSourceSequence: integrity.last?.sequence,
                lastSourceEventHash: integrity.last?.eventHash
            )
        let coverage = ComputerHistoryCoverage(
            sourceEventCount: journalSummary.eventCount,
            actionEventCount: captured.filter(ComputerHistorySupport.isActionEvent).count,
            semanticSnapshotCount: resolution.semanticSnapshotCount,
            linkedInteractionCount: interactions.count,
            interactionsWithBeforeAndAfterContext: interactions.filter {
                $0.beforeContext != nil && $0.afterContext != nil
            }.count,
            resourceCount: resolution.resources.count,
            episodeCount: episodes.count,
            suppressedEventCount: journalSummary.continuityBoundaryCount,
            firstSourceSequence: journalSummary.firstSourceSequence,
            lastSourceSequence: journalSummary.lastSourceSequence,
            lastSourceEventHash: journalSummary.lastSourceEventHash,
            retainedEpisodeCount: projection.isCompact
                ? projection.episodes.count
                : nil,
            retainedInteractionCount: projection.isCompact
                ? projection.episodes.reduce(0) { $0 + $1.interactions.count }
                : nil,
            retainedResourceCount: projection.isCompact
                ? projection.resources.count
                : nil
        )

        let base = ComputerHistoryDayMemory(
            dayStart: dayStart,
            dayEnd: dayEnd.addingTimeInterval(-0.001),
            generatedAt: generatedAt,
            title: dayTitle(episodes: episodes, dayStart: dayStart),
            executiveSummary: executiveSummary(
                episodes: episodes,
                resources: resolution.resources,
                suggestions: workflows.suggestions,
                suppressedEventCount: coverage.suppressedEventCount
            ),
            episodes: projection.episodes,
            resources: projection.resources,
            workflowPatterns: projection.workflowPatterns,
            suggestions: projection.suggestions,
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

    /// Rebuilds one retained episode against the bounded raw evidence for its day
    /// and returns every source event identifier, even when the persisted memory
    /// keeps only representative provenance. This is intentionally on-demand so
    /// normal display and search stay compact while an explicit local deletion can
    /// target exact journal rows instead of erasing a broad time interval.
    package static func exactSourceEventIDs(
        forEpisodeID episodeID: String,
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload] = [:],
        day: Date,
        calendar: Calendar = .current
    ) -> [String]? {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd =
            calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let evidence = events
            .filter {
                $0.timestamp >= dayStart
                    && $0.timestamp < dayEnd
                    && $0.isComputerHistoryEvidence
            }
            .sorted(by: ComputerHistorySupport.eventOrder)
        let captured = evidence.filter {
            $0.suppressionReason == nil && !$0.isObservationContinuityBoundary
        }
        var resolution = ComputerHistoryResourceResolver.resolve(
            events: captured,
            semanticSnapshots: semanticSnapshots
        )
        let semanticTexts = resolution.takeInteractionSemanticTexts()
        let interactions = ComputerHistoryInteractionBuilder.build(
            events: captured,
            semanticSnapshots: semanticSnapshots,
            eventResourceIDs: resolution.eventResourceIDs,
            precomputedSemanticTexts: semanticTexts
        )
        let episodes = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: evidence,
            resources: resolution.resources,
            provenanceReferenceLimit: nil
        )
        return episodes.first(where: { $0.id == episodeID })?.provenance.sourceEventIDs
    }

    /// Applies the current bounded representative projection to a readable memory
    /// produced by an older build. Exact coverage totals stay unchanged and the raw
    /// journals remain authoritative; only the derived display/search payload is
    /// reduced. This lets storage migrate legacy large days without replaying or
    /// rewriting their original event stream.
    public static func compactStoredMemory(
        _ memory: ComputerHistoryDayMemory,
        renderMarkdown: Bool = true
    ) -> ComputerHistoryDayMemory {
        guard !memory.coverage.usesRepresentativeProjection else { return memory }
        let projection = representativeProjection(
            episodes: memory.episodes,
            resources: memory.resources,
            workflowPatterns: memory.workflowPatterns,
            suggestions: memory.suggestions
        )
        guard projection.isCompact else { return memory }

        let coverage = ComputerHistoryCoverage(
            sourceEventCount: memory.coverage.sourceEventCount,
            actionEventCount: memory.coverage.actionEventCount,
            semanticSnapshotCount: memory.coverage.semanticSnapshotCount,
            linkedInteractionCount: memory.coverage.linkedInteractionCount,
            interactionsWithBeforeAndAfterContext: memory.coverage
                .interactionsWithBeforeAndAfterContext,
            resourceCount: memory.coverage.resourceCount,
            episodeCount: memory.coverage.episodeCount,
            suppressedEventCount: memory.coverage.suppressedEventCount,
            firstSourceSequence: memory.coverage.firstSourceSequence,
            lastSourceSequence: memory.coverage.lastSourceSequence,
            lastSourceEventHash: memory.coverage.lastSourceEventHash,
            retainedEpisodeCount: projection.episodes.count,
            retainedInteractionCount: projection.episodes.reduce(0) {
                $0 + $1.interactions.count
            },
            retainedResourceCount: projection.resources.count
        )
        let base = ComputerHistoryDayMemory(
            schemaVersion: memory.schemaVersion,
            dayStart: memory.dayStart,
            dayEnd: memory.dayEnd,
            generatedAt: memory.generatedAt,
            title: memory.title,
            executiveSummary: memory.executiveSummary,
            episodes: projection.episodes,
            resources: projection.resources,
            workflowPatterns: projection.workflowPatterns,
            suggestions: projection.suggestions,
            coverage: coverage,
            markdown: "",
            securityNotice: memory.securityNotice
        )
        guard renderMarkdown else { return base }
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

    private struct RepresentativeProjection {
        let episodes: [ComputerHistoryEpisode]
        let resources: [ComputerHistoryResourceReference]
        let workflowPatterns: [ComputerHistoryWorkflowPattern]
        let suggestions: [ComputerHistorySuggestion]
        let isCompact: Bool
    }

    private struct InteractionLocation: Hashable {
        let episode: Int
        let interaction: Int
    }

    private struct RankedInteraction {
        let location: InteractionLocation
        let score: Int
        let stableID: String
    }

    /// Produces a bounded search/display projection after all inference has run on
    /// the complete sequence. The limits are deliberately independent of source
    /// volume so a busy day cannot recreate a second raw-event journal in JSON.
    private static func representativeProjection(
        episodes: [ComputerHistoryEpisode],
        resources: [ComputerHistoryResourceReference],
        workflowPatterns: [ComputerHistoryWorkflowPattern],
        suggestions: [ComputerHistorySuggestion]
    ) -> RepresentativeProjection {
        let totalInteractions = episodes.reduce(0) { $0 + $1.interactions.count }
        var retainedTextCharacters = 0
        for episode in episodes {
            for interaction in episode.interactions {
                retainedTextCharacters += interaction.label.count
                retainedTextCharacters += interaction.beforeContext?.count ?? 0
                retainedTextCharacters += interaction.afterContext?.count ?? 0
                for line in interaction.semanticDelta {
                    retainedTextCharacters += line.count
                }
            }
        }
        let shouldCompact =
            episodes.count > 256
            || totalInteractions > 512
            || resources.count > 384
            || retainedTextCharacters > 1_000_000
        guard shouldCompact else {
            return RepresentativeProjection(
                episodes: episodes,
                resources: resources,
                workflowPatterns: workflowPatterns,
                suggestions: suggestions,
                isCompact: false
            )
        }

        let resourceByID = Dictionary(
            uniqueKeysWithValues: resources.map { ($0.id, $0) }
        )
        let reopenableResourceIDs = Set(
            resources.compactMap { resource -> String? in
                resource.localPath != nil || resource.canonicalURI != nil
                    ? resource.id
                    : nil
            })
        var flattened: [InteractionLocation] = []
        flattened.reserveCapacity(totalInteractions)
        var ranked: [RankedInteraction] = []
        ranked.reserveCapacity(totalInteractions)

        for (episodeIndex, episode) in episodes.enumerated() {
            for (interactionIndex, interaction) in episode.interactions.enumerated() {
                let location = InteractionLocation(
                    episode: episodeIndex,
                    interaction: interactionIndex
                )
                flattened.append(location)
                var score = 0
                if interactionIndex == 0 || interactionIndex == episode.interactions.count - 1 {
                    score += 800
                }
                if [.completed, .blocked, .waiting].contains(episode.status) {
                    score += 180
                }
                let evidenceText =
                    ([interaction.label] + interaction.semanticDelta
                    + [interaction.afterContext].compactMap { $0 })
                    .joined(separator: " ")
                if ComputerHistorySupport.isHighValueComputerHistoryText(evidenceText) {
                    score += 700
                }
                if !Set(interaction.resourceIDs).isDisjoint(
                    with: reopenableResourceIDs
                ) {
                    score += 320
                }
                if !interaction.semanticDelta.isEmpty { score += 220 }
                if interaction.beforeContext != nil || interaction.afterContext != nil {
                    score += 80
                }
                if ![.scroll, .focusChange, .contextObservation]
                    .contains(interaction.action)
                {
                    score += 90
                }
                if interactionIndex > 0 {
                    let previous = episode.interactions[interactionIndex - 1]
                    if previous.application != interaction.application
                        || previous.host != interaction.host
                        || previous.action != interaction.action
                        || previous.resourceIDs != interaction.resourceIDs
                    {
                        score += 280
                    }
                }
                ranked.append(
                    RankedInteraction(
                        location: location,
                        score: score,
                        stableID: interaction.id
                    )
                )
            }
        }

        if var first = ranked.first {
            first = RankedInteraction(
                location: first.location,
                score: first.score + 4_000,
                stableID: first.stableID
            )
            ranked[0] = first
        }
        if ranked.count > 1, var last = ranked.last {
            last = RankedInteraction(
                location: last.location,
                score: last.score + 4_000,
                stableID: last.stableID
            )
            ranked[ranked.count - 1] = last
        }
        ranked.sort {
            if $0.score == $1.score {
                if $0.stableID == $1.stableID {
                    if $0.location.episode == $1.location.episode {
                        return $0.location.interaction < $1.location.interaction
                    }
                    return $0.location.episode < $1.location.episode
                }
                return $0.stableID < $1.stableID
            }
            return $0.score > $1.score
        }

        let maximumInteractions = 640
        let priorityBudget = min(480, maximumInteractions)
        var selected = Set<InteractionLocation>()
        selected.reserveCapacity(min(maximumInteractions, flattened.count))
        for candidate in ranked.prefix(priorityBudget) {
            selected.insert(candidate.location)
        }
        for location in ComputerHistorySupport.representativeElements(
            flattened,
            maximum: maximumInteractions
        ) where selected.count < maximumInteractions {
            selected.insert(location)
        }
        if selected.count < min(maximumInteractions, flattened.count) {
            for candidate in ranked where selected.count < maximumInteractions {
                selected.insert(candidate.location)
            }
        }

        // An adversarially fragmented day can contain one short interaction per
        // episode. Bound the episode projection independently so the derived JSON
        // cannot grow without limit even when interaction/resource caps hold.
        let maximumEpisodes = 256
        let priorityEpisodeBudget = 192
        let selectedEpisodeCandidates = Set(selected.map(\.episode)).sorted()
        var selectedEpisodeIndices = Set<Int>()
        selectedEpisodeIndices.reserveCapacity(
            min(maximumEpisodes, selectedEpisodeCandidates.count)
        )
        for candidate in ranked where selected.contains(candidate.location) {
            selectedEpisodeIndices.insert(candidate.location.episode)
            if selectedEpisodeIndices.count == priorityEpisodeBudget { break }
        }
        for episodeIndex in ComputerHistorySupport.representativeElements(
            selectedEpisodeCandidates,
            maximum: maximumEpisodes
        ) where selectedEpisodeIndices.count < maximumEpisodes {
            selectedEpisodeIndices.insert(episodeIndex)
        }
        if selectedEpisodeIndices.count
            < min(maximumEpisodes, selectedEpisodeCandidates.count)
        {
            for episodeIndex in selectedEpisodeCandidates
            where selectedEpisodeIndices.count < maximumEpisodes {
                selectedEpisodeIndices.insert(episodeIndex)
            }
        }
        selected = selected.filter {
            selectedEpisodeIndices.contains($0.episode)
        }

        var selectedResourceReferenceCounts: [String: Int] = [:]
        var episodeResourceReferenceCounts: [String: Int] = [:]
        for location in selected {
            for resourceID in episodes[location.episode]
                .interactions[location.interaction].resourceIDs
            {
                selectedResourceReferenceCounts[resourceID, default: 0] += 1
            }
        }
        for episode in episodes {
            for resourceID in episode.resourceIDs.prefix(8) {
                episodeResourceReferenceCounts[resourceID, default: 0] += 1
            }
        }
        let firstResourceID = resources.first?.id
        let lastResourceID = resources.last?.id
        let selectedResources = resources.sorted { left, right in
            func score(_ resource: ComputerHistoryResourceReference) -> Int {
                var value = (selectedResourceReferenceCounts[resource.id] ?? 0) * 10_000
                value += (episodeResourceReferenceCounts[resource.id] ?? 0) * 120
                if resource.localPath != nil || resource.canonicalURI != nil {
                    value += 2_000
                }
                if resource.kind != .application { value += 300 }
                value += Int((resource.locatorConfidence * 100).rounded())
                if resource.id == firstResourceID || resource.id == lastResourceID {
                    value += 4_000
                }
                return value
            }
            let leftScore = score(left)
            let rightScore = score(right)
            if leftScore == rightScore {
                if left.lastSeen == right.lastSeen { return left.id < right.id }
                return left.lastSeen > right.lastSeen
            }
            return leftScore > rightScore
        }
        .prefix(384)
        .map(compactResource)
        let selectedResourceIDs = Set(selectedResources.map(\.id))

        var selectedByEpisode: [Int: Set<Int>] = [:]
        for location in selected {
            selectedByEpisode[location.episode, default: []]
                .insert(location.interaction)
        }
        let compactEpisodes = episodes.enumerated().compactMap {
            episodeIndex, episode -> ComputerHistoryEpisode? in
            guard selectedEpisodeIndices.contains(episodeIndex) else { return nil }
            return compactEpisode(
                episode,
                selectedInteractionIndices: selectedByEpisode[episodeIndex] ?? [],
                selectedResourceIDs: selectedResourceIDs,
                resourceByID: resourceByID
            )
        }
        let retainedEpisodeIDs = Set(compactEpisodes.map(\.id))
        return RepresentativeProjection(
            episodes: compactEpisodes,
            resources: selectedResources,
            workflowPatterns: Array(workflowPatterns.prefix(64)).map {
                compactWorkflow($0, retainedEpisodeIDs: retainedEpisodeIDs)
            },
            suggestions: Array(suggestions.prefix(8)).map {
                compactSuggestion($0, retainedEpisodeIDs: retainedEpisodeIDs)
            },
            isCompact: true
        )
    }

    private static func compactResource(
        _ resource: ComputerHistoryResourceReference
    ) -> ComputerHistoryResourceReference {
        ComputerHistoryResourceReference(
            id: resource.id,
            kind: resource.kind,
            title: ComputerHistorySupport.bounded(resource.title, maximum: 180),
            canonicalURI: resource.canonicalURI.map {
                ComputerHistorySupport.bounded($0, maximum: 1_024)
            },
            localPath: resource.localPath.map {
                ComputerHistorySupport.bounded($0, maximum: 1_024)
            },
            host: resource.host.map {
                ComputerHistorySupport.bounded($0, maximum: 180)
            },
            application: resource.application.map {
                ComputerHistorySupport.bounded($0, maximum: 120)
            },
            bundleIdentifier: resource.bundleIdentifier.map {
                ComputerHistorySupport.bounded($0, maximum: 180)
            },
            locatorConfidence: resource.locatorConfidence,
            firstSeen: resource.firstSeen,
            lastSeen: resource.lastSeen,
            provenance: ComputerHistorySupport.compactProvenance(
                resource.provenance,
                maximumReferences: 8
            )
        )
    }

    private static func compactEpisode(
        _ episode: ComputerHistoryEpisode,
        selectedInteractionIndices: Set<Int>,
        selectedResourceIDs: Set<String>,
        resourceByID: [String: ComputerHistoryResourceReference]
    ) -> ComputerHistoryEpisode {
        var seenContext = Set<String>()
        var seenDelta = Set<String>()
        let compactInteractions = episode.interactions.enumerated().compactMap {
            index, interaction -> ComputerHistoryInteraction? in
            guard selectedInteractionIndices.contains(index) else { return nil }
            let resourceIDs = Array(
                interaction.resourceIDs.lazy.filter(selectedResourceIDs.contains).prefix(4)
            )
            let before = compactUniqueText(
                interaction.beforeContext,
                maximum: 320,
                seen: &seenContext
            )
            let after = compactUniqueText(
                interaction.afterContext,
                maximum: 320,
                seen: &seenContext
            )
            var delta: [String] = []
            for value in interaction.semanticDelta {
                let bounded = ComputerHistorySupport.bounded(value, maximum: 220)
                let key = ComputerHistorySupport.normalized(bounded)
                guard !key.isEmpty, seenDelta.insert(key).inserted else { continue }
                delta.append(bounded)
                if delta.count == 3 { break }
            }
            return ComputerHistoryInteraction(
                id: interaction.id,
                start: interaction.start,
                end: interaction.end,
                action: interaction.action,
                label: ComputerHistorySupport.bounded(
                    interaction.label,
                    maximum: 180
                ),
                application: interaction.application.map {
                    ComputerHistorySupport.bounded($0, maximum: 120)
                },
                bundleIdentifier: interaction.bundleIdentifier.map {
                    ComputerHistorySupport.bounded($0, maximum: 180)
                },
                host: interaction.host.map {
                    ComputerHistorySupport.bounded($0, maximum: 180)
                },
                resourceIDs: resourceIDs,
                beforeContext: before,
                afterContext: after,
                semanticDelta: delta,
                confidence: interaction.confidence,
                provenance: ComputerHistorySupport.compactProvenance(
                    interaction.provenance,
                    maximumReferences: 4
                )
            )
        }
        let retainedEpisodeResourceIDs = Array(
            episode.resourceIDs.lazy.filter(selectedResourceIDs.contains).prefix(16)
        )
        // Prefer reopenable locators inside the bounded episode resource list.
        let sortedEpisodeResourceIDs = retainedEpisodeResourceIDs.sorted { left, right in
            let leftReopenable =
                resourceByID[left].map {
                    $0.localPath != nil || $0.canonicalURI != nil
                } ?? false
            let rightReopenable =
                resourceByID[right].map {
                    $0.localPath != nil || $0.canonicalURI != nil
                } ?? false
            if leftReopenable == rightReopenable {
                return retainedEpisodeResourceIDs.firstIndex(of: left) ?? 0
                    < retainedEpisodeResourceIDs.firstIndex(of: right) ?? 0
            }
            return leftReopenable && !rightReopenable
        }
        return ComputerHistoryEpisode(
            id: episode.id,
            start: episode.start,
            end: episode.end,
            title: ComputerHistorySupport.bounded(episode.title, maximum: 120),
            summary: ComputerHistorySupport.bounded(episode.summary, maximum: 520),
            status: episode.status,
            statusConfidence: episode.statusConfidence,
            applications: Array(episode.applications.prefix(8)).map {
                ComputerHistorySupport.bounded($0, maximum: 120)
            },
            sites: Array(episode.sites.prefix(8)).map {
                ComputerHistorySupport.bounded($0, maximum: 180)
            },
            resourceIDs: sortedEpisodeResourceIDs,
            requestsOrIntentions: ComputerHistorySupport.distinctText(
                episode.requestsOrIntentions,
                maximum: 6,
                maximumLength: 280
            ),
            observableOutcomes: ComputerHistorySupport.distinctText(
                episode.observableOutcomes,
                maximum: 6,
                maximumLength: 280
            ),
            interactions: compactInteractions,
            sourceInteractionCount: episode.totalInteractionCount,
            eventCount: episode.eventCount,
            semanticSnapshotCount: episode.semanticSnapshotCount,
            workflowFingerprint: episode.workflowFingerprint,
            provenance: ComputerHistorySupport.compactProvenance(
                episode.provenance,
                maximumReferences: 16
            )
        )
    }

    private static func compactUniqueText(
        _ value: String?,
        maximum: Int,
        seen: inout Set<String>
    ) -> String? {
        guard let value else { return nil }
        let bounded = ComputerHistorySupport.bounded(value, maximum: maximum)
        let key = ComputerHistorySupport.normalized(bounded)
        guard !key.isEmpty, seen.insert(key).inserted else { return nil }
        return bounded
    }

    private static func compactWorkflow(
        _ workflow: ComputerHistoryWorkflowPattern,
        retainedEpisodeIDs: Set<String>
    ) -> ComputerHistoryWorkflowPattern {
        ComputerHistoryWorkflowPattern(
            id: workflow.id,
            fingerprint: workflow.fingerprint,
            title: ComputerHistorySupport.bounded(workflow.title, maximum: 120),
            occurrenceCount: workflow.occurrenceCount,
            episodeIDs: ComputerHistorySupport.representativeElements(
                workflow.episodeIDs.filter(retainedEpisodeIDs.contains),
                maximum: 32
            ),
            actionSequence: Array(workflow.actionSequence.prefix(12)).map {
                ComputerHistorySupport.bounded($0, maximum: 160)
            },
            applications: Array(workflow.applications.prefix(8)).map {
                ComputerHistorySupport.bounded($0, maximum: 120)
            },
            confidence: workflow.confidence
        )
    }

    private static func compactSuggestion(
        _ suggestion: ComputerHistorySuggestion,
        retainedEpisodeIDs: Set<String>
    ) -> ComputerHistorySuggestion {
        ComputerHistorySuggestion(
            id: suggestion.id,
            kind: suggestion.kind,
            title: ComputerHistorySupport.bounded(suggestion.title, maximum: 140),
            rationale: ComputerHistorySupport.bounded(
                suggestion.rationale,
                maximum: 320
            ),
            suggestedPrompt: ComputerHistorySupport.bounded(
                suggestion.suggestedPrompt,
                maximum: 480
            ),
            workflowID: suggestion.workflowID,
            episodeIDs: ComputerHistorySupport.representativeElements(
                suggestion.episodeIDs.filter(retainedEpisodeIDs.contains),
                maximum: 32
            ),
            confidence: suggestion.confidence
        )
    }

    private static func dayTitle(
        episodes: [ComputerHistoryEpisode],
        dayStart: Date
    ) -> String {
        guard
            let primary = episodes.max(by: {
                $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
            })
        else {
            return "Computer history — \(dayFormatter.string(from: dayStart))"
        }
        guard episodes.count > 1 else { return primary.title }
        let remainder = episodes.count - 1
        return "\(primary.title) and \(remainder) other work episode\(remainder == 1 ? "" : "s")"
    }

    private static func executiveSummary(
        episodes: [ComputerHistoryEpisode],
        resources: [ComputerHistoryResourceReference],
        suggestions: [ComputerHistorySuggestion],
        suppressedEventCount: Int
    ) -> String {
        guard !episodes.isEmpty else {
            return suppressedEventCount > 0
                ? "No inspectable activity episode was available; private or unavailable periods remain explicit gaps."
                : "No inspectable activity episode was available."
        }
        let completed = episodes.filter { $0.status == .completed }.count
        let unfinished = episodes.filter {
            [.planned, .inProgress, .blocked, .waiting].contains($0.status)
        }.count
        var parts = [
            "Reconstructed \(episodes.count) chronological work episode\(episodes.count == 1 ? "" : "s") from the full interaction sequence",
            "linked \(resources.count) identifiable resource\(resources.count == 1 ? "" : "s")",
        ]
        if completed > 0 {
            parts.append("found \(completed) episode\(completed == 1 ? "" : "s") with observable completion signals")
        }
        if unfinished > 0 {
            parts.append(
                "kept \(unfinished) unfinished, blocked or waiting episode\(unfinished == 1 ? "" : "s") explicit")
        }
        if !suggestions.isEmpty {
            parts.append(
                "detected \(suggestions.count) grounded skill or automation suggestion\(suggestions.count == 1 ? "" : "s")"
            )
        }
        if suppressedEventCount > 0 {
            parts.append(
                "preserved \(suppressedEventCount) suppressed event\(suppressedEventCount == 1 ? "" : "s") as coverage gaps"
            )
        }
        return parts.joined(separator: "; ") + "."
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
