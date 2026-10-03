import Foundation
import SQLite3
import CryptoKit
import Darwin
import LocalHistoryCore

public struct T3CodeProjectDay: Equatable, Sendable, Identifiable {
    public let project: GoalongDeveloperProject
    public var id: String { project.id }
    public let requests: Int
    public let busyIntervals: [DateInterval]
    public let waitingIntervals: [DateInterval]
    public var busySeconds: TimeInterval { GoalongDeveloperIntervals.unionSeconds(busyIntervals) }
    /// Time between completion and the next request in a thread, capped at two hours.
    /// This is an interval between requests, not proof that the agent expected user input.
    public var waitingSeconds: TimeInterval { GoalongDeveloperIntervals.unionSeconds(waitingIntervals) }
    public var maximumParallelTurns: Int { GoalongDeveloperIntervals.maximumParallel(busyIntervals) }
    public let firstActivity: Date?
    public let lastActivity: Date?
}
public struct T3CodeDay: Equatable, Sendable {
    public let day: Date
    public let status: GoalongDeveloperLaneStatus
    public let projects: [T3CodeProjectDay]
    public let discoveredProjects: [GoalongDeveloperProject]
    public let fingerprint: String
    public let schemaFingerprint: String
    public let rowsRead: Int
}

/// A discovered metadata source, independent of transcript parsers and folder indexing.
/// Uses AI-conversations consent supplied by the caller; never reads message or payload values.
public enum T3CodeMetadataReader {
    /// Longest duration counted for a turn still marked running without an end.
    public static let maximumOpenTurn: TimeInterval = 6 * 3600
    public static func sourceURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".t3/userdata/statev2.sqlite")
    }
    public static func isDiscovered(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = sourceURL(home: home)
        return (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }
    public struct Limits {
        public var maximumRows = 20_000
        public var maximumProjects = 1024
        public var maximumSeconds: TimeInterval = 2
        public init() {}
    }
    public static func fingerprint(at url: URL) -> String {
        let stamps = ["", "-wal", "-shm", "-journal"].map { suffix -> String in
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path + suffix) else { return "absent" }
            return "\(a[.systemFileNumber] ?? 0)|\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return digest(stamps.joined(separator: ";"))
    }
    public static func read(at url: URL = sourceURL(), day: Date, enabled: Bool,
                            now: Date = Date(), calendar: Calendar = .current,
                            limits: Limits = Limits(), shouldContinue: @escaping () -> Bool = { true }) -> T3CodeDay {
        let start = calendar.startOfDay(for: day)
        func empty(_ status: GoalongDeveloperLaneStatus, schema: String = "", rows: Int = 0) -> T3CodeDay {
            .init(day: start, status: status, projects: [], discoveredProjects: [], fingerprint: enabled ? fingerprint(at: url) : "disabled", schemaFingerprint: schema, rowsRead: rows)
        }
        guard enabled else { return empty(.disabled) }
        guard FileManager.default.fileExists(atPath: url.path) else { return empty(.noData) }
        guard let dayInterval = calendar.dateInterval(of: .day, for: start) else { return empty(.failed("Date invalide.")) }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parseDate(_ string: String?) -> Date? { guard let string else { return nil }; return fractional.date(from: string) ?? plain.date(from: string) }
        let initial = fingerprint(at: url)
        do {
            let db = try Connection(url: url, limits: limits, shouldContinue: shouldContinue)
            try db.command("BEGIN")
            defer { try? db.command("ROLLBACK") }
            let columns: [String: Set<String>] = [
                "projection_projects": ["project_id", "title", "workspace_root", "deleted_at"],
                "projection_threads": ["thread_id", "project_id"],
                "projection_turns": ["turn_id", "thread_id", "requested_at", "started_at", "completed_at", "state"],
                "orchestration_v2_projection_threads": ["thread_id", "project_id"],
                "orchestration_v2_projection_runs": ["run_id", "thread_id", "requested_at", "completed_at", "status"],
                "orchestration_v2_projection_provider_turns": ["provider_turn_id", "thread_id", "run_attempt_id", "started_at", "completed_at", "status"],
                "orchestration_v2_projection_run_attempts": ["attempt_id", "run_id"]
            ]
            let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table' LIMIT 512").compactMap { $0.first ?? nil })
            let v1 = tables.contains("projection_turns"), v2 = tables.contains("orchestration_v2_projection_runs")
            guard tables.contains("projection_projects"), v1 || v2 else { return empty(.unsupported) }
            let selectedTables = columns.keys.filter { $0 == "projection_projects" || ($0.hasPrefix("orchestration_v2_") ? v2 : v1) }.sorted()
            var schemaParts: [String] = []
            for table in selectedTables {
                guard tables.contains(table) else { return empty(.unsupported) }
                let actual = Set(try db.rows("PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1] : nil })
                guard columns[table]!.isSubset(of: actual) else { return empty(.unsupported) }
                schemaParts.append(table + ":" + actual.sorted().joined(separator: ","))
            }
            let schema = digest(schemaParts.joined(separator: "|"))
            var projectMap: [String: GoalongDeveloperProject] = [:]
            let projects = try db.rows("SELECT project_id,title,workspace_root FROM projection_projects WHERE deleted_at IS NULL LIMIT \(max(1, min(1024, limits.maximumProjects)) + 1)")
            var partial = projects.count > limits.maximumProjects
            for row in projects.prefix(max(0, limits.maximumProjects)) {
                guard let id = row[0], let root = row[2], root.hasPrefix("/"), root.utf8.count <= 4096 else { partial = true; continue }
                projectMap[id] = GoalongDeveloperProject(root: URL(fileURLWithPath: root), name: row[1])
            }
            struct Request { let id: String; let thread: String; let project: String; let requested: Date; let completed: Date? }
            struct Busy { let request: String; let thread: String; let project: String; let start: Date; let end: Date }
            var requests: [Request] = [], busy: [Busy] = []
            let lower = dateString(dayInterval.start.addingTimeInterval(-7200)), upper = dateString(dayInterval.end.addingTimeInterval(7200))
            func thread(_ raw: String) -> String { raw.hasPrefix("mcp:") ? String(raw.dropFirst(4)) : raw }
            func interval(start: String?, end: String?, status: String?) -> (Date, Date)? {
                guard let s = parseDate(start) else { partial = true; return nil }
                let terminal = parseDate(end)
                let ongoing = ["running", "started", "in_progress", "active"].contains(status ?? "")
                // A turn left « running » by a crash must not fill the day: an open turn counts six hours at most.
                var open = min(now, dayInterval.end)
                if ongoing && terminal == nil && open.timeIntervalSince(s) > maximumOpenTurn { open = s.addingTimeInterval(maximumOpenTurn); partial = true }
                guard let e = terminal ?? (ongoing ? open : nil), e >= s else { partial = true; return nil }
                return (s, e)
            }
            let cap = max(1, min(20_000, limits.maximumRows))
            if v1 {
                let rows = try db.rows("SELECT t.turn_id,t.thread_id,h.project_id,t.requested_at,t.started_at,t.completed_at,t.state FROM projection_turns t JOIN projection_threads h ON h.thread_id=t.thread_id WHERE t.requested_at < ?2 AND (t.completed_at >= ?1 OR t.completed_at IS NULL OR t.requested_at >= ?1) LIMIT \(cap + 1)", binds: [lower, upper])
                if rows.count > cap { partial = true }
                for r in rows.prefix(cap) {
                    guard let id = r[0], let th = r[1], let p = r[2], let requested = parseDate(r[3]) else { partial = true; continue }
                    requests.append(.init(id: id, thread: thread(th), project: p, requested: requested, completed: parseDate(r[5])))
                    if let i = interval(start: r[4], end: r[5], status: r[6]) { busy.append(.init(request: id, thread: thread(th), project: p, start: i.0, end: i.1)) }
                }
            }
            if v2 {
                let rows = try db.rows("SELECT r.run_id,r.thread_id,h.project_id,r.requested_at,r.completed_at,r.status FROM orchestration_v2_projection_runs r JOIN orchestration_v2_projection_threads h ON h.thread_id=r.thread_id WHERE r.requested_at < ?2 AND (r.completed_at >= ?1 OR r.completed_at IS NULL OR r.requested_at >= ?1) LIMIT \(cap + 1)", binds: [lower, upper])
                if rows.count > cap { partial = true }
                let providerRows = try db.rows("SELECT a.run_id,t.thread_id,h.project_id,t.started_at,t.completed_at,t.status FROM orchestration_v2_projection_provider_turns t JOIN orchestration_v2_projection_threads h ON h.thread_id=t.thread_id JOIN orchestration_v2_projection_run_attempts a ON a.attempt_id=t.run_attempt_id WHERE t.started_at < ?2 AND (t.completed_at >= ?1 OR t.completed_at IS NULL) LIMIT \(cap + 1)", binds: [lower, upper])
                if providerRows.count > cap { partial = true }
                var withTurn = Set<String>()
                for r in providerRows.prefix(cap) {
                    guard let id = r[0], let th = r[1], let p = r[2] else { partial = true; continue }
                    withTurn.insert(id)
                    if let i = interval(start: r[3], end: r[4], status: r[5]) { busy.append(.init(request: id, thread: thread(th), project: p, start: i.0, end: i.1)) }
                }
                for r in rows.prefix(cap) {
                    guard let id = r[0], let th = r[1], let p = r[2], let requested = parseDate(r[3]) else { partial = true; continue }
                    requests.append(.init(id: id, thread: thread(th), project: p, requested: requested, completed: parseDate(r[4])))
                    // A run request is not a start timestamp. Missing provider turns cannot prove busy time.
                    if !withTurn.contains(id), r[5] == "running" { partial = true }
                }
            }
            var seenRequests = Set<String>(), seenBusy = Set<String>()
            requests = requests.filter { seenRequests.insert("\($0.thread)|\($0.requested.timeIntervalSince1970)").inserted }
            busy = busy.filter { seenBusy.insert("\($0.thread)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)").inserted }
            let grouped = Dictionary(grouping: requests, by: \.thread)
            var waits: [String: [DateInterval]] = [:]
            for threadRequests in grouped.values {
                let sorted = threadRequests.sorted { $0.requested < $1.requested }
                for (index, request) in sorted.enumerated() {
                    guard let completion = request.completed, completion <= now else { continue }
                    let next = index + 1 < sorted.count ? sorted[index + 1].requested : min(now, dayInterval.end)
                    let end = min(next, completion.addingTimeInterval(7200), now)
                    if end > completion, let clipped = GoalongDeveloperIntervals.clipped(.init(start: completion, end: end), to: dayInterval) { waits[request.project, default: []].append(clipped) }
                }
            }
            var results: [T3CodeProjectDay] = []
            // Canonical roots merge multiple T3 project entries and linked worktrees.
            for group in Dictionary(grouping: projectMap, by: { $0.value.id }).values {
                guard let project = GoalongDeveloperProject.combining(group.map(\.value)) else { continue }
                let ids = Set(group.map(\.key))
                let req = requests.filter { ids.contains($0.project) && $0.requested >= dayInterval.start && $0.requested < dayInterval.end && $0.requested <= now }
                let intervals = busy.filter { ids.contains($0.project) }.compactMap { GoalongDeveloperIntervals.clipped(.init(start: $0.start, end: $0.end), to: dayInterval) }
                let waiting = ids.flatMap { waits[$0] ?? [] }
                let points = req.map(\.requested) + intervals.flatMap { [$0.start, $0.end] }
                guard !points.isEmpty || !waiting.isEmpty else { continue }
                results.append(.init(project: project, requests: req.count, busyIntervals: intervals, waitingIntervals: waiting, firstActivity: points.min(), lastActivity: points.max()))
            }
            if requests.contains(where: { projectMap[$0.project] == nil }) { partial = true }
            let final = fingerprint(at: url)
            if final != initial { partial = true }
            return .init(day: start, status: partial ? .partial : (results.isEmpty ? .noData : .ready), projects: results.sorted { $0.id < $1.id }, discoveredProjects: Dictionary(grouping: projectMap.values, by: \.id).values.compactMap { GoalongDeveloperProject.combining(Array($0)) }.sorted { $0.id < $1.id }, fingerprint: initial, schemaFingerprint: schema, rowsRead: db.rowsRead)
        } catch ReadError.unsupported { return empty(.unsupported) }
        catch ReadError.limit { return empty(.partial) }
        catch ReadError.sqlite(let code, let stage) { return empty(.failed("T3 SQLite : \(stage) (code \(code)).")) }
        catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) { return empty(.permissionDenied) }
            return empty(.failed("La source T3 n’a pas pu être lue."))
        }
    }
    private static func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func dateString(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    private enum ReadError: Error { case inaccessible, unsupported, limit, sqlite(Int32, String) }
    private final class Connection {
        var db: OpaquePointer?
        var rowsRead = 0
        let deadline: Date
        let shouldContinue: () -> Bool
        let maximumRows: Int
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        init(url: URL, limits: Limits, shouldContinue: @escaping () -> Bool) throws {
            deadline = Date().addingTimeInterval(max(0, min(10, limits.maximumSeconds)))
            self.shouldContinue = shouldContinue
            maximumRows = max(1, min(20_000, limits.maximumRows)) * 3 + 4096
            guard shouldContinue(), Date() < deadline else { throw ReadError.limit }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReadError.inaccessible }
            let wal = url.path + "-wal", shm = url.path + "-shm"
            let hasWAL = (((try? FileManager.default.attributesOfItem(atPath: wal)[.size]) as? NSNumber)?.int64Value ?? 0) > 0
            for suffix in ["-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                let side = try URL(fileURLWithPath: url.path + suffix).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard side.isRegularFile == true, side.isSymbolicLink != true else { throw ReadError.inaccessible }
            }
            // Live WAL needs existing shared memory. Refuse to create any source sidecar.
            guard !hasWAL || FileManager.default.fileExists(atPath: shm) else { throw ReadError.limit }
            let journalSize = ((try? FileManager.default.attributesOfItem(atPath: url.path + "-journal")[.size]) as? NSNumber)?.int64Value ?? 0
            guard journalSize == 0 else { throw ReadError.limit }
            // Foundation deliberately preserves the /var alias on macOS. SQLite's
            // NOFOLLOW flag rejects aliases in parent components, so use POSIX realpath.
            var original = stat()
            guard lstat(url.path, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
                  let resolved = realpath(url.path, nil) else { throw ReadError.inaccessible }
            defer { free(resolved) }
            let canonical = String(cString: resolved)
            var authorized = stat()
            guard lstat(canonical, &authorized) == 0, authorized.st_dev == original.st_dev,
                  authorized.st_ino == original.st_ino else { throw ReadError.limit }
            let uri = URL(fileURLWithPath: canonical).absoluteString + (hasWAL ? "?mode=ro" : "?mode=ro&immutable=1")
            let opened = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
            guard opened == SQLITE_OK, sqlite3_db_readonly(db, "main") == 1 else {
                let code = sqlite3_extended_errcode(db)
                if db != nil { sqlite3_close(db); db = nil }
                throw ReadError.sqlite(code, "ouverture")
            }
            var openedIdentity = stat()
            guard lstat(canonical, &openedIdentity) == 0, openedIdentity.st_dev == original.st_dev,
                  openedIdentity.st_ino == original.st_ino else { sqlite3_close(db); db = nil; throw ReadError.limit }
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16_384)
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16_384)
            sqlite3_busy_timeout(db, 100)
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                let connection = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
                return connection.shouldContinue() && Date() < connection.deadline ? 0 : 1
            }, Unmanaged.passUnretained(self).toOpaque())
            do {
                for sql in ["PRAGMA query_only=ON", "PRAGMA automatic_index=OFF", "PRAGMA temp_store=MEMORY", "PRAGMA mmap_size=0", "PRAGMA cache_size=-2048"] { try command(sql) }
            } catch { sqlite3_progress_handler(db, 0, nil, nil); sqlite3_close(db); db = nil; throw error }
        }
        deinit { if let db { sqlite3_progress_handler(db, 0, nil, nil); sqlite3_close(db) } }
        func command(_ sql: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.sqlite(sqlite3_extended_errcode(db), "préparation") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) == 1 else { throw ReadError.inaccessible }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW { result = sqlite3_step(statement) }
            if result == SQLITE_INTERRUPT || result == SQLITE_BUSY || result == SQLITE_LOCKED { throw ReadError.limit }
            guard result == SQLITE_DONE else { throw ReadError.sqlite(sqlite3_extended_errcode(db), "configuration") }
        }
        func rows(_ sql: String, binds: [String] = []) throws -> [[String?]] {
            guard shouldContinue(), Date() < deadline else { throw ReadError.limit }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unsupported }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) == 1 else { throw ReadError.inaccessible }
            for (index, value) in binds.enumerated() { guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw ReadError.inaccessible } }
            var rows: [[String?]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                if status == SQLITE_INTERRUPT || status == SQLITE_BUSY || status == SQLITE_LOCKED || status == SQLITE_TOOBIG { throw ReadError.limit }
                guard status == SQLITE_ROW else { throw ReadError.sqlite(sqlite3_extended_errcode(db), "lecture") }
                rowsRead += 1
                guard rowsRead <= maximumRows, Date() < deadline, shouldContinue() else { throw ReadError.limit }
                let row = try (0..<sqlite3_column_count(statement)).map { column -> String? in
                    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                    guard sqlite3_column_bytes(statement, column) <= 8192 else { throw ReadError.limit }
                    return sqlite3_column_text(statement, column).map { String(cString: $0) }
                }
                rows.append(row)
            }
        }
    }
}
