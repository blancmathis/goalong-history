#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// R-20: every displayed time follows the macOS 12/24 h choice; whole hours read « 8 h ».
final class GoalongUIFormatClockTests: XCTestCase {
    override func tearDown() { GoalongUIFormat.twelveHourOverride = nil; super.tearDown() }

    func testMinuteOfDayFollowsTheClockChoice() {
        GoalongUIFormat.twelveHourOverride = false
        XCTAssertEqual(GoalongUIFormat.time(minuteOfDay: 9 * 60 + 5), "09:05")
        XCTAssertEqual(GoalongUIFormat.time(minuteOfDay: 1_440), "24:00")
        GoalongUIFormat.twelveHourOverride = true
        XCTAssertEqual(GoalongUIFormat.time(minuteOfDay: 9 * 60 + 5), "9:05 AM")
        XCTAssertEqual(GoalongUIFormat.time(minuteOfDay: 14 * 60 + 30), "2:30 PM")
        XCTAssertEqual(GoalongUIFormat.time(minuteOfDay: 0), "12:00 AM")
    }

    func testDateTimeFollowsTheClockChoice() {
        var parts = DateComponents(); parts.year = 2026; parts.month = 10; parts.day = 22; parts.hour = 14; parts.minute = 5
        let date = Calendar.current.date(from: parts)!
        GoalongUIFormat.twelveHourOverride = false
        XCTAssertEqual(GoalongUIFormat.time(date), "14:05")
        GoalongUIFormat.twelveHourOverride = true
        let twelve = GoalongUIFormat.time(date)
        XCTAssertTrue(twelve.hasPrefix("2:05"), twelve)
        XCTAssertFalse(twelve.contains("14"), twelve)
    }

    func testWholeHourHasNoLeadingZero() {
        XCTAssertEqual(GoalongUIFormat.hour(8), "8 h")
        XCTAssertEqual(GoalongUIFormat.hour(16), "16 h")
    }
}
#endif
