import Foundation

public enum ComputerHistoryMarkdownRenderer {
    public static func render(_ memory: ComputerHistoryDayMemory) -> String {
        var lines: [String] = [
            "# \(memory.title)",
            "",
            memory.executiveSummary,
            "",
            "> \(memory.securityNotice)",
        ]
        let resources = Dictionary(uniqueKeysWithValues: memory.resources.map { ($0.id, $0) })

        lines.append(contentsOf: ["", "## Timeline"])
        if let retained = memory.coverage.retainedEpisodeCount,
            retained < memory.coverage.episodeCount
        {
            lines.append(contentsOf: [
                "",
                "Representative episodes retained: \(retained) of "
                    + "\(memory.coverage.episodeCount) exact reconstructed episodes.",
            ])
        }
        if memory.episodes.isEmpty {
            lines.append(contentsOf: ["", "No inspectable episodes were reconstructed."])
        } else {
            for episode in memory.episodes {
                lines.append("")
                lines.append(
                    "### \(timeFormatter.string(from: episode.start))–\(timeFormatter.string(from: episode.end)) — \(episode.title)"
                )
                lines.append("")
                lines.append(
                    "- Status: `\(episode.status.rawValue)` (confidence \(Int((episode.statusConfidence * 100).rounded()))%)"
                )
                if !episode.applications.isEmpty {
                    lines.append("- Apps: \(episode.applications.joined(separator: ", "))")
                }
                if !episode.sites.isEmpty {
                    lines.append("- Sites: \(episode.sites.joined(separator: ", "))")
                }
                let episodeResources = episode.resourceIDs.compactMap { resources[$0] }
                if !episodeResources.isEmpty {
                    lines.append("- Resources:")
                    for resource in episodeResources {
                        let locator = resource.localPath
                            ?? resource.canonicalURI
                            ?? "locator unavailable"
                        lines.append(
                            "  - [\(resource.kind.rawValue)] \(resource.title) — `\(locator)`"
                        )
                    }
                }
                lines.append("- Summary: \(episode.summary)")
                if !episode.requestsOrIntentions.isEmpty {
                    lines.append("- Requests or intentions:")
                    for value in episode.requestsOrIntentions {
                        lines.append("  - \(value)")
                    }
                }
                if !episode.observableOutcomes.isEmpty {
                    lines.append("- Observable outcomes:")
                    for value in episode.observableOutcomes {
                        lines.append("  - \(value)")
                    }
                }
                if episode.totalInteractionCount > episode.interactions.count {
                    lines.append(
                        "- Interactions represented: \(episode.interactions.count) of "
                            + "\(episode.totalInteractionCount) exact interactions"
                    )
                }
                lines.append("- Action sequence:")
                for interaction in episode.interactions {
                    var detail = "  - \(timeFormatter.string(from: interaction.start)) — \(interaction.label)"
                    if !interaction.semanticDelta.isEmpty {
                        detail += " | change: "
                            + interaction.semanticDelta.prefix(3).joined(separator: " · ")
                    }
                    lines.append(detail)
                }
                lines.append(
                    "- Evidence: events=\(episode.eventCount), semantic_snapshots=\(episode.semanticSnapshotCount), workflow=\(episode.workflowFingerprint)"
                )
            }
        }

        if !memory.resources.isEmpty {
            lines.append(contentsOf: ["", "## Source index"])
            if let retained = memory.coverage.retainedResourceCount,
                retained < memory.coverage.resourceCount
            {
                lines.append("")
                lines.append(
                    "Representative links retained: \(retained) of "
                        + "\(memory.coverage.resourceCount) exact identified resources."
                )
            }
            for resource in memory.resources {
                let locator = resource.localPath
                    ?? resource.canonicalURI
                    ?? "locator unavailable"
                lines.append(
                    "- [\(resource.kind.rawValue)] \(resource.title) — `\(locator)` — confidence \(Int((resource.locatorConfidence * 100).rounded()))%"
                )
            }
        }

        if !memory.workflowPatterns.isEmpty {
            lines.append(contentsOf: ["", "## Repeatable workflows"])
            for workflow in memory.workflowPatterns {
                lines.append(
                    "- \(workflow.title) — \(workflow.occurrenceCount) occurrences — \(workflow.actionSequence.joined(separator: " → "))"
                )
            }
        }

        if !memory.suggestions.isEmpty {
            lines.append(contentsOf: ["", "## Suggested skills and automations"])
            for suggestion in memory.suggestions {
                lines.append(
                    "- **\(suggestion.title)** (`\(suggestion.kind.rawValue)`): \(suggestion.rationale)"
                )
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
            "- Reconstructed episodes: \(memory.coverage.episodeCount)",
            "- Linked interactions: \(memory.coverage.linkedInteractionCount)",
            "- Identified resources: \(memory.coverage.resourceCount)",
            "- Before/after semantic pairs: \(memory.coverage.interactionsWithBeforeAndAfterContext)",
            "- Suppressed events: \(memory.coverage.suppressedEventCount)",
            "- Foreground observations do not prove attention, identity, authorship, productivity or completion. Statuses are bounded interpretations of observable evidence.",
        ])
        if let retained = memory.coverage.retainedEpisodeCount {
            lines.append("- Representative episodes retained: \(retained)")
        }
        if let retained = memory.coverage.retainedInteractionCount {
            lines.append("- Representative interactions retained: \(retained)")
        }
        if let retained = memory.coverage.retainedResourceCount {
            lines.append("- Representative resource links retained: \(retained)")
        }
        if let first = memory.coverage.firstSourceSequence,
            let last = memory.coverage.lastSourceSequence
        {
            lines.append("- Source integrity sequence: \(first)–\(last)")
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
