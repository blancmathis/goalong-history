#if os(macOS)
import XCTest
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// T-044 tour 7, volet C2 (cas limites hors horloge). Red tests only; never committed.
final class C044R7C2EdgeTests: XCTestCase {
    private func store() throws -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/c044r7c2-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    private func noon() -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        return c.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
    }

    /// « Taille actuelle » (Confidentialité) and Agents use a ByteCountFormatter that follows the system region.
    func testPrivacyStorageSizeIsFrenchWhateverTheRegion() {
        let shown = DashboardFormatters.byteCount.string(fromByteCount: 10_630_000_000)
        XCTAssertEqual(shown, GoalongUIFormat.bytes(10_630_000_000), "region \(Locale.current.identifier)")
    }

    /// CLI `plan move ID --day D+1 --to D`: the task goes back to its first day.
    @MainActor func testMovingATaskBackToItsFirstDayKeepsItOpen() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now), d1 = try c.dayAfter(d0)
        let item = try c.addPlanItem(title: "Rapport", day: d0)
        try c.movePlanItem(item.id, day: d0, to: d1)
        try c.movePlanItem(item.id, day: d1, to: d0)
        let first: [FocusPlanItem] = try c.plan(on: d0).items, second: [FocusPlanItem] = try c.plan(on: d1).items
        let open = (first + second).filter { $0.id == item.id && $0.status == .open }
        XCTAssertEqual(open.count, 1, "d0 \(first.map(\.status)) d1 \(second.map(\.status))")
    }

    /// Evening review of D: « Demain d'abord : Appeler la banque ». On D+1 the task is done.
    /// Reopening D's review (prefilled) to add a note puts the task back to open.
    @MainActor func testResavingAReviewKeepsTheCarriedTaskDone() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now), d1 = try c.dayAfter(d0)
        _ = try c.addPlanItem(title: "Rapport", day: d0)
        try c.setReview(FocusReview(day: d0, items: [], tomorrowFirst: "Appeler la banque"))
        let carried = try XCTUnwrap(c.plan(on: d1).items.first)
        try c.setItemStatus(carried.id, day: d1, status: .done)
        try c.setReview(FocusReview(day: d0, items: [], tomorrowFirst: "Appeler la banque", note: "Bonne journée"))
        XCTAssertEqual(try c.plan(on: d1).items.first(where: { $0.title == "Appeler la banque" })?.status, .done)
    }

    /// Clearing « Demain d'abord » in a saved review leaves the old task in tomorrow's plan.
    @MainActor func testClearingTomorrowFirstWithdrawsTheCarriedTask() throws {
        let now = noon(), s = try store()
        let c = try ConcentrationController(store: s, clock: { now })
        let d0 = FocusCalendar.dayKey(now), d1 = try c.dayAfter(d0)
        _ = try c.addPlanItem(title: "Rapport", day: d0)
        try c.setReview(FocusReview(day: d0, items: [], tomorrowFirst: "Appeler la banque"))
        try c.setReview(FocusReview(day: d0, items: [], tomorrowFirst: ""))
        XCTAssertEqual(try c.plan(on: d1).items.map(\.title), [])
    }
}
#endif
