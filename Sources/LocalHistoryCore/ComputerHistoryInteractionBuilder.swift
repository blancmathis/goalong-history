import Foundation

enum ComputerHistoryInteractionBuilder {
    private struct SemanticObservation {
        let event: HistoryEvent
        let text: String
        let interactionID: String?
        let phase: String?
    }

    private enum ApplicationNameKey: Hashable {
        case missing
        case value(String)
    }

    private struct ContinuityBarrierLookup {
        private let sequenced: [UInt64]
        private let unsequenced: [HistoryEvent]

        init(_ events: [HistoryEvent]) {
            sequenced = events.compactMap { $0.integrity?.sequence }.sorted()
            unsequenced = events
                .filter { $0.integrity?.sequence == nil }
                .sorted(by: ComputerHistorySupport.eventOrder)
        }

        func separates(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
            if let leftSequence = left.integrity?.sequence,
                let rightSequence = right.integrity?.sequence,
                leftSequence < rightSequence
            {
                let candidate = firstIndex(in: sequenced) { $0 > leftSequence }
                if candidate < sequenced.count, sequenced[candidate] < rightSequence {
                    return true
                }
            }

            let candidate = firstIndex(in: unsequenced) {
                ComputerHistorySupport.eventOrder(left, $0)
            }
            return candidate < unsequenced.count
                && ComputerHistorySupport.eventOrder(unsequenced[candidate], right)
        }

        private func firstIndex<T>(
            in values: [T],
            where predicate: (T) -> Bool
        ) -> Int {
            var lower = 0
            var upper = values.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if predicate(values[middle]) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return lower
        }
    }

    /// Timestamp-sorted observation indices partitioned with the exact matching
    /// semantics from `ComputerHistorySupport.sameApplication`.
    private struct ObservationLookup {
        private static let maximumCarriedBeforeCandidates = 64

        private var all: [Int] = []
        private var byBundleIdentifier: [String: [Int]] = [:]
        private var byApplicationName: [ApplicationNameKey: [Int]] = [:]
        private var unbundledByApplicationName: [ApplicationNameKey: [Int]] = [:]

        mutating func append(_ observation: SemanticObservation, at index: Int) {
            all.append(index)
            let nameKey = Self.nameKey(for: observation.event)
            byApplicationName[nameKey, default: []].append(index)
            if let bundleIdentifier = observation.event.app?.bundleIdentifier {
                byBundleIdentifier[bundleIdentifier, default: []].append(index)
            } else {
                unbundledByApplicationName[nameKey, default: []].append(index)
            }
        }

        func nearest(
            before event: HistoryEvent,
            observations: [SemanticObservation]
        ) -> SemanticObservation? {
            var bestIndex: Int?
            forEachCandidateList(for: event) { indices in
                guard
                    let candidate = Self.nearestBefore(
                        event.timestamp,
                        in: indices,
                        observations: observations
                    )
                else { return }
                if Self.isBetterBefore(
                    candidate,
                    than: bestIndex,
                    observations: observations
                ) {
                    bestIndex = candidate
                }
            }
            return bestIndex.map { observations[$0] }
        }

        func nearest(
            after event: HistoryEvent,
            observations: [SemanticObservation]
        ) -> SemanticObservation? {
            var bestIndex: Int?
            forEachCandidateList(for: event) { indices in
                guard
                    let candidate = Self.nearestAfter(
                        event.timestamp,
                        in: indices,
                        observations: observations
                    )
                else { return }
                if Self.isBetterAfter(
                    candidate,
                    than: bestIndex,
                    observations: observations
                ) {
                    bestIndex = candidate
                }
            }
            return bestIndex.map { observations[$0] }
        }

        /// Reuses a completed prior interaction state as the next interaction's
        /// chronological before-state. This adds no Accessibility read: it only
        /// consumes an already persisted after/settled observation from a different
        /// interaction in the same resource context. The bounded reverse scan keeps
        /// bursty days from turning this fallback into an unbounded search.
        func nearestPriorOutcome(
            before event: HistoryEvent,
            excludingInteractionID interactionID: String,
            allowsApplicationTransition: Bool,
            barriers: ContinuityBarrierLookup,
            observations: [SemanticObservation]
        ) -> SemanticObservation? {
            var bestIndex: Int?
            let consider: ([Int]) -> Void = { indices in
                guard
                    let candidate = Self.nearestPriorOutcome(
                        before: event,
                        excludingInteractionID: interactionID,
                        allowsApplicationTransition: allowsApplicationTransition,
                        barriers: barriers,
                        in: indices,
                        observations: observations
                    )
                else { return }
                if Self.isBetterBefore(
                    candidate,
                    than: bestIndex,
                    observations: observations
                ) {
                    bestIndex = candidate
                }
            }
            if allowsApplicationTransition {
                consider(all)
            } else {
                forEachCandidateList(for: event, consider)
            }
            return bestIndex.map { observations[$0] }
        }

