import Foundation

extension HistoryEvent {
    /// Drops heap-backed source fields that the Computer History causal pipeline
    /// does not consume while leaving the immutable JSONL journal untouched.
    ///
    /// `schemaVersion`, secure-element state and the semantic reference remain
    /// complete because `SemanticContextValidator` uses them before exposing
    /// semantic text. Source identity, ordering and reopenable provenance remain
    /// exact through `id`, `timestamp`, `integrity.sequence` and
    /// `integrity.eventHash`.
    package var compactedForComputerHistoryAnalysis: HistoryEvent {
        HistoryEvent(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: "",
            timestamp: timestamp,
            kind: kind,
            app: app,
            window: window,
            element: element,
            url: url,
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            inputOrigin: nil,
            semanticContext: semanticContext,
            classification: nil,
            suppressionReason: suppressionReason,
            message: message,
            metadata: compactedComputerHistoryMetadata,
            integrity: integrity.map {
                EventIntegrity(
                    sequence: $0.sequence,
                    previousEventHash: "",
                    eventRoot: "",
                    eventHash: $0.eventHash,
                    fieldCommitments: []
                )
            }
        )
    }

    private var compactedComputerHistoryMetadata: [String: String]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        if metadata.keys.allSatisfy(Self.computerHistoryMetadataKeys.contains) {
            return metadata
        }
        let retained = metadata.filter {
            Self.computerHistoryMetadataKeys.contains($0.key)
        }
        return retained.isEmpty ? nil : retained
    }

    /// Kept in sync with the direct metadata reads in the Computer History
    /// builders, continuity classifier and legacy semantic resolver.
    private static let computerHistoryMetadataKeys: Set<String> = [
        "accessibility",
        "input_monitoring",
        "observation_gap",
        "pointer_gesture",
        "drag_distance",
        "keystroke_count",
        ComputerHistoryMetadata.interactionID,
        ComputerHistoryMetadata.interactionPhase,
        ComputerHistoryMetadata.semanticDelta,
        "analysis.semantic_text",
        "semantic.text",
        "rich_context.text",
    ]
}
