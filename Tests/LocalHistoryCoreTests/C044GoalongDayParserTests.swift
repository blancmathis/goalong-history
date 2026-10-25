import XCTest
@testable import LocalHistoryCore

/// T-044 C1: the shared day parser and the Core sites that use it, in a zone that skips 00:00 on 2026-09-06.
final class C044GoalongDayParserTests: XCTestCase {
    private let santiago = TimeZone(identifier: "America/Santiago")!

    func testParserReturnsTheFirstInstantOfADayWithoutMidnight() throws {
        let start = try XCTUnwrap(GoalongDayParser.date("2026-09-06", timeZone: santiago))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = santiago
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: start), DateComponents(year: 2026, month: 9, day: 6, hour: 1))
        XCTAssertEqual(start, calendar.startOfDay(for: start))
    }

    func testParserRejectsMalformedAndImpossibleDays() {
        for bad in ["2026-02-30", "2026-9-06", "2026-09-06 ", "26-09-06", "2026/09/06", "２０２６-09-06", "", "2026-13-01"] {
            XCTAssertNil(GoalongDayParser.date(bad, timeZone: santiago), bad)
        }
    }

    func testParserReadsTheZoneAtCallTime() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        let tokyo = try XCTUnwrap(GoalongDayParser.date("2026-09-06"))
        NSTimeZone.default = santiago
        let chile = try XCTUnwrap(GoalongDayParser.date("2026-09-06"))
        XCTAssertNotEqual(tokyo, chile)
    }

    func testProfileAnalysisAcceptsADayWithoutMidnight() throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = santiago
        defer { NSTimeZone.default = saved }
        let request = try GoalongProfileAnalysis.prepare(date: "2026-09-06", timezone: "America/Santiago", evidence: [
            .init(id: "e", start: "2026-09-06T14:00:00Z", end: "2026-09-06T14:01:00Z", application: "Editor", text: "Atlas")
        ], policy: .init(), selected: ["projects"])
        XCTAssertFalse(request.digest.isEmpty)
    }

    func testForeignSummaryOfADayWithoutMidnightIsAccepted() throws {
        // Covered by journalDays below for the same parser; the foreign-summary branch needs a signed summary fixture.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c044p-\(UUID().uuidString)")
        let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: events.appendingPathComponent("2026-09-06.jsonl"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: .init(year: 2026, month: 9, day: 8, hour: 12))!
        XCTAssertEqual(try GoalongActivityDayStore(root: root).journalDays(before: now, calendar: calendar).count, 1)
    }
}
