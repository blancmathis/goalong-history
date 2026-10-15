#if os(macOS)
import Ambiance
import XCTest
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

final class ConcentrationControllerTests: XCTestCase {
    private func store() -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/focus-controller-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return FocusStore(directory: root)
    }
    private func quiet(_ store: FocusStore) throws {
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try store.saveSettings(settings)
    }
    @MainActor func testOffCreatesNoControllerFactoryTimerPanelOrFileAndRoutesDisabled() throws {
        let name = "focus-off-" + UUID().uuidString, s = store()
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let modules = GoalongModuleStore(defaults: defaults); var stores = 0, controllers = 0
        let runtime = ConcentrationRuntime(storeFactory: { stores += 1; return s }, factory: { store in controllers += 1; return try ConcentrationController(store: store) })
        runtime.start(modules: modules)
        XCTAssertNil(runtime.controller); XCTAssertEqual(stores, 0); XCTAssertEqual(controllers, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.directory.path))
        for command in ["focus status", "session current", "sessions", "plan show", "review show", "limits"] {
            XCTAssertThrowsError(try runtime.handle(.init(command: command))) { XCTAssertEqual($0 as? GoalongFocusError, .moduleDisabled) }
        }
        // The entry stays: its tab says the module is off and offers to turn it on.
        XCTAssertTrue(DashboardSection.sidebarSections(modules: modules.enabled).contains(.concentration))
    }
    /// R2-019: plan, review and session files saved under a pre-Gregorian key move to the Gregorian name, once.
    @MainActor func testLegacyCalendarDayFilesAreRenamedOnLoad() throws {
        let now = Date(timeIntervalSince1970: 1792065600)  // 2026-10-15 12:00 UTC
        for (identifier, today, yesterday) in [(Calendar.Identifier.buddhist, "2569-10-15", "2569-10-14"), (.japanese, "0008-10-15", "0008-10-14"), (.indian, "1948-07-23", "1948-07-22")] {
            var legacy = Calendar(identifier: identifier); legacy.timeZone = TimeZone(identifier: "UTC")!
            let s = store(); try quiet(s)
            let session = FocusSession(intent: "Lire", mode: FocusMode(minutes: 5), startedAt: now.addingTimeInterval(-86_400), events: [.init(kind: .start, at: now.addingTimeInterval(-86_400))])
            try s.saveSessions([session], day: yesterday)
            try s.savePlans([FocusPlan(day: today)], review: FocusReview(day: yesterday))
            for _ in 0..<2 {  // the second launch changes nothing
                let c = try ConcentrationController(store: s, clock: { now }, calendar: legacy)
                XCTAssertEqual(try c.plan(on: "2026-10-15").day, "2026-10-15");
                XCTAssertEqual(try s.plan("2026-10-15")?.day, "2026-10-15", "\(identifier)")
                XCTAssertEqual(try s.sessions("2026-10-14").count, 1, "\(identifier)")
                XCTAssertEqual(try s.review("2026-10-14")?.day, "2026-10-14")
                XCTAssertEqual(try s.sessionDays(), ["2026-10-14"]); XCTAssertEqual(try s.planDays(), ["2026-10-15"])
            }
        }
    }
    @MainActor func testRestoreRunningAndAppClosedEnd() throws {
        let s = store(); try quiet(s)
        var now = Date(timeIntervalSince1970: 1791201600)
        let c = try ConcentrationController(store: s, clock: { now })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        let id = c.currentSession!.id
        now = now.addingTimeInterval(120)
        let restored = try ConcentrationController(store: s, clock: { now })
        XCTAssertEqual(restored.currentSession?.id, id); XCTAssertEqual(restored.phase?.kind, .work)
        now = now.addingTimeInterval(300)
        let closed = try ConcentrationController(store: s, clock: { now })
        XCTAssertNil(closed.currentSession)
        let values = try s.sessions(BlockingController.dayKey(now))
        XCTAssertEqual(values.last?.events.last?.reason, .appClosed)
        XCTAssertNil(values.last?.outcome)
    }
    @MainActor func testWorkBlocksBreaksAndLockedStopSkipBothAppAndCLI() throws {
        let s = store(); try quiet(s); var now = Date(timeIntervalSince1970: 1791201600)
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")])
        let b = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, continuous: { now.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { now }, blocking: { b })
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 5
        try c.startSession(intent: "Travail", mode: mode, blockListIds: [list.id], lock: true)
        XCTAssertEqual(b.activeBlocks.count, 1); XCTAssertEqual(b.activeBlocks[0].lock, .locked)
        XCTAssertThrowsError(try c.stopSession()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertThrowsError(try c.skipPhase()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let modules = GoalongModuleStore(defaults: defaults)
        let runtime = ConcentrationRuntime(storeFactory: { s }, factory: { _ in c }, blockingProvider: { b }, presentsPanels: false); runtime.start(modules: modules)
        XCTAssertThrowsError(try runtime.handle(.init(command: "session stop"))) { XCTAssertEqual($0 as? GoalongFocusError, .locked) }
        modules.setEnabled(.concentration, false); XCTAssertTrue(modules.isEnabled(.concentration)); XCTAssertNotNil(runtime.controller)
        now = now.addingTimeInterval(300); c.refresh()
        XCTAssertEqual(c.phase?.kind, .shortBreak); XCTAssertTrue(b.activeBlocks.isEmpty)
        now = now.addingTimeInterval(300); c.refresh(); XCTAssertEqual(c.phase?.kind, .work); XCTAssertEqual(b.activeBlocks.count, 1)
    }
    @MainActor func testBreakBlockingFreeAndOpenLeaseRenewal() throws {
        let s = store(); try quiet(s); var now = Date(timeIntervalSince1970: 1791201600)
        let list = BlockList(name: "Apps")
        let b = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, continuous: { now.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { now }, blocking: { b })
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 5
        try c.startSession(intent: "Écrire", mode: mode, blockListIds: [list.id], blockDuringBreaks: true, lock: true)
        now = now.addingTimeInterval(300); c.refresh(); XCTAssertEqual(b.activeBlocks.first?.lock, .free)
        try c.stopSession(); XCTAssertTrue(b.activeBlocks.isEmpty)
        mode = FocusMode(minutes: nil); try c.startSession(intent: "Lire", mode: mode, blockListIds: [list.id])
        let before = b.activeBlocks.first!.end
        now = now.addingTimeInterval(45); c.refresh(); XCTAssertGreaterThan(b.activeBlocks.first!.end, before)
        try c.stopSession(); XCTAssertTrue(b.activeBlocks.isEmpty)
    }
    @MainActor func testAudioWorkBreakStopAndOutcomeDismissed() throws {
        let s = store(); try quiet(s); var now = Date(timeIntervalSince1970: 1791201600)
        let audio = AudioSpy(), c = try ConcentrationController(store: s, clock: { now }, audio: audio)
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 5
        try c.startSession(intent: "Écrire", mode: mode, ambiance: true)
        XCTAssertEqual(audio.actions, ["work"])
        now = now.addingTimeInterval(300); c.refresh(); XCTAssertEqual(audio.actions, ["work", "break"])
        try c.stopSession(); XCTAssertEqual(audio.actions.last, "stop"); XCTAssertEqual(c.panel?.kind, .sessionReview)
        c.dismissPanel(); XCTAssertNil(c.sessions.last?.outcome)
    }
    @MainActor func testPlanReviewMovesBoundsAndCarryIdentityPreservesHumanItem() throws {
        let s = store(); try quiet(s); let c = try ConcentrationController(store: s)
        let day = BlockingController.dayKey(Date()), tomorrow = BlockingController.dayKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        let item = try c.addPlanItem(title: "Écrire", day: day, estimateMinutes: 30)
        let human = try c.addPlanItem(title: "Commencer", day: tomorrow)
        try c.setReview(FocusReview(day: day, items: [.init(id: item.id, toDay: tomorrow)], tomorrowFirst: "Commencer"))
        var next = try c.plan(on: tomorrow); XCTAssertEqual(next.items.count, 3); XCTAssertEqual(next.items.first?.title, "Commencer")
        try c.setReview(FocusReview(day: day, items: [.init(id: item.id, toDay: tomorrow)], tomorrowFirst: "Finir"))
        next = try c.plan(on: tomorrow); XCTAssertEqual(next.items.count, 3); XCTAssertTrue(next.items.contains { $0.id == human.id })
        XCTAssertEqual(try c.plan(on: day).items.first?.status, .moved)
        XCTAssertThrowsError(try c.addPlanItem(title: "a\nb", day: day))
        for i in 0..<7 { _ = try c.addPlanItem(title: "\(i)", day: tomorrow) }
        XCTAssertThrowsError(try c.addPlanItem(title: "11e", day: tomorrow))
    }
    @MainActor func testPromptOneReminderAndStatusChangesOnly() throws {
        let s = store(); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 7))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        var changes = 0; c.onStatusChange = { _ in changes += 1 }
        c.observe(.init(at: now, input: true, context: "a")); XCTAssertEqual(c.panel?.kind, .morning)
        c.observe(.init(at: now, input: true, context: "a")); XCTAssertEqual(changes, 1)
        c.promptLater(); now = now.addingTimeInterval(1800); c.refresh(); XCTAssertEqual(c.panel?.kind, .morning)
        c.promptLater(); now = now.addingTimeInterval(1800); c.refresh(); XCTAssertNil(c.panel)
        let restored = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        restored.observe(.init(at: now, input: true, context: "a")); XCTAssertNil(restored.panel)
    }
    @MainActor func testCLIPlanJSONRoundTripAndEveryRoute() throws {
        let s = store(); try quiet(s)
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let runtime = ConcentrationRuntime(storeFactory: { s }, factory: { try ConcentrationController(store: $0) }, presentsPanels: false); runtime.start(modules: GoalongModuleStore(defaults: defaults))
        let add = try GoalongFocusCLI.parse(command: "plan", arguments: ["add", "Écrire", "--estimate", "30"])
        let shown = try runtime.handle(add)
        let set = try GoalongFocusCLI.parse(command: "plan", arguments: ["set", "--file", "-"], readFile: { _ in shown })
        XCTAssertEqual(try runtime.handle(set), shown)
        let value = try FocusJSON.decode(FocusPlan.self, from: shown), id = value.items[0].id.uuidString
        for action in ["done", "drop"] { _ = try runtime.handle(GoalongFocusCLI.parse(command: "plan", arguments: [action, id])) }
        for command in ["focus status", "session current", "sessions", "plan show", "review show", "limits"] {
            let p = command.split(separator: " ").map(String.init)
            _ = try runtime.handle(GoalongFocusCLI.parse(command: p[0], arguments: Array(p.dropFirst())))
        }
        _ = try runtime.handle(GoalongFocusCLI.parse(command: "session", arguments: ["start", "--intent", "Lire", "--open"]))
        _ = try runtime.handle(GoalongFocusCLI.parse(command: "session", arguments: ["stop", "--outcome", "partly", "--note", "Suite demain"]))
        XCTAssertThrowsError(try runtime.handle(.init(command: "session skip"))) { XCTAssertEqual($0 as? GoalongFocusError, .notFound) }
        let body = Data("{\"items\":[{\"outcome\":\"done\"}]}".utf8)
        _ = try runtime.handle(GoalongFocusCLI.parse(command: "review", arguments: ["set", "--file", "-"], readFile: { _ in body }))
        XCTAssertEqual(runtime.controller?.review?.items.first?.id.uuidString, id)
        XCTAssertThrowsError(try runtime.handle(.init(command: "plan add", options: ["title": "Invalid", "--estimate": "9999"])))
    }
    @MainActor func testForwardClockJumpCannotCutFocusLockShort() throws {
        let s = store(); try quiet(s); var now = Date(timeIntervalSince1970: 1791201600), uptime = 100.0
        let list = BlockList(name: "Travail")
        let b = BlockingController(document: .init(lists: [list]), clock: { now }, continuous: { uptime }, boot: { "boot" })
        let c = try ConcentrationController(store: s, clock: { now }, blocking: { b })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 5), blockListIds: [list.id], lock: true)
        now = now.addingTimeInterval(1800); uptime += 1; c.refresh()
        XCTAssertTrue(c.hasLockedBlock); XCTAssertEqual(c.phase?.kind, .work)
        XCTAssertThrowsError(try c.stopSession()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
    }
    @MainActor func testEarnedCreditFailureStillEndsTheSessionInMemory() throws {
        let s = store(); try quiet(s); var now = Date(timeIntervalSince1970: 1791453600)
        let list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init())
        var document = BlockingDocument(lists: [list]), usage = BlockDayUsage(day: BlockingController.dayKey(now))
        usage.earnedSessionIDs = (0..<4096).map { _ in UUID() }; document.usage = usage
        let b = BlockingController(document: document, clock: { now }, continuous: { now.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { now }, blocking: { b })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 60), blockListIds: [list.id])
        now = now.addingTimeInterval(600)
        XCTAssertNoThrow(try c.stopSession(outcome: .done))
        XCTAssertNil(c.currentSession); XCTAssertNil(c.phase); XCTAssertTrue(b.activeBlocks.isEmpty); XCTAssertNotNil(c.error)
        XCTAssertEqual(c.sessions.last?.events.filter { $0.kind == .stop }.count, 1)
        // A timed session reaching its end through refresh also ends once.
        try c.startSession(intent: "Lire", mode: FocusMode(minutes: 5))
        now = now.addingTimeInterval(300); c.refresh(); c.refresh()
        XCTAssertNil(c.currentSession)
        XCTAssertEqual(c.sessions.last?.events.filter { $0.kind == .stop }.count, 1)
        XCTAssertEqual(c.sessions.last?.events.last?.reason, .completed)
    }
    @MainActor func testReviewPanelKeepsCLINoteAndSessionAfterMidnight() throws {
        let s = store(); try quiet(s); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 23, minute: 30))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil))
        now = now.addingTimeInterval(50 * 60); c.refresh()
        try c.stopSession(outcome: .partly, note: "reste les tests")
        XCTAssertEqual(c.panel?.kind, .sessionReview)
        XCTAssertFalse(c.sessions.contains { $0.id == c.panel?.sessionID }, "the session is stored under its start day")
        let reviewed = try XCTUnwrap(c.reviewedSession); XCTAssertEqual(reviewed.id, c.panel?.sessionID)
        XCTAssertEqual(reviewed.intent, "Écrire"); XCTAssertEqual(reviewed.note, "reste les tests")
        XCTAssertEqual(FocusPanelMath.workSeconds(reviewed), 50 * 60, accuracy: 1)
        try c.recordOutcome(sessionID: reviewed.id, outcome: .done, note: reviewed.note)
        XCTAssertNil(c.reviewedSession)
        let saved = try s.sessions("2026-10-05").first { $0.id == reviewed.id }
        XCTAssertEqual(saved?.outcome, .done); XCTAssertEqual(saved?.note, "reste les tests")
    }
    @MainActor func testDayKeysStayCivilGregorianWithABuddhistSystemCalendar() throws {
        let s = store(); try quiet(s); var calendar = Calendar(identifier: .buddhist); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = Date(timeIntervalSince1970: 1791201600)
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let today = FocusCalendar.dayKey(now, calendar: calendar)
        XCTAssertTrue(today.hasPrefix("2026-")); XCTAssertEqual(c.plan.day, today)
        _ = try c.setCommitment(period: .init(kind: .day, key: today), kind: .sessions, target: 1)
        XCTAssertNotNil(c.todayCommitment)
        XCTAssertEqual(try c.dayAfter("2026-10-31"), "2026-11-01")
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertEqual(try s.sessions(today).count, 1)
    }
    @MainActor func testReviewSavedAfterMidnightMovesItemsToTheDayAfterThePlan() throws {
        let s = store(); try quiet(s); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 23, minute: 50))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let item = try c.addPlanItem(title: "Rédiger", day: "2026-10-05")
        now = now.addingTimeInterval(15 * 60); c.refresh()   // 00:05 on 2026-10-06
        // The sheet path: it used Date() + 1 day, which gave 2026-10-07 here.
        let review = try ConcentrationReviewSheet.review(of: try c.plan(on: "2026-10-05"), choices: [item.id: .tomorrow],
                                                         tomorrowFirst: " Relire ", note: "", controller: c)
        XCTAssertEqual(review.items.first?.toDay, "2026-10-06"); XCTAssertEqual(review.tomorrowFirst, "Relire")
        try c.setReview(review)
        XCTAssertEqual(try c.plan(on: "2026-10-06").items.map(\.title), ["Relire", "Rédiger"])
        XCTAssertTrue(try c.plan(on: "2026-10-07").items.isEmpty)
    }
    @MainActor func testReReviewWithdrawsOnlyTheStillOpenMovedCopy() throws {
        let s = store(); try quiet(s); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 20))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let (d0, d1, d2) = ("2026-10-05", "2026-10-06", "2026-10-07")
        let item = try c.addPlanItem(title: "Rédiger", day: d0), human = try c.addPlanItem(title: "Appeler", day: d1)
        // (a) moved, then answered done: the open copy leaves tomorrow; the human item stays.
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, toDay: d1)], tomorrowFirst: "Relire"))
        XCTAssertTrue(try c.plan(on: d1).items.contains { $0.id == item.id })
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, outcome: .done)], tomorrowFirst: "Relire"))
        XCTAssertEqual(try c.plan(on: d1).items.map(\.title), ["Relire", "Appeler"])
        XCTAssertEqual(try c.plan(on: d0).items.first?.status, .done)
        // (b) moved to D+1, then to D+2: one copy, in D+2 only.
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, toDay: d1)]))
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, toDay: d2)]))
        XCTAssertFalse(try c.plan(on: d1).items.contains { $0.id == item.id })
        XCTAssertEqual(try c.plan(on: d2).items.filter { $0.id == item.id }.count, 1)
        // (c) a copy finished in its new day stays when the review changes again.
        try c.setItemStatus(item.id, day: d2, status: .done)
        try c.setReview(FocusReview(day: d0, items: [.init(id: item.id, outcome: .notDone)]))
        XCTAssertEqual(try c.plan(on: d2).items.first { $0.id == item.id }?.status, .done)
        // (d) a removal that empties the day is saved without error; reopen also withdraws the copy.
        try c.movePlanItem(item.id, day: d0, to: "2026-10-08")
        try c.reopenPlanItem(item.id, day: d0)
        XCTAssertTrue(try c.plan(on: "2026-10-08").items.isEmpty)
        XCTAssertEqual(try c.plan(on: d0).items.first?.status, .open)
        XCTAssertTrue(try c.plan(on: d1).items.contains { $0.id == human.id })
    }
    @MainActor func testSessionsCommitmentProgressCountsOldOpenSessionsAndFollowsNewStops() throws {
        let s = store(); try quiet(s); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // An open session started three days before the week (2026-W41 starts Monday 5 October).
        var now = calendar.date(from: .init(year: 2026, month: 10, day: 2, hour: 9))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        try c.startSession(intent: "Longue", mode: FocusMode(minutes: nil))
        now = calendar.date(from: .init(year: 2026, month: 10, day: 5, hour: 9))!; c.refresh()
        let week = FocusCommitmentPeriod(kind: .week, key: "2026-W41")
        let value = try c.setCommitment(period: week, kind: .sessions, target: 3)
        now = now.addingTimeInterval(1800)
        XCTAssertEqual(try c.commitmentProgress(value).measured, 1)
        try c.stopSession()
        try c.startSession(intent: "Courte", mode: FocusMode(minutes: 20))
        now = now.addingTimeInterval(20 * 60); c.refresh()
        XCTAssertNil(c.currentSession)
        // The cached days follow every stop this controller writes.
        XCTAssertEqual(try c.commitmentProgress(value).measured, 2)
        XCTAssertEqual(try ConcentrationController(store: s, clock: { now }, calendar: calendar).commitmentProgress(value).measured, 2)
        // Decoded once: an outside rewrite of the old day file is not read again by this controller.
        try s.saveSessions([], day: "2026-10-02")
        XCTAssertEqual(try c.commitmentProgress(value).measured, 2)
        XCTAssertEqual(try ConcentrationController(store: s, clock: { now }, calendar: calendar).commitmentProgress(value).measured, 1)
    }
}
extension ConcentrationControllerTests {
    @MainActor func testAmbianceAdapterPicksAnInstalledFocusSourceAndNothingElse() {
        let sources = [AmbianceSource(id: "calm", title: "Calme", kind: .focus, isAvailable: false),
                       AmbianceSource(id: "rain", title: "Pluie", kind: .texture, isAvailable: true),
                       AmbianceSource(id: "deep", title: "Profond", kind: .focus, isAvailable: true),
                       AmbianceSource(id: "flow", title: "Flux", kind: .focus, isAvailable: true)]
        XCTAssertEqual(AmbianceFocusSessionAudio.focusSource(in: sources, last: "flow")?.id, "flow")
        XCTAssertEqual(AmbianceFocusSessionAudio.focusSource(in: sources, last: "rain")?.id, "deep")
        XCTAssertEqual(AmbianceFocusSessionAudio.focusSource(in: sources, last: "calm")?.id, "deep")
        XCTAssertNil(AmbianceFocusSessionAudio.focusSource(in: Array(sources.prefix(2)), last: nil))
    }

    @MainActor func testAmbianceAdapterIsSilentWhileTheModuleIsOff() {
        var asked = 0
        let audio = AmbianceFocusSessionAudio(controller: { asked += 1; return nil }, lastSource: { nil })
        audio.startWork(); audio.startBreak(); audio.stop()
        XCTAssertGreaterThan(asked, 0)
    }

    @MainActor func testRuntimeHandsItsAudioToTheController() throws {
        let s = store(); try quiet(s)
        let spy = AudioSpy()
        let runtime = ConcentrationRuntime(storeFactory: { s }, blockingProvider: { nil }, presentsPanels: false)
        runtime.audio = spy
        runtime.apply(enabled: true)
        defer { runtime.apply(enabled: false) }
        let controller = try XCTUnwrap(runtime.controller)
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 5
        try controller.startSession(intent: "Code", mode: mode, ambiance: true)
        XCTAssertEqual(spy.actions.first, "work")
    }
}

private final class AudioSpy: FocusSessionAudio {
    var actions: [String] = []
    func startWork() { actions.append("work") }; func startBreak() { actions.append("break") }; func stop() { actions.append("stop") }
}
#endif
