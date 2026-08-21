import Foundation

enum ComputerHistoryEpisodeBuilder {
    private struct Builder {
        var interactions: [ComputerHistoryInteraction]

        var last: ComputerHistoryInteraction { interactions[interactions.count - 1] }

        mutating func append(_ interaction: ComputerHistoryInteraction) {
            interactions.append(interaction)
        }
    }

    static func build(
        interactions: [ComputerHistoryInteraction],
        events: [HistoryEvent],
        resources: [ComputerHistoryResourceReference]
    ) -> [ComputerHistoryEpisode] {
        guard !interactions.isEmpty else { return [] }
        let suppressedTimestamps = events
            .filter { $0.suppressionReason != nil }
            .map(\.timestamp)
        let resourcesByID = Dictionary(
            uniqueKeysWithValues: resources.map { ($0.id, $0) }
        )
        var builders: [Builder] = []

        for interaction in interactions {
            guard var previous = builders.popLast() else {
                builders.append(Builder(interactions: [interaction]))
                continue
            }
            if shouldMerge(
                previous,
                interaction,
                resources: resourcesByID,
                suppressedTimestamps: suppressedTimestamps
            ) {
                previous.append(interaction)
                builders.append(previous)
            } else {
                builders.append(previous)
                builders.append(Builder(interactions: [interaction]))
            }
        }

        return builders.map {
            finish($0, events: events, resources: resourcesByID)
        }
    }

    private static func shouldMerge(
        _ builder: Builder,
        _ next: ComputerHistoryInteraction,
        resources: [String: ComputerHistoryResourceReference],
        suppressedTimestamps: [Date]
    ) -> Bool {
        let previous = builder.last
        let gap = next.start.timeIntervalSince(previous.end)
        guard gap >= -1, gap <= 20 * 60 else { return false }
        if suppressedTimestamps.contains(where: {
            $0 > previous.end && $0 < next.start
        }) {
            return false
        }

        let previousResources = Set(previous.resourceIDs)
        let nextResources = Set(next.resourceIDs)
        if !previousResources.isDisjoint(with: nextResources) {
            return gap <= 20 * 60
        }

        let similarity = ComputerHistorySupport.tokenSimilarity(
            [previous.label] + previous.semanticDelta,
            [next.label] + next.semanticDelta
        )
        if let leftHost = previous.host,
            let rightHost = next.host
        {
            if leftHost == rightHost { return gap <= 10 * 60 }
            // A browser switch to a different host is normally a new task unless it is
            // immediate and the surrounding semantic evidence is clearly related.
            return gap <= 120 && similarity >= 0.25
        }

        let previousKinds = Set(
            previous.resourceIDs.compactMap { resources[$0]?.kind }
        )
        let nextKinds = Set(
            next.resourceIDs.compactMap { resources[$0]?.kind }
        )
        let bothHaveSpecificResources = !previousResources.isEmpty
            && !nextResources.isEmpty
            && !previousKinds.isSubset(of: [.application])
            && !nextKinds.isSubset(of: [.application])

        if let leftBundle = previous.bundleIdentifier,
            let rightBundle = next.bundleIdentifier,
            leftBundle == rightBundle
        {
            if bothHaveSpecificResources {
                if similarity >= 0.22 { return gap <= 6 * 60 }
                return gap <= 120
            }
            return gap <= 8 * 60
        }
        if previous.application == next.application,
            previous.application != nil
        {
            if bothHaveSpecificResources {
                return gap <= 120 || (gap <= 6 * 60 && similarity >= 0.22)
            }
            return gap <= 8 * 60
        }
        if similarity >= 0.18 { return gap <= 6 * 60 }
        return gap <= 90
    }

