import XCTest
@testable import LocalHistoryCore

@testable import LocalHistoryQueryCLI

/// T-045 T1: success path, one bad argument and the exact error text for the commands the matrix marked
/// « à faire » (analysis-evidence, analysis-prompt, analysis-review, analysis-export) or « faible »
/// (version, status, summary, activities, days). CLI usage text is English by contract; the analysis
/// pipeline errors are French and are checked word for word.
final class T045T1CLICommandsTests: XCTestCase {
    private typealias A = GoalongProfileAnalysis
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    // MARK: helpers

    private func makeRoot(events: Bool = false, consent: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-t045t1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        cleanup.append(root)
        if consent {
            try Data(#"{"schemaVersion":1,"policyVersion":1,"capabilities":{"localComputerHistory":{"enabled":true}}}"#.utf8)
                .write(to: root.appendingPathComponent("capability-consent.json"))
        }
        if events {
            let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 31))!
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var lines = Data()
            for (index, app) in [("Safari", "test.Safari"), ("Xcode", "test.Xcode")].enumerated() {
                for step in 0..<3 {
                    let event = HistoryEvent(
                        sessionID: "fixture",
                        timestamp: midnight.addingTimeInterval(Double(36_000 + index * 1_800 + step * 60)),
                        kind: step == 0 ? .applicationActivated : .windowChanged,
                        app: .init(name: app.0, bundleIdentifier: app.1, processIdentifier: 0),
                        window: .init(title: "Zephyrfoo \(app.0) \(step)", role: nil, subrole: nil))
                    lines.append(try encoder.encode(event)); lines.append(10)
                }
            }
            try lines.write(to: root.appendingPathComponent("events/2026-08-31.jsonl"))
        }
        return root
    }

    /// Runs the CLI against `root` and returns what it printed, or the thrown error.
    private func run(_ arguments: [String], root: URL) -> (out: Data, error: Error?) {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var failure: Error?
        do { try GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments) } catch { failure = error }
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        return (pipe.fileHandleForReading.readDataToEndOfFile(), failure)
    }

    private func json(_ arguments: [String], root: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let result = run(arguments, root: root)
        if let error = result.error { XCTFail("\(arguments): \(error)", file: file, line: line) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.out) as? [String: Any], file: file, line: line)
    }

    private func message(_ arguments: [String], root: URL) -> String {
        guard let error = run(arguments, root: root).error else { return "no error" }
        return error is CLIError ? "\(error)" : (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: version

    func testVersionPrintsTheContractEnvelopeAndRefusesArguments() throws {
        let root = try makeRoot()
        let object = try json(["version"], root: root)
        XCTAssertEqual(object["name"] as? String, "goalong")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["cliContractSchemaVersion"] as? Int, GoalongCLIContract.schemaVersion)
        XCTAssertFalse((object["appVersion"] as? String ?? "").isEmpty)
        XCTAssertEqual(try json(["--version"], root: root)["name"] as? String, "goalong")
        XCTAssertEqual(message(["version", "x"], root: root), "version does not accept arguments")
    }

    // MARK: status

    func testStatusReportsConsentsOffOnAnEmptyRootAndRefusesArguments() throws {
        let root = try makeRoot()
        let result = run(["status"], root: root)
        XCTAssertNil(result.error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.out) as? [String: Any])
        XCTAssertEqual(object["rootDirectory"] as? String, root.path)
        XCTAssertFalse(String(decoding: result.out, as: UTF8.self).contains("\"enabled\" : true"))
        XCTAssertEqual(message(["status", "x"], root: root), "status does not accept arguments")
    }

    // MARK: summary

    func testSummaryOfAFilledDayAndOfAnEmptyDayAndBadArguments() throws {
        let root = try makeRoot(events: true)
        let full = try json(["summary", "2026-08-31"], root: root)
        XCTAssertNil(full["error"] as? String)
        XCTAssertNotNil(full["memory"] as? [String: Any])
        let empty = try json(["summary", "2026-08-30"], root: root)
        XCTAssertEqual(empty["error"] as? String, "No events were loaded for that day.")
        XCTAssertEqual(message(["summary", "today", "extra"], root: root), "Use summary [today|yesterday|YYYY-MM-DD]")
        XCTAssertEqual(message(["summary", "not-a-date"], root: root), "Invalid date: not-a-date")
    }

    // MARK: activities

    func testActivitiesListsTheDayPagesItAndRejectsBadArguments() throws {
        let root = try makeRoot(events: true)
        let object = try json(["activities", "2026-08-31"], root: root)
        XCTAssertNotNil(object["activities"] as? [Any])
        XCTAssertEqual(message(["activities", "--limit", "0"], root: root), "activities requires --limit 1...1000 and --offset >= 0")
        XCTAssertEqual(message(["activities", "--limit", "1001"], root: root), "activities requires --limit 1...1000 and --offset >= 0")
        XCTAssertEqual(message(["activities", "--offset", "-1"], root: root), "activities requires --limit 1...1000 and --offset >= 0")
        XCTAssertEqual(message(["activities", "--limit", "abc"], root: root), "Invalid integer: abc")
        XCTAssertEqual(message(["activities", "today", "again"], root: root), "activities accepts one date plus --limit and --offset")
    }

    // MARK: days

    func testDaysListsTheRawEventDaysAndRefusesArguments() throws {
        let root = try makeRoot(events: true)
        let object = try json(["days"], root: root)
        XCTAssertEqual(object["rawEvents"] as? [String], ["2026-08-31"])
        XCTAssertEqual(object["rootDirectory"] as? String, root.path)
        XCTAssertEqual(try json(["days"], root: try makeRoot())["rawEvents"] as? [String], [])
        XCTAssertEqual(message(["days", "x"], root: root), "days does not accept arguments")
    }

    // MARK: analysis-evidence

    func testAnalysisEvidenceExportsTheWindowAndRefusesBadArguments() throws {
        let root = try makeRoot(events: true, consent: true)
        let object = try json(["analysis-evidence", "--start-utc", "2026-08-30T22:00:00Z", "--end-utc", "2026-08-31T22:00:00Z"], root: root)
        XCTAssertNotNil(object["evidence"] as? [Any])
        XCTAssertEqual(object["date"] as? String, "2026-08-31")
        let usage = "analysis-evidence --start-utc ISO-8601Z --end-utc ISO-8601Z [--include-rich-context] [--include-conversations --conversations-from YYYY-MM-DD] [--conversations-only]"
        XCTAssertEqual(message(["analysis-evidence", "--start-utc", "2026-08-31T00:00:00+02:00", "--end-utc", "2026-08-31T22:00:00Z"], root: root), usage)
        XCTAssertEqual(message(["analysis-evidence", "--start-utc", "2026-08-31T00:00:00Z"], root: root), usage)
        XCTAssertEqual(message(["analysis-evidence", "--start-utc", "2026-08-30T22:00:00Z", "--end-utc", "2026-08-31T22:00:00Z", "--conversations-from", "2026-08-31"], root: root),
                       "--conversations-from requires --include-conversations or --conversations-only; rich context requires Computer History.")
    }

    func testAnalysisEvidenceNeedsTheComputerHistoryConsentAndAWindowOf31DaysAtMost() throws {
        let window = ["--start-utc", "2026-08-30T22:00:00Z", "--end-utc", "2026-08-31T22:00:00Z"]
        XCTAssertEqual(message(["analysis-evidence"] + window, root: try makeRoot(events: true)),
                       "Enable the explicitly selected Computer History sources before reading their evidence.")
        XCTAssertEqual(message(["analysis-evidence", "--start-utc", "2026-06-01T00:00:00Z", "--end-utc", "2026-08-31T00:00:00Z"], root: try makeRoot(consent: true)),
                       "Choisissez une période de 31 jours maximum.")
    }

    // MARK: analysis-prompt / review / export

    private struct Prepared { let request: URL; let response: URL; let selected: A.Result }

    private func prepare() throws -> Prepared {
        let policy = A.Policy(excluded_terms: ["Discord"], replacements: [.init(term: "Atlas", replacement: "Projet secret")], additional_instructions: "")
        let request = try A.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [
            .init(id: "x", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Safari", text: "Création Atlas"),
            .init(id: "y", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Discord", text: "Message privé"),
        ], policy: policy, selected: ["projects"])
        let result = A.Result(request_id: request.request_id, evidence_digest: request.digest, items: [
            .init(id: "i0", module: "projects", title: "Atlas", summary: "Travail sur Atlas et Discord", status: "inferred", caveat: "", evidence_refs: ["e1"])
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-t045t1-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanup.append(dir)
        let requestURL = dir.appendingPathComponent("request.json"), responseURL = dir.appendingPathComponent("response.json")
        try request.encoded().write(to: requestURL)
        try JSONEncoder().encode(result).write(to: responseURL)
        return Prepared(request: requestURL, response: responseURL, selected: result)
    }

    func testAnalysisPromptRendersThePrivatePromptWithoutLeakingAndRefusesBadArguments() throws {
        let root = try makeRoot(), files = try prepare()
        let result = run(["analysis-prompt", "--request", files.request.path], root: root)
        XCTAssertNil(result.error)
        let prompt = String(decoding: result.out, as: UTF8.self)
        XCTAssertFalse(prompt.isEmpty)
        for term in ["Discord", "Message privé", "Atlas"] { XCTAssertFalse(prompt.contains(term), term) }
        XCTAssertEqual(message(["analysis-prompt"], root: root), "analysis-prompt --request LOCAL_REQUEST.json [--file RESPONSE.json] [--items i1,i3]")
        XCTAssertEqual(message(["analysis-prompt", "--request", files.request.path, "--file", files.response.path], root: root), "analysis-prompt accepts only --request.")
        XCTAssertEqual(message(["analysis-prompt", "--request", files.request.path, "--items", "i0"], root: root),
                       "analysis-prompt --request LOCAL_REQUEST.json [--file RESPONSE.json] [--items i1,i3]")
        let bad = files.request.deletingLastPathComponent().appendingPathComponent("bad.json")
        try Data(#"{"a":1}"#.utf8).write(to: bad)
        XCTAssertEqual(message(["analysis-prompt", "--request", bad.path], root: root), "Champs inattendus dans le fichier.")
    }

    func testAnalysisReviewRedactsTheResponseAndRefusesAStaleOrMissingResponse() throws {
        let root = try makeRoot(), files = try prepare()
        let result = run(["analysis-review", "--request", files.request.path, "--file", files.response.path], root: root)
        XCTAssertNil(result.error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.out) as? [String: Any])
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["summary"] as? String, "Travail sur Projet secret et [masqué]")
        XCTAssertEqual(message(["analysis-review", "--request", files.request.path], root: root), "--file RESPONSE.json is required.")
        var stale = files.selected; stale.evidence_digest = "stale"
        let staleURL = files.response.deletingLastPathComponent().appendingPathComponent("stale.json")
        try JSONEncoder().encode(stale).write(to: staleURL)
        XCTAssertEqual(message(["analysis-review", "--request", files.request.path, "--file", staleURL.path], root: root),
                       "Cette réponse ne correspond plus à la sélection préparée.")
    }

    func testAnalysisExportKeepsOnlySelectedCardsAndRefusesBadSelections() throws {
        let root = try makeRoot(), files = try prepare()
        let result = run(["analysis-export", "--request", files.request.path, "--file", files.response.path, "--items", "i0"], root: root)
        XCTAssertNil(result.error)
        let text = String(decoding: result.out, as: UTF8.self)
        XCTAssertTrue(text.contains("Projet secret"))
        for field in ["Atlas", "Discord", "evidence_refs", "request_id"] { XCTAssertFalse(text.contains(field), field) }
        let base = ["analysis-export", "--request", files.request.path, "--file", files.response.path]
        XCTAssertEqual(message(base + ["--items", "i0,i0"], root: root), "Duplicate result selections.")
        XCTAssertEqual(message(base + ["--items", "nope"], root: root), "Sélection d’envoi invalide.")
        XCTAssertEqual(message(base, root: root), "Choisissez au moins un résultat à transmettre.")
        XCTAssertEqual(message(["analysis-export", "--items", "i0"], root: root), "analysis-export --request LOCAL_REQUEST.json [--file RESPONSE.json] [--items i1,i3]")
    }
}
