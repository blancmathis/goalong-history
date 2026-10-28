import Foundation
import XCTest
@testable import LocalHistoryCore

/// T-045 H7: day files are named with Gregorian keys, whatever the system calendar.
/// Retention and « Effacer l’historique » compare Gregorian keys (R1-231).
final class T045H7Tests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var value = Calendar(identifier: identifier); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
    }
    private let noon = ISO8601DateFormatter().date(from: "2026-10-28T11:00:00Z")!

    func testSystemSourceDayKeyIsGregorianUnderBuddhistAndJapaneseCalendars() {
        XCTAssertEqual(GoalongSystemSourceFiles.dayKey(noon, calendar: calendar(.buddhist)), "2026-10-28")
        XCTAssertEqual(GoalongSystemSourceFiles.dayKey(noon, calendar: calendar(.japanese)), "2026-10-28")
    }

    func testDeveloperDayFileIsGregorianUnderABuddhistCalendar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongDeveloperStore(root: root)
        let bucket = GoalongFileModificationBucket(projectID: String(repeating: "a", count: 64), start: noon,
                                                   modifiedFiles: 3, estimated: false, lastEventID: 1)
        try store.append([bucket], day: noon, calendar: calendar(.buddhist))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("developer").path)
        XCTAssertEqual(names, ["2026-10-28.jsonl"])
        XCTAssertEqual(store.read(day: noon, calendar: calendar(.buddhist)).fileChanges, 3)
    }
}