        /// Returns the latest semantic state that was already recorded before an
        /// application transition. Unlike an input action, an app switch is itself
        /// the resource boundary, so its useful before-state normally belongs to the
        /// application being left. Sequence ordering and continuity barriers keep
        /// this fallback causal without performing another Accessibility capture.
        func nearestChronologicalState(
            before event: HistoryEvent,
            barriers: ContinuityBarrierLookup,
            observations: [SemanticObservation]
        ) -> SemanticObservation? {
            var cursor = Self.firstIndex(in: all) {
                observations[$0].event.timestamp > event.timestamp
            }
            var examined = 0
            while cursor > 0, examined < Self.maximumCarriedBeforeCandidates {
                cursor -= 1
                examined += 1
                let candidate = observations[all[cursor]]
                let age = event.timestamp.timeIntervalSince(candidate.event.timestamp)
                if age > 20 { break }
                guard age >= 0,
                    ComputerHistoryInteractionBuilder.occursBefore(candidate.event, event),
                    !barriers.separates(candidate.event, event)
                else { continue }
                return candidate
            }
            return nil
        }

        private func forEachCandidateList(
            for event: HistoryEvent,
            _ body: ([Int]) -> Void
        ) {
            let nameKey = Self.nameKey(for: event)
            if let bundleIdentifier = event.app?.bundleIdentifier {
                if let indices = byBundleIdentifier[bundleIdentifier] {
                    body(indices)
                }
                // `sameApplication` falls back to the application name whenever
                // either side has no bundle identifier.
                if let indices = unbundledByApplicationName[nameKey] {
                    body(indices)
                }
            } else if let indices = byApplicationName[nameKey] {
                body(indices)
            }
        }

        private static func nameKey(for event: HistoryEvent) -> ApplicationNameKey {
            event.app.map { .value($0.name) } ?? .missing
        }

        private static func nearestBefore(
            _ timestamp: Date,
            in indices: [Int],
            observations: [SemanticObservation]
        ) -> Int? {
            let upperBound = firstIndex(in: indices) {
                observations[$0].event.timestamp > timestamp
            }
            guard upperBound > 0 else { return nil }

            let nearestTimestamp = observations[indices[upperBound - 1]].event.timestamp
            guard timestamp.timeIntervalSince(nearestTimestamp) <= 20 else { return nil }

            // `Sequence.max(by:)` keeps the first element for equal timestamps.
            let firstAtNearestTimestamp = firstIndex(
                in: indices,
                upperBound: upperBound
            ) {
                observations[$0].event.timestamp >= nearestTimestamp
            }
            return indices[firstAtNearestTimestamp]
        }

        private static func nearestAfter(
            _ timestamp: Date,
            in indices: [Int],
            observations: [SemanticObservation]
        ) -> Int? {
            let lowerBound = firstIndex(in: indices) {
                observations[$0].event.timestamp >= timestamp
            }
            guard lowerBound < indices.count else { return nil }
            let candidate = indices[lowerBound]
            guard observations[candidate].event.timestamp.timeIntervalSince(timestamp) <= 20 else {
                return nil
            }
            return candidate
        }

        private static func nearestPriorOutcome(
            before event: HistoryEvent,
            excludingInteractionID interactionID: String,
            allowsApplicationTransition: Bool,
            barriers: ContinuityBarrierLookup,
            in indices: [Int],
            observations: [SemanticObservation]
        ) -> Int? {
            var cursor = firstIndex(in: indices) {
                observations[$0].event.timestamp > event.timestamp
            }
            var examined = 0
            while cursor > 0, examined < maximumCarriedBeforeCandidates {
                cursor -= 1
                examined += 1
                let candidateIndex = indices[cursor]
                let candidate = observations[candidateIndex]
                let age = event.timestamp.timeIntervalSince(candidate.event.timestamp)
                if age > 20 { break }
                guard age >= 0,
                    candidate.interactionID != interactionID,
                    candidate.phase == ComputerHistoryMetadata.Phase.after
                        || candidate.phase == ComputerHistoryMetadata.Phase.settled,
                    ComputerHistoryInteractionBuilder.occursBefore(candidate.event, event),
                    !barriers.separates(candidate.event, event),
                    allowsApplicationTransition
                        || ComputerHistoryInteractionBuilder.sameResourceContext(candidate.event, event)
                else { continue }
                return candidateIndex
            }
            return nil
        }

        private static func firstIndex(
            in indices: [Int],
            upperBound: Int? = nil,
            where predicate: (Int) -> Bool
        ) -> Int {
            var lower = 0
            var upper = upperBound ?? indices.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if predicate(indices[middle]) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return lower
        }

