import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryEvidenceFilteringTests: XCTestCase {
    func testMaintenanceNoiseDoesNotChangeCausalityOrProvenanceButRemainsCounted() throws {
        let start = date("2026-08-23T09:00:00Z")
        let generatedAt = date("2026-08-23T23:00:00Z")
        let safari = application("Safari", bundleID: "com.apple.Safari", processID: 41)
        let goalong = application(
            "Goalong History",
            bundleID: "ai.goalong.history",
            processID: 42
        )
        let interactionID = "save-proposal"
        let before = semanticPayload(
            id: "before-save",
            text: "Proposal draft before save",
            at: start,
            application: safari
        )
        let after = semanticPayload(
            id: "after-save",
            text: "Proposal saved successfully",
            at: start.addingTimeInterval(4),
            application: safari
        )
        let maintenanceContext = semanticPayload(
            id: "agent-maintenance-context",
            text: "Indexed transcript maintenance payload that must not become user evidence",
            at: start.addingTimeInterval(2),
            application: goalong
        )

        let userEvents = [
            event(
                id: "semantic-before",
                sequence: 10,
                at: start,
                kind: .semanticSnapshot,
                application: safari,
                semanticContext: before.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ]
            ),
            event(
                id: "application-switch",
                sequence: 11,
                at: start.addingTimeInterval(1),
                kind: .applicationActivated,
                application: safari
            ),
            event(
                id: "window-change",
                sequence: 12,
                at: start.addingTimeInterval(2),
                kind: .windowChanged,
                application: safari
            ),
            event(
                id: "save-click",
                sequence: 13,
                at: start.addingTimeInterval(3),
                kind: .mouseClick,
                application: safari,
                pointer: PointerSnapshot(
                    button: "left",
                    x: 120,
                    y: 80,
                    clickCount: 1
                ),
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionTrigger: "click",
                ]
            ),
            event(
                id: "semantic-after",
                sequence: 14,
                at: start.addingTimeInterval(4),
                kind: .semanticSnapshot,
                application: safari,
                semanticContext: after.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
        ]

        var maintenanceEvents = [
            event(
                id: "maintenance-permission",
                sequence: 2,
                at: start.addingTimeInterval(0.1),
                kind: .permissionStatus,
                application: goalong
            ),
            event(
                id: "maintenance-health",
                sequence: 3,
                at: start.addingTimeInterval(0.2),
                kind: .recorderHealth,
                application: goalong
            ),
            event(
                id: "maintenance-heartbeat",
                sequence: 4,
                at: start.addingTimeInterval(2.2),
                kind: .heartbeat,
                application: goalong
            ),
            event(
                id: "maintenance-diagnostic",
                sequence: 6,
                at: start.addingTimeInterval(3.8),
                kind: .diagnostic,
                application: goalong,
                semanticContext: maintenanceContext.reference
            ),
        ]
        maintenanceEvents += (0..<200).map { index in
            event(
                id: "maintenance-agent-artifact-\(index)",
                sequence: UInt64(100 + index),
                at: start.addingTimeInterval(0.5 + Double(index) / 100),
                kind: .agentArtifactCaptured,
                application: goalong,
                semanticContext: maintenanceContext.reference,
                message: "Agent source indexed from original storage"
            )
        }

        let baseline = ComputerHistoryEngine.analyze(
            events: userEvents,
            semanticSnapshots: [before.id: before, after.id: after],
            day: start,
            calendar: utcCalendar,
            generatedAt: generatedAt
        )
        let noisy = ComputerHistoryEngine.analyze(
            events: userEvents + maintenanceEvents,
            semanticSnapshots: [
                before.id: before,
                after.id: after,
                maintenanceContext.id: maintenanceContext,
            ],
            day: start,
            calendar: utcCalendar,
            generatedAt: generatedAt
        )

        XCTAssertEqual(noisy.title, baseline.title)
        XCTAssertEqual(noisy.executiveSummary, baseline.executiveSummary)
        XCTAssertEqual(noisy.episodes, baseline.episodes)
        XCTAssertEqual(noisy.resources, baseline.resources)
        XCTAssertEqual(noisy.workflowPatterns, baseline.workflowPatterns)
        XCTAssertEqual(noisy.suggestions, baseline.suggestions)
        XCTAssertEqual(noisy.coverage.sourceEventCount, 209)
        XCTAssertEqual(noisy.coverage.actionEventCount, 3)
        XCTAssertEqual(noisy.coverage.semanticSnapshotCount, 2)
        XCTAssertEqual(noisy.coverage.linkedInteractionCount, 3)
        XCTAssertEqual(noisy.coverage.suppressedEventCount, 0)
        XCTAssertEqual(
            noisy.episodes.flatMap(\.interactions).map(\.action),
            [.applicationSwitch, .windowChange, .click]
        )
        XCTAssertEqual(noisy.coverage.firstSourceSequence, 10)
        XCTAssertEqual(noisy.coverage.lastSourceSequence, 14)

        let provenanceIDs = Set(
            noisy.resources.flatMap(\.provenance.sourceEventIDs)
                + noisy.episodes.flatMap(\.provenance.sourceEventIDs)
                + noisy.episodes.flatMap(\.interactions).flatMap(\.provenance.sourceEventIDs)
        )
        XCTAssertFalse(provenanceIDs.contains { $0.hasPrefix("maintenance-") })
        XCTAssertFalse(noisy.resources.contains { $0.application == "Goalong History" })
        XCTAssertEqual(maintenanceEvents.filter { $0.kind == .agentArtifactCaptured }.count, 200)
    }

    func testSuppressedObservationStillCreatesAnExplicitCoverageGap() {
        let start = date("2026-08-23T10:00:00Z")
        let safari = application("Safari", bundleID: "com.apple.Safari", processID: 41)
        let firstClick = event(
            id: "click-before-gap",
            sequence: 1,
            at: start,
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1)
        )
        let suppressed = event(
            id: "manual-pause-gap",
            sequence: 2,
            at: start.addingTimeInterval(30),
            kind: .captureSuppressed,
            application: safari,
            suppressionReason: .manualPause
        )
        let secondClick = event(
            id: "click-after-gap",
            sequence: 3,
            at: start.addingTimeInterval(60),
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [firstClick, suppressed, secondClick],
            day: start,
            calendar: utcCalendar,
            generatedAt: date("2026-08-23T23:00:00Z")
        )

        XCTAssertEqual(memory.coverage.sourceEventCount, 3)
        XCTAssertEqual(memory.coverage.actionEventCount, 2)
        XCTAssertEqual(memory.coverage.suppressedEventCount, 1)
        XCTAssertEqual(memory.coverage.linkedInteractionCount, 2)
        XCTAssertEqual(memory.episodes.count, 2)
        XCTAssertTrue(memory.executiveSummary.contains("suppressed event"))
    }

    func testAggregatedRecorderDropCreatesAContinuityGapWithoutPayload() {
        let start = date("2026-08-23T10:30:00Z")
        let safari = application("Safari", bundleID: "com.apple.Safari", processID: 41)
        let firstClick = event(
            id: "click-before-drop",
            sequence: 1,
            at: start,
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1)
        )
        let drop = event(
            id: "event-tap-gap",
            sequence: 2,
            at: start.addingTimeInterval(30),
            kind: .recorderHealth,
            application: safari,
            metadata: [
                "observation_gap": "true",
                "dropped_input_callbacks": "17",
                "gap_reasons": "bounded_ingress_overflow",
            ]
        )
        let secondClick = event(
            id: "click-after-drop",
            sequence: 3,
            at: start.addingTimeInterval(60),
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [firstClick, drop, secondClick],
            day: start,
            calendar: utcCalendar,
            generatedAt: date("2026-08-23T23:00:00Z")
        )

        XCTAssertEqual(memory.coverage.sourceEventCount, 3)
        XCTAssertEqual(memory.coverage.actionEventCount, 2)
        XCTAssertEqual(memory.coverage.suppressedEventCount, 1)
        XCTAssertEqual(memory.episodes.count, 2)
        XCTAssertFalse(memory.markdown.contains("bounded_ingress_overflow"))
    }

    func testPointerDragIsNotReportedAsAClick() throws {
        let start = date("2026-08-23T11:00:00Z")
        let safari = application("Safari", bundleID: "com.apple.Safari", processID: 41)
        let drag = event(
            id: "drag-card",
            sequence: 1,
            at: start,
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 420, y: 180, clickCount: 1),
            metadata: [
                "pointer_gesture": "drag",
                "drag_distance": "240",
            ]
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [drag],
            day: start,
            calendar: utcCalendar,
            generatedAt: date("2026-08-23T23:00:00Z")
        )
        let interaction = try XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertEqual(interaction.action, .drag)
        XCTAssertTrue(interaction.label.hasPrefix("Dragged"))
        XCTAssertFalse(interaction.label.hasPrefix("Clicked"))
    }

    func testLateSemanticObservationCannotMasqueradeAsBeforeState() throws {
        let start = date("2026-08-23T12:00:00Z")
        let safari = application("Safari", bundleID: "com.apple.Safari", processID: 41)
        let interactionID = "late-near-event"
        let latePayload = semanticPayload(
            id: "late-context",
            text: "UI state sampled after the click",
            at: start.addingTimeInterval(2),
            application: safari
        )
        let click = event(
            id: "click",
            sequence: 1,
            at: start.addingTimeInterval(1),
            kind: .mouseClick,
            application: safari,
            pointer: PointerSnapshot(button: "left", x: 12, y: 34, clickCount: 1),
            metadata: [ComputerHistoryMetadata.interactionID: interactionID]
        )
        let lateObservation = event(
            id: "late-observation",
            sequence: 2,
            at: start.addingTimeInterval(2),
            kind: .semanticSnapshot,
            application: safari,
            semanticContext: latePayload.reference,
            metadata: [
                ComputerHistoryMetadata.interactionID: interactionID,
                ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
            ]
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [click, lateObservation],
            semanticSnapshots: [latePayload.id: latePayload],
            day: start,
            calendar: utcCalendar,
            generatedAt: date("2026-08-23T23:00:00Z")
        )
        let interaction = try XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertNil(interaction.beforeContext)
        XCTAssertEqual(interaction.afterContext, latePayload.text)
    }

    private func event(
        id: String,
        sequence: UInt64,
        at timestamp: Date,
        kind: EventKind,
        application: AppSnapshot,
        suppressionReason: SuppressionReason? = nil,
        semanticContext: SemanticContextReference? = nil,
        pointer: PointerSnapshot? = nil,
        metadata: [String: String]? = nil,
        message: String? = nil
    ) -> HistoryEvent {
        HistoryEvent(
            schemaVersion: 4,
            id: id,
            sessionID: "computer-history-evidence-filtering",
            timestamp: timestamp,
            kind: kind,
            app: application,
            window: WindowSnapshot(
                title: application.name == "Safari" ? "Proposal — Docs" : "Agent Activity",
                role: "AXWindow",
                subrole: nil
            ),
            element: ElementSnapshot(
                role: "AXButton",
                subrole: nil,
                title: "Save",
                label: "Save",
                identifier: "save",
                isSecure: false
            ),
            url: URLSnapshot(
                value: application.name == "Safari"
                    ? "https://docs.example.com/proposal"
                    : "file:///private/agent/transcript.jsonl",
                host: application.name == "Safari" ? "docs.example.com" : nil,
                redactionApplied: false
            ),
            pointer: pointer,
            semanticContext: semanticContext,
            classification: LocalClassification(
                category: "work",
                isWork: true,
                confidence: 0.9,
                classifierVersion: "test"
            ),
            suppressionReason: suppressionReason,
            message: message,
            metadata: metadata,
            integrity: fixtureIntegrity(sequence)
        )
    }

    private func semanticPayload(
        id: String,
        text: String,
        at timestamp: Date,
        application: AppSnapshot
    ) -> SemanticContextPayload {
        SemanticContextPayload(
            id: id,
            capturedAt: timestamp,
            application: application,
            window: WindowSnapshot(title: "Proposal — Docs", role: "AXWindow", subrole: nil),
            url: URLSnapshot(
                value: "https://docs.example.com/proposal",
                host: "docs.example.com",
                redactionApplied: false
            ),
            focusedRole: "AXButton",
            source: .mixed,
            text: text,
            contentSHA256: SHA256Digest.hashHex(text),
            redacted: false,
            truncated: false
        )
    }

    private func application(
        _ name: String,
        bundleID: String,
        processID: Int32
    ) -> AppSnapshot {
        AppSnapshot(name: name, bundleIdentifier: bundleID, processIdentifier: processID)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
