#if os(macOS)
import Ambiance
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 D1b: what the member sees of the pauses, and the « + 15 min ». One test per item; every time comes from a
/// fake clock. No real guard, gamma, brightness or window: fake controllers and temporary folders only.
final class PauseDisplayTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Europe/Paris")!; return result
    }
    /// 2026-10-05 is a Monday.
    private func date(_ day: Int = 5, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func always(lock: BlockLock, pause: PausePolicy?) -> BlockProgramRange {
        var range = BlockProgramRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: lock)
        range.pause = pause
        return range
    }
    private func list(_ ranges: [BlockProgramRange] = [], breaks: BlockBreaks? = nil) -> BlockList {
        var value = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], breaks: breaks)
        value.program.ranges = ranges
        return value
    }
    @MainActor private func controller(_ lists: [BlockList], now: @escaping () -> Date) -> BlockingController {
        let c = BlockingController(document: BlockingDocument(lists: lists), clock: now, calendar: calendar,
                                   continuous: { now().timeIntervalSince1970 })
        c.refresh()
        return c
    }

    // Item 1: the budget left, in words, for any period; the former day count keeps its own words.
    @MainActor func testBudgetTextEveryPeriodAndLegacy() {
        let now = date()
        XCTAssertEqual(PauseEngine.budgetText(PausePolicy(budgetMinutes: 10), usage: nil, now: now, calendar: calendar),
                       "Pauses : 10 min sur 10 aujourd’hui")
        XCTAssertEqual(PauseEngine.budgetText(PausePolicy(budgetMinutes: 30, period: .week), usage: nil, now: now, calendar: calendar),
                       "Pauses : 30 min sur 30 cette semaine")
        let capped = PausePolicy(budgetMinutes: 10, period: .month, maxPauseMinutes: 4, maxPauses: 2)
        let (_, usage) = PauseEngine.request(capped, usage: nil, lock: .free, hasPassword: false, proof: .none, now: now, calendar: calendar)
        XCTAssertEqual(PauseEngine.budgetText(capped, usage: usage, now: now.addingTimeInterval(5 * 60), calendar: calendar),
                       "Pauses : 6 min sur 10 ce mois-ci · 1 pause restante")

        // A rule's pool, through the controller: the same words once a pause is taken.
        let rule = list([always(lock: .free, pause: PausePolicy(budgetMinutes: 10, maxPauseMinutes: 3))])
        var clock = now
        let c = controller([rule], now: { clock })
        XCTAssertEqual(c.pauseBudget(listID: rule.id), "Pauses : 10 min sur 10 aujourd’hui")
        XCTAssertEqual(c.takeBreak(listID: rule.id), .ok)
        clock = now.addingTimeInterval(4 * 60); c.refresh()
        XCTAssertEqual(c.pauseBudget(listID: rule.id), "Pauses : 7 min sur 10 aujourd’hui")

        // The former list pauses (a session over a list with `breaks`).
        let old = list(breaks: BlockBreaks(count: 2, minutes: 5))
        let legacy = controller([old], now: { now })
        XCTAssertNotNil(legacy.startSession(listIDs: [old.id], until: now.addingTimeInterval(3_600), lock: .free))
        XCTAssertEqual(legacy.pauseBudget(listID: old.id), "Pauses : 2 × 5 min restantes aujourd’hui")
        XCTAssertNil(controller([list()], now: { now }).pauseBudget(listID: UUID()), "no pause: no line")
    }

    // Item 1 (block screen): the line under the pause button shows the budget; once all is used, the budget then the password offer.
    func testShieldNoteShowsBudget() {
        let now = date()
        var veil = BlockingVeilPresentation(reason: .site("youtube.com"), listName: "Vidéo", start: now, end: now.addingTimeInterval(3_600),
                                            lock: .free, breakMinutes: 10, breaksLeft: 1)
        XCTAssertEqual(BlockedSiteVeil.breakNote(veil), "Dernière pause du jour", "no budget known: the former words")
        veil.pauseBudget = "Pauses : 10 min sur 30 cette semaine"
        XCTAssertEqual(BlockedSiteVeil.breakNote(veil), "Pauses : 10 min sur 30 cette semaine")
        veil.breaksLeft = 0; veil.pauseBudget = "Pauses : 0 min sur 30 cette semaine"; veil.extraBreak = true
        XCTAssertEqual(BlockedSiteVeil.breakNote(veil), "Pauses : 0 min sur 30 cette semaine. Le mot de passe en accorde une de plus.")
    }

    // Item 3: during a pause, the screen and the page say which other rule keeps the block.
    @MainActor func testHolderNamesTheOtherRule() {
        let now = date()
        let paused = always(lock: .free, pause: PausePolicy(budgetMinutes: 10))
        let alone = list([paused]), both = list([paused, always(lock: .typing, pause: nil)])
        let single = controller([alone], now: { now })
        XCTAssertEqual(single.takeBreak(listID: alone.id), .ok)
        XCTAssertNil(single.pauseHolder(listID: alone.id), "nothing else blocks")
        let held = controller([both], now: { now })
        XCTAssertNil(held.pauseHolder(listID: both.id), "no pause yet: no line")
        XCTAssertEqual(held.takeBreak(listID: both.id), .ok)
        XCTAssertEqual(held.pauseHolder(listID: both.id), "Votre pause est en cours, mais la règle « Toujours » bloque encore.")
    }

    // Item 2: « + 15 min » on a running Blocage session, in one call; never on a focus phase or a rule window.
    @MainActor func testExtendSessionByFifteenMinutes() {
        var now = date()
        let value = list([always(lock: .free, pause: nil)])
        let c = controller([value], now: { now })
        let end = now.addingTimeInterval(3_600)
        guard let id = c.startSession(listIDs: [value.id], until: end, lock: .locked) else { return XCTFail("no session") }
        XCTAssertTrue(c.canExtend(id))
        XCTAssertTrue(c.extendSession(id))
        XCTAssertEqual(c.snapshot.sessions.first { $0.id == id }?.end, end.addingTimeInterval(15 * 60), "stricter: even under « Verrouillé »")
        let program = c.activeBlocks.first { if case .program = $0.origin { return true }; return false }
        XCTAssertNotNil(program); XCTAssertFalse(c.canExtend(program!.id), "a rule window is not a session")
        c.isFocusBlock = { $0 == id }
        XCTAssertFalse(c.canExtend(id), "a focus phase keeps its own timer"); XCTAssertFalse(c.extendSession(id))
        c.isFocusBlock = { _ in false }
        now = end.addingTimeInterval(16 * 60); c.refresh()
        XCTAssertFalse(c.canExtend(id), "an ended session is not extended")
    }

    // Item 4: a focus session carries its own pause setting into its blocks.
    @MainActor func testFocusSessionCarriesPause() throws {
        let root = URL(fileURLWithPath: "/private/tmp/pause-display-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let now = date()
        let value = list()
        let b = controller([value], now: { now })
        let c = try ConcentrationController(store: FocusStore(directory: root), clock: { now }, blocking: { b })
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 25
        let policy = PausePolicy(budgetMinutes: 5)
        try c.startSession(intent: "Travail", mode: mode, blockListIds: [value.id], pause: policy)
        XCTAssertEqual(b.activeBlocks.count, 1)
        XCTAssertEqual(b.activeBlocks[0].pauses[value.id], policy)
        XCTAssertEqual(c.currentSession?.pause, policy)
        XCTAssertEqual(b.takeBreak(listID: value.id), .ok)
        XCTAssertEqual(b.pauseEnd(of: value.id, at: now), now.addingTimeInterval(5 * 60))
    }

    // Item 6: a session's own pause rests its « Surveillance » mark; a list's former pause does not.
    @MainActor func testSurveillanceMarkRestsDuringSessionPause() {
        let now = date()
        let value = list(breaks: BlockBreaks(count: 2, minutes: 5))
        let c = controller([value], now: { now })
        let policy = PausePolicy(budgetMinutes: 10)
        guard let own = c.startSession(listIDs: [value.id], until: now.addingTimeInterval(3_600), lock: .free, pause: policy),
              let old = c.startSession(listIDs: [value.id], until: now.addingTimeInterval(1_800), lock: .free) else { return XCTFail() }
        XCTAssertTrue(c.pausedSessionIDs.isEmpty)
        XCTAssertEqual(c.takeBreak(listID: value.id), .ok)
        XCTAssertEqual(c.pausedSessionIDs, [own], "only the session whose own pool runs")

        let focus = UUID()
        let mark = { (id: UUID, kind: JevSessionMark.Kind) in
            JevSessionMark(id: id, kind: kind, on: true, start: nil, end: nil, lock: .free, settings: JevInterventionSettings())
        }
        let document = JevSurveillanceDocument(marks: [mark(own, .block), mark(old, .block), mark(focus, .focus)])
        let running = JevRunningSessions(focus: focus, blocks: [own, old])
        XCTAssertEqual(JevSurveillanceStore.active(document, sessions: running, now: now, calendar: calendar).count, 3)
        var paused = running; paused.pausedSessions = [own, focus]
        XCTAssertEqual(JevSurveillanceStore.active(document, sessions: paused, now: now, calendar: calendar).count, 1,
                       "the session without a pause of its own still watches")
    }

    // Item 5: the list-level « Autoriser des pauses » is gone; an old setting reads as one line and can only be removed.
    @MainActor func testLegacyListPauseOnlyRemoved() {
        let now = date()
        let value = list(breaks: BlockBreaks(count: 2, minutes: 5))
        XCTAssertEqual(BlockingListsSection.legacyBreaksTitle(value.breaks!), "Pauses de séance : 2 × 5 min")
        let c = controller([value], now: { now })
        XCTAssertNotNil(c.startSession(listIDs: [value.id], until: now.addingTimeInterval(3_600), lock: .locked))
        var removed = value; removed.breaks = nil
        XCTAssertNil(c.save(removed), "removing pauses is stricter: allowed even under « Verrouillé »")
        XCTAssertNil(c.lists.first?.breaks)
        XCTAssertNotNil(c.save(value), "adding them back is weaker: refused while the session runs")
    }

    // Item 1 (rule row and menu bar): the rule shows what is left of its pauses, and the panel offers « Pause » and « + 15 min ».
    @MainActor func testRuleRowAndMenuBarShowBudget() throws {
        let now = date()
        let value = list([always(lock: .free, pause: PausePolicy(budgetMinutes: 10))])
        let c = controller([value], now: { now })
        let rule = BlockRules.rules(.init(lists: c.lists, now: now, calendar: calendar)).first
        XCTAssertEqual(rule?.pauseBudget(blocking: c), "Pauses : 10 min sur 10 aujourd’hui")
        XCTAssertNil(rule?.pauseBudget(blocking: nil), "no Blocage module: no line")

        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GoalongModule.blocking.defaultsKey)
        let root = URL(fileURLWithPath: "/private/tmp/pause-display-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try XCTUnwrap(c.startSession(listIDs: [value.id], until: now.addingTimeInterval(3_600), lock: .free))
        let model = MenuBarPanelModel(state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { c }, clock: { now }, calendar: calendar, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {},
            onShowClassicMenu: {})
        model.braise = { nil }; model.surveillanceRanges = { [] }
        model.refreshRuntimeState()
        let ruleLine = try XCTUnwrap(model.live.first { $0.id == rule?.id })
        XCTAssertEqual(ruleLine.pauses, "Pauses : 10 min sur 10 aujourd’hui")
        XCTAssertEqual(ruleLine.pauseList, value.id); XCTAssertEqual(ruleLine.pauseMinutes, 10)
        XCTAssertFalse(ruleLine.extendable)
        let sessionLine = try XCTUnwrap(model.live.first { $0.id == session.uuidString })
        XCTAssertTrue(sessionLine.extendable)
        model.extendLive(session.uuidString)
        XCTAssertEqual(c.snapshot.sessions.first { $0.id == session }?.end, now.addingTimeInterval(75 * 60))
        model.takeLivePause(ruleLine.id)
        XCTAssertEqual(c.pauseHolder(listID: value.id), "Votre pause est en cours, mais une séance jusqu’à \(BlockingFormat.endTime(now.addingTimeInterval(75 * 60))) bloque encore.",
                       "the pause runs; the session without a pause keeps the list")
    }
}
#endif