        private static func isBetterBefore(
            _ candidate: Int,
            than current: Int?,
            observations: [SemanticObservation]
        ) -> Bool {
            guard let current else { return true }
            let candidateEvent = observations[candidate].event
            let currentEvent = observations[current].event
            if candidateEvent.timestamp != currentEvent.timestamp {
                return candidateEvent.timestamp > currentEvent.timestamp
            }
            // The former `max(by:)` kept the first observation when timestamps
            // were equal, even for duplicate event identifiers.
            return candidate < current
        }

        private static func isBetterAfter(
            _ candidate: Int,
            than current: Int?,
            observations: [SemanticObservation]
        ) -> Bool {
            guard let current else { return true }
            let candidateEvent = observations[candidate].event
            let currentEvent = observations[current].event
            if candidateEvent.timestamp != currentEvent.timestamp {
                return candidateEvent.timestamp < currentEvent.timestamp
            }
            // The former `min(by:)` also kept the first equal observation.
            return candidate < current
        }
    }

    private static func occursBefore(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        if let leftSequence = left.integrity?.sequence,
            let rightSequence = right.integrity?.sequence,
            leftSequence != rightSequence
        {
            return leftSequence < rightSequence
        }
        return ComputerHistorySupport.eventOrder(left, right)
    }

    private static func sameResourceContext(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
        guard ComputerHistorySupport.sameApplication(left, right) else { return false }

        let leftHost = ComputerHistorySupport.normalizedHost(left.url?.host)
        let rightHost = ComputerHistorySupport.normalizedHost(right.url?.host)
        if leftHost != nil || rightHost != nil {
            return leftHost == rightHost
        }

        let leftWindow = left.window?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightWindow = right.window?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftWindow, !leftWindow.isEmpty,
            let rightWindow, !rightWindow.isEmpty
        {
            return leftWindow == rightWindow
        }
        return true
    }

