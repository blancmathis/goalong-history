import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryEpisodeQualityTests: XCTestCase {
    func testBriefStaleLoginWindowRecoveryDoesNotBecomeUserActivity() {
        let loginWindow = AppSnapshot(
            name: "loginwindow",
            bundleIdentifier: "com.apple.loginwindow",
            processIdentifier: 406
        )
        let hermes = AppSnapshot(
            name: "Hermes",
            bundleIdentifier: "com.nousresearch.hermes",
            processIdentifier: 12_529
        )
        let events = [
            fixtureEvent(
                id: "stale-login-window",
                sequence: 1,
                offset: 0,
                kind: .applicationActivated,
                app: loginWindow,
                windowTitle: "Login",
                host: nil
            ),
            fixtureEvent(
                id: "stale-login-heartbeat",
                sequence: 2,
                offset: 0.1,
                kind: .heartbeat,
                app: loginWindow,
                windowTitle: "Login",
                host: nil,
                metadata: ["idle_seconds": "1033121.7"]
            ),
            fixtureEvent(
                id: "real-foreground-app",
                sequence: 3,
                offset: 1,
                kind: .applicationActivated,
                app: hermes,
                windowTitle: "Hermes",
                host: nil
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.coverage.sourceEventCount, 3)
        XCTAssertEqual(memory.coverage.actionEventCount, 1)
        XCTAssertEqual(memory.episodes.flatMap(\.applications), ["Hermes"])
        XCTAssertEqual(memory.resources.map(\.application), ["Hermes"])
        XCTAssertFalse(memory.markdown.contains("loginwindow"))
    }

    func testSustainedLoginWindowIntervalRemainsExplicitEvidence() {
        let loginWindow = AppSnapshot(
            name: "loginwindow",
            bundleIdentifier: "com.apple.loginwindow",
            processIdentifier: 406
        )
        let finder = fixtureApp("Finder")
        let memory = ComputerHistoryEngine.analyze(
            events: [
                fixtureEvent(
                    id: "real-login-window",
                    sequence: 1,
                    offset: 0,
                    kind: .applicationActivated,
                    app: loginWindow,
                    windowTitle: "Login",
                    host: nil
                ),
                fixtureEvent(
                    id: "later-finder",
                    sequence: 2,
                    offset: 30,
                    kind: .applicationActivated,
                    app: finder,
                    windowTitle: "Finder",
                    host: nil
                ),
            ],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.coverage.actionEventCount, 2)
        XCTAssertTrue(memory.episodes.flatMap(\.applications).contains("loginwindow"))
        XCTAssertTrue(memory.resources.contains { $0.bundleIdentifier == "com.apple.loginwindow" })
    }

    func testDifferentBrowserHostsBecomeSeparateEpisodes() {
        let safari = fixtureApp("Safari")
        let events = [
            fixtureEvent(
                id: "github-task",
                sequence: 1,
                offset: 0,
                kind: .urlChanged,
                app: safari,
                windowTitle: "Fix onboarding · Issue #42",
                host: "github.com"
            ),
            fixtureEvent(
                id: "unrelated-news",
                sequence: 2,
                offset: 180,
                kind: .urlChanged,
                app: safari,
                windowTitle: "Unrelated industry news",
                host: "news.example.com"
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.count, 2)
        XCTAssertEqual(memory.episodes.map(\.sites), [["github.com"], ["news.example.com"]])
        XCTAssertTrue(memory.title.hasPrefix("Computer history — "))
        XCTAssertFalse(memory.title.contains("other work episode"))
        XCTAssertFalse(memory.title.contains("Fix onboarding"))
    }

    func testImmediateCrossSiteNavigationRemainsOneTaskEpisode() {
        let safari = fixtureApp("Safari")
        let events = [
            fixtureEvent(
                id: "issue-link",
                sequence: 1,
                offset: 0,
                kind: .urlChanged,
                app: safari,
                windowTitle: "Fix onboarding · Issue #42",
                host: "github.com"
            ),
            fixtureEvent(
                id: "linked-document",
                sequence: 2,
                offset: 5,
                kind: .urlChanged,
                app: safari,
                windowTitle: "Onboarding specification",
                host: "docs.example.com"
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.count, 1)
        XCTAssertEqual(
            Set(memory.episodes[0].sites),
            Set(["github.com", "docs.example.com"])
        )
        XCTAssertEqual(memory.episodes[0].interactions.count, 2)
    }

    func testLatestVisibleSuccessOverridesAnEarlierTransientFailure() {
        let failedBefore = payload(
            id: "failed-before",
            text: "Deploy production",
            offset: 0
        )
        let failedAfter = payload(
            id: "failed-after",
            text: "Deployment failed with error: temporary timeout",
            offset: 2
        )
        let retryBefore = payload(
            id: "retry-before",
            text: "Retry deployment after temporary timeout",
            offset: 60
        )
        let retryAfter = payload(
            id: "retry-after",
            text: "Deployment completed successfully",
            offset: 62
        )
        let events = interactionEvents(
            interactionID: "first-attempt",
            baseSequence: 1,
            offset: 0,
            before: failedBefore,
            after: failedAfter
        ) + interactionEvents(
            interactionID: "retry-attempt",
            baseSequence: 10,
            offset: 60,
            before: retryBefore,
            after: retryAfter
        )
        let snapshots = [
            failedBefore.id: failedBefore,
            failedAfter.id: failedAfter,
            retryBefore.id: retryBefore,
            retryAfter.id: retryAfter,
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: snapshots,
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.count, 1)
        XCTAssertEqual(memory.episodes.first?.status, .completed)
        XCTAssertTrue(
            memory.episodes.first?.observableOutcomes.contains {
                $0.contains("completed successfully")
            } == true
        )
    }

    func testOldFailureDoesNotLabelLaterContinuedWorkAsBlocked() {
        let failedBefore = payload(id: "old-failure-before", text: "Run export", offset: 0)
        let failedAfter = payload(
            id: "old-failure-after",
            text: "Export failed with a temporary error",
            offset: 2
        )
        var events = interactionEvents(
            interactionID: "old-failure",
            baseSequence: 1,
            offset: 0,
            before: failedBefore,
            after: failedAfter
        )
        for index in 0..<16 {
            events.append(
                fixtureEvent(
                    id: "continued-work-\(index)",
                    sequence: UInt64(10 + index),
                    offset: TimeInterval(30 + index * 5),
                    kind: .mouseClick,
                    app: fixtureApp("Safari"),
                    windowTitle: "Production deployment",
                    host: "dashboard.example.com",
                    metadata: [
                        ComputerHistoryMetadata.interactionID: "continued-work-\(index)"
                    ],
                    pointer: PointerSnapshot(
                        button: "left",
                        x: 100,
                        y: 100,
                        clickCount: 1
                    )
                )
            )
        }

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [
                failedBefore.id: failedBefore,
                failedAfter.id: failedAfter,
            ],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.count, 1)
        XCTAssertEqual(memory.episodes.first?.status, .inProgress)
    }

    func testViewingAnOlderCompletedConversationDoesNotCompleteTheCurrentEpisode() {
        let before = payload(
            id: "conversation-before",
            text: "ChatGPT home",
            offset: 0
        )
        let after = payload(
            id: "conversation-after",
            text: "Previous conversation\nDeployment completed successfully\nOpen profile menu",
            offset: 2
        )
        let interactionID = "open-chatgpt"
        let events = [
            fixtureEvent(
                id: "open-chatgpt-before",
                sequence: 1,
                offset: 0,
                kind: .semanticSnapshot,
                app: fixtureApp("ChatGPT"),
                windowTitle: "ChatGPT",
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ],
                semanticContext: before.reference
            ),
            fixtureEvent(
                id: "open-chatgpt-action",
                sequence: 2,
                offset: 1,
                kind: .applicationActivated,
                app: fixtureApp("ChatGPT"),
                windowTitle: "ChatGPT",
                metadata: [ComputerHistoryMetadata.interactionID: interactionID]
            ),
            fixtureEvent(
                id: "open-chatgpt-after",
                sequence: 3,
                offset: 2,
                kind: .semanticSnapshot,
                app: fixtureApp("ChatGPT"),
                windowTitle: "ChatGPT",
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ],
                semanticContext: after.reference
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [before.id: before, after.id: after],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.count, 1)
        XCTAssertNotEqual(memory.episodes.first?.status, .completed)
        XCTAssertFalse(
            memory.episodes.first?.observableOutcomes.contains {
                $0.localizedCaseInsensitiveContains("completed successfully")
            } == true
        )
    }

    func testTypedCompletionWordsAndWindowTitleDoNotCreateAnOutcome() {
        let before = payload(
            id: "typed-completion-before",
            text: "Write deployment notes",
            offset: 0
        )
        let after = payload(
            id: "typed-completion-after",
            text: "Write deployment notes\nDeployment completed successfully",
            offset: 2
        )
        let interactionID = "typed-completion-claim"
        let events = [
            fixtureEvent(
                id: "typed-completion-before-event",
                sequence: 1,
                offset: 0,
                kind: .semanticSnapshot,
                app: fixtureApp("TextEdit"),
                windowTitle: "Deployment completed successfully",
                host: nil,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ],
                semanticContext: before.reference
            ),
            fixtureEvent(
                id: "typed-completion-action",
                sequence: 2,
                offset: 1,
                kind: .typingBurst,
                app: fixtureApp("TextEdit"),
                windowTitle: "Deployment completed successfully",
                host: nil,
                metadata: [ComputerHistoryMetadata.interactionID: interactionID],
                keyboard: KeyboardSnapshot(
                    category: "text_activity",
                    key: nil,
                    modifiers: [],
                    isRepeat: false
                )
            ),
            fixtureEvent(
                id: "typed-completion-after-event",
                sequence: 3,
                offset: 2,
                kind: .semanticSnapshot,
                app: fixtureApp("TextEdit"),
                windowTitle: "Deployment completed successfully",
                host: nil,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ],
                semanticContext: after.reference
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [before.id: before, after.id: after],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.episodes.first?.status, .inProgress)
        XCTAssertEqual(memory.episodes.first?.observableOutcomes, [])
    }

    func testInternalApplicationURLFallsBackToApplicationResource() {
        let event = fixtureEvent(
            id: "internal-app-url",
            sequence: 1,
            offset: 0,
            kind: .applicationActivated,
            app: fixtureApp("ChatGPT"),
            windowTitle: "ChatGPT",
            host: "-"
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.resources.map(\.kind), [.application])
        XCTAssertEqual(memory.resources.map(\.title), ["ChatGPT"])
        XCTAssertEqual(memory.episodes.first?.sites, [])
        XCTAssertEqual(memory.episodes.first?.title, "Worked in ChatGPT")
    }

    func testLocatorStringsAreNotInterpretedAsUserIntentions() {
        XCTAssertFalse(
            ComputerHistorySupport.looksLikeRequestOrIntention(
                "google.com/search?q=test&oq=test&sourceid=chrome"
            )
        )
        XCTAssertFalse(
            ComputerHistorySupport.looksLikeRequestOrIntention(
                "https://photos.google.com/search/example?photo=123"
            )
        )
        XCTAssertTrue(
            ComputerHistorySupport.looksLikeRequestOrIntention(
                "How should the complete local history be summarized?"
            )
        )
    }

    func testBrowserDecorationsAreRemovedFromResourceAndActionTitles() {
        let event = fixtureEvent(
            id: "decorated-browser-title",
            sequence: 1,
            offset: 0,
            kind: .urlChanged,
            app: fixtureApp("Google Chrome"),
            windowTitle: "Paris - Google Photos – Part of group Backup - High memory usage - 976 MB - Google Chrome – Mathis",
            host: "photos.google.com"
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.resources.first?.title, "Paris - Google Photos")
        XCTAssertEqual(
            memory.episodes.first?.interactions.first?.label,
            "Opened page Paris - Google Photos [High memory usage - 976 MB]"
        )
    }

    func testFileResourceStopsAtItsExtensionInsteadOfAbsorbingFollowingProse() {
        let context = payload(
            id: "path-with-following-prose",
            text: "Read /Users/example/Documents/work/UPLOAD_STATE.md et considère ce fichier comme la vérité courante.",
            offset: 0
        )
        let event = fixtureEvent(
            id: "path-event",
            sequence: 1,
            offset: 0,
            kind: .mouseClick,
            app: fixtureApp("ChatGPT"),
            windowTitle: "ChatGPT",
            metadata: [ComputerHistoryMetadata.interactionID: "path-interaction"],
            semanticContext: context.reference,
            pointer: PointerSnapshot(
                button: "left",
                x: 100,
                y: 100,
                clickCount: 1
            )
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            semanticSnapshots: [context.id: context],
            day: fixtureStart,
            calendar: utcCalendar
        )

        let file = memory.resources.first { $0.kind == .file }
        XCTAssertEqual(file?.title, "UPLOAD_STATE.md")
        XCTAssertEqual(file?.localPath, "/Users/example/Documents/work/UPLOAD_STATE.md")
    }

    func testLocalIntranetHostRemainsAReopenableWebResource() {
        let event = fixtureEvent(
            id: "intranet-url",
            sequence: 1,
            offset: 0,
            kind: .urlChanged,
            app: fixtureApp("Safari"),
            windowTitle: "Build dashboard",
            host: "intranet"
        )

        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(memory.resources.map(\.kind), [.webPage])
        XCTAssertEqual(memory.resources.map(\.host), ["intranet"])
        XCTAssertEqual(memory.episodes.first?.sites, ["intranet"])
    }

    private func interactionEvents(
        interactionID: String,
        baseSequence: UInt64,
        offset: TimeInterval,
        before: SemanticContextPayload,
        after: SemanticContextPayload
    ) -> [HistoryEvent] {
        let metadataBefore = [
            ComputerHistoryMetadata.interactionID: interactionID,
            ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
        ]
        let metadataAction = [
            ComputerHistoryMetadata.interactionID: interactionID,
            ComputerHistoryMetadata.interactionTrigger: "click",
        ]
        let metadataAfter = [
            ComputerHistoryMetadata.interactionID: interactionID,
            ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
        ]
        return [
            fixtureEvent(
                id: "\(interactionID)-before",
                sequence: baseSequence,
                offset: offset,
                kind: .semanticSnapshot,
                app: fixtureApp("Safari"),
                windowTitle: "Production deployment",
                host: "dashboard.example.com",
                metadata: metadataBefore,
                semanticContext: before.reference
            ),
            fixtureEvent(
                id: "\(interactionID)-click",
                sequence: baseSequence + 1,
                offset: offset + 1,
                kind: .mouseClick,
                app: fixtureApp("Safari"),
                windowTitle: "Production deployment",
                host: "dashboard.example.com",
                metadata: metadataAction,
                pointer: PointerSnapshot(
                    button: "left",
                    x: 120,
                    y: 80,
                    clickCount: 1
                )
            ),
            fixtureEvent(
                id: "\(interactionID)-after",
                sequence: baseSequence + 2,
                offset: offset + 2,
                kind: .semanticSnapshot,
                app: fixtureApp("Safari"),
                windowTitle: "Production deployment",
                host: "dashboard.example.com",
                metadata: metadataAfter,
                semanticContext: after.reference
            ),
        ]
    }

    private func payload(
        id: String,
        text: String,
        offset: TimeInterval
    ) -> SemanticContextPayload {
        SemanticContextPayload(
            id: id,
            capturedAt: fixtureStart.addingTimeInterval(offset),
            application: fixtureApp("Safari"),
            window: WindowSnapshot(
                title: "Production deployment",
                role: "AXWindow",
                subrole: nil
            ),
            url: URLSnapshot(
                value: "https://dashboard.example.com/page",
                host: "dashboard.example.com",
                redactionApplied: true
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
}
