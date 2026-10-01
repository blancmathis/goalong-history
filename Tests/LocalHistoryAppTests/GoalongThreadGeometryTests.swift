#if os(macOS)
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// The thread only draws what was observed: classes keep their place and order, a few
/// seconds never paint minutes, and a nearly empty day still shows where it happened.
final class GoalongThreadGeometryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ kind: GoalongLocalAnalytics.Kind,
                         task: String? = nil) -> GoalongLocalAnalytics.Segment {
        var value = GoalongLocalAnalytics.Segment(start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end),
                                                  kind: kind, application: "App", bundleIdentifier: "fixture.app", host: nil)
        value.task = task
        return value
    }

    func testRunsFollowTheDominantClassOfEachSlot() {
        // One hour in six ten-minute slots: work, work, other, nothing, unclassified, unclassified.
        let segments = [segment(0, 1200, .work), segment(1200, 1800, .other), segment(2400, 3600, .unclassified)]
        let runs = GoalongThreadGeometry.runs(segments, from: origin, to: origin.addingTimeInterval(3600), bins: 6)
        XCTAssertEqual(runs, [
            .init(lower: 0, upper: 2, kind: .work),
            .init(lower: 2, upper: 3, kind: .other),
            .init(lower: 4, upper: 6, kind: .unclassified),
        ])
    }

    func testAFewSecondsDoNotPaintAWholeSlotWhenTheDayHasRealActivity() {
        let segments = [segment(0, 600, .work), segment(1900, 1910, .other)]
        let runs = GoalongThreadGeometry.runs(segments, from: origin, to: origin.addingTimeInterval(3600), bins: 6)
        XCTAssertEqual(runs, [.init(lower: 0, upper: 1, kind: .work)])
    }

    func testANearlyEmptyDayStillShowsWhereItHappened() {
        let runs = GoalongThreadGeometry.runs([segment(1900, 1909, .unclassified)], from: origin,
                                              to: origin.addingTimeInterval(3600), bins: 6)
        XCTAssertEqual(runs, [.init(lower: 3, upper: 4, kind: .unclassified)])
    }

    func testIdleAndUnobservedTimeNeverThickensTheThread() {
        let segments = [segment(0, 1800, .idle), segment(1800, 3600, .unobserved)]
        XCTAssertTrue(GoalongThreadGeometry.runs(segments, from: origin, to: origin.addingTimeInterval(3600), bins: 12).isEmpty)
        XCTAssertTrue(GoalongThreadGeometry.stretches(segments).isEmpty)
        XCTAssertTrue(GoalongThreadGeometry.runs(segments, from: origin, to: origin, bins: 12).isEmpty)
    }

    func testStretchesMergeTheSameClassAcrossShortGapsOnly() {
        let segments = [segment(0, 300, .work, task: "A"), segment(330, 600, .work, task: "A"),
                        segment(600, 900, .work, task: "B"), segment(1200, 1500, .work, task: "B")]
        let stretches = GoalongThreadGeometry.stretches(segments)
        XCTAssertEqual(stretches.map(\.task), ["A", "B", "B"])
        XCTAssertEqual(stretches.map(\.seconds), [570, 300, 300])
        XCTAssertEqual(stretches[0].end, origin.addingTimeInterval(600))
    }

    func testSharedHoursCoverEveryDayOnWholeHoursAndAtLeastSixHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: origin)
        func day(_ start: Double, _ end: Double, offset: Int) -> GoalongLocalAnalytics.Day {
            let date = midnight.addingTimeInterval(Double(offset) * 86400)
            let active = GoalongLocalAnalytics.Segment(start: date.addingTimeInterval(start * 3600), end: date.addingTimeInterval(end * 3600),
                                                       kind: .work, application: "App", bundleIdentifier: nil, host: nil)
            return .init(date: date, end: date.addingTimeInterval(86400), state: .ready, segments: [active],
                         eventCount: 1, classifierVersions: [])
        }
        XCTAssertEqual(GoalongThreadGeometry.sharedHours([day(9.5, 12, offset: 0), day(8.2, 17.4, offset: 1)], calendar: calendar), 8...18)
        XCTAssertEqual(GoalongThreadGeometry.sharedHours([day(10, 11, offset: 0)], calendar: calendar).count, 7)
        XCTAssertEqual(GoalongThreadGeometry.sharedHours([], calendar: calendar), 0...24)
    }
}
#endif
