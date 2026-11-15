import XCTest

@testable import LocalHistoryCore

final class LocalDayKeyTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    func testKeyIsGregorianForBuddhistAndJapaneseSystemCalendars() throws {
        let date = Date(timeIntervalSince1970: 1_794_700_000)  // 2026-11-15 in Paris
        let expected = LocalDayKey.string(from: date, timeZone: paris)
        XCTAssertEqual(expected, "2026-11-15")
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = paris
            // The same instant read with a non-Gregorian formatter gives another year: the shared helper must not.
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = paris
            formatter.dateFormat = "yyyy-MM-dd"
            XCTAssertNotEqual(formatter.string(from: date), expected)
            XCTAssertEqual(LocalDayKey.string(from: date, timeZone: paris), expected)
        }
    }

    func testFileNameIntervalIsTheGregorianDayInTheGivenZone() throws {
        let interval = try XCTUnwrap(LocalDayKey.interval(fromFileName: "2026-11-15.jsonl", timeZone: paris))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = paris
        let parts = gregorian.dateComponents([.year, .month, .day, .hour], from: interval.start)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 11, 15, 0])
        XCTAssertEqual(interval.duration, 86_400, accuracy: 0.1)
    }

    func testFileNameIntervalRejectsImpossibleDays() {
        XCTAssertNil(LocalDayKey.interval(fromFileName: "2026-02-30.jsonl", timeZone: paris))
        XCTAssertNil(LocalDayKey.interval(fromFileName: "notes.jsonl", timeZone: paris))
        XCTAssertNil(LocalDayKey.interval(fromFileName: "26-11-15.jsonl", timeZone: paris))
    }
}