    private static func finish(
        _ builder: Builder,
        events: [HistoryEvent],
        resources: [String: ComputerHistoryResourceReference]
    ) -> ComputerHistoryEpisode {
        let interactions = builder.interactions
        let start = interactions.first?.start ?? Date()
        let end = interactions.last?.end ?? start
        let resourceIDs = ComputerHistorySupport.distinct(
            interactions.flatMap(\.resourceIDs)
        )
        let episodeResources = resourceIDs.compactMap { resources[$0] }
        let applications = ComputerHistorySupport.rankedDistinct(
            interactions.compactMap(\.application)
        )
        let sites = ComputerHistorySupport.rankedDistinct(
            interactions.compactMap(\.host)
        )
        let semanticLines = interactions.flatMap { interaction -> [String] in
            var lines = interaction.semanticDelta
            if let after = interaction.afterContext {
                lines.append(contentsOf: ComputerHistorySupport.splitSemanticLines(after))
            }
            return lines
        }
        let requests = ComputerHistorySupport.distinctText(
            semanticLines.filter(ComputerHistorySupport.looksLikeRequestOrIntention),
            maximum: 12,
            maximumLength: 360
        )
        let outcomes = observableOutcomes(
            interactions: interactions,
            semanticLines: semanticLines
        )
        let status = inferStatus(
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
        let fingerprint = workflowFingerprint(
            interactions: interactions,
            resources: resources
        )
        let sourceIDs = Set(interactions.flatMap { $0.provenance.sourceEventIDs })
        let sourceSequences = Set(interactions.flatMap { $0.provenance.sourceSequences })
        let episodeEvents = events.filter { event in
            let isLinked = sourceIDs.contains(event.id)
                || event.integrity.map { sourceSequences.contains($0.sequence) } == true
            let isInside = event.timestamp >= start
                && event.timestamp <= end.addingTimeInterval(1)
            return isLinked || isInside
        }

        return ComputerHistoryEpisode(
            id: ComputerHistorySupport.stableIdentifier(
                "episode|\(start.timeIntervalSince1970)|\(fingerprint)"
            ),
            start: start,
            end: end,
            title: title,
            summary: episodeSummary(
                title: title,
                interactions: interactions,
                resources: episodeResources,
                requests: requests,
                outcomes: outcomes,
                status: status.value
            ),
            status: status.value,
            statusConfidence: status.confidence,
            applications: applications,
            sites: sites,
            resourceIDs: resourceIDs,
            requestsOrIntentions: requests,
            observableOutcomes: outcomes,
            interactions: interactions,
            eventCount: episodeEvents.count,
            semanticSnapshotCount: episodeEvents.filter {
                $0.kind == .semanticSnapshot
            }.count,
            workflowFingerprint: fingerprint,
            provenance: ComputerHistorySupport.provenance(for: episodeEvents)
        )
    }

    private static func observableOutcomes(
        interactions: [ComputerHistoryInteraction],
        semanticLines: [String]
    ) -> [String] {
        let completionMarkers = [
            "saved", "sent", "submitted", "published", "merged", "closed", "resolved",
            "deployed", "passed", "success", "completed", "done", "created", "updated",
            "enregistr", "envoy", "publi", "fusionn", "ferme", "resolu", "reussi", "termine",
        ]
        var output = semanticLines.compactMap { line -> String? in
            let normalized = ComputerHistorySupport.normalized(line)
            guard ComputerHistorySupport.containsAny(
                normalized,
                markers: completionMarkers
            ) else { return nil }
            return ComputerHistorySupport.bounded(line, maximum: 360)
        }
        if output.isEmpty,
            let lastDelta = interactions.reversed().flatMap(\.semanticDelta).first
        {
            output.append(
                "Last observable change: "
                    + ComputerHistorySupport.bounded(lastDelta, maximum: 320)
            )
        }
        if output.isEmpty, let last = interactions.last {
            output.append("Last observable action: \(last.label)")
        }
        return ComputerHistorySupport.distinctText(
            output,
            maximum: 8,
            maximumLength: 360
        )
    }

    private struct StatusResult {
        let value: ComputerHistoryTaskStatus
        let confidence: Double
    }

    private static func inferStatus(
        interactions: [ComputerHistoryInteraction],
        semanticLines: [String],
        requests: [String]
    ) -> StatusResult {
        let blocked = [
            " error ", " failed ", " failure ", " blocked ", " cannot ", " impossible ",
            " erreur ", " echoue ", " bloque ",
        ]
        let waiting = [
            " waiting ", " pending ", " awaiting ", " review requested ",
            " en attente ", " attend ",
        ]
        let completed = [
            " saved ", " sent ", " submitted ", " published ", " merged ", " closed ",
            " resolved ", " deployed ", " tests passed ", " success ", " completed ",
            " done ", " enregistre ", " envoye ", " publie ", " fusionne ", " ferme ",
            " resolu ", " reussi ", " termine ",
        ]

        // The latest observable state wins over earlier transient errors. This avoids
        // marking a task blocked when a later retry visibly succeeded.
        let recentLines = interactions.suffix(3).flatMap { interaction -> [String] in
            var values = interaction.semanticDelta
            if let after = interaction.afterContext {
                values.append(contentsOf: ComputerHistorySupport.splitSemanticLines(after))
            }
            values.append(interaction.label)
            return values
        }
        let recentText = " " + ComputerHistorySupport.normalized(
            recentLines.joined(separator: " ")
        ) + " "
        if let recent = explicitStatus(
            in: recentText,
            blocked: blocked,
            waiting: waiting,
            completed: completed,
            confidence: 0.86
        ) {
            return recent
        }

        let allText = " " + ComputerHistorySupport.normalized(
            (semanticLines + interactions.map(\.label)).joined(separator: " ")
        ) + " "
        if let historical = explicitStatus(
            in: allText,
            blocked: blocked,
            waiting: waiting,
            completed: completed,
            confidence: 0.76
        ) {
            return historical
        }

        let productive = interactions.filter {
            [.click, .typing, .shortcut, .navigationKey].contains($0.action)
        }
        if productive.isEmpty, !requests.isEmpty {
            return StatusResult(value: .planned, confidence: 0.68)
        }
        if !productive.isEmpty {
            return StatusResult(value: .inProgress, confidence: 0.72)
        }
        return StatusResult(value: .unknown, confidence: 0.45)
    }

    private static func explicitStatus(
        in text: String,
        blocked: [String],
        waiting: [String],
        completed: [String],
        confidence: Double
    ) -> StatusResult? {
        let completionIsNegated = text.contains(" not completed ")
            || text.contains(" not done ")
            || text.contains(" pas termine ")
            || text.contains(" non termine ")
        if ComputerHistorySupport.containsAny(text, markers: completed),
            !completionIsNegated
        {
            return StatusResult(value: .completed, confidence: confidence)
        }
        if ComputerHistorySupport.containsAny(text, markers: blocked) {
            return StatusResult(value: .blocked, confidence: confidence)
        }
        if ComputerHistorySupport.containsAny(text, markers: waiting) {
            return StatusResult(value: .waiting, confidence: confidence - 0.04)
        }
        return nil
    }

    private static func episodeTitle(
        requests: [String],
        outcomes: [String],
        resources: [ComputerHistoryResourceReference],
        interactions: [ComputerHistoryInteraction],
        applications: [String]
    ) -> String {
        if let request = requests.first {
            return ComputerHistorySupport.sentenceTitle(request, maximum: 100)
        }
        if let resource = resources.first(where: { $0.kind != .application }) {
            return "Worked on "
                + ComputerHistorySupport.bounded(resource.title, maximum: 86)
        }
        if let outcome = outcomes.first,
            !outcome.hasPrefix("Last observable")
        {
            return ComputerHistorySupport.sentenceTitle(outcome, maximum: 100)
        }
        if let delta = interactions.flatMap(\.semanticDelta).first {
            return ComputerHistorySupport.sentenceTitle(delta, maximum: 100)
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
            parts.append(
                "Resources: "
                    + resources.prefix(4).map(\.title).joined(separator: ", ")
            )
        }
        let meaningful = interactions.filter {
            ![.scroll, .focusChange, .contextObservation].contains($0.action)
        }
        let sequence = meaningful.prefix(10).map(\.label)
        if !sequence.isEmpty {
            parts.append("Observed sequence: " + sequence.joined(separator: " → "))
        }
        if let request = requests.first {
            parts.append("Observed intention: \(request)")
        }
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
            guard ![.scroll, .focusChange, .contextObservation]
                .contains(interaction.action)
            else { return nil }
            let application = interaction.bundleIdentifier
                ?? ComputerHistorySupport.normalized(interaction.application ?? "unknown")
            let resourceKind = interaction.resourceIDs
                .compactMap { resources[$0]?.kind.rawValue }
                .first ?? "none"
            return "\(application):\(interaction.action.rawValue):\(resourceKind)"
        }
        let compact = Array(
            ComputerHistorySupport.collapseConsecutive(sequence).prefix(12)
        )
        return ComputerHistorySupport.stableIdentifier(
            "workflow|" + compact.joined(separator: "→")
        )
    }
}
