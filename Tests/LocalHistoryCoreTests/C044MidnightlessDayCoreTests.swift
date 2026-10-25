import XCTest
@testable import LocalHistoryCore

/// T-044 C1: America/Santiago skips 00:00 on 2026-09-06 (00:00 → 01:00).
/// A strict `yyyy-MM-dd` DateFormatter returns nil for that day.
final class C044MidnightlessDayCoreTests: XCTestCase {
    func testJournalDaysKeepsADayWithoutMidnight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c044-\(UUID().uuidString)")
        let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for day in ["2026-09-05", "2026-09-06", "2026-09-07"] {
            try Data().write(to: events.appendingPathComponent("\(day).jsonl"))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        let now = calendar.date(from: .init(year: 2026, month: 9, day: 8, hour: 12))!
        let days = try GoalongActivityDayStore(root: root).journalDays(before: now, calendar: calendar)
        XCTAssertEqual(days.map { GoalongActivityDayStore.dayKey($0, calendar: calendar) },
                       ["2026-09-05", "2026-09-06", "2026-09-07"])
    }
}
