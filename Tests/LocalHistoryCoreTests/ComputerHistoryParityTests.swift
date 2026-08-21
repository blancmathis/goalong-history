import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryParityTests: XCTestCase {
    func testPairsBeforeAndAfterContextWithoutLosingTheAction() {
        let start = makeDate("2026-08-20T09:00:00Z")
        let application = app("Safari", "com.apple.Safari")
        let URL = "https://docs.google.com/document/d/proposal/edit"
        let before = semanticPayload(
            id: "before",
            text: "Enterprise proposal draft version one",
            at: start,
            app: application,
            URL: URL
        )
        let after = semanticPayload(
            id: "after",
            text: "Enterprise proposal draft version two\nSaved successfully",
            at: start.addingTimeInterval(2),
            app: application,
            URL: URL
        )
        let interactionID = "edit-proposal"
        let events = [
            event(
                id: "before-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: application,
                title: "Enterprise Proposal — Google Docs",
                URL: URL,
                semanticContext: before.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ]
            ),
            event(
                id: "typing-event",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .typingBurst,
                app: application,
                title: "Enterprise Proposal — Google Docs",
                URL: URL,
                keyboard: KeyboardSnapshot(category: "text_activity", key: nil, modifiers: [], isRepeat: false),
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionTrigger: "typing",
                    "keystroke_count": "24",
                ]
            ),
            event(
                id: "after-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .semanticSnapshot,
                app: application,
                title: "Enterprise Proposal — Google Docs",
                URL: URL,
                semanticContext: after.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [before.id: before, after.id: after],
            day: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.coverage.linkedInteractionCount, 1)
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 1)
        XCTAssertEqual(memory.episodes.count, 1)
        let interaction = try! XCTUnwrap(memory.episodes.first?.interactions.first)
        XCTAssertEqual(interaction.action, .typing)
        XCTAssertTrue(interaction.beforeContext?.contains("version one") == true)
        XCTAssertTrue(interaction.afterContext?.contains("Saved successfully") == true)
        XCTAssertTrue(interaction.semanticDelta.contains { $0.contains("version two") })
        XCTAssertEqual(memory.episodes.first?.status, .completed)
        XCTAssertTrue(memory.markdown.contains("Action sequence"))
    }

    func testResolvesDocumentsConversationsIssuesAndFiles() {
        let start = makeDate("2026-08-20T10:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let finder = app("Finder", "com.apple.finder")
        let events = [
            event(
                id: "doc",
                sequence: 1,
                at: start,
                kind: .urlChanged,
                app: safari,
                title: "Enterprise Proposal — Google Docs",
                URL: "https://docs.google.com/document/d/abc/edit"
            ),
            event(
                id: "conversation",
                sequence: 2,
                at: start.addingTimeInterval(60),
                kind: .urlChanged,
                app: safari,
                title: "launch-plan — Slack",
                URL: "https://workspace.slack.com/archives/C123/p456"
            ),
            event(
                id: "issue",
                sequence: 3,
                at: start.addingTimeInterval(120),
                kind: .urlChanged,
                app: safari,
                title: "Fix onboarding · Issue #42",
                URL: "https://github.com/example/project/issues/42"
            ),
            event(
                id: "file",
                sequence: 4,
                at: start.addingTimeInterval(180),
                kind: .windowChanged,
                app: finder,
                title: "Launch Plan.pdf",
                URL: "file:///Users/mathis/Documents/Launch%20Plan.pdf"
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )
        let kinds = Set(memory.resources.map(\.kind))

        XCTAssertTrue(kinds.contains(.document))
        XCTAssertTrue(kinds.contains(.conversation))
        XCTAssertTrue(kinds.contains(.issue))
        XCTAssertTrue(kinds.contains(.file))
        XCTAssertTrue(memory.resources.contains { $0.localPath == "/Users/mathis/Documents/Launch Plan.pdf" })
    }

    func testNaturalQuestionFindsTheReopenableProposalSource() {
        let start = makeDate("2026-08-20T11:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let memory = ComputerHistoryEngine.analyze(
            events: [
                event(
                    id: "proposal",
                    sequence: 1,
                    at: start,
                    kind: .urlChanged,
                    app: safari,
                    title: "Enterprise Proposal — Google Docs",
                    URL: "https://docs.google.com/document/d/proposal/edit"
                ),
            ],
            day: start,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory])
            .ask("Where can I find the proposal document?", now: start.addingTimeInterval(300))

        XCTAssertFalse(answer.hits.isEmpty)
        XCTAssertEqual(answer.hits.first?.kind, .resource)
        XCTAssertEqual(answer.hits.first?.resource?.kind, .document)
        XCTAssertTrue(answer.answer.contains("docs.google.com/document/d/proposal"))
    }

    func testResumeQuestionUsesTheEpisodeBeforeTheMostRecentBreak() {
        let start = makeDate("2026-08-20T12:00:00Z")
        let textEdit = app("TextEdit", "com.apple.TextEdit")
        let safari = app("Safari", "com.apple.Safari")
        let memory = ComputerHistoryEngine.analyze(
            events: [
                event(
                    id: "proposal-work",
                    sequence: 1,
                    at: start,
                    kind: .typingBurst,
                    app: textEdit,
                    title: "Launch Proposal.md",
                    URL: "file:///Users/mathis/Documents/Launch%20Proposal.md",
                    keyboard: KeyboardSnapshot(category: "text_activity", key: nil, modifiers: [], isRepeat: false)
                ),
                event(
                    id: "after-break",
                    sequence: 2,
                    at: start.addingTimeInterval(25 * 60),
                    kind: .urlChanged,
                    app: safari,
                    title: "News",
                    URL: "https://example.com/news"
                ),
            ],
            day: start,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory])
            .ask("Where was I before my last break?", now: start.addingTimeInterval(30 * 60))

        XCTAssertTrue(answer.answer.contains("Launch Proposal"))
        XCTAssertTrue(answer.hits.first?.title.contains("Launch Proposal") == true)
    }

    func testKeepsCompletedAndBlockedStatusesSeparate() {
        let start = makeDate("2026-08-20T13:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let completed = pairedInteraction(
            start: start,
            interactionID: "deploy",
            app: safari,
            title: "Deploy production",
            URL: "https://dashboard.example.com/deploy",
            beforeText: "Deploy production",
            afterText: "Deployment completed successfully",
            baseSequence: 1
        )
        let blocked = pairedInteraction(
            start: start.addingTimeInterval(30 * 60),
            interactionID: "tests",
            app: safari,
            title: "CI tests",
            URL: "https://github.com/example/project/actions/runs/9",
            beforeText: "Run integration tests",
            afterText: "Tests failed with error: database unavailable",
            baseSequence: 10
        )
        let events = completed.events + blocked.events
        let payloads = completed.payloads.merging(blocked.payloads) { left, _ in left }

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: payloads,
            day: start,
            calendar: utcCalendar
        )
        let statuses = Set(memory.episodes.map(\.status))

        XCTAssertTrue(statuses.contains(.completed))
        XCTAssertTrue(statuses.contains(.blocked))
        let answer = ComputerHistorySearchService(memories: [memory])
            .ask("What is done and what is blocked?", now: start.addingTimeInterval(35 * 60))
        XCTAssertTrue(answer.answer.contains("completed"))
        XCTAssertTrue(answer.answer.contains("blocked"))
    }

    func testRepeatedCausalSequenceProducesAGroundedSkillSuggestion() {
        let firstDay = makeDate("2026-08-19T09:00:00Z")
        let secondDay = makeDate("2026-08-20T09:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let firstEvents = workflowEvents(day: firstDay, app: safari, sequenceBase: 1)
        let firstMemory = ComputerHistoryEngine.analyze(
            events: firstEvents,
            day: firstDay,
            calendar: utcCalendar
        )
        let secondEvents = workflowEvents(day: secondDay, app: safari, sequenceBase: 20)
        let secondMemory = ComputerHistoryEngine.analyze(
            events: secondEvents,
            day: secondDay,
            calendar: utcCalendar,
            priorMemories: [firstMemory]
        )

        XCTAssertEqual(secondMemory.workflowPatterns.first?.occurrenceCount, 2)
        XCTAssertEqual(secondMemory.suggestions.first?.kind, .skill)
        XCTAssertTrue(secondMemory.suggestions.first?.rationale.contains("2 similar workflow occurrences") == true)
        XCTAssertFalse(secondMemory.suggestions.first?.episodeIDs.isEmpty ?? true)
    }

    func testPrivateSuppressedContentNeverAppearsInMemoryOrSearch() {
        let start = makeDate("2026-08-20T15:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let events = [
            event(
                id: "public",
                sequence: 1,
                at: start,
                kind: .urlChanged,
                app: safari,
                title: "Public documentation",
                URL: "https://example.com/docs"
            ),
            event(
                id: "private",
                sequence: 2,
                at: start.addingTimeInterval(30),
                kind: .semanticSnapshot,
                app: safari,
                title: "Private secret",
                URL: "https://secret.example/private",
                suppression: .privateBrowserWindow,
                metadata: [ActivitySemanticMetadata.text: "PRIVATE_TOKEN_SHOULD_NEVER_APPEAR"],
                schemaVersion: 3
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )
        let answer = ComputerHistorySearchService(memories: [memory])
            .ask("PRIVATE_TOKEN_SHOULD_NEVER_APPEAR", now: start.addingTimeInterval(60))

        XCTAssertEqual(memory.coverage.suppressedEventCount, 1)
        XCTAssertFalse(memory.markdown.contains("PRIVATE_TOKEN_SHOULD_NEVER_APPEAR"))
        XCTAssertTrue(answer.hits.isEmpty)
        XCTAssertFalse(answer.answer.contains("PRIVATE_TOKEN_SHOULD_NEVER_APPEAR"))
    }

    func testDoesNotCollapseSeveralActionsInsideOneMinute() {
        let start = makeDate("2026-08-20T16:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let events = (0..<5).map { index in
            event(
                id: "click-\(index)",
                sequence: UInt64(index + 1),
                at: start.addingTimeInterval(TimeInterval(index * 8)),
                kind: .mouseClick,
                app: safari,
                title: "Project dashboard",
                URL: "https://example.com/project",
                pointer: PointerSnapshot(button: "left", x: Double(index * 10), y: 100, clickCount: 1)
            )
        }

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.coverage.linkedInteractionCount, 5)
        XCTAssertEqual(memory.episodes.first?.interactions.count, 5)
        XCTAssertEqual(memory.episodes.first?.provenance.sourceEventIDs.count, 5)
    }

    private struct PairedResult {
        let events: [HistoryEvent]
        let payloads: [String: SemanticContextPayload]
    }

    private func pairedInteraction(
        start: Date,
        interactionID: String,
        app: AppSnapshot,
        title: String,
        URL: String,
        beforeText: String,
        afterText: String,
        baseSequence: UInt64
    ) -> PairedResult {
        let before = semanticPayload(
            id: "\(interactionID)-before",
            text: beforeText,
            at: start,
            app: app,
            URL: URL
        )
        let after = semanticPayload(
            id: "\(interactionID)-after",
            text: afterText,
            at: start.addingTimeInterval(2),
            app: app,
            URL: URL
        )
        return PairedResult(
            events: [
                event(
                    id: "\(interactionID)-before-event",
                    sequence: baseSequence,
                    at: start,
                    kind: .semanticSnapshot,
                    app: app,
                    title: title,
                    URL: URL,
                    semanticContext: before.reference,
                    metadata: [
                        ComputerHistoryMetadata.interactionID: interactionID,
                        ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                    ]
                ),
                event(
                    id: "\(interactionID)-action",
                    sequence: baseSequence + 1,
                    at: start.addingTimeInterval(1),
                    kind: .mouseClick,
                    app: app,
                    title: title,
                    URL: URL,
                    pointer: PointerSnapshot(button: "left", x: 120, y: 80, clickCount: 1),
                    metadata: [ComputerHistoryMetadata.interactionID: interactionID]
                ),
                event(
                    id: "\(interactionID)-after-event",
                    sequence: baseSequence + 2,
                    at: start.addingTimeInterval(2),
                    kind: .semanticSnapshot,
                    app: app,
                    title: title,
                    URL: URL,
                    semanticContext: after.reference,
                    metadata: [
                        ComputerHistoryMetadata.interactionID: interactionID,
                        ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                    ]
                ),
            ],
            payloads: [before.id: before, after.id: after]
        )
    }

    private func workflowEvents(
        day: Date,
        app: AppSnapshot,
        sequenceBase: UInt64
    ) -> [HistoryEvent] {
        let URL = "https://crm.example.com/customer/42"
        return [
            event(
                id: "\(sequenceBase)-open",
                sequence: sequenceBase,
                at: day,
                kind: .urlChanged,
                app: app,
                title: "Customer 42 — CRM",
                URL: URL
            ),
            event(
                id: "\(sequenceBase)-type",
                sequence: sequenceBase + 1,
                at: day.addingTimeInterval(20),
                kind: .typingBurst,
                app: app,
                title: "Customer 42 — CRM",
                URL: URL,
                keyboard: KeyboardSnapshot(category: "text_activity", key: nil, modifiers: [], isRepeat: false)
            ),
            event(
                id: "\(sequenceBase)-save",
                sequence: sequenceBase + 2,
                at: day.addingTimeInterval(40),
                kind: .mouseClick,
                app: app,
                title: "Customer 42 — CRM",
                URL: URL,
                pointer: PointerSnapshot(button: "left", x: 90, y: 60, clickCount: 1)
            ),
        ]
    }

    private func event(
        id: String,
        sequence: UInt64,
        at date: Date,
        kind: EventKind,
        app: AppSnapshot,
        title: String,
        URL rawURL: String,
        suppression: SuppressionReason? = nil,
        semanticContext: SemanticContextReference? = nil,
        keyboard: KeyboardSnapshot? = nil,
        pointer: PointerSnapshot? = nil,
        metadata: [String: String]? = nil,
        schemaVersion: Int = 4
    ) -> HistoryEvent {
        let parsed = Foundation.URL(string: rawURL)
        return HistoryEvent(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: "computer-history-tests",
            timestamp: date,
            kind: kind,
            app: app,
            window: WindowSnapshot(title: title, role: "AXWindow", subrole: nil),
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
            keyboard: keyboard,
            semanticContext: semanticContext,
            classification: LocalClassification(
                category: "work",
                isWork: true,
                confidence: 0.9,
                classifierVersion: "test"
            ),
            suppressionReason: suppression,
            metadata: metadata,
            integrity: fixtureIntegrity(sequence)
        )
    }

    private func semanticPayload(
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
            window: WindowSnapshot(title: "Context", role: "AXWindow", subrole: nil),
            url: URLSnapshot(value: rawURL, host: parsed?.host, redactionApplied: false),
            focusedRole: "AXTextArea",
            source: .mixed,
            text: text,
            contentSHA256: SHA256Digest.hashHex(text),
            redacted: false,
            truncated: false
        )
    }

    private func app(_ name: String, _ bundle: String) -> AppSnapshot {
        AppSnapshot(name: name, bundleIdentifier: bundle, processIdentifier: 42)
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
