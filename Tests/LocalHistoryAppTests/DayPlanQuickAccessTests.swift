#if os(macOS)
import Ambiance
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-057 M1: the « Plan du jour » row, the plan view's actions and « Bilan » in the evening, on real plans.
final class DayPlanQuickAccessTests: XCTestCase {
    private let day = "2026-11-27"
    private let zone = "Europe/Paris"
    private func at(_ minute: Int) -> Date { FocusDayPlanner.date(day: day, minute: minute, timeZoneID: zone)! }
    private var paris: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }

    private func plan() -> (FocusPlan, FocusPlanItem) {
        let work = FocusPlanItem(title: "Préparer la démo", actionKind: .work)
        let plan = FocusPlan(day: day, items: [work], agenda: FocusAgenda(timeZoneID: zone, autoAdjust: false, slots: [
            .init(title: "Réponses aux e-mails", startMinute: 975, endMinute: 1020),
            .init(title: "Rédaction du rapport", startMinute: 540, endMinute: 630, state: .done),
            .init(itemID: work.id, title: work.title, startMinute: 870, endMinute: 960),
            .init(title: "À caser", startMinute: 600, endMinute: 630, state: .unscheduled)
        ]))
        return (plan, work)
    }

    func testRowsAreTodaysTimedSlotsInOrder() {
        let rows = DayPlanDigest.rows(plan: plan().0, now: at(700))
        XCTAssertEqual(rows.map(\.title), ["Rédaction du rapport", "Préparer la démo", "Réponses aux e-mails"])
        XCTAssertEqual(rows.first?.time, "09:00 – 10:30")
        XCTAssertTrue(DayPlanDigest.rows(plan: plan().0, now: at(700).addingTimeInterval(86_400)).isEmpty, "another day: no plan")
    }

    func testSummaryNamesTheNextStepAndIsHiddenWithoutAPlan() {
        XCTAssertEqual(DayPlanDigest.summary(plan: plan().0, now: at(700)),
                       DayPlanSummary(nextTime: "14:30", nextTitle: "Préparer la démo", done: 1, total: 3))
        XCTAssertNil(DayPlanDigest.summary(plan: FocusPlan(day: day), now: at(700)))
        XCTAssertNil(DayPlanDigest.summary(plan: FocusPlan(day: day, agenda: FocusAgenda(timeZoneID: zone)), now: at(700)))
    }

    func testRecapLeadsAfterTheLastSlotOrAtSixWithoutAPlan() {
        let (p, _) = plan()
        XCTAssertFalse(DayPlanDigest.recapIsMain(plan: p, now: at(1019), calendar: paris))
        XCTAssertTrue(DayPlanDigest.recapIsMain(plan: p, now: at(1020), calendar: paris), "end of 16:15 – 17:00")
        XCTAssertFalse(DayPlanDigest.recapIsMain(plan: nil, now: at(1079), calendar: paris))
        XCTAssertTrue(DayPlanDigest.recapIsMain(plan: nil, now: at(1080), calendar: paris), "18:00")
        XCTAssertTrue(DayPlanDigest.recapIsMain(plan: FocusPlan(day: day), now: at(1080), calendar: paris))
    }

    func testDayTitleIsFrench() {
        XCTAssertEqual(DayPlanDigest.dayTitle(at(700)), "Vendredi 27 novembre")
    }

    func testPanelMaxHeightKeepsAMarginAndAFloor() {
        XCTAssertEqual(MenuBarPanelPresenter.maxHeight(visibleHeight: 875), 851)
        XCTAssertEqual(MenuBarPanelPresenter.maxHeight(visibleHeight: 100), 240)
    }

    /// « Commencer » then « C’est fait » on the controller the plan view drives.
    @MainActor func testStartThenDoneMoveTheSlotThroughTheDay() throws {
        let store = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/day-plan-m1-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: store.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false
        try store.saveSettings(settings)
        var (p, _) = plan()
        p.agenda?.slots.removeAll { $0.itemID != nil }
        try store.savePlans([p])
        let now = at(980)
        let controller = try ConcentrationController(store: store, clock: { now }, calendar: paris)
        let mails = try XCTUnwrap(DayPlanDigest.rows(plan: controller.plan, now: now).first { $0.title == "Réponses aux e-mails" })
        try controller.startAgendaSlot(mails.id)
        XCTAssertEqual(DayPlanDigest.rows(plan: controller.plan, now: now).first { $0.id == mails.id }?.state, .active)
        try controller.finishAgendaSlot(mails.id)
        XCTAssertEqual(DayPlanDigest.rows(plan: controller.plan, now: now).first { $0.id == mails.id }?.state, .done)
        XCTAssertEqual(DayPlanDigest.summary(plan: controller.plan, now: now)?.done, 2)
    }

    @MainActor func testPanelRowOpensThePlanView() {
        let suite = "day-plan-m1-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var opened: [String] = []
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil },
            ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { URL(fileURLWithPath: "/private/tmp/" + suite) }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { opened.append("section \($0)") }, onOpenDay: {},
            onOpenDayPlan: { opened.append("plan") }, onShowClassicMenu: {})
        model.openDayPlan()
        XCTAssertEqual(opened, ["plan"])
        model.refresh()
        XCTAssertNil(model.dayPlanSummary, "no Concentration: no row")
    }
}
#endif
