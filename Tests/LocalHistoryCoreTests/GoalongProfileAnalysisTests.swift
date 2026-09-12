import XCTest
@testable import LocalHistoryCore

final class GoalongProfileAnalysisTests: XCTestCase {
    typealias A = GoalongProfileAnalysis
    func fixture() throws -> (A.Request, A.Result) {
        let policy = A.Policy(excluded_terms: ["Discord"], replacements: [.init(term: "Atlas", replacement: "Projet secret")], additional_instructions: "Ne parle pas de Discord ni d’Atlas.")
        let request = try A.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [
            .init(id: "secret-atlas", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Safari", text: "Création Atlas"),
            .init(id: "hidden", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Discord", text: "Message privé"),
            .init(id: "ai", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", kind: "ai", application: "Agent", text: "Question IA privée")
        ], policy: policy, selected: ["projects", "methods"])
        let result = A.Result(request_id: request.request_id, evidence_digest: request.digest, items: ["projects", "methods"].enumerated().map { index, key in
            .init(id: "i\(index)", module: key, title: "Atlas", summary: "Travail sur Atlas", status: "inferred", caveat: "Achèvement inconnu.", evidence_refs: ["e1"])
        })
        return (request, result)
    }
    func testProtectionBeforeAgentAndAfterResponse() throws {
        let (r, result) = try fixture(), prompt = try r.prompt()
        for term in ["Atlas", "Discord", "Message privé", "Question IA privée", "secret-atlas"] { XCTAssertFalse(prompt.contains(term), term) }
        XCTAssertEqual(try r.context().evidence.count, 1)
        var response = result; response.items[0].summary = "Discord et Atlas"
        XCTAssertEqual(try A.apply(response, to: r).items[0].summary, "[masqué] et Projet secret")
    }
    func testUncheckedModulesAndWrongEvidenceRejected() throws {
        let (r, result) = try fixture()
        var changed = result; changed.items[0].module = "ai"; XCTAssertThrowsError(try A.apply(changed, to: r))
        changed = result; changed.items[0].evidence_refs = ["private-id"]; XCTAssertThrowsError(try A.apply(changed, to: r))
        changed = result; changed.items.removeLast(); XCTAssertThrowsError(try A.apply(changed, to: r))
        changed = result; changed.evidence_digest = "stale"; XCTAssertThrowsError(try A.apply(changed, to: r))
    }
    func testProjectionContainsOnlySelectedCards() throws {
        let (r, result) = try fixture(); let archive = A.Archive(request: r, result: result)
        XCTAssertTrue(try A.project(archive, selectedIDs: []).modules.isEmpty)
        let bytes = try A.siteImport(archive, selectedIDs: ["i0"]), text = String(decoding: bytes, as: UTF8.self)
        for field in ["Atlas", "Discord", "evidence_refs", "context_json", "policy", "methods", "request_id"] { XCTAssertFalse(text.contains(field), field) }
        XCTAssertTrue(text.contains("Projet secret"))
    }
    func testUnknownFieldsInsideContextCannotReachAgent() throws {
        var (r, _) = try fixture()
        var context = try JSONSerialization.jsonObject(with: Data(r.context_json.utf8)) as! [String: Any]
        var rows = context["evidence"] as! [[String: Any]]; rows[0]["private_extra"] = "must never reach agent"; context["evidence"] = rows
        r.context_json = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        XCTAssertThrowsError(try r.prompt())
    }
    func testDuplicateKeysAndUnexpectedDurationRejected() throws {
        let (r, result) = try fixture()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        var rows = object["items"] as! [[String: Any]]; rows[0]["seconds"] = 50; object["items"] = rows
        XCTAssertThrowsError(try A.parseResult(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try A.parseResult(Data("{\"items\":[],\"items\":[]}".utf8)))
        XCTAssertEqual(try A.parseRequest(r.encoded()), r)
    }
    func testSharedCrossLanguageFixture() throws {
        let (r, result) = try fixture()
        if let path = ProcessInfo.processInfo.environment["GOALONG_PROFILE_FIXTURE"] {
            try GoalongContextualRhythm.encode(A.Archive(request: r, result: result)).write(to: URL(fileURLWithPath: path))
        }
    }
}
