#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp
@testable import LocalHistoryQueryCLI

/// T-044 r11 volet C2: midnight, DST night 2026-10-25 (Europe/Paris), daily send, CLI day range.
final class C044R11C2EdgeTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Double = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = paris
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: Int(s)))!
            .addingTimeInterval(s - s.rounded(.down))
    }
    private func withParis<T>(_ body: () throws -> T) rethrows -> T {
        let saved = NSTimeZone.default
        NSTimeZone.default = paris
        defer { NSTimeZone.default = saved }
        return try body()
    }
    private func tmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c044r11c2-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: (4) CLI range of 31 calendar days across the DST change of 2026-10-25

    /// « --start 2026-10-01 --end 2026-10-31 » is 31 calendar days. The cap compares seconds (31 × 86 400),
    /// but the range holds a 25-hour day, so it is 31 days + 1 h and is refused as « more than 31 days ».
    /// Witness: the same 31 days in June pass.
    func testConversationRangeOf31DaysAcrossFallBackIsAccepted() {
        withParis {
            XCTAssertEqual(Calendar.current.timeZone.identifier, "Europe/Paris")
            for (label, start, end) in [("juin", at(2026, 6, 1, 0), at(2026, 7, 2, 0)),
                                        ("octobre", at(2026, 10, 1, 0), at(2026, 11, 1, 0))] {
                var refused: String?
                do {
                    _ = try GoalongConversationEvidence.collect(start: start, end: end) { _, _ in
                        Data(#"{"status":"noConversations","nextCandidateOffset":null,"issues":[],"conversations":[]}"#.utf8)
                    }
                } catch { refused = "\(error)" }
                XCTAssertNil(refused, "\(label): 31 jours civils refusés : \(refused ?? "")")
            }
        }
    }

    /// Same cap in the profile analysis read (`end - start <= 31 × 86 400`).
    func testProfileAnalysisRangeOf31DaysAcrossFallBackIsAccepted() throws {
        let root = try tmp()
        try withParis {
            for (label, start, end) in [("juin", at(2026, 6, 1, 0), at(2026, 7, 2, 0)),
                                        ("octobre", at(2026, 10, 1, 0), at(2026, 11, 1, 0))] {
                do { _ = try GoalongProfileAnalysis.load(root: root, start: start, end: end, rich: false) }
                catch { XCTAssertFalse("\(error)".contains("31 jours"), "\(label): période de 31 jours civils refusée : \(error)") }
            }
        }
    }

    // MARK: (1) event file at midnight

    private func event(_ id: String, _ t: Date) -> HistoryEvent {
        HistoryEvent(id: id, sessionID: "c2", timestamp: t, kind: .mouseClick)
    }

    /// Rollover, two days in two files, DST ambiguous hour (02:30 twice) in one file, reader sees the right day.
    func testMidnightRolloverAndDSTNightEventFiles() throws {
        // The store names files with TimeZone.current, which NSTimeZone.default does not move.
        // CI runs this class again under TZ=Europe/Paris (Timezone regression checks).
        try XCTSkipUnless(TimeZone.current.identifier == "Europe/Paris", "needs a Europe/Paris system zone")
        let root = try tmp(); let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try withParis {
            let store = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false)
            let first = at(2026, 10, 25, 2, 30)                       // CEST
            let second = first.addingTimeInterval(3600)               // 02:30 CET (same wall clock)
            let list = [event("a", at(2026, 10, 24, 23, 59, 59.9)), event("b", at(2026, 10, 25, 0, 0, 0.1)),
                        event("c", first), event("d", second), event("e", at(2026, 10, 25, 23, 59, 59.9)),
                        event("f", at(2026, 10, 26, 0, 0, 0.1))]
            for e in list { XCTAssertNoThrow(try store.appendAndWait(e)) }
            try store.closeAndWait()
            let names = try FileManager.default.contentsOfDirectory(atPath: events.path).filter { $0.hasSuffix(".jsonl") }.sorted()
            XCTAssertEqual(names, ["2026-10-24.jsonl", "2026-10-25.jsonl", "2026-10-26.jsonl"])
            let reader = HistoryLocalStoreReader(rootDirectory: root)
            let day = reader.load(start: at(2026, 10, 25, 0), end: at(2026, 10, 25, 23, 59, 59.5)).events.map(\.id)
            XCTAssertEqual(day, ["b", "c", "d", "e"], "journée du 25 (25 h) mal lue")
        }
    }

    /// Reader during a write: the last line is a half-written fragment. Complete rows stay readable,
    /// and the next append after a restart does not glue to the fragment.
    func testPartialLastLineDoesNotHideCompleteRowsNorCorruptNextAppend() throws {
        let root = try tmp(); let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try withParis {
            let store = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false)
            try store.appendAndWait(event("a", at(2026, 10, 24, 23, 59, 58)))
            try store.closeAndWait()
            let file = events.appendingPathComponent("2026-10-24.jsonl")
            let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
            try h.write(contentsOf: Data(#"{"id":"half","kind":"mouse"#.utf8)); try h.close()
            let reader = HistoryLocalStoreReader(rootDirectory: root)
            XCTAssertEqual(reader.load(start: at(2026, 10, 24, 0), end: at(2026, 10, 25, 0)).events.map(\.id), ["a"])
            let again = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false)
            try again.appendAndWait(event("b", at(2026, 10, 24, 23, 59, 59)))
            try again.closeAndWait()
            XCTAssertEqual(reader.load(start: at(2026, 10, 24, 0), end: at(2026, 10, 25, 0)).events.map(\.id), ["a", "b"])
        }
    }

    // MARK: (2) daily website send around midnight / DST

    @MainActor private func sender(_ sent: @escaping (String) -> Void) throws -> (GoalongWebsiteAutoSender, URL) {
        let suite = "c044r11c2-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = try tmp()
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-credential-only".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let ok = Data(#"{"version":2,"source":"goalong-history","days":[{"date":"2026-09-14","title":"G","summary":"","outcomes":[],"activities":[],"telemetry":{"devices":[{"id":"d","name":"O","screenSeconds":null,"hourly":null,"apps":[{"id":"e","name":"E","seconds":60}]}],"websites":null,"agent":null}}]}"#.utf8)
        let s = GoalongWebsiteAutoSender(defaults: defaults, root: root,
            exporter: { _, day, _ in sent(day); return ok },
            sender: { _, _, _, _ in Data(#"{"imported":1}"#.utf8) },
            sourceConsent: { _ in true }, hiddenWebsites: { { _ in false } }, hiddenApplications: { { _, _ in false } })
        try s.enable(origin: "https://goalong.example", tokenPath: token.path,
                     options: .init(deviceIDs: ["mac"], includeApplications: true, selectedApplicationIDs: ["a"]),
                     hour: 0, minute: 0, timeZoneIdentifier: "Europe/Paris")
        return (s, root)
    }

    /// 00:00 plan: the first tick after midnight sends « yesterday » once; later ticks, a restart-like double tick,
    /// and the DST night add nothing; the next midnight sends the next day; 3 days asleep catch up one day per tick.
    @MainActor func testMidnightPlanSendsEachDayOnceAcrossDSTNight() async throws {
        var days: [String] = []
        let (s, _) = try sender { days.append($0) }
        await s.tick(now: at(2026, 10, 25, 0, 0, 30)); await s.tick(now: at(2026, 10, 25, 0, 1))
        await s.tick(now: at(2026, 10, 25, 2, 30)); await s.tick(now: at(2026, 10, 25, 3, 30))
        await s.tick(now: at(2026, 10, 26, 0, 0, 30)); await s.tick(now: at(2026, 10, 26, 0, 0, 40))
        XCTAssertEqual(days, ["2026-10-24", "2026-10-25"])
        // Mac asleep from 10-26 to 10-29 evening: catches up from the oldest allowed day, one per tick.
        await s.tick(now: at(2026, 10, 29, 20)); await s.tick(now: at(2026, 10, 29, 20, 1)); await s.tick(now: at(2026, 10, 29, 20, 2))
        XCTAssertEqual(Array(days.suffix(3)), ["2026-10-26", "2026-10-27", "2026-10-28"])
    }

    /// 23:59 plan across the spring change (2027-03-28, 02:00 → 03:00) and a 02:30 plan (hour that does not exist).
    @MainActor func testPlanInTheSkippedHourStillSendsOnSpringChangeDay() async throws {
        var days: [String] = []
        let (s, _) = try sender { days.append($0) }
        try s.enable(origin: "https://goalong.example", tokenPath: s.savedConfiguration!.tokenPath,
                     options: s.savedConfiguration!.options, hour: 2, minute: 30, timeZoneIdentifier: "Europe/Paris")
        await s.tick(now: at(2027, 3, 28, 1, 59)); XCTAssertEqual(days, [])
        await s.tick(now: at(2027, 3, 28, 3, 0)); await s.tick(now: at(2027, 3, 28, 3, 30));  XCTAssertEqual(days, ["2027-03-27"], "same day already sent")
        await s.tick(now: at(2027, 3, 29, 3, 0));  XCTAssertEqual(days, ["2027-03-27", "2027-03-28"])
    }
}
#endif
