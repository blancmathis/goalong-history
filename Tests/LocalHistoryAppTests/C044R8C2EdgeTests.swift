#if os(macOS)
import XCTest
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// T-044 tour 8, volet C2 (C8-21, C8-23).
final class C044R8C2EdgeTests: XCTestCase {
    private func store() throws -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/c044r8c2-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    private func noon() -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        return c.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
    }

    /// CLI `plan move ID` on a finished task: it comes back to life as an open copy on the next day.
    @MainActor func testMovingADoneTaskDoesNotReopenIt() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now), d1 = try c.dayAfter(d0)
        let item = try c.addPlanItem(title: "Rapport", day: d0)
        try c.setItemStatus(item.id, day: d0, status: .done)
        XCTAssertThrowsError(try c.movePlanItem(item.id, day: d0, to: d1)) { XCTAssertEqual($0 as? FocusFailure, .itemFinished) }
        let all = try c.plan(on: d0).items + c.plan(on: d1).items
        XCTAssertFalse(all.contains { $0.id == item.id && $0.status == .open }, "\(all.map(\.status))")
    }

    /// Same for a dropped task.
    @MainActor func testMovingADroppedTaskDoesNotReopenIt() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now), d1 = try c.dayAfter(d0)
        let item = try c.addPlanItem(title: "Rapport", day: d0)
        try c.setItemStatus(item.id, day: d0, status: .dropped)
        XCTAssertThrowsError(try c.movePlanItem(item.id, day: d0, to: d1)) { XCTAssertEqual($0 as? FocusFailure, .itemFinished) }
        let all = try c.plan(on: d0).items + c.plan(on: d1).items
        XCTAssertFalse(all.contains { $0.id == item.id && $0.status == .open }, "\(all.map(\.status))")
    }

    /// The Dashboard and the Health sheet show the same zero / sub-minute text with no-break spaces.
    func testZeroAndSubMinuteDurationsUseNoBreakSpaces() {
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(0), DashboardFormatters.duration(seconds: 0))
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(30), DashboardFormatters.duration(seconds: 30))
    }
}
#endif
