import Foundation

struct ComputerHistoryWorkflowResult {
    let patterns: [ComputerHistoryWorkflowPattern]
    let suggestions: [ComputerHistorySuggestion]
}

enum ComputerHistoryWorkflowDetector {
    static func detect(
        currentEpisodes: [ComputerHistoryEpisode],
        priorMemories: [ComputerHistoryDayMemory]
    ) -> ComputerHistoryWorkflowResult {
        let historical = priorMemories.flatMap(\.episodes)
        let candidates = historical + currentEpisodes
        var clusters: [[ComputerHistoryEpisode]] = []

        for episode in candidates where isGroundedWorkflowCandidate(episode) {
            if let index = clusters.firstIndex(where: { cluster in
                guard let representative = cluster.first else { return false }
                return representative.workflowFingerprint == episode.workflowFingerprint
                    || similarity(representative, episode) >= 0.72
            }) {
                clusters[index].append(episode)
            } else {
                clusters.append([episode])
            }
        }

        let patterns = clusters
            .filter { Set($0.map(\.id)).count >= 2 }
            .map(makePattern)
            .sorted {
                if $0.occurrenceCount == $1.occurrenceCount {
                    return $0.title < $1.title
                }
                return $0.occurrenceCount > $1.occurrenceCount
            }
        let suggestions = patterns.prefix(8).map(makeSuggestion)
        return ComputerHistoryWorkflowResult(
            patterns: patterns,
            suggestions: suggestions
        )
    }

    /// A workflow needs more than a repeated app-navigation trace. It must contain
    /// multiple user-significant actions, a concrete resource, and evidence of an
    /// observable result such as a semantic change or an explicit save/submit action.
    private static func isGroundedWorkflowCandidate(
        _ episode: ComputerHistoryEpisode
    ) -> Bool {
        guard episode.interactions.count >= 3 else { return false }

        let significant = episode.interactions.filter {
            [.click, .typing, .shortcut, .navigationKey].contains($0.action)
        }
        guard significant.count >= 2 else { return false }

        let hasSpecificResource = !episode.resourceIDs.isEmpty
            && (!episode.sites.isEmpty || !episode.title.hasPrefix("Worked in "))
        guard hasSpecificResource else { return false }

        let hasSemanticResult = episode.interactions.contains {
            !$0.semanticDelta.isEmpty || $0.afterContext != nil
        }
        let hasExplicitOutcome = episode.observableOutcomes.contains {
            !$0.hasPrefix("Last observable action:")
        }
        let resultMarkers = [
            "save", "saved", "send", "sent", "submit", "submitted", "publish",
            "published", "merge", "merged", "create", "created", "update", "updated",
            "close", "closed", "deploy", "deployed", "run", "ran",
        ]
        let hasResultAction = significant.last.map { interaction in
            let label = ComputerHistorySupport.normalized(interaction.label)
            return resultMarkers.contains { label.contains($0) }
        } ?? false

        return hasSemanticResult || hasExplicitOutcome || hasResultAction
    }

    private static func makePattern(
        _ cluster: [ComputerHistoryEpisode]
    ) -> ComputerHistoryWorkflowPattern {
        let representative = cluster.max {
            $0.interactions.count < $1.interactions.count
        }!
        let occurrenceCount = Set(cluster.map(\.id)).count
        let applications = ComputerHistorySupport.rankedDistinct(
            cluster.flatMap(\.applications)
        )
        return ComputerHistoryWorkflowPattern(
            id: ComputerHistorySupport.stableIdentifier(
                "workflow|\(representative.workflowFingerprint)"
            ),
            fingerprint: representative.workflowFingerprint,
            title: ComputerHistorySupport.sentenceTitle(
                representative.title,
                maximum: 100
            ),
            occurrenceCount: occurrenceCount,
            episodeIDs: ComputerHistorySupport.distinct(cluster.map(\.id)),
            actionSequence: compactActionSequence(representative.interactions),
            applications: applications,
            confidence: min(0.98, 0.65 + Double(occurrenceCount) * 0.08)
        )
    }

    private static func makeSuggestion(
        _ pattern: ComputerHistoryWorkflowPattern
    ) -> ComputerHistorySuggestion {
        let crossApplication = pattern.applications.count >= 2
        let kind: ComputerHistorySuggestionKind = pattern.occurrenceCount >= 3
            && crossApplication ? .automation : .skill
        let prefix = kind == .automation ? "Automate" : "Create a skill for"
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
            id: ComputerHistorySupport.stableIdentifier(
                "suggestion|\(kind.rawValue)|\(pattern.id)"
            ),
            kind: kind,
            title: ComputerHistorySupport.sentenceTitle(
                "\(prefix) \(pattern.title.lowercased())",
                maximum: 120
            ),
            rationale: rationale,
            suggestedPrompt: prompt,
            workflowID: pattern.id,
            episodeIDs: pattern.episodeIDs,
            confidence: pattern.confidence
        )
    }

    private static func similarity(
        _ left: ComputerHistoryEpisode,
        _ right: ComputerHistoryEpisode
    ) -> Double {
        let leftActions = Set(
            compactActionSequence(left.interactions).map(ComputerHistorySupport.normalized)
        )
        let rightActions = Set(
            compactActionSequence(right.interactions).map(ComputerHistorySupport.normalized)
        )
        let actionScore = ComputerHistorySupport.jaccard(leftActions, rightActions)
        let appScore = ComputerHistorySupport.jaccard(
            Set(left.applications.map(ComputerHistorySupport.normalized)),
            Set(right.applications.map(ComputerHistorySupport.normalized))
        )
        let titleScore = ComputerHistorySupport.tokenSimilarity(
            [left.title],
            [right.title]
        )
        return actionScore * 0.55 + appScore * 0.25 + titleScore * 0.20
    }

    private static func compactActionSequence(
        _ interactions: [ComputerHistoryInteraction]
    ) -> [String] {
        let values = interactions.compactMap { interaction -> String? in
            guard ![.scroll, .focusChange, .contextObservation]
                .contains(interaction.action)
            else { return nil }
            let application = interaction.application.map { " in \($0)" } ?? ""
            return interaction.action.rawValue + application
        }
        return Array(
            ComputerHistorySupport.collapseConsecutive(values).prefix(12)
        )
    }
}
