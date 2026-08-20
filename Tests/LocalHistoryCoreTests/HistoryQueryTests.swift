import XCTest
@testable import LocalHistoryCore

final class HistoryQueryTests: XCTestCase {
    func testSuppressedHitDoesNotExposeHiddenApplicationWindowOrURL() {
        let malformedSuppressed = fixtureEvent(
            id: "gap",
            sequence: 1,
            offset: 0,
            kind: .captureSuppressed,
            app: fixtureApp("SecretApp"),
            windowTitle: "Secret project",
            host: "secret.example",
            suppression: .excludedApplication,
            message: "Application excluded"
        )
        let result = HistoryQueryService(events: [malformedSuppressed]).gaps()
        let hit = result.hits.first!
        XCTAssertTrue(hit.applications.isEmpty)
        XCTAssertTrue(hit.sites.isEmpty)
        XCTAssertFalse(hit.snippet.contains("Secret"))
        XCTAssertEqual(hit.suppressionReason, SuppressionReason.excludedApplication.rawValue)
    }

    func testSemanticSearchUsesSeparatePayloadAndCarriesProvenance() {
        let payload = fixtureSemanticPayload(text: "Please review project Atlas architecture")
        let event = fixtureEvent(
            id: "semantic",
            sequence: 22,
            offset: 0,
            kind: .semanticSnapshot,
            semanticContext: payload.reference
        )
        let service = HistoryQueryService(
            events: [event],
            semanticSnapshots: [payload.id: payload]
        )
        let result = service.textSearch("atlas")
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.provenance.sourceSequences, [22])
        XCTAssertTrue(result.hits.first?.snippet.contains("Atlas") == true)
    }

    func testActionsAndGapsFiltersAreDistinct() {
        let events = [
            fixtureEvent(id: "click", sequence: 1, offset: 0, kind: .mouseClick),
            fixtureEvent(id: "heartbeat", sequence: 2, offset: 1, kind: .heartbeat),
            fixtureEvent(
                id: "gap",
                sequence: 3,
                offset: 2,
                kind: .captureSuppressed,
                app: nil,
                windowTitle: nil,
                host: nil,
                suppression: .accessibilityUnavailable
            ),
        ]
        let service = HistoryQueryService(events: events)
        XCTAssertEqual(
            service.recent(
                since: fixtureStart.addingTimeInterval(-1),
                until: fixtureStart.addingTimeInterval(10),
                actionsOnly: true
            ).hits.map(\.id),
            ["click"]
        )
        XCTAssertEqual(
            service.recent(
                since: fixtureStart.addingTimeInterval(-1),
                until: fixtureStart.addingTimeInterval(10),
                gapsOnly: true
            ).hits.map(\.id),
            ["gap"]
        )
    }

    func testMemorySourceLookupReturnsClaimEvidence() throws {
        let event = fixtureEvent(id: "click", sequence: 9, offset: 0, kind: .mouseClick)
        let memory = try DeterministicActivitySummarizer().summarize(ActivitySummaryInput(events: [event]))
        let result = HistoryQueryService(events: [event], memories: [memory]).sources(forMemoryID: memory.id)
        XCTAssertEqual(result.hits.map(\.id), ["click"])
        XCTAssertEqual(result.coverage.matchingEventCount, 1)
    }
}
