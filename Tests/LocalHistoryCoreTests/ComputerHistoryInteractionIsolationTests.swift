import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryInteractionIsolationTests: XCTestCase {
    func testDelayedAfterSnapshotFromAnotherApplicationIsRejected() {
        let start = makeDate("2026-08-21T09:00:00Z")
        let safari = AppSnapshot(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 41
        )
        let textEdit = AppSnapshot(
            name: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 42
        )
        let interactionID = "click-before-fast-app-switch"
        let before = payload(
            id: "before-safari",
            text: "Proposal page before save",
            at: start,
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let wrongAfter = payload(
            id: "after-textedit",
            text: "Unrelated notes from the next application",
            at: start.addingTimeInterval(2),
            app: textEdit,
            URL: "file:///Users/mathis/Documents/Notes.txt"
        )
        let events = [
            event(
                id: "before-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: before.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ]
            ),
            event(
                id: "action-event",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .mouseClick,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
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
                id: "wrong-after-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .semanticSnapshot,
                app: textEdit,
                title: "Notes.txt",
                URL: "file:///Users/mathis/Documents/Notes.txt",
                semanticContext: wrongAfter.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [
                before.id: before,
                wrongAfter.id: wrongAfter,
            ],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertEqual(interaction.application, "Safari")
        XCTAssertTrue(interaction.beforeContext?.contains("before save") == true)
        XCTAssertNil(interaction.afterContext)
        XCTAssertFalse(
            interaction.semanticDelta.contains {
                $0.contains("Unrelated notes")
            }
        )
        XCTAssertFalse(
            interaction.provenance.sourceEventIDs.contains("wrong-after-event")
        )
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 0)
    }

    private func event(
        id: String,
        sequence: UInt64,
        at date: Date,
        kind: EventKind,
        app: AppSnapshot,
        title: String,
        URL rawURL: String,
        semanticContext: SemanticContextReference? = nil,
        pointer: PointerSnapshot? = nil,
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        let parsed = Foundation.URL(string: rawURL)
        return HistoryEvent(
            schemaVersion: 4,
            id: id,
            sessionID: "interaction-isolation-test",
            timestamp: date,
            kind: kind,
            app: app,
            window: WindowSnapshot(
                title: title,
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
                value: rawURL,
                host: parsed?.host,
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
            metadata: metadata,
            integrity: fixtureIntegrity(sequence)
        )
    }

    private func payload(
        id: String,
        text: String,
        at date: Date,
        app: AppSnapshot,
        URL rawURL: String
    ) -> SemanticContextPayload {
        let parsed = Foundation.URL(string: rawURL)
        return SemanticContextPayload(
            id: id,
            capturedAt: date,
            application: app,
            window: WindowSnapshot(
                title: "Context",
                role: "AXWindow",
                subrole: nil
            ),
            url: URLSnapshot(
                value: rawURL,
                host: parsed?.host,
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

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
