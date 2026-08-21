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
        generatedAt: Date = Date()
    ) -> ComputerHistoryDayMemory {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let scoped = events
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted(by: ComputerHistorySupport.eventOrder)
        let captured = scoped.filter { $0.suppressionReason == nil }

        let resolution = ComputerHistoryResourceResolver.resolve(
            events: captured,
            semanticSnapshots: semanticSnapshots
        )
        let interactions = ComputerHistoryInteractionBuilder.build(
            events: captured,
            semanticSnapshots: semanticSnapshots,
            eventResourceIDs: resolution.eventResourceIDs
        )
        let episodes = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: scoped,
            resources: resolution.resources
        )
        let workflows = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: priorMemories
        )

        let integrity = scoped.compactMap(\.integrity)
        let coverage = ComputerHistoryCoverage(
            sourceEventCount: scoped.count,
            actionEventCount: captured.filter(ComputerHistorySupport.isActionEvent).count,
            semanticSnapshotCount: captured.filter {
                ComputerHistorySupport.semanticText(
                    for: $0,
                    semanticSnapshots: semanticSnapshots
                ) != nil
            }.count,
            linkedInteractionCount: interactions.count,
            interactionsWithBeforeAndAfterContext: interactions.filter {
                $0.beforeContext != nil && $0.afterContext != nil
            }.count,
            resourceCount: resolution.resources.count,
            episodeCount: episodes.count,
            suppressedEventCount: scoped.filter { $0.suppressionReason != nil }.count,
            firstSourceSequence: integrity.first?.sequence,
            lastSourceSequence: integrity.last?.sequence,
            lastSourceEventHash: integrity.last?.eventHash
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
            episodes: episodes,
            resources: resolution.resources,
            workflowPatterns: workflows.patterns,
            suggestions: workflows.suggestions,
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

    private static func dayTitle(
        episodes: [ComputerHistoryEpisode],
        dayStart: Date
    ) -> String {
        guard let primary = episodes.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }) else {
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
            parts.append("kept \(unfinished) unfinished, blocked or waiting episode\(unfinished == 1 ? "" : "s") explicit")
        }
        if !suggestions.isEmpty {
            parts.append("detected \(suggestions.count) grounded skill or automation suggestion\(suggestions.count == 1 ? "" : "s")")
        }
        if suppressedEventCount > 0 {
            parts.append("preserved \(suppressedEventCount) suppressed event\(suppressedEventCount == 1 ? "" : "s") as coverage gaps")
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
