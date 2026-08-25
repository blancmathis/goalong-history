import Foundation

enum ComputerHistoryEpisodeBuilder {
    private struct Builder {
        var interactions: [ComputerHistoryInteraction]

        var last: ComputerHistoryInteraction { interactions[interactions.count - 1] }

        mutating func append(_ interaction: ComputerHistoryInteraction) {
            interactions.append(interaction)
        }
    }

    /// Scans every line while retaining only bounded first/last, state-changing
    /// and deterministic landmark evidence. Small fixtures keep their historical
    /// byte-for-byte behavior.
    private struct BoundedTextEvidence {
        private let compact: Bool
        private var count = 0
        private var all: [String] = []
        private var first: [String] = []
        private var signals: [String] = []
        private var landmarks: [String] = []
        private var last: [String] = []

        init(compact: Bool) {
            self.compact = compact
        }

        mutating func append(_ value: String) {
            guard !value.isEmpty else { return }
            guard compact else {
                all.append(value)
                return
            }

            count += 1
            if first.count < 24 { first.append(value) }
            if ComputerHistorySupport.isHighValueComputerHistoryText(value),
                signals.count < 64
            {
                signals.append(value)
            }
            if (count & (count - 1)) == 0 || count.isMultiple(of: 256),
                landmarks.count < 48
            {
                landmarks.append(value)
            }
            last.append(value)
            if last.count > 24 { last.removeFirst() }
        }

        mutating func append(contentsOf values: [String]) {
            for value in values { append(value) }
        }

        var values: [String] {
            guard compact else { return all }
            return ComputerHistorySupport.distinctText(
                first + signals + landmarks + last,
                maximum: 160,
                maximumLength: 360
            )
        }
    }

    private struct EpisodeEventSummary {
        let eventCount: Int
        let semanticSnapshotCount: Int
        let provenance: ActivityProvenance
    }

    /// One bounded index per build replaces repeated full-event scans for every
    /// episode while preserving the caller's original event order.
    private struct EventLookup {
        private let events: [HistoryEvent]
        private let chronologicalIndices: [Int]
        private let chronologyMatchesOriginalOrder: Bool
        private let linkedIndicesByID: [String: [Int]]
        private let linkedIndicesBySequence: [UInt64: [Int]]
        private let suppressedTimestamps: [Date]

        init(
            events: [HistoryEvent],
            linkedSourceIDs: Set<String>,
            linkedSourceSequences: Set<UInt64>
        ) {
            self.events = events
            let originalIndices = Array(events.indices)
            let alreadyChronological = zip(originalIndices, originalIndices.dropFirst())
                .allSatisfy { left, right in
                    events[left].timestamp <= events[right].timestamp
                }
            let chronologicalIndices =
                alreadyChronological
                ? originalIndices
                : originalIndices.sorted { left, right in
                    let leftTimestamp = events[left].timestamp
                    let rightTimestamp = events[right].timestamp
                    if leftTimestamp == rightTimestamp { return left < right }
                    return leftTimestamp < rightTimestamp
                }
            self.chronologicalIndices = chronologicalIndices
            chronologyMatchesOriginalOrder = alreadyChronological

            var linkedIndicesByID: [String: [Int]] = [:]
            var linkedIndicesBySequence: [UInt64: [Int]] = [:]
            var suppressedTimestamps: [Date] = []
            for index in originalIndices {
                let event = events[index]
                if event.isObservationContinuityBoundary {
                    suppressedTimestamps.append(event.timestamp)
                }
                if linkedSourceIDs.contains(event.id) {
                    linkedIndicesByID[event.id, default: []].append(index)
                }
                if let sequence = event.integrity?.sequence,
                    linkedSourceSequences.contains(sequence)
                {
                    linkedIndicesBySequence[sequence, default: []].append(index)
                }
            }
            self.linkedIndicesByID = linkedIndicesByID
            self.linkedIndicesBySequence = linkedIndicesBySequence
            self.suppressedTimestamps = suppressedTimestamps.sorted()
        }

        func hasSuppressedEvent(after lowerBound: Date, before upperBound: Date) -> Bool {
            guard lowerBound < upperBound else { return false }
            let index = firstSuppressedIndex { $0 > lowerBound }
            return index < suppressedTimestamps.count
                && suppressedTimestamps[index] < upperBound
        }

