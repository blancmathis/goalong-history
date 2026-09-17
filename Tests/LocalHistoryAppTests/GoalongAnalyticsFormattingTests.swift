#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class GoalongAnalyticsFormattingTests: XCTestCase {
    func testZeroNeverBecomesOneMinute() {
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(0), "0 min")
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(-0.0), "0 min")
    }
    func testSubMinuteObservationKeepsItsPrecisionBoundary() {
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(0.1), "< 1 min")
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(59.9), "< 1 min")
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(60), DashboardFormatters.duration(seconds: 60))
    }
    func testInvalidMeasurementIsNotPresentedAsObservedTime() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(GoalongAnalyticsFormatting.duration(value), "—")
        }
    }
}
#endif
