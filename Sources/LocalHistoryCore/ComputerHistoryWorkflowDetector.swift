import Foundation

struct ComputerHistoryWorkflowResult {
    let patterns: [ComputerHistoryWorkflowPattern]
    let suggestions: [ComputerHistorySuggestion]
}

enum ComputerHistoryWorkflowDetector {
    private struct Candidate {
        let episode: ComputerHistoryEpisode
        let actionSequence: [String]
        let normalizedActions: Set<String>
        let normalizedApplications: Set<String>
        let titleTokens: Set<String>

        init(episode: ComputerHistoryEpisode) {
            self.episode = episode
            actionSequence = compactActionSequence(episode.interactions)
            normalizedActions = Set(
                actionSequence.map(ComputerHistorySupport.normalized)
            )
            normalizedApplications = Set(
                episode.applications.map(ComputerHistorySupport.normalized)
            )
            titleTokens = Set(ComputerHistorySupport.tokens(episode.title))
        }
    }

    private struct Cluster {
        let representative: Candidate
        var episodes: [ComputerHistoryEpisode]
        var fingerprints: Set<String>
    }

    private struct ClusterLookup {
        private var byFingerprint: [String: Set<Int>] = [:]
        private var byActionPrefix: [String: Set<Int>] = [:]
        private var byApplication: [String: Set<Int>] = [:]
        private var byTitleToken: [String: Set<Int>] = [:]
        private let actionTokenFrequencies: [String: Int]

        init(actionTokenFrequencies: [String: Int]) {
            self.actionTokenFrequencies = actionTokenFrequencies
        }

        mutating func recordFingerprint(_ fingerprint: String, at index: Int) {
            byFingerprint[fingerprint, default: []].insert(index)
        }

        mutating func insert(_ candidate: Candidate, at index: Int) {
            recordFingerprint(candidate.episode.workflowFingerprint, at: index)
            for value in actionPrefix(for: candidate.normalizedActions) {
                byActionPrefix[value, default: []].insert(index)
            }
            for value in candidate.normalizedApplications {
                byApplication[value, default: []].insert(index)
            }
            for value in candidate.titleTokens {
                byTitleToken[value, default: []].insert(index)
            }
        }

        func possibleClusterIndices(for candidate: Candidate) -> [Int] {
            let exactMatches =
                byFingerprint[candidate.episode.workflowFingerprint] ?? []
            // Once a stable fingerprint has joined a cluster, feature drift must
            // not fork that identity into another similarity cluster.
            guard exactMatches.isEmpty else { return exactMatches.sorted() }

            var actionMatches = Set<Int>()
            for value in actionPrefix(for: candidate.normalizedActions) {
                actionMatches.formUnion(byActionPrefix[value] ?? [])
            }
            guard !actionMatches.isEmpty else { return [] }

            var supportingMatches = Set<Int>()
            for value in candidate.normalizedApplications {
                supportingMatches.formUnion(byApplication[value] ?? [])
            }
            for value in candidate.titleTokens {
                supportingMatches.formUnion(byTitleToken[value] ?? [])
            }

            // Without any shared action, similarity is at most 0.45. With actions
            // alone it is at most 0.55. Neither can reach the 0.72 threshold, so
            // intersecting these indices is an exact rejection, not approximation.
            return actionMatches.intersection(supportingMatches).sorted()
        }

        private func actionPrefix(for actions: Set<String>) -> [String] {
            guard !actions.isEmpty else { return [] }
            let ordered = actions.sorted { left, right in
                let leftFrequency = actionTokenFrequencies[left] ?? 0
                let rightFrequency = actionTokenFrequencies[right] ?? 0
                if leftFrequency == rightFrequency { return left < right }
                return leftFrequency < rightFrequency
            }

            // Applications and title tokens contribute at most 0.45 to the
            // weighted score. Reaching 0.72 therefore requires action Jaccard
            // similarity of at least 27/55. Standard Jaccard prefix filtering
            // guarantees that qualifying sets share one token in these prefixes.
            // The global frequency/lexical order removes dense common actions
            // while preserving every possible match.
            let requiredOverlap = (27 * ordered.count + 54) / 55
            let prefixLength = ordered.count - requiredOverlap + 1
            return Array(ordered.prefix(prefixLength))
        }
    }

