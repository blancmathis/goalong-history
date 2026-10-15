#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

@MainActor final class GoalongProfileStudioTests: XCTestCase {
    func populated() throws -> GoalongProfileStudioModel {
        let model = GoalongProfileStudioModel()
        let request = try GoalongProfileAnalysis.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [.init(id: "private-id", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Editor", text: "Atlas")], policy: .init(replacements: [.init(term: "Atlas", replacement: "Secret")]), selected: ["projects"])
        model.request = request
        let output: [String: Any] = ["request_id": request.request_id, "evidence_digest": request.digest, "items": [["id":"i1", "module":"projects", "title":"Atlas", "summary":"Avancée Atlas", "status":"inferred", "caveat":"À confirmer", "evidence_refs":["e1"]]]]
        model.result = try GoalongProfileAnalysis.apply(GoalongProfileAnalysis.parseResult(JSONSerialization.data(withJSONObject: output)), to: request)
        return model
    }
    func testReopeningWithAnotherDayRebuildsOnlyAnIdleStudio() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let a = Date(timeIntervalSince1970: 1_791_000_000), b = a.addingTimeInterval(86_400)
        XCTAssertEqual(GoalongProfileWindow.reopen(shownDay: a, requestedDay: nil, idle: true, calendar: calendar), .front)
        XCTAssertEqual(GoalongProfileWindow.reopen(shownDay: a, requestedDay: a.addingTimeInterval(60), idle: false, calendar: calendar), .front)
        XCTAssertEqual(GoalongProfileWindow.reopen(shownDay: a, requestedDay: b, idle: true, calendar: calendar), .rebuild)
        XCTAssertEqual(GoalongProfileWindow.reopen(shownDay: nil, requestedDay: b, idle: true, calendar: calendar), .rebuild)
        XCTAssertEqual(GoalongProfileWindow.reopen(shownDay: a, requestedDay: b, idle: false, calendar: calendar), .keepWork)
    }
    func testProfileShareSurvivesTheOpeningPaneAndCapturesTheRevisionAtSendTime() {
        var revision = "r1"
        let host = GoalongProfileStudioHost(currentRevision: { revision })
        revision = "r2"
        host.receive(Data("projection".utf8))
        revision = "r3"
        XCTAssertEqual(host.pending, GoalongProfileStudioHost.Share(data: Data("projection".utf8), privacyRevision: "r2"))
    }
    func testOneHostOwnsOneWindowForEveryCaller() {
        let host = GoalongProfileStudioHost()
        XCTAssertTrue(host.window === host.window)
        XCTAssertNil(host.pending)
    }
    func testLocalResultDoesNotImplicitlySelectAnyCardOrAuthorizeSend() throws {
        let model = try populated()
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertFalse(model.reviewed)
        XCTAssertThrowsError(try model.projection())
        model.reviewed = true
        XCTAssertThrowsError(try model.projection())
        model.selectedItems = ["i1"]
        let output = String(decoding: try model.projection(), as: UTF8.self)
        XCTAssertFalse(output.contains("Atlas")); XCTAssertFalse(output.contains("evidence_refs")); XCTAssertTrue(output.contains("Secret"))
    }
    func testCorrectionInvalidatesReviewAndReappliesAliases() throws {
        let model = try populated(); model.selectedItems = ["i1"]; model.reviewed = true
        model.correct("i1", field: "summary", text: "Correction sur Atlas")
        XCTAssertFalse(model.reviewed)
        XCTAssertThrowsError(try model.projection())
        model.reviewed = true
        XCTAssertFalse(String(decoding: try model.projection(), as: UTF8.self).contains("Atlas"))
        XCTAssertEqual(model.result?.items.first?.status, "declared")
    }
    func testImportedConversationCanInformProjectsOnlyWhenItsSourceIsSelected() throws {
        let model = GoalongProfileStudioModel()
        model.evidence = [.init(id: "c1", start: "2026-09-07T08:00:00Z", end: "2026-09-07T09:00:00Z", kind: "ai", application: "Agent", text: "Décision passée")]
        model.selectedEvidence = ["c1"]
        model.prepare(day: Date(), modules: ["projects"], policy: .init(), includeConversations: true)
        XCTAssertEqual(try model.request?.context().modules, ["projects"])
        XCTAssertEqual(try model.request?.context().include_conversations, true)
        model.consent = true
        model.prepare(day: Date(), modules: ["ai"], policy: .init(), includeConversations: false)
        XCTAssertNil(model.request)
        XCTAssertFalse(model.consent)
    }
    func testChangingSelectionRevokesAgentConsentAndDiscardsStaleResult() throws {
        let model = try populated(); model.consent = true; model.selectedItems = ["i1"]; model.reviewed = true
        model.invalidate()
        XCTAssertNil(model.request); XCTAssertNil(model.result); XCTAssertFalse(model.consent); XCTAssertFalse(model.reviewed); XCTAssertTrue(model.selectedItems.isEmpty)
    }
}
#endif
