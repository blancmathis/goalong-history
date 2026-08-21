import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryEpisodeQualityTests: XCTestCase {
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
    }

    func testLatestVisibleSuccessOverridesAnEarlierTransientFailure() {
        let safari = fixtureApp("Safari")
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