    static func detect(
        currentEpisodes: [ComputerHistoryEpisode],
        priorMemories: [ComputerHistoryDayMemory]
    ) -> ComputerHistoryWorkflowResult {
        let currentEpisodeIDs = Set(currentEpisodes.map(\.id))
        var priorOccurrenceCounts: [String: Int] = [:]
        for pattern in priorMemories.flatMap(\.workflowPatterns) {
            // Prior day memories carry cumulative workflow history. Taking the
            // maximum preserves that history without summing the same earlier
            // occurrences again when several prior days are loaded together.
            priorOccurrenceCounts[pattern.fingerprint] = max(
                priorOccurrenceCounts[pattern.fingerprint] ?? 0,
                pattern.occurrenceCount
            )
        }
        let historical = priorMemories.flatMap(\.episodes)
        let candidates = historical + currentEpisodes
        var actionTokenFrequencies: [String: Int] = [:]
        for episode in candidates where episode.totalInteractionCount >= 3 {
            let actions = Set(
                compactActionSequence(episode.interactions).map(
                    ComputerHistorySupport.normalized
                )
            )
            for action in actions {
                actionTokenFrequencies[action, default: 0] += 1
            }
        }
        var clusters: [Cluster] = []
        var lookup = ClusterLookup(
            actionTokenFrequencies: actionTokenFrequencies
        )

        for episode in candidates where episode.totalInteractionCount >= 3 {
            let candidate = Candidate(episode: episode)
            let matchingIndex = lookup.possibleClusterIndices(for: candidate)
                .first { index in
                    let cluster = clusters[index]
                    return cluster.fingerprints.contains(episode.workflowFingerprint)
                        || similarity(cluster.representative, candidate) >= 0.72
                }
            if let index = matchingIndex {
                clusters[index].episodes.append(episode)
                if clusters[index].fingerprints.insert(episode.workflowFingerprint).inserted {
                    lookup.recordFingerprint(episode.workflowFingerprint, at: index)
                }
            } else {
                let index = clusters.count
                clusters.append(
                    Cluster(
                        representative: candidate,
                        episodes: [episode],
                        fingerprints: [episode.workflowFingerprint]
                    )
                )
                lookup.insert(candidate, at: index)
            }
        }

        let patterns =
            clusters
            .map(\.episodes)
            .compactMap {
                makePattern(
                    $0,
                    currentEpisodeIDs: currentEpisodeIDs,
                    priorOccurrenceCounts: priorOccurrenceCounts
                )
            }
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

    private static func makePattern(
        _ cluster: [ComputerHistoryEpisode],
        currentEpisodeIDs: Set<String>,
        priorOccurrenceCounts: [String: Int]
    ) -> ComputerHistoryWorkflowPattern? {
        let currentEpisodes = cluster.filter {
            currentEpisodeIDs.contains($0.id)
        }
        guard !currentEpisodes.isEmpty else { return nil }
        let currentIDs = ComputerHistorySupport.distinct(currentEpisodes.map(\.id))
        let carriedFingerprint = Set(currentEpisodes.map(\.workflowFingerprint))
            .compactMap { fingerprint -> (fingerprint: String, count: Int)? in
                guard let count = priorOccurrenceCounts[fingerprint] else {
                    return nil
                }
                return (fingerprint, count)
            }
            .sorted {
                if $0.count == $1.count { return $0.fingerprint < $1.fingerprint }
                return $0.count > $1.count
            }
            .first?.fingerprint
        let representativeCandidates =
            carriedFingerprint.map { fingerprint in
                currentEpisodes.filter { $0.workflowFingerprint == fingerprint }
            } ?? currentEpisodes
        let representative = representativeCandidates.max {
            if $0.interactions.count == $1.interactions.count {
                if $0.totalInteractionCount == $1.totalInteractionCount {
                    return $0.id > $1.id
                }
                return $0.totalInteractionCount < $1.totalInteractionCount
            }
            return $0.interactions.count < $1.interactions.count
        }!
        let carriedOccurrenceCount =
            carriedFingerprint.flatMap {
                priorOccurrenceCounts[$0]
            } ?? 0
        let (carriedAndCurrentCount, overflow) =
            carriedOccurrenceCount
            .addingReportingOverflow(currentIDs.count)
        let boundedOccurrenceCount = max(
            Set(cluster.map(\.id)).count,
            overflow ? Int.max : carriedAndCurrentCount
        )
        guard boundedOccurrenceCount >= 2 else { return nil }
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
            occurrenceCount: boundedOccurrenceCount,
            episodeIDs: currentIDs,
            actionSequence: compactActionSequence(representative.interactions),
            applications: applications,
            confidence: min(0.98, 0.65 + Double(boundedOccurrenceCount) * 0.08)
        )
    }

    private static func makeSuggestion(
        _ pattern: ComputerHistoryWorkflowPattern
    ) -> ComputerHistorySuggestion {
        let crossApplication = pattern.applications.count >= 2
        let kind: ComputerHistorySuggestionKind =
            pattern.occurrenceCount >= 3
                && crossApplication ? .automation : .skill
        let prefix = kind == .automation ? "Automate" : "Create a skill for"
        let sequence = pattern.actionSequence.prefix(8).joined(separator: " → ")
        let rationale =
            "Observed \(pattern.occurrenceCount) similar workflow occurrences"
            + (sequence.isEmpty ? "." : ": \(sequence).")
        let prompt: String
        if kind == .automation {
            prompt =
                "Create an automation that reproduces this reviewed workflow: \(sequence). Ask before any destructive, external or irreversible step."
        } else {
            prompt =
                "Create a reusable skill from this reviewed workflow: \(sequence). Preserve the observed order, required inputs and verification steps."
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
        _ left: Candidate,
        _ right: Candidate
    ) -> Double {
        let actionScore = ComputerHistorySupport.jaccard(
            left.normalizedActions,
            right.normalizedActions
        )
        let appScore = ComputerHistorySupport.jaccard(
            left.normalizedApplications,
            right.normalizedApplications
        )
        let titleScore = ComputerHistorySupport.jaccard(
            left.titleTokens,
            right.titleTokens
        )
        return actionScore * 0.55 + appScore * 0.25 + titleScore * 0.20
    }

    private static func compactActionSequence(
        _ interactions: [ComputerHistoryInteraction]
    ) -> [String] {
        var output: [String] = []
        output.reserveCapacity(12)
        for interaction in interactions {
            guard
                ![.scroll, .focusChange, .contextObservation]
                    .contains(interaction.action)
            else { continue }
            let application = interaction.application.map { " in \($0)" } ?? ""
            let value = interaction.action.rawValue + application
            guard output.last != value else { continue }
            output.append(value)
            if output.count == 12 { break }
        }
        return output
    }
}
