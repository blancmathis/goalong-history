#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// Edge cases found in T-044 tour 9 (C9-41).
final class ConcentrationReviewDroppedTests: XCTestCase {
    private func store() throws -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/c044r9c2b-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    private func noon() -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        return c.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
    }

    /// C9-41: `goalong review set` with a dropped task in the body (the UI never lists it) reopens it.
    @MainActor func testReviewSetDoesNotReopenADroppedTask() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now)
        let item = try c.addPlanItem(title: "Rapport", day: d0)
        try c.setItemStatus(item.id, day: d0, status: .dropped)
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, outcome: .notDone, toDay: nil)]))
        XCTAssertEqual(try c.plan(on: d0).items.first?.status, .dropped)
    }
}
#endif
