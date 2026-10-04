#if os(macOS)
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
        XCTAssertFalse(DashboardSection.sidebarSections(modules: modules.enabled).contains(.concentration))
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

}
private final class AudioSpy: FocusSessionAudio {
    var actions: [String] = []
    func startWork() { actions.append("work") }; func startBreak() { actions.append("break") }; func stop() { actions.append("stop") }
}
#endif
