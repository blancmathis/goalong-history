import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongFocusCalendarMissingMidnightTests: XCTestCase {
    func testDayWithoutMidnightStillHasAValidInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let interval = try XCTUnwrap(GoalongFocusCalendar.dayInterval("2026-09-06", calendar: calendar))
        XCTAssertEqual(interval.duration, 23 * 3600)
        XCTAssertEqual(GoalongFocusCalendar.dayKey(interval.start, calendar: calendar), "2026-09-06")
    }
}