        func temporalIndices(from start: Date, through end: Date) -> [Int] {
            let lowerBound = firstChronologicalIndex {
                events[$0].timestamp >= start
            }
            let upperBound = firstChronologicalIndex {
                events[$0].timestamp > end
            }
            guard lowerBound < upperBound else { return [] }
            var result = Array(chronologicalIndices[lowerBound..<upperBound])
            if !chronologyMatchesOriginalOrder {
                result.sort()
            }
            return result
        }

        func contextLines(at indices: [Int]) -> [String] {
            var evidence = BoundedTextEvidence(compact: indices.count > 512)
            for index in indices {
                autoreleasepool {
                    let event = events[index]
                    guard event.suppressionReason == nil,
                        !event.isObservationContinuityBoundary
                    else { return }
                    for value in [event.window?.title, event.message].compactMap({ $0 }) {
                        if let clean = ActivitySemanticTextSanitizer.clean(
                            value,
                            maximumLength: 360
                        ) {
                            evidence.append(clean)
                        }
                    }
                }
            }
            return evidence.values
        }

        func episodeEvents(
            temporalIndices: [Int],
            temporalStart: Date,
            temporalEnd: Date,
            linkedSourceIDs: Set<String>,
            linkedSourceSequences: Set<UInt64>,
            provenanceReferenceLimit: Int?
        ) -> EpisodeEventSummary {
            var linkedOutsideTemporalRange: [Int] = []
            for sourceID in linkedSourceIDs {
                if let indices = linkedIndicesByID[sourceID] {
                    for index in indices
                    where
                        !(events[index].timestamp >= temporalStart
                        && events[index].timestamp <= temporalEnd)
                    {
                        linkedOutsideTemporalRange.append(index)
                    }
                }
            }
            for sequence in linkedSourceSequences {
                if let indices = linkedIndicesBySequence[sequence] {
                    for index in indices
                    where
                        !(events[index].timestamp >= temporalStart
                        && events[index].timestamp <= temporalEnd)
                    {
                        linkedOutsideTemporalRange.append(index)
                    }
                }
            }
            linkedOutsideTemporalRange.sort()

            var eventCount = 0
            var semanticSnapshotCount = 0
            var completeEvents: [HistoryEvent] = []
            if provenanceReferenceLimit == nil {
                completeEvents.reserveCapacity(
                    temporalIndices.count + linkedOutsideTemporalRange.count
                )
            }
            var firstEvents: [HistoryEvent] = []
            var lastEvents: [HistoryEvent] = []
            var temporalPosition = 0
            var linkedPosition = 0
            var lastSelectedIndex: Int?
            while temporalPosition < temporalIndices.count
                || linkedPosition < linkedOutsideTemporalRange.count
            {
                let nextIndex: Int
                if temporalPosition >= temporalIndices.count {
                    nextIndex = linkedOutsideTemporalRange[linkedPosition]
                    linkedPosition += 1
                } else if linkedPosition >= linkedOutsideTemporalRange.count
                    || temporalIndices[temporalPosition]
                        < linkedOutsideTemporalRange[linkedPosition]
                {
                    nextIndex = temporalIndices[temporalPosition]
                    temporalPosition += 1
                } else {
                    nextIndex = linkedOutsideTemporalRange[linkedPosition]
                    linkedPosition += 1
                }
                if nextIndex != lastSelectedIndex {
                    let event = events[nextIndex]
                    eventCount += 1
                    if event.kind == .semanticSnapshot {
                        semanticSnapshotCount += 1
                    }
                    if provenanceReferenceLimit == nil {
                        completeEvents.append(event)
                    } else if firstEvents.count < 8 {
                        firstEvents.append(event)
                    } else {
                        lastEvents.append(event)
                        if lastEvents.count > 8 { lastEvents.removeFirst() }
                    }
                    lastSelectedIndex = nextIndex
                }
            }
            return EpisodeEventSummary(
                eventCount: eventCount,
                semanticSnapshotCount: semanticSnapshotCount,
                provenance: ComputerHistorySupport.provenance(
                    for: provenanceReferenceLimit == nil
                        ? completeEvents
                        : firstEvents + lastEvents
                )
            )
        }

