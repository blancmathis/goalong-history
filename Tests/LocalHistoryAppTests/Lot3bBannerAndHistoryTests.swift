#if os(macOS)
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-052 lot 3b: one banner at a time, neighbouring Historique ranges merged.
final class Lot3bBannerAndHistoryTests: XCTestCase {
    // 17: the most urgent banner first; the others wait behind « n autres ».
    func testBannerStackKeepsOneAndCountsTheOthers() {
        let all = GoalongBannerStack.active(pause: true, notice: .lowSpace(1), menuBarHidden: true)
        XCTAssertEqual(all, [.pause, .attention, .menuBar])
        let one = GoalongBannerStack.pick(all, expanded: false)
        XCTAssertEqual(one.shown, [.pause])
        XCTAssertEqual(one.hidden, 2)
        XCTAssertEqual(GoalongBannerStack.pick(all, expanded: true).shown, all)
        XCTAssertEqual(GoalongBannerStack.moreTitle(hidden: 2, expanded: false), "2 autres avis")
        XCTAssertEqual(GoalongBannerStack.moreTitle(hidden: 1, expanded: false), "1 autre avis")
        XCTAssertEqual(GoalongBannerStack.moreTitle(hidden: 2, expanded: true), "Masquer les autres avis")
    }

    func testBannerStackOrderAndEmpty() {
        XCTAssertEqual(GoalongBannerStack.active(pause: false, notice: nil, menuBarHidden: false), [])
        // The green update confirmation yields to a warning.
        XCTAssertEqual(GoalongBannerStack.active(pause: false, notice: .updated(from: "1", to: "2"), menuBarHidden: true),
                       [.menuBar, .updated])
        XCTAssertEqual(GoalongBannerStack.pick([], expanded: false).hidden, 0)
    }

    // S7: windows that touch and show the same apps read as one range.
    func testNeighbouringWindowsWithTheSameAppsMerge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 27)))
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let sessions = [session("a", "Safari", at(9, 10), at(9, 30)),
                        session("b", "Mail", at(9, 40), at(9, 50)),
                        session("c", "Safari", at(10, 0), at(10, 10))]
        let built = ComputerHistoryTenMinuteGroup.build(sessions: sessions, day: day, calendar: calendar, now: at(23, 0))
        XCTAssertEqual(built.count, 4, "9:10, 9:20, 9:40, 10:00")
        let merged = ComputerHistoryTenMinuteGroup.mergingNeighbours(built)
        XCTAssertEqual(merged.map(\.start), [at(10, 0), at(9, 40), at(9, 10)], "newest first")
        let first = try XCTUnwrap(merged.last)
        XCTAssertEqual(first.end, at(9, 30))
        XCTAssertEqual(first.apps.map(\.name), ["Safari"])
        XCTAssertEqual(first.activeSeconds, built.suffix(2).reduce(0) { $0 + $1.activeSeconds })
        XCTAssertEqual(first.sessions.count, 1, "one continuous Safari session")
        XCTAssertEqual(first.appChangeCount, 0)
    }

    func testMergeNeverBridgesAGapOrAnotherApp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 27)))
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let sessions = [session("a", "Safari", at(9, 0), at(9, 10)),
                        session("b", "Safari", at(9, 20), at(9, 30)),
                        session("c", "Mail", at(9, 30), at(9, 40))]
        let built = ComputerHistoryTenMinuteGroup.build(sessions: sessions, day: day, calendar: calendar, now: at(23, 0))
        XCTAssertEqual(ComputerHistoryTenMinuteGroup.mergingNeighbours(built).count, built.count)
        XCTAssertTrue(ComputerHistoryTenMinuteGroup.mergingNeighbours([]).isEmpty)
    }

    private func session(_ id: String, _ app: String, _ start: Date, _ end: Date) -> ActivitySession {
        ActivitySession(
            id: id, start: start, end: end, appName: app, bundleIdentifier: "test.\(app)",
            windowTitle: "Document", host: nil, category: "productivity", isWork: true, confidence: 1,
            suppressionReason: nil, eventCount: 3, inputEventCount: 1, softwareAttributedEventCount: 0,
            kindCounts: [:], latestMessage: nil)
    }
}
#endif
