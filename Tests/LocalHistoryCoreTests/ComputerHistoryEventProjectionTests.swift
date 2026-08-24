import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryEventProjectionTests: XCTestCase {
    func testProjectionPreservesCompleteComputerHistoryResult() throws {
        let semantic = fixtureSemanticPayload(
            id: "projection-semantic",
            text: "User: verify the compact Computer History projection"
        )
        let commitments = [
            LocalFieldCommitment(
                name: "context",
                commitmentHex: String(repeating: "a", count: 64),
                opening: CommitmentOpening(
                    domain: "event-field:context",
                    fields: ["value": String(repeating: "source-only", count: 64)],
                    saltBase64: Data(repeating: 7, count: 32).base64EncodedString()
                )
            )
        ]
        let before = replacingIntegrity(
            fixtureEvent(
                id: "projection-before",
                sequence: 1,
                offset: 1,
                kind: .semanticSnapshot,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "projection-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                    "computer_history.interaction_trigger": "mouseClick",
                    "analysis.semantic_fingerprint": "unused",
                ],
                semanticContext: semantic.reference
            ),
            commitments: commitments
        )
        let action = replacingIntegrity(
            fixtureEvent(
                id: "projection-action",
                sequence: 2,
                offset: 2,
                kind: .mouseClick,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "projection-interaction",
                    "pointer_gesture": "drag",
                    "drag_distance": "42",
                    "unused_recorder_detail": String(repeating: "discarded", count: 128),
                ],
                pointer: PointerSnapshot(button: "left", x: 20, y: 30, clickCount: 1)
            ),
            commitments: commitments
        )
        let after = replacingIntegrity(
            fixtureEvent(
                id: "projection-after",
                sequence: 3,
                offset: 3,
                kind: .semanticSnapshot,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "projection-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                    "semantic_storage": "separate_encrypted_local_store",
                ],
                semanticContext: semantic.reference
            ),
            commitments: commitments
        )
        let gap = replacingIntegrity(
            fixtureEvent(
                id: "projection-gap",
                sequence: 4,
                offset: 4,
                kind: .permissionStatus,
                metadata: [
                    "accessibility": "false",
                    "input_monitoring": "true",
                    "unused_permission_detail": "discarded",
                ]
            ),
            commitments: commitments
        )
        let maintenance = replacingIntegrity(
            fixtureEvent(
                id: "projection-maintenance",
                sequence: 5,
                offset: 5,
                kind: .agentArtifactCaptured,
                message: String(repeating: "source-index-only", count: 128)
            ),
            commitments: commitments
        )
        let sourceEvents = [before, action, after, gap, maintenance]
        let evidence = sourceEvents.filter(\.isComputerHistoryEvidence)
        let projected = evidence.map(\.compactedForComputerHistoryAnalysis)

        for (full, compact) in zip(evidence, projected) {
            XCTAssertEqual(compact.schemaVersion, full.schemaVersion)
            XCTAssertEqual(compact.id, full.id)
            XCTAssertEqual(compact.timestamp, full.timestamp)
            XCTAssertEqual(compact.kind, full.kind)
            XCTAssertEqual(compact.app, full.app)
            XCTAssertEqual(compact.window, full.window)
            XCTAssertEqual(compact.element, full.element)
            XCTAssertEqual(compact.url, full.url)
            XCTAssertEqual(compact.pointer, full.pointer)
            XCTAssertEqual(compact.keyboard, full.keyboard)
            XCTAssertEqual(compact.scroll, full.scroll)
            XCTAssertEqual(compact.semanticContext, full.semanticContext)
            XCTAssertEqual(compact.suppressionReason, full.suppressionReason)
            XCTAssertEqual(compact.message, full.message)
            XCTAssertEqual(compact.sessionID, "")
            XCTAssertNil(compact.inputOrigin)
            XCTAssertNil(compact.classification)
            XCTAssertEqual(compact.integrity?.sequence, full.integrity?.sequence)
            XCTAssertEqual(compact.integrity?.eventHash, full.integrity?.eventHash)
            XCTAssertEqual(compact.integrity?.previousEventHash, "")
            XCTAssertEqual(compact.integrity?.eventRoot, "")
            XCTAssertEqual(compact.integrity?.fieldCommitments, [])
            XCTAssertEqual(compact.isComputerHistoryEvidence, full.isComputerHistoryEvidence)
            XCTAssertEqual(compact.isObservationContinuityBoundary, full.isObservationContinuityBoundary)
            XCTAssertEqual(
                ComputerHistorySupport.semanticText(
                    for: compact,
                    semanticSnapshots: [semantic.id: semantic]
                ),
                ComputerHistorySupport.semanticText(
                    for: full,
                    semanticSnapshots: [semantic.id: semantic]
                )
            )
        }

        XCTAssertEqual(
            projected[0].metadata,
            [
                ComputerHistoryMetadata.interactionID: "projection-interaction",
                ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
            ]
        )
        XCTAssertEqual(
            projected[1].metadata,
            [
                ComputerHistoryMetadata.interactionID: "projection-interaction",
                "pointer_gesture": "drag",
                "drag_distance": "42",
            ]
        )
        XCTAssertEqual(
            projected[3].metadata,
            [
                "accessibility": "false",
                "input_monitoring": "true",
            ]
        )

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: fixtureStart)
        let generatedAt = fixtureStart.addingTimeInterval(80_000)
        let expected = ComputerHistoryEngine.analyze(
            events: sourceEvents,
            semanticSnapshots: [semantic.id: semantic],
            day: dayStart,
            calendar: calendar,
            generatedAt: generatedAt
        )
        let actual = ComputerHistoryEngine.analyze(
            events: projected,
            semanticSnapshots: [semantic.id: semantic],
            day: dayStart,
            calendar: calendar,
            sourceJournalSummary: ComputerHistorySourceJournalSummary(
                eventCount: sourceEvents.count,
                continuityBoundaryCount: 1,
                firstSourceSequence: 1,
                lastSourceSequence: 5,
                lastSourceEventHash: "hash-5"
            ),
            generatedAt: generatedAt
        )
        XCTAssertEqual(actual, expected)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let fullBytes = try evidence.reduce(0) { try $0 + encoder.encode($1).count }
        let projectedBytes = try projected.reduce(0) { try $0 + encoder.encode($1).count }
        XCTAssertLessThan(projectedBytes * 2, fullBytes)
    }

    func testProjectionPreservesEveryMetadataDrivenComputerHistoryDecision() {
        let metadata: [String: String] = [
            "accessibility": "false",
            "input_monitoring": "false",
            "observation_gap": "true",
            "pointer_gesture": "drag",
            "drag_distance": "123",
            "keystroke_count": "17",
            ComputerHistoryMetadata.interactionID: "interaction",
            ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
            ComputerHistoryMetadata.semanticDelta: "before\nafter",
            "analysis.semantic_text": "legacy semantic text",
            "semantic.text": "legacy fallback",
            "rich_context.text": "legacy rich context",
            "unused": "must disappear",
        ]

        for (index, kind) in EventKind.allCases.enumerated() {
            let event = fixtureEvent(
                id: "projection-kind-\(kind.rawValue)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index),
                kind: kind,
                metadata: metadata,
                keyboard: KeyboardSnapshot(
                    category: "navigation",
                    key: "Return",
                    modifiers: ["command"],
                    isRepeat: true
                ),
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 2),
                scroll: ScrollSnapshot(deltaX: 0, deltaY: -80, eventCount: 4),
                schemaVersion: 3
            )
            let projected = event.compactedForComputerHistoryAnalysis
            XCTAssertEqual(projected.isComputerHistoryEvidence, event.isComputerHistoryEvidence)
            XCTAssertEqual(
                projected.isObservationContinuityBoundary,
                event.isObservationContinuityBoundary
            )
            XCTAssertEqual(
                ComputerHistorySupport.isActionEvent(projected),
                ComputerHistorySupport.isActionEvent(event)
            )
            XCTAssertEqual(
                ComputerHistorySupport.actionKind(for: projected),
                ComputerHistorySupport.actionKind(for: event)
            )
            XCTAssertEqual(
                ComputerHistorySupport.actionLabel(for: projected),
                ComputerHistorySupport.actionLabel(for: event)
            )
            XCTAssertEqual(
                ComputerHistorySupport.semanticText(for: projected, semanticSnapshots: [:]),
                ComputerHistorySupport.semanticText(for: event, semanticSnapshots: [:])
            )
            XCTAssertNil(projected.metadata?["unused"])
        }
    }

    private func replacingIntegrity(
        _ event: HistoryEvent,
        commitments: [LocalFieldCommitment]
    ) -> HistoryEvent {
        let integrity = event.integrity!
        return event.replacingIntegrity(
            EventIntegrity(
                sequence: integrity.sequence,
                previousEventHash: String(repeating: "b", count: 64),
                eventRoot: String(repeating: "c", count: 64),
                eventHash: integrity.eventHash,
                fieldCommitments: commitments
            )
        )
    }
}