    static func build(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload],
        eventResourceIDs: [String: [String]],
        precomputedSemanticTexts: [String?]? = nil,
        continuityBoundaries: [HistoryEvent] = []
    ) -> [ComputerHistoryInteraction] {
        let eventIndices = events.indices
        let eventsAreOrdered = zip(eventIndices, eventIndices.dropFirst())
            .allSatisfy { left, right in
                !ComputerHistorySupport.eventOrder(events[right], events[left])
            }
        let ordered =
            eventsAreOrdered
            ? events
            : events.sorted(by: ComputerHistorySupport.eventOrder)
        let canUsePrecomputedSemanticTexts =
            eventsAreOrdered && precomputedSemanticTexts?.count == ordered.count
        // Status and outcome inference must see the sanitizer's complete bounded
        // window even on large days. Only the returned interaction snippets are
        // compacted below; these transient observations are released when this
        // builder returns.
        let usesCompactContext = ordered.count > 1_024
        let observationTextLimit = 6_000
        let interactionContextLimit = usesCompactContext ? 360 : 1_800
        let semanticDeltaLineLimit = usesCompactContext ? 240 : 500
        let semanticDeltaCountLimit = usesCompactContext ? 4 : 10
        var observations: [SemanticObservation] = []
        observations.reserveCapacity(min(ordered.count, semanticSnapshots.count))
        var linked: [String: [Int]] = [:]
        var lookup = ObservationLookup()
        // An explicit interaction identity is causal evidence, not a generic
        // temporal "before" candidate for the same or another interaction.
        var unlinkedLookup = ObservationLookup()
        // A completed interaction may become the chronological before-state of the
        // next action in the same resource. Keeping this separate preserves the rule
        // above for near-event and same-interaction observations.
        var priorOutcomeLookup = ObservationLookup()
        let continuityBarrierLookup = ContinuityBarrierLookup(continuityBoundaries)
        for (eventIndex, event) in ordered.enumerated() {
            autoreleasepool {
                let resolvedText: String?
                if canUsePrecomputedSemanticTexts {
                    resolvedText = precomputedSemanticTexts?[eventIndex]
                } else {
                    resolvedText = ComputerHistorySupport.semanticText(
                        for: event,
                        semanticSnapshots: semanticSnapshots
                    )
                }
                guard let text = resolvedText else { return }
                let observation = SemanticObservation(
                    event: event,
                    text: ComputerHistorySupport.bounded(
                        text,
                        maximum: observationTextLimit
                    ),
                    interactionID: event.metadata?[ComputerHistoryMetadata.interactionID],
                    phase: event.metadata?[ComputerHistoryMetadata.interactionPhase]
                )
                let index = observations.count
                observations.append(observation)
                lookup.append(observation, at: index)
                if let interactionID = observation.interactionID {
                    linked[interactionID, default: []].append(index)
                    if observation.phase == ComputerHistoryMetadata.Phase.after
                        || observation.phase == ComputerHistoryMetadata.Phase.settled
                    {
                        priorOutcomeLookup.append(observation, at: index)
                    }
                } else {
                    unlinkedLookup.append(observation, at: index)
                }
            }
        }

        var output: [ComputerHistoryInteraction] = []
        output.reserveCapacity(ordered.count)
        for event in ordered {
            guard ComputerHistorySupport.isActionEvent(event) else { continue }
            autoreleasepool {
                let interactionID = event.metadata?[ComputerHistoryMetadata.interactionID] ?? event.id

                // Delayed after/settled callbacks can execute after the foreground app changes.
                // An interaction ID is therefore not sufficient by itself: explicit semantic
                // observations must also belong to the same application as the action.
                let explicit = (linked[interactionID] ?? [])
                    .map { observations[$0] }
                    .filter { ComputerHistorySupport.sameApplication($0.event, event) }
                    .sorted { $0.event.timestamp < $1.event.timestamp }
                let explicitBefore = explicit.last(where: {
                        $0.phase == ComputerHistoryMetadata.Phase.before
                            && $0.event.timestamp <= event.timestamp
                    })
                let before: SemanticObservation?
                if event.kind == .applicationActivated {
                    before = explicitBefore
                        ?? lookup.nearestChronologicalState(
                            before: event,
                            barriers: continuityBarrierLookup,
                            observations: observations
                        )
                } else {
                    before = explicitBefore
                        ?? unlinkedLookup.nearest(before: event, observations: observations)
                        ?? priorOutcomeLookup.nearestPriorOutcome(
                            before: event,
                            excludingInteractionID: interactionID,
                            allowsApplicationTransition: false,
                            barriers: continuityBarrierLookup,
                            observations: observations
                        )
                }
                let settled = explicit.last(where: {
                    $0.phase == ComputerHistoryMetadata.Phase.settled
                        && $0.event.timestamp >= event.timestamp
                })
                let after =
                    settled
                    ?? explicit.last(where: {
                        $0.phase == ComputerHistoryMetadata.Phase.after
                            && $0.event.timestamp >= event.timestamp
                    })
                    ?? lookup.nearest(after: event, observations: observations)

                let beforeText = before?.text
                let afterText = after?.text
                let explicitDelta: [String]
                if let rawDelta = event.metadata?[ComputerHistoryMetadata.semanticDelta] {
                    explicitDelta = ComputerHistorySupport.splitSemanticLines(rawDelta)
                } else {
                    explicitDelta = []
                }
                let delta =
                    explicitDelta.isEmpty
                    ? ComputerHistorySupport.semanticDelta(before: beforeText, after: afterText)
                    : explicitDelta
                let linkedEvents = ComputerHistorySupport.distinctEvents(
                    [event] + [before?.event, after?.event].compactMap { $0 }
                )
                let directResources = eventResourceIDs[event.id] ?? []
                let contextualResources = [before?.event.id, after?.event.id]
                    .compactMap { $0 }
                    .flatMap { eventResourceIDs[$0] ?? [] }
                let resources = ComputerHistorySupport.distinct(
                    directResources + contextualResources
                )
                let confidence: Double
                if beforeText != nil && afterText != nil {
                    confidence = 0.98
                } else if beforeText != nil || afterText != nil {
                    confidence = 0.82
                } else {
                    confidence = 0.66
                }

                output.append(
                    ComputerHistoryInteraction(
                        id: ComputerHistorySupport.stableIdentifier("interaction|\(interactionID)"),
                        start: event.timestamp,
                        end: max(event.timestamp, after?.event.timestamp ?? event.timestamp),
                        action: ComputerHistorySupport.actionKind(for: event),
                        label: ComputerHistorySupport.actionLabel(for: event),
                        application: event.app?.name,
                        bundleIdentifier: event.app?.bundleIdentifier,
                        host: ComputerHistorySupport.normalizedHost(event.url?.host),
                        resourceIDs: resources,
                        beforeContext: beforeText.map {
                            ComputerHistorySupport.bounded(
                                $0,
                                maximum: interactionContextLimit
                            )
                        },
                        afterContext: afterText.map {
                            ComputerHistorySupport.bounded(
                                $0,
                                maximum: interactionContextLimit
                            )
                        },
                        semanticDelta: Array(
                            delta.lazy.map {
                                ComputerHistorySupport.bounded(
                                    $0,
                                    maximum: semanticDeltaLineLimit
                                )
                            }.prefix(semanticDeltaCountLimit)
                        ),
                        confidence: confidence,
                        provenance: ComputerHistorySupport.provenance(for: linkedEvents)
                    )
                )
            }
        }
        output.sort {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
        return output
    }

}