        private func firstChronologicalIndex(
            where predicate: (Int) -> Bool
        ) -> Int {
            var lower = 0
            var upper = chronologicalIndices.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if predicate(chronologicalIndices[middle]) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return lower
        }

        private func firstSuppressedIndex(where predicate: (Date) -> Bool) -> Int {
            var lower = 0
            var upper = suppressedTimestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if predicate(suppressedTimestamps[middle]) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return lower
        }
    }

    static func build(
        interactions: [ComputerHistoryInteraction],
        events: [HistoryEvent],
        resources: [ComputerHistoryResourceReference],
        provenanceReferenceLimit: Int? = nil
    ) -> [ComputerHistoryEpisode] {
        guard !interactions.isEmpty else { return [] }
        let (linkedSourceIDs, linkedSourceSequences) = sourceReferences(
            for: interactions
        )
        let eventLookup = EventLookup(
            events: events,
            linkedSourceIDs: linkedSourceIDs,
            linkedSourceSequences: linkedSourceSequences
        )
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
                eventLookup: eventLookup
            ) {
                previous.append(interaction)
                builders.append(previous)
            } else {
                builders.append(previous)
                builders.append(Builder(interactions: [interaction]))
            }
        }

        return builders.map { builder in
            autoreleasepool {
                finish(
                    builder,
                    eventLookup: eventLookup,
                    resources: resourcesByID,
                    provenanceReferenceLimit: provenanceReferenceLimit
                )
            }
        }
    }

    private static func shouldMerge(
        _ builder: Builder,
        _ next: ComputerHistoryInteraction,
        resources: [String: ComputerHistoryResourceReference],
        eventLookup: EventLookup
    ) -> Bool {
        let previous = builder.last
        let gap = next.start.timeIntervalSince(previous.end)
        guard gap >= -1, gap <= 20 * 60 else { return false }
        if eventLookup.hasSuppressedEvent(after: previous.end, before: next.start) {
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
            let sameApplication =
                (previous.bundleIdentifier != nil
                    && previous.bundleIdentifier == next.bundleIdentifier)
                || (previous.application != nil
                    && previous.application == next.application)
            // A cross-site navigation completed within a few seconds is normally one
            // observed workflow step (for example, opening a linked document from an
            // issue). Longer visits remain separate unless their semantic evidence is
            // related, preserving task boundaries for unrelated tab switches.
            if sameApplication, gap <= 5 { return true }
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
        let bothHaveSpecificResources =
            !previousResources.isEmpty
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
        eventLookup: EventLookup,
        resources: [String: ComputerHistoryResourceReference],
        provenanceReferenceLimit: Int?
    ) -> ComputerHistoryEpisode {
        let interactions = builder.interactions
        let start = interactions.first?.start ?? Date()
        let end = interactions.last?.end ?? start
        var seenResourceIDs = Set<String>()
        var resourceIDs: [String] = []
        for interaction in interactions {
            for resourceID in interaction.resourceIDs
            where seenResourceIDs.insert(resourceID).inserted {
                resourceIDs.append(resourceID)
            }
        }
        let episodeResources = resourceIDs.compactMap { resources[$0] }
        let applications = ComputerHistorySupport.rankedDistinct(
            interactions.compactMap(\.application)
        )
        let sites = ComputerHistorySupport.rankedDistinct(
            interactions.compactMap(\.host)
        )
        var semanticEvidence = BoundedTextEvidence(
            compact: interactions.count > 512
        )
        for interaction in interactions {
            semanticEvidence.append(contentsOf: interaction.semanticDelta)
            if let after = interaction.afterContext {
                semanticEvidence.append(
                    contentsOf: ComputerHistorySupport.splitSemanticLines(after)
                )
            }
        }
        let semanticLines = semanticEvidence.values

        // Window titles and recorder messages are also observable foreground evidence.
        // They matter when an application exposes a state such as “tests failed” in its
        // title bar but does not expose equivalent Accessibility text inside the page.
        // Suppressed events never contribute content to status inference.
        let temporalEventIndices = eventLookup.temporalIndices(
            from: start,
            through: end.addingTimeInterval(1)
        )
        let visibleEventContextLines = eventLookup.contextLines(at: temporalEventIndices)

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
            eventContextLines: visibleEventContextLines,
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
        let (sourceIDs, sourceSequences) = sourceReferences(for: interactions)
        let episodeEvents = eventLookup.episodeEvents(
            temporalIndices: temporalEventIndices,
            temporalStart: start,
            temporalEnd: end.addingTimeInterval(1),
            linkedSourceIDs: sourceIDs,
            linkedSourceSequences: sourceSequences,
            provenanceReferenceLimit: provenanceReferenceLimit
        )
        let firstInteractionID = interactions.first?.id ?? "missing-first"
        let lastInteractionID = interactions.last?.id ?? "missing-last"

        return ComputerHistoryEpisode(
            id: ComputerHistorySupport.stableIdentifier(
                "episode|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(firstInteractionID)|\(lastInteractionID)|\(fingerprint)"
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
            eventCount: episodeEvents.eventCount,
            semanticSnapshotCount: episodeEvents.semanticSnapshotCount,
            workflowFingerprint: fingerprint,
            provenance: episodeEvents.provenance
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
            guard
                ComputerHistorySupport.containsAny(
                    normalized,
                    markers: completionMarkers
                )
            else { return nil }
            return ComputerHistorySupport.bounded(line, maximum: 360)
        }
        let lastDelta = interactions.reversed().lazy.compactMap {
            $0.semanticDelta.first
        }.first
        if output.isEmpty, let lastDelta {
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

    private static func sourceReferences(
        for interactions: [ComputerHistoryInteraction]
    ) -> (ids: Set<String>, sequences: Set<UInt64>) {
        var ids = Set<String>()
        var sequences = Set<UInt64>()
        for interaction in interactions {
            ids.formUnion(interaction.provenance.sourceEventIDs)
            sequences.formUnion(interaction.provenance.sourceSequences)
        }
        return (ids, sequences)
    }

    private struct StatusResult {
        let value: ComputerHistoryTaskStatus
        let confidence: Double
    }

    private static func inferStatus(
        interactions: [ComputerHistoryInteraction],
        semanticLines: [String],
        eventContextLines: [String],
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
        var recentLines = interactions.suffix(3).flatMap { interaction -> [String] in
            var values = interaction.semanticDelta
            if let after = interaction.afterContext {
                values.append(contentsOf: ComputerHistorySupport.splitSemanticLines(after))
            }
            values.append(interaction.label)
            return values
        }
        recentLines.append(contentsOf: eventContextLines.suffix(3))
        let recentText =
            " "
            + ComputerHistorySupport.normalized(
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

        let interactionLabels: [String]
        if interactions.count > 512 {
            var labelEvidence = BoundedTextEvidence(compact: true)
            for interaction in interactions {
                labelEvidence.append(interaction.label)
            }
            interactionLabels = labelEvidence.values
        } else {
            interactionLabels = interactions.map(\.label)
        }
        let allText =
            " "
            + ComputerHistorySupport.normalized(
                (semanticLines + eventContextLines + interactionLabels).joined(separator: " ")
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
        let completionIsNegated =
            text.contains(" not completed ")
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
        if let delta = interactions.lazy.compactMap({ $0.semanticDelta.first }).first {
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
        let sequence = Array(
            interactions.lazy.filter {
                ![.scroll, .focusChange, .contextObservation].contains($0.action)
            }.prefix(10).map(\.label)
        )
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
        var compact: [String] = []
        for interaction in interactions {
            guard
                ![.scroll, .focusChange, .contextObservation]
                    .contains(interaction.action)
            else { continue }
            let application =
                interaction.bundleIdentifier
                ?? ComputerHistorySupport.normalized(interaction.application ?? "unknown")
            let resourceKind =
                interaction.resourceIDs
                .compactMap { resources[$0]?.kind.rawValue }
                .first ?? "none"
            let value = "\(application):\(interaction.action.rawValue):\(resourceKind)"
            if compact.last != value { compact.append(value) }
            if compact.count == 12 { break }
        }
        return ComputerHistorySupport.stableIdentifier(
            "workflow|" + compact.joined(separator: "→")
        )
    }
}
