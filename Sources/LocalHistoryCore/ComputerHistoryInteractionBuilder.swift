import Foundation

enum ComputerHistoryInteractionBuilder {
    private struct SemanticObservation {
        let event: HistoryEvent
        let text: String
        let interactionID: String?
        let phase: String?
    }

    static func build(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload],
        eventResourceIDs: [String: [String]]
    ) -> [ComputerHistoryInteraction] {
        let ordered = events.sorted(by: ComputerHistorySupport.eventOrder)
        let observations = ordered.compactMap { event -> SemanticObservation? in
            guard let text = ComputerHistorySupport.semanticText(
                for: event,
                semanticSnapshots: semanticSnapshots
            ) else { return nil }
            return SemanticObservation(
                event: event,
                text: ComputerHistorySupport.bounded(text, maximum: 6_000),
                interactionID: event.metadata?[ComputerHistoryMetadata.interactionID],
                phase: event.metadata?[ComputerHistoryMetadata.interactionPhase]
            )
        }
        var linked: [String: [SemanticObservation]] = [:]
        for observation in observations {
            guard let interactionID = observation.interactionID else { continue }
            linked[interactionID, default: []].append(observation)
        }

        var output: [ComputerHistoryInteraction] = []
        for event in ordered where ComputerHistorySupport.isActionEvent(event) {
            let interactionID = event.metadata?[ComputerHistoryMetadata.interactionID] ?? event.id

            // Delayed callbacks can execute after either the foreground application or the
            // active document/page changes. Both identities must remain continuous.
            let explicit = (linked[interactionID] ?? [])
                .filter {
                    ComputerHistorySupport.sameApplication($0.event, event)
                        && ComputerHistorySupport.sameResourceContext(
                            $0.event,
                            event,
                            eventResourceIDs: eventResourceIDs
                        )
                }
                .sorted { $0.event.timestamp < $1.event.timestamp }
            let before = explicit.last(where: {
                $0.phase == ComputerHistoryMetadata.Phase.before
            }) ?? nearest(
                before: event,
                observations: observations,
                eventResourceIDs: eventResourceIDs
            )
            let settled = explicit.last(where: {
                $0.phase == ComputerHistoryMetadata.Phase.settled
            })
            let after = settled
                ?? explicit.last(where: { $0.phase == ComputerHistoryMetadata.Phase.after })
                ?? nearest(
                    after: event,
                    observations: observations,
                    eventResourceIDs: eventResourceIDs
                )

            let beforeText = before?.text
            let afterText = after?.text
            let explicitDelta: [String]
            if let rawDelta = event.metadata?[ComputerHistoryMetadata.semanticDelta] {
                explicitDelta = ComputerHistorySupport.splitSemanticLines(rawDelta)
            } else {
                explicitDelta = []
            }
            let delta = explicitDelta.isEmpty
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
            if beforeText != nil && afterText != nil { confidence = 0.98 }
            else if beforeText != nil || afterText != nil { confidence = 0.82 }
            else { confidence = 0.66 }

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
                        ComputerHistorySupport.bounded($0, maximum: 1_800)
                    },
                    afterContext: afterText.map {
                        ComputerHistorySupport.bounded($0, maximum: 1_800)
                    },
                    semanticDelta: Array(
                        delta.map {
                            ComputerHistorySupport.bounded($0, maximum: 500)
                        }.prefix(10)
                    ),
                    confidence: confidence,
                    provenance: ComputerHistorySupport.provenance(for: linkedEvents)
                )
            )
        }
        return output.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
    }

    private static func nearest(
        before event: HistoryEvent,
        observations: [SemanticObservation],
        eventResourceIDs: [String: [String]]
    ) -> SemanticObservation? {
        observations
            .filter {
                $0.event.timestamp <= event.timestamp
                    && event.timestamp.timeIntervalSince($0.event.timestamp) <= 20
                    && ComputerHistorySupport.sameApplication($0.event, event)
                    && ComputerHistorySupport.sameResourceContext(
                        $0.event,
                        event,
                        eventResourceIDs: eventResourceIDs
                    )
            }
            .max { $0.event.timestamp < $1.event.timestamp }
    }

    private static func nearest(
        after event: HistoryEvent,
        observations: [SemanticObservation],
        eventResourceIDs: [String: [String]]
    ) -> SemanticObservation? {
        observations
            .filter {
                $0.event.timestamp >= event.timestamp
                    && $0.event.timestamp.timeIntervalSince(event.timestamp) <= 20
                    && ComputerHistorySupport.sameApplication($0.event, event)
                    && ComputerHistorySupport.sameResourceContext(
                        $0.event,
                        event,
                        eventResourceIDs: eventResourceIDs
                    )
            }
            .min { $0.event.timestamp < $1.event.timestamp }
    }
}
