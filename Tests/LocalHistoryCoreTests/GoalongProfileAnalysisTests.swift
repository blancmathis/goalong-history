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
    func testDamagedArchiveThrowsInsteadOfCrashing() throws {
        let (r, result) = try fixture()
        let request = try JSONSerialization.jsonObject(with: r.encoded())
        let response = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        for text in ["{\"request\":1,\"result\":2}", "{\"request\":null,\"result\":null}", "{\"request\":\"a\",\"result\":[]}", "[1]", "3"] {
            XCTAssertThrowsError(try A.parseArchive(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try A.parseArchive(JSONSerialization.data(withJSONObject: ["request": request, "result": 2])))
        XCTAssertThrowsError(try A.parseArchive(JSONSerialization.data(withJSONObject: ["request": NSNull(), "result": response])))
        let archive = try A.parseArchive(JSONSerialization.data(withJSONObject: ["request": request, "result": response]))
        XCTAssertEqual(archive.request, r)
    }
    func testConversationContextIsIndependentFromAIRubricAndLegacyArchivesStillOpen() throws {
        let e = A.Evidence(id: "old", start: "2026-09-07T08:00:00Z", end: "2026-09-07T09:00:00Z", kind: "ai", application: "Agent", text: "Décision antérieure Atlas")
        let policy = A.Policy(replacements: [.init(term: "Atlas", replacement: "Projet secret")])
        let r = try A.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [e], policy: policy, selected: ["projects"], includeConversations: true)
        XCTAssertEqual(try r.context().include_conversations, true)
        XCTAssertEqual(try r.context().evidence.first?.start, e.start)
        XCTAssertTrue(try r.prompt().contains("Projet secret"))
        XCTAssertFalse(try r.prompt().contains("Atlas"))
        XCTAssertThrowsError(try A.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [e], policy: policy, selected: ["ai"]))
        var forged = r
        var changed = try JSONSerialization.jsonObject(with: Data(forged.context_json.utf8)) as! [String: Any]
        changed["include_conversations"] = false
        forged.context_json = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
        XCTAssertThrowsError(try forged.context())
        var legacy = try A.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [e], policy: policy, selected: ["ai"], includeConversations: true)
        legacy.schema = "goalong.profile-analysis.v1"
        var c = try JSONSerialization.jsonObject(with: Data(legacy.context_json.utf8)) as! [String: Any]
        c.removeValue(forKey: "include_conversations")
        legacy.context_json = String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)
        XCTAssertNil(try legacy.context().include_conversations)
        XCTAssertEqual(try A.parseRequest(legacy.encoded()), legacy)
    }
    func testSharedCrossLanguageFixture() throws {
        let (r, result) = try fixture()
        if let path = ProcessInfo.processInfo.environment["GOALONG_PROFILE_FIXTURE"] {
            try GoalongContextualRhythm.encode(A.Archive(request: r, result: result)).write(to: URL(fileURLWithPath: path))
        }
    }

    private func loadRoot(_ events: [HistoryEvent]) throws -> (URL, Date, Date) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-profile-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let day = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        var data = Data()
        for event in events { data.append(try encoder.encode(event)); data.append(10) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        try data.write(to: root.appendingPathComponent("events/\(formatter.string(from: day)).jsonl"))
        return (root, day, day.addingTimeInterval(86_000))
    }
    private func event(_ app: String, bundle: String, host: String? = nil, at day: Date, offset: TimeInterval) -> HistoryEvent {
        HistoryEvent(sessionID: "s", timestamp: day.addingTimeInterval(offset), kind: .applicationActivated,
            app: .init(name: app, bundleIdentifier: bundle, processIdentifier: 0),
            window: .init(title: "\(app) window", role: nil, subrole: nil),
            url: host.map { .init(value: "https://\($0)/page", host: $0, redactionApplied: false) })
    }
    func testLoadOmitsEventsExcludedByGlobalPolicyAndFailsClosedWhenUnreadable() throws {
        let day = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let (root, start, end) = try loadRoot([
            event("Keeper", bundle: "test.keeper", at: day, offset: 60),
            event("Secret", bundle: "test.secret", at: day, offset: 120),
            event("Browser", bundle: "test.browser", host: "private.example", at: day, offset: 180),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try A.load(root: root, start: start, end: end, rich: false).count, 3)
        var policy = GoalongPrivacyPolicy()
        policy.applications = ["test.secret": "Secret"]; policy.domains = ["private.example"]
        try policy.save(in: root)
        let rows = try A.load(root: root, start: start, end: end, rich: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.contains { $0.text.contains("Secret") || $0.text.contains("private.example") })
        try Data("not json".utf8).write(to: GoalongPrivacyPolicy.file(in: root))
        XCTAssertThrowsError(try A.load(root: root, start: start, end: end, rich: false))
    }
    func testLoadReadsNothingWhileGlobalPauseIsOn() throws {
        let day = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let (root, start, end) = try loadRoot([event("Keeper", bundle: "test.keeper", at: day, offset: 60)])
        defer { try? FileManager.default.removeItem(at: root) }
        try GoalongGlobalPause.setPaused(true, in: root)
        XCTAssertThrowsError(try A.load(root: root, start: start, end: end, rich: false))
        try GoalongGlobalPause.setPaused(false, in: root)
        XCTAssertEqual(try A.load(root: root, start: start, end: end, rich: false).count, 1)
    }
}
