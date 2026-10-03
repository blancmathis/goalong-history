import XCTest
import SQLite3
import LocalHistoryCore
@testable import AgentActivity

final class T3CodeMetadataTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 3))! }
    private func fixture(v2: Bool = true, wal: Bool = false) throws -> (URL, OpaquePointer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-t3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("statev2.sqlite"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK); let opened = try XCTUnwrap(db)
        addTeardownBlock { sqlite3_close(opened); try? FileManager.default.removeItem(at: root) }
        if wal { try sql(opened, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        try sql(opened, """
        CREATE TABLE projection_projects(project_id TEXT,title TEXT,workspace_root TEXT,deleted_at TEXT);
        CREATE TABLE projection_threads(thread_id TEXT,project_id TEXT,title TEXT);
        CREATE TABLE projection_turns(turn_id TEXT,thread_id TEXT,requested_at TEXT,started_at TEXT,completed_at TEXT,state TEXT);
        INSERT INTO projection_projects VALUES('p','Project','\(root.path)',NULL);
        INSERT INTO projection_threads VALUES('one','p','THREAD-TITLE-DO-NOT-READ');
        CREATE TABLE messages(payload_json TEXT);
        INSERT INTO messages VALUES('RAW-MESSAGE-DO-NOT-READ');
        """)
        if v2 { try sql(opened, """
        CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT,project_id TEXT,title TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_runs(run_id TEXT,thread_id TEXT,requested_at TEXT,completed_at TEXT,status TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_provider_turns(provider_turn_id TEXT,thread_id TEXT,run_attempt_id TEXT,started_at TEXT,completed_at TEXT,status TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_run_attempts(attempt_id TEXT,run_id TEXT,payload_json TEXT);
        INSERT INTO orchestration_v2_projection_threads VALUES('mcp:one','p','THREAD-TITLE-DO-NOT-READ','SECRET');
        INSERT INTO orchestration_v2_projection_threads VALUES('two','p','THREAD-TITLE-DO-NOT-READ','SECRET');
        """) }
        return (file, opened)
    }
    private func sql(_ db: OpaquePointer, _ query: String) throws {
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "FixtureSQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    }
    func testBothGenerationsDeduplicateRequestsAndUnionBusyTime() throws {
        let (file, db) = try fixture()
        try sql(db, """
        INSERT INTO projection_turns VALUES('old','one','2026-10-03T01:00:00.000Z','2026-10-03T01:00:00.000Z','2026-10-03T01:20:00.000Z','completed');
        INSERT INTO orchestration_v2_projection_runs VALUES('new','mcp:one','2026-10-03T01:00:00.000Z','2026-10-03T01:20:00.000Z','completed','SECRET');
        INSERT INTO orchestration_v2_projection_runs VALUES('parallel','two','2026-10-03T01:10:00.000Z','2026-10-03T01:30:00.000Z','completed','SECRET');
        INSERT INTO orchestration_v2_projection_run_attempts VALUES('a','new','SECRET'),('b','parallel','SECRET');
        INSERT INTO orchestration_v2_projection_provider_turns VALUES('t','mcp:one','a','2026-10-03T01:00:00.000Z','2026-10-03T01:20:00.000Z','completed','SECRET');
        INSERT INTO orchestration_v2_projection_provider_turns VALUES('u','two','b','2026-10-03T01:10:00.000Z','2026-10-03T01:30:00.000Z','completed','SECRET');
        """)
        let before = try Data(contentsOf: file), directoryBefore = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        let value = T3CodeMetadataReader.read(at: file, day: day, enabled: true, now: day.addingTimeInterval(4 * 3600), calendar: calendar)
        XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.projects.count, 1)
        let project = try XCTUnwrap(value.projects.first)
        XCTAssertEqual(project.requests, 2); XCTAssertEqual(project.busySeconds, 1800); XCTAssertEqual(project.maximumParallelTurns, 2)
        XCTAssertEqual(project.waitingSeconds, 7800)
        XCTAssertEqual(value.schemaFingerprint.count, 64); XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), directoryBefore)
        XCTAssertFalse(String(describing: value).contains("THREAD-TITLE")); XCTAssertFalse(String(describing: value).contains("RAW-MESSAGE")); XCTAssertFalse(String(describing: value).contains("SECRET"))
    }
    func testLegacyOnlyAndCrossMidnightClipping() throws {
        let (file, db) = try fixture(v2: false)
        try sql(db, """
        INSERT INTO projection_turns VALUES('a','one','2026-10-02T23:50:00.000Z','2026-10-02T23:50:00.000Z','2026-10-03T00:10:00.000Z','completed');
        INSERT INTO projection_turns VALUES('b','one','2026-10-03T00:30:00.000Z','2026-10-03T00:30:00.000Z','2026-10-03T00:40:00.000Z','completed');
        """)
        let value = T3CodeMetadataReader.read(at: file, day: day, enabled: true, now: day.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.projects.first?.requests, 1); XCTAssertEqual(value.projects.first?.busySeconds, 1200)
        XCTAssertEqual(value.projects.first?.waitingSeconds, 2400)
    }
    func testLiveWALUsesCommittedRowsWithoutWritingDatabaseOrWAL() throws {
        let (file, db) = try fixture(v2: false, wal: true)
        try sql(db, "INSERT INTO projection_turns VALUES('a','one','2026-10-03T00:01:00.000Z','2026-10-03T00:01:00.000Z','2026-10-03T00:02:00.000Z','completed');")
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let databaseBefore = try Data(contentsOf: file), walBefore = try Data(contentsOf: wal)
        let directoryBefore = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        let value = T3CodeMetadataReader.read(at: file, day: day, enabled: true, now: day.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.projects.first?.requests, 1)
        XCTAssertEqual(try Data(contentsOf: file), databaseBefore); XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), directoryBefore)
    }
    func testUnknownSchemaFailsClosedAndDisabledReaderTouchesNothing() throws {
        let (file, db) = try fixture()
        try sql(db, "ALTER TABLE orchestration_v2_projection_runs RENAME COLUMN requested_at TO future_request;")
        XCTAssertEqual(T3CodeMetadataReader.read(at: file, day: day, enabled: true).status, .unsupported)
        let disabled = T3CodeMetadataReader.read(at: file, day: day, enabled: false)
        XCTAssertEqual(disabled.status, .disabled); XCTAssertEqual(disabled.fingerprint, "disabled"); XCTAssertEqual(disabled.rowsRead, 0)
        XCTAssertEqual(T3CodeMetadataReader.read(at: file, day: day, enabled: true, shouldContinue: { false }).status, .partial)
    }
    func testOversizedMetadataIsPartialWithoutReturningProviderContent() throws {
        let (file, db) = try fixture(v2: false)
        try sql(db, "UPDATE projection_projects SET title='\(String(repeating: "x", count: 32_768))';")
        let result = T3CodeMetadataReader.read(at: file, day: day, enabled: true)
        XCTAssertEqual(result.status, .partial); XCTAssertTrue(result.projects.isEmpty)
    }
    func testRealSourcesAggregateProbe() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_DEVELOPER_REAL_PROBE"] == "1" else { throw XCTSkip("Explicit aggregate-only local probe.") }
        let home = URL(fileURLWithPath: "/Users/mathisblanc")
        let database = T3CodeMetadataReader.sourceURL(home: home)
        for offset in [0, -1] {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            var limits = T3CodeMetadataReader.Limits(); limits.maximumSeconds = 10
            let result = T3CodeMetadataReader.read(at: database, day: date, enabled: true, limits: limits)
            print("T3 aggregate dayOffset=\(offset) status=\(result.status.label) rows=\(result.rowsRead) projects=\(result.projects.count) requests=\(result.projects.reduce(0) { $0 + $1.requests })")
            for project in result.projects { print("T3 project=\(project.id.prefix(12)) requests=\(project.requests) busySeconds=\(Int(project.busySeconds)) waitingSeconds=\(Int(project.waitingSeconds)) maximumParallel=\(project.maximumParallelTurns)") }
            XCTAssertTrue(result.status == .ready || result.status == .partial || result.status == .noData)
            let repo = home.appendingPathComponent("Developer/goalong-data-developer-20261003")
            let git = GoalongGitActivityReader.read(project: .init(root: repo), day: date)
            print("Git aggregate dayOffset=\(offset) project=\(git.project.id.prefix(12)) status=\(git.status.label) commits=\(git.commits.count) otherActions=\(git.actions.count - git.commits.count)")
        }
    }
}
