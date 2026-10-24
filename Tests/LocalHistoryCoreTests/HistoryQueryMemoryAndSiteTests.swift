import XCTest
@testable import LocalHistoryCore

final class HistoryQueryMemoryAndSiteTests: XCTestCase {
    private func memoryFixture() throws -> (HistoryEvent, ActivityMemory) {
        let event = fixtureEvent(id: "click", sequence: 9, offset: 0, kind: .mouseClick, windowTitle: "Quarterly zebra budget")
        let memory = try DeterministicActivitySummarizer().summarize(ActivitySummaryInput(events: [event]))
        return (event, memory)
    }

    func testSiteQueryMatchesHostIgnoringCaseAndSkipsSuppressedEvents() {
        let visible = fixtureEvent(id: "v", sequence: 1, offset: 0, kind: .applicationActivated, host: "Docs.Example.com")
        let hidden = fixtureEvent(id: "h", sequence: 2, offset: 5, kind: .captureSuppressed, host: "docs.example.com",
                                  suppression: .excludedApplication)
        let other = fixtureEvent(id: "o", sequence: 3, offset: 9, kind: .applicationActivated, host: "other.org")
        let result = HistoryQueryService(events: [visible, hidden, other]).site("DOCS.example")
        XCTAssertEqual(result.hits.map(\.id), ["v"])
        XCTAssertEqual(result.coverage.sourceEventCount, 3)
        XCTAssertEqual(result.queryDescription, "site: DOCS.example")
    }

    func testTextSearchReturnsTheMemoryWhoseTextMatches() throws {
        let (event, memory) = try memoryFixture()
        let service = HistoryQueryService(events: [event], memories: [memory])
        let result = service.textSearch(memory.title)
        XCTAssertTrue(result.hits.contains { $0.kind == .memory && $0.id == memory.id })
        let miss = service.textSearch("nothing-like-this-qxz")
        XCTAssertFalse(miss.hits.contains { $0.kind == .memory })
    }

    func testMemoryHitConfidenceIsTheLowestClaimConfidenceAndKeepsProvenance() throws {
        let (event, memory) = try memoryFixture()
        let hit = try XCTUnwrap(HistoryQueryService(events: [event], memories: [memory]).availableMemories().hits.first)
        XCTAssertEqual(hit.kind, .memory)
        XCTAssertEqual(hit.confidence, memory.claims.map(\.confidence).min() ?? 1)
        XCTAssertEqual(Set(hit.provenance.sourceEventIDs), Set(memory.claims.flatMap { $0.provenance.sourceEventIDs }))
    }

    func testSourcesForUnknownMemoryReturnsNoHitAndSaysSo() throws {
        let (event, memory) = try memoryFixture()
        let result = HistoryQueryService(events: [event], memories: [memory]).sources(forMemoryID: "missing-id")
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.coverage.matchingEventCount, 0)
        XCTAssertTrue(result.limitations.contains("No memory with that identifier was loaded."))
        XCTAssertEqual(result.queryDescription, "sources for memory missing-id")
    }
}

final class GoalongUsageClassificationKeyTests: XCTestCase {
    func testApplicationKeyPrefersBundleIdentifierThenTrimmedName() {
        typealias Rules = GoalongUsageClassificationRules
        XCTAssertEqual(Rules.applicationKey(bundleIdentifier: "com.a.b", name: "Name"), "com.a.b")
        XCTAssertEqual(Rules.applicationKey(bundleIdentifier: "", name: "  Notes \n"), "Notes")
        XCTAssertEqual(Rules.applicationKey(bundleIdentifier: nil, name: "Notes"), "Notes")
    }

    func testApplicationKeyIsNilWhenNothingUsableIsGiven() {
        typealias Rules = GoalongUsageClassificationRules
        XCTAssertNil(Rules.applicationKey(bundleIdentifier: nil, name: nil))
        XCTAssertNil(Rules.applicationKey(bundleIdentifier: "", name: "   "))
        XCTAssertNil(Rules.applicationKey(bundleIdentifier: "  ", name: "Notes"))
    }

    func testIsEmptyTracksBothTables() {
        XCTAssertTrue(GoalongUsageClassificationRules().isEmpty)
        XCTAssertFalse(GoalongUsageClassificationRules(applications: ["a": .work]).isEmpty)
        XCTAssertFalse(GoalongUsageClassificationRules(websites: ["a.com": .other]).isEmpty)
    }
}
