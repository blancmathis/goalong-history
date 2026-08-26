import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryInteractionIsolationTests: XCTestCase {
    func testLinkedNonBeforePhasesNeverBecomeGenericBeforeFallback() {
        let start = makeDate("2026-08-21T08:00:00Z")
        let safari = AppSnapshot(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 41
        )
        let phases = [
            ComputerHistoryMetadata.Phase.nearEvent,
            ComputerHistoryMetadata.Phase.after,
            ComputerHistoryMetadata.Phase.settled,
        ]

        for (index, phase) in phases.enumerated() {
            let interactionID = "antedated-\(phase)"
            let antedated = payload(
                id: "antedated-\(phase)-payload",
                text: "This \(phase) state existed before the click",
                at: start,
                app: safari,
                URL: "https://docs.example.com/proposal"
            )
            let events = [
                event(
                    id: "antedated-\(phase)-event",
                    sequence: UInt64(index * 2 + 1),
                    at: start,
                    kind: .semanticSnapshot,
                    app: safari,
                    title: "Proposal",
                    URL: "https://docs.example.com/proposal",
                    semanticContext: antedated.reference,
                    metadata: [
                        ComputerHistoryMetadata.interactionID: interactionID,
                        ComputerHistoryMetadata.interactionPhase: phase,
                    ]
                ),
                event(
                    id: "action-\(phase)-event",
                    sequence: UInt64(index * 2 + 2),
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
                    metadata: [ComputerHistoryMetadata.interactionID: interactionID]
                ),
            ]

            let memory = ComputerHistoryEngine.analyze(
                events: events,
                semanticSnapshots: [antedated.id: antedated],
                day: start,
                calendar: utcCalendar
            )

            let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
            XCTAssertNil(interaction.beforeContext, "phase \(phase)")
            XCTAssertNil(interaction.afterContext, "phase \(phase)")
            XCTAssertFalse(
                interaction.provenance.sourceEventIDs.contains("antedated-\(phase)-event"),
                "phase \(phase)"
            )
        }
    }

    func testUnlinkedObservationRemainsAvailableAsGenericBeforeFallback() {
        let start = makeDate("2026-08-21T08:30:00Z")
        let safari = AppSnapshot(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 41
        )
        let before = payload(
            id: "unlinked-before-payload",
            text: "Generic context before the click",
            at: start,
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let events = [
            event(
                id: "unlinked-before-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: before.reference
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
                metadata: [ComputerHistoryMetadata.interactionID: "click-without-linked-before"]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [before.id: before],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertEqual(interaction.beforeContext, before.text)
    }

    func testPriorSettledOutcomeBecomesTheNextInteractionBeforeState() {
        let start = makeDate("2026-08-21T08:45:00Z")
        let safari = AppSnapshot(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 41
        )
        let priorSettled = payload(
            id: "prior-settled-payload",
            text: "Proposal draft saved and ready for review",
            at: start.addingTimeInterval(1),
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let nextSettled = payload(
            id: "next-settled-payload",
            text: "Proposal review submitted successfully",
            at: start.addingTimeInterval(3),
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let events = [
            event(
                id: "prior-action-event",
                sequence: 1,
                at: start,
                kind: .mouseClick,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                pointer: PointerSnapshot(button: "left", x: 100, y: 80, clickCount: 1),
                metadata: [ComputerHistoryMetadata.interactionID: "prior-interaction"]
            ),
            event(
                id: "prior-settled-event",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: priorSettled.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "prior-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
            event(
                id: "next-action-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .mouseClick,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                pointer: PointerSnapshot(button: "left", x: 120, y: 80, clickCount: 1),
                metadata: [ComputerHistoryMetadata.interactionID: "next-interaction"]
            ),
            event(
                id: "next-settled-event",
                sequence: 4,
                at: start.addingTimeInterval(3),
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: nextSettled.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "next-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [
                priorSettled.id: priorSettled,
                nextSettled.id: nextSettled,
            ],
            day: start,
            calendar: utcCalendar
        )

        let interactions = memory.episodes.flatMap(\.interactions)
        let next = try! XCTUnwrap(
            interactions.first { $0.provenance.sourceEventIDs.contains("next-action-event") }
        )
        XCTAssertEqual(next.beforeContext, priorSettled.text)
        XCTAssertEqual(next.afterContext, nextSettled.text)
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 1)
    }

    func testPriorSettledOutcomeDoesNotCrossBrowserHosts() {
        let start = makeDate("2026-08-21T08:50:00Z")
        let safari = AppSnapshot(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 41
        )
        let priorSettled = payload(
            id: "prior-host-payload",
            text: "Private proposal context from the prior site",
            at: start,
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let events = [
            event(
                id: "prior-host-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: priorSettled.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "prior-host-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
            event(
                id: "other-host-action",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .mouseClick,
                app: safari,
                title: "Issue",
                URL: "https://issues.example.net/42",
                pointer: PointerSnapshot(button: "left", x: 120, y: 80, clickCount: 1),
                metadata: [ComputerHistoryMetadata.interactionID: "other-host-interaction"]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [priorSettled.id: priorSettled],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertNil(interaction.beforeContext)
        XCTAssertFalse(interaction.provenance.sourceEventIDs.contains("prior-host-event"))
    }

    func testApplicationSwitchUsesThePriorApplicationOutcomeAsBeforeState() {
        let start = makeDate("2026-08-21T08:55:00Z")
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
        let prior = payload(
            id: "switch-prior-payload",
            text: "Proposal review complete before leaving Safari",
            at: start,
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let after = payload(
            id: "switch-after-payload",
            text: "Notes document visible after switching to TextEdit",
            at: start.addingTimeInterval(2),
            app: textEdit,
            URL: "file:///Users/mathis/Documents/Notes.txt"
        )
        let events = [
            event(
                id: "switch-prior-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: prior.reference
            ),
            event(
                id: "switch-event",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .applicationActivated,
                app: textEdit,
                title: "Notes.txt",
                URL: "file:///Users/mathis/Documents/Notes.txt"
            ),
            event(
                id: "switch-after-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .semanticSnapshot,
                app: textEdit,
                title: "Notes.txt",
                URL: "file:///Users/mathis/Documents/Notes.txt",
                semanticContext: after.reference
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [prior.id: prior, after.id: after],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertEqual(interaction.action, .applicationSwitch)
        XCTAssertEqual(interaction.beforeContext, prior.text)
        XCTAssertEqual(interaction.afterContext, after.text)
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 1)
    }

    func testApplicationSwitchDoesNotCarryContextAcrossAContinuityBoundary() {
        let start = makeDate("2026-08-21T08:57:00Z")
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
        let prior = payload(
            id: "barrier-prior-payload",
            text: "State that must not cross the private browsing boundary",
            at: start,
            app: safari,
            URL: "https://docs.example.com/proposal"
        )
        let after = payload(
            id: "barrier-after-payload",
            text: "TextEdit state after observation resumed",
            at: start.addingTimeInterval(3),
            app: textEdit,
            URL: "file:///Users/mathis/Documents/Notes.txt"
        )
        let events = [
            event(
                id: "barrier-prior-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal",
                URL: "https://docs.example.com/proposal",
                semanticContext: prior.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "prior-click",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
            event(
                id: "private-boundary-event",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .captureSuppressed,
                app: safari,
                title: "Private",
                URL: "about:privatebrowsing",
                suppressionReason: .privateBrowserWindow
            ),
            event(
                id: "post-boundary-switch-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .applicationActivated,
                app: textEdit,
                title: "Notes.txt",
                URL: "file:///Users/mathis/Documents/Notes.txt"
            ),
            event(
                id: "barrier-after-event",
                sequence: 4,
                at: start.addingTimeInterval(3),
                kind: .semanticSnapshot,
                app: textEdit,
                title: "Notes.txt",
                URL: "file:///Users/mathis/Documents/Notes.txt",
                semanticContext: after.reference
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [prior.id: prior, after.id: after],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertNil(interaction.beforeContext)
        XCTAssertEqual(interaction.afterContext, after.text)
        XCTAssertFalse(interaction.provenance.sourceEventIDs.contains("barrier-prior-event"))
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 0)
    }

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
        metadata: [String: String]? = nil,
        suppressionReason: SuppressionReason? = nil
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
            suppressionReason: suppressionReason,
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
