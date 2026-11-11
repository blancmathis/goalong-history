#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 D1a: the pauses of a rule or a session. One test per point; every time comes from a fake clock.
final class PauseRuleTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Europe/Paris")!; return result
    }
    /// 2026-10-05 is a Monday.
    private func date(_ day: Int = 5, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func request(_ policy: PausePolicy, _ usage: PauseUsage?, at now: Date, lock: BlockLock = .free,
                         password: Bool = false, proof: PauseProof = .none) -> (PauseDecision, PauseUsage) {
        PauseEngine.request(policy, usage: usage, lock: lock, hasPassword: password, proof: proof, now: now, calendar: calendar)
    }
    /// Every day, all day: the range runs at any fake time.
    private func always(lock: BlockLock, pause: PausePolicy?) -> BlockProgramRange {
        var range = BlockProgramRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: lock)
        range.pause = pause
        return range
    }
    private func list(_ ranges: [BlockProgramRange], breaks: BlockBreaks? = nil) -> BlockList {
        var value = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")], breaks: breaks)
        value.program.ranges = ranges
        return value
    }

    // Point 1: a rule's pause is stored on its ranges, read back by the rule, and works under the 4 stop levels.
    @MainActor func testPoint1PauseStoredWithRuleUnderEveryLevel() throws {
        let base = list([])
        var draft = BlockRuleDraft()
        draft.weekdays = Set(1...7); draft.startMinute = 0; draft.endMinute = 1_440; draft.listIDs = [base.id]
        let policy = PausePolicy(budgetMinutes: 20)
        draft.setPause(policy)
        let writes = BlockRulePlan.writes(draft, replacing: nil, lists: [base], red: nil)
        let saved = try XCTUnwrap(writes.lists.first)
        XCTAssertEqual(saved.program.ranges.last?.pause, policy)
        let rule = try XCTUnwrap(BlockRules.rules(.init(lists: [saved], now: date(), calendar: calendar)).first)
        XCTAssertEqual(rule.pause, policy)
        XCTAssertEqual(BlockRuleDraft(rule).pause, policy)

        for lock in BlockLock.allCases {
            let now = date()
            let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
            let value = list([always(lock: lock, pause: policy)])
            let c = BlockingController(document: BlockingDocument(lists: [value], passwordLock: credential), clock: { now },
                                       calendar: calendar, continuous: { now.timeIntervalSince1970 })
            c.refresh()
            XCTAssertEqual(c.takeBreak(listID: value.id), .ok, "\(lock)")
            XCTAssertEqual(c.pauseEnd(of: value.id, at: now), now.addingTimeInterval(20 * 60), "\(lock)")
        }
    }

    // Point 1 (session): a session carries its own pause.
    @MainActor func testPoint1SessionCarriesPause() throws {
        let now = date()
        let value = list([])
        let c = BlockingController(document: BlockingDocument(lists: [value]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 })
        let policy = PausePolicy(budgetMinutes: 7)
        XCTAssertNotNil(c.startSession(listIDs: [value.id], until: now.addingTimeInterval(3_600), lock: .free, pause: policy))
        XCTAssertEqual(c.snapshot.sessions.last?.pause, policy)
        XCTAssertEqual(c.takeBreak(listID: value.id), .ok)
        XCTAssertEqual(c.pauseEnd(of: value.id, at: now), now.addingTimeInterval(7 * 60))
    }

    // Point 2: one model: a budget (10 min by default), an optional longest pause and an optional number of pauses.
    func testPoint2BudgetLongestAndCount() {
        XCTAssertEqual(PausePolicy().budgetMinutes, 10)
        let now = date()
        var policy = PausePolicy(budgetMinutes: 10, maxPauseMinutes: 4, maxPauses: 2)
        var (decision, usage) = request(policy, nil, at: now)
        XCTAssertEqual(decision, .granted(end: now.addingTimeInterval(4 * 60), extra: false))
        (decision, usage) = request(policy, usage, at: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(decision, .granted(end: now.addingTimeInterval(9 * 60), extra: false))
        (decision, usage) = request(policy, usage, at: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(decision, .refused("Les pauses de cette période sont prises."), "the count is used, 2 min of budget remain")
        policy.maxPauses = nil
        (decision, _) = request(policy, usage, at: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(decision, .granted(end: now.addingTimeInterval(12 * 60), extra: false), "only the 2 min left")
    }

    // Point 3: day (default), week or month, reset at local time.
    func testPoint3PeriodsResetAtLocalTime() {
        XCTAssertEqual(PausePolicy().period, .day)
        XCTAssertEqual(PauseEngine.periodKey(.day, at: date(5, 23, 59), calendar: calendar), "day:2026-10-05")
        XCTAssertEqual(PauseEngine.periodKey(.day, at: date(6, 0, 0), calendar: calendar), "day:2026-10-06")
        XCTAssertEqual(PauseEngine.periodKey(.week, at: date(11, 23, 59), calendar: calendar), "week:2026-10-05", "Sunday is in Monday's week")
        XCTAssertEqual(PauseEngine.periodKey(.week, at: date(12, 0, 0), calendar: calendar), "week:2026-10-12")
        XCTAssertEqual(PauseEngine.periodKey(.month, at: date(31, 23, 59), calendar: calendar), "month:2026-10-01")
        XCTAssertEqual(PauseEngine.periodKey(.month, at: date(1, 0, 0, month: 11), calendar: calendar), "month:2026-11-01")

        let policy = PausePolicy(budgetMinutes: 5, period: .week)
        var (_, usage) = request(policy, nil, at: date(5, 12))
        usage = PauseEngine.current(usage, policy: policy, now: date(7, 12), calendar: calendar)
        XCTAssertEqual(request(policy, usage, at: date(7, 12)).0, .refused("Les pauses de cette période sont prises."))
        XCTAssertEqual(request(policy, usage, at: date(12, 0)).0, .granted(end: date(12, 0, 5), extra: false), "new week, new budget")
    }

    // Point 4: before each pause: nothing, a wait (1 min to 1 day), a text to retype, or the password.
    func testPoint4Gates() {
        let now = date()
        XCTAssertEqual(PausePolicy.waitRange, 1...1_440)
        var policy = PausePolicy(budgetMinutes: 10, gate: .none)
        XCTAssertEqual(request(policy, nil, at: now).0, .granted(end: now.addingTimeInterval(600), extra: false))

        policy.gate = .wait(minutes: 3)
        var (decision, usage) = request(policy, nil, at: now)
        XCTAssertEqual(decision, .waiting(until: now.addingTimeInterval(180)))
        XCTAssertEqual(request(policy, usage, at: now.addingTimeInterval(60)).0, .waiting(until: now.addingTimeInterval(180)))
        (decision, _) = request(policy, usage, at: now.addingTimeInterval(200))
        XCTAssertEqual(decision, .granted(end: now.addingTimeInterval(800), extra: false))
        (decision, usage) = request(policy, usage, at: now.addingTimeInterval(180 + PauseEngine.claimWindow + 1))
        XCTAssertEqual(decision, .waiting(until: now.addingTimeInterval(180 + PauseEngine.claimWindow + 1 + 180)), "too late: the wait starts again")

        for gate in [PausePolicy.Gate.typing, .password] {
            policy.gate = gate
            XCTAssertEqual(request(policy, nil, at: now).0, .needsGate(gate))
            XCTAssertEqual(request(policy, nil, at: now, proof: .passed).0, .granted(end: now.addingTimeInterval(600), extra: false))
        }
    }

    // Point 4 (controller): the typing gate asks the exact text before the pause.
    @MainActor func testPoint4TypingGateInController() {
        let now = date()
        let value = list([always(lock: .free, pause: PausePolicy(budgetMinutes: 10, gate: .typing))])
        let c = BlockingController(document: BlockingDocument(lists: [value]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 })
        c.refresh()
        XCTAssertNotEqual(c.takeBreak(listID: value.id), .ok)
        XCTAssertNotEqual(c.takeBreak(listID: value.id, typed: "faux"), .ok)
        XCTAssertNil(c.pauseEnd(of: value.id, at: now))
        XCTAssertEqual(c.takeBreak(listID: value.id, typed: c.pauseTypingChallenge(listID: value.id)), .ok)
        XCTAssertNotNil(c.pauseEnd(of: value.id, at: now))
    }

    // Point 5: a pause suspends its rule only; another active rule on the same list keeps it blocked.
    @MainActor func testPoint5PauseSuspendsOnlyItsRule() {
        let now = date()
        let paused = always(lock: .free, pause: PausePolicy(budgetMinutes: 10))
        let other = always(lock: .typing, pause: nil)
        let alone = list([paused])
        let both = list([paused, other])
        for (value, kept) in [(alone, false), (both, true)] {
            let c = BlockingController(document: BlockingDocument(lists: [value]), clock: { now }, calendar: calendar,
                                       continuous: { now.timeIntervalSince1970 })
            c.refresh()
            XCTAssertEqual(c.activeBlocks.count, kept ? 2 : 1)
            XCTAssertEqual(c.takeBreak(listID: value.id), .ok)
            XCTAssertEqual(c.pauseEnd(of: value.id, at: now) == nil, kept, kept ? "the other rule still blocks" : "the rule is paused")
        }
        // « Surveillance » of the same rule does not watch during its pause.
        let policy = PausePolicy(budgetMinutes: 10)
        var range = JevSurveillanceRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: .free,
                                         settings: JevInterventionSettings())
        range.pause = policy
        let document = JevSurveillanceDocument(ranges: [range])
        XCTAssertEqual(JevSurveillanceStore.active(document, sessions: JevRunningSessions(), now: now, calendar: calendar).count, 1)
        XCTAssertTrue(JevSurveillanceStore.active(document, sessions: JevRunningSessions(pausedPools: [policy.id]), now: now,
                                                  calendar: calendar).isEmpty)
    }

    // Point 6: a pause ends at its length, at the end of the budget, or at midnight; never without an end.
    func testPoint6PauseAlwaysEnds() {
        let now = date(5, 23, 50)
        XCTAssertEqual(request(PausePolicy(budgetMinutes: 30), nil, at: now).0, .granted(end: date(6, 0, 0), extra: false), "midnight")
        XCTAssertEqual(request(PausePolicy(budgetMinutes: 30, maxPauseMinutes: 5), nil, at: now).0,
                       .granted(end: date(5, 23, 55), extra: false), "its length")
        let noon = date(5, 12)
        XCTAssertEqual(request(PausePolicy(budgetMinutes: 8), nil, at: noon).0, .granted(end: date(5, 12, 8), extra: false), "the budget")
        // « Reprendre » early: only the time used counts.
        let policy = PausePolicy(budgetMinutes: 10)
        let started = request(policy, nil, at: noon).1
        let ended = PauseEngine.ended(started, now: noon.addingTimeInterval(120))
        XCTAssertNil(ended.end)
        XCTAssertEqual(PauseEngine.secondsLeft(policy, usage: ended, now: noon.addingTimeInterval(130)), 480)
    }

    // Point 7: « Pause en plus »: a cap per period (0 = never, the default), always the password, refused under « Verrouillé ».
    func testPoint7ExtraPause() {
        XCTAssertEqual(PausePolicy().extraPerPeriod, 0)
        let now = date()
        var policy = PausePolicy(budgetMinutes: 1)
        let spent = PauseEngine.current(request(policy, nil, at: now).1, policy: policy, now: now.addingTimeInterval(120), calendar: calendar)
        let later = now.addingTimeInterval(120)
        XCTAssertEqual(request(policy, spent, at: later, lock: .password, password: true).0, .refused("Les pauses de cette période sont prises."))
        policy.extraPerPeriod = 1
        XCTAssertEqual(request(policy, spent, at: later, lock: .free, password: true).0, .needsExtraPassword)
        XCTAssertEqual(request(policy, spent, at: later, lock: .free, password: false).0,
                       .refused("Les pauses de cette période sont prises. Une pause en plus demande le mot de passe de blocage."))
        XCTAssertEqual(request(policy, spent, at: later, lock: .locked, password: true, proof: .passed).0,
                       .refused("Les pauses de cette période sont prises. Verrouillé : aucune pause en plus."))
        let (decision, usage) = request(policy, spent, at: later, lock: .free, password: true, proof: .passed)
        XCTAssertEqual(decision, .granted(end: later.addingTimeInterval(60), extra: true))
        let after = PauseEngine.current(usage, policy: policy, now: later.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(request(policy, after, at: later.addingTimeInterval(120), password: true, proof: .passed).0,
                       .refused("Les pauses de cette période sont prises, pauses en plus comprises."))
    }

    // Point 8: under « Verrouillé » the budget's pauses stay allowed and the words say it; « Durcir seulement »: no more.
    @MainActor func testPoint8LockedAndHardenOnly() {
        let now = date()
        let policy = PausePolicy(budgetMinutes: 10)
        XCTAssertEqual(request(policy, nil, at: now, lock: .locked).0, .granted(end: now.addingTimeInterval(600), extra: false))
        var draft = BlockRuleDraft()
        let value = list([always(lock: .locked, pause: policy)])
        draft.listIDs = [value.id]; draft.lock = .locked; draft.setPause(policy)
        let sentence = BlockRuleSentence.text(trigger: .schedule, draft: draft, lists: [value], lock: .locked, now: now) ?? ""
        XCTAssertTrue(sentence.hasSuffix("Les pauses du budget restent permises, sans pause en plus."), sentence)
        XCTAssertTrue(PausePolicy.lockedText.contains("Les pauses du budget restent permises"))

        // Pure rules of « Durcir seulement ».
        var more = policy; more.budgetMinutes = 11
        var less = policy; less.budgetMinutes = 5; less.gate = .typing
        var shorter = policy; shorter.period = .day
        var longerPeriod = policy; longerPeriod.period = .week
        XCTAssertNotNil(PauseEngine.weakening(policy, more))
        XCTAssertNil(PauseEngine.weakening(policy, less))
        XCTAssertNil(PauseEngine.weakening(policy, nil), "removing the pauses hardens")
        XCTAssertNotNil(PauseEngine.weakening(nil, policy), "adding pauses weakens")
        XCTAssertNotNil(PauseEngine.weakening(policy, longerPeriod), "a new period starts from zero: a used budget would come back")
        XCTAssertNotNil(PauseEngine.weakening(longerPeriod, shorter))
        var newPool = policy; newPool.id = UUID()
        XCTAssertNotNil(PauseEngine.weakening(policy, newPool), "a new pool starts from zero")

        // The engine refuses a higher budget while the rule runs locked.
        let c = BlockingController(document: BlockingDocument(lists: [value]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 })
        c.refresh()
        XCTAssertTrue(c.isStricterOnly(value.id))
        var raised = value; raised.program.ranges[0].pause = more
        guard case .refused(let reason) = c.editCheck(raised) else { return XCTFail("a higher budget must be refused") }
        XCTAssertTrue(reason.contains("les pauses peuvent seulement diminuer"), reason)
        var lowered = value; lowered.program.ranges[0].pause = less
        XCTAssertEqual(c.editCheck(lowered), .allowed)
    }

    // Point 10: one migration: a list's `BlockBreaks` becomes the pause of each of its rules, with the same limits.
    @MainActor func testPoint10MigrationOnce() throws {
        let now = date()
        let value = list([always(lock: .free, pause: nil), always(lock: .password, pause: nil)], breaks: BlockBreaks(count: 3, minutes: 5))
        let c = BlockingController(document: BlockingDocument(lists: [value]), clock: { now }, calendar: calendar,
                                   continuous: { now.timeIntervalSince1970 })
        let migrated = try XCTUnwrap(c.snapshot.lists.first)
        XCTAssertEqual(c.snapshot.pauseMigration, 1)
        let free = try XCTUnwrap(migrated.program.ranges[0].pause)
        XCTAssertEqual(free.id, value.id)
        XCTAssertEqual(free.budgetMinutes, 15); XCTAssertEqual(free.maxPauseMinutes, 5); XCTAssertEqual(free.maxPauses, 3)
        XCTAssertEqual(free.period, .day); XCTAssertEqual(free.gate, .none); XCTAssertEqual(free.extraPerPeriod, 0)
        XCTAssertNil(migrated.program.ranges[1].pause?.extraPerPeriod, "« Mot de passe » kept its uncapped extra pause")

        // The former path still counts in the list's day usage, as before.
        c.refresh()
        XCTAssertEqual(c.takeBreak(listID: value.id), .ok)
        XCTAssertEqual(c.snapshot.usage?.breaksTaken[value.id], 1)
        XCTAssertEqual(c.pauseEnd(of: value.id, at: now), now.addingTimeInterval(300))

        // Once: a document already migrated keeps a range without pause as it is.
        var done = BlockingDocument(lists: [value])
        done.pauseMigration = 1
        let again = BlockingController(document: done, clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        XCTAssertNil(again.snapshot.lists.first?.program.ranges[0].pause)
    }

    // Point 10 (editor): changing a list's former pauses gives the rule its own pool; not touching them writes nothing.
    func testPoint10EditingMigratedPauseGetsOwnPool() throws {
        let legacy = PausePolicy.migrated(BlockBreaks(count: 2, minutes: 5), listID: UUID(), lock: .free)
        var value = list([BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 720, lock: .free)])
        value.id = legacy.id
        value.program.ranges[0].pause = legacy
        let rule = try XCTUnwrap(BlockRules.rules(.init(lists: [value], now: date(), calendar: calendar)).first)
        var draft = BlockRuleDraft(rule)
        XCTAssertTrue(BlockRulePlan.writes(draft, replacing: rule, lists: [value], red: nil).lists.isEmpty)
        var changed = legacy; changed.budgetMinutes = 8
        draft.setPause(changed)
        XCTAssertNotEqual(draft.pause?.id, legacy.id)
        let written = try XCTUnwrap(BlockRulePlan.writes(draft, replacing: rule, lists: [value], red: nil).lists.first)
        XCTAssertEqual(written.program.ranges[0].pause?.budgetMinutes, 8)
        XCTAssertNotEqual(written.program.ranges[0].pause?.id, value.id)
        draft.setPause(legacy)
        XCTAssertFalse(draft.pauseChanged, "back to the opening values = unchanged")
    }
}
#endif
