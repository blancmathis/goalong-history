#if os(macOS)
import XCTest
@testable import LocalHistoryCore
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

final class ConcentrationCommitmentControllerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }
    private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/commitment-controller-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings); return s
    }
    private func modules() -> GoalongModuleStore {
        let key = UUID().uuidString, d = UserDefaults(suiteName: key)!
        addTeardownBlock { d.removePersistentDomain(forName: key) }
        return GoalongModuleStore(defaults: d)
    }
    @MainActor func testCreateEditDeleteWindowUniquenessHorizonAndNeutralLimit() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        var settings = c.settings; settings.limits.dailyHours = 2; try c.updateSettings(settings)
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        let first = try c.setCommitment(period: period, kind: .work, target: 180)
        XCTAssertEqual(c.todayCommitment?.limitHours, 2); XCTAssertNil(c.panel)
        let changed = try c.setCommitment(period: period, kind: .work, target: 30)
        XCTAssertEqual(changed.id, first.id); XCTAssertEqual(c.commitments.count, 1); XCTAssertEqual(changed.edits.count, 1)
        _ = try c.setCommitment(period: period, kind: .sessions, target: 1)
        _ = try c.setCommitment(period: period, kind: .work, target: 30)
        XCTAssertEqual(c.todayCommitment?.editMode, "free")
        now = now.addingTimeInterval(600); c.refresh()
        XCTAssertEqual(c.todayCommitment?.editMode, "harderOnly")
        XCTAssertThrowsError(try c.deleteCommitment(period: period)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertThrowsError(try c.setCommitment(period: period, kind: .sessions, target: 1)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        _ = try c.setCommitment(period: period, kind: .work, target: 60)
        XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-12"), kind: .work, target: 60))
        let future = FocusCommitmentPeriod(kind: .day, key: "2026-10-05")
        _ = try c.setCommitment(period: future, kind: .sessions, target: 1); try c.deleteCommitment(period: future)
        XCTAssertEqual(try s.commitments().count, 1)
    }
    @MainActor func testDayAndWeekSettleOnlyAtRefreshTogetherOnceAndNoStakeJoker() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04"), week = FocusCommitmentPeriod(kind: .week, key: "2026-W40")
        _ = try c.setCommitment(period: day, kind: .plan, target: 1); _ = try c.setCommitment(period: week, kind: .plan, target: 1)
        var panels = 0; c.onPanelChange = { if $0?.kind == .commitment { panels += 1 } }
        now = date("2026-10-05"); c.refresh(); XCTAssertTrue(c.commitments.allSatisfy { $0.result == nil })
        c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.panel?.commitmentIDs.count, 2); XCTAssertEqual(panels, 1)
        XCTAssertTrue(c.commitments.allSatisfy { $0.result?.outcome == .missed })
        c.dismissPanel(); c.applyMeasurements([], hasDefinition: true); XCTAssertNil(c.panel); XCTAssertEqual(panels, 1)
        try c.useCommitmentJoker(period: day); XCTAssertEqual(c.commitmentSeries.day, 1); XCTAssertEqual(c.commitmentJokersLeft.day, 1)
        try c.declareCommitmentHeld(period: week); XCTAssertEqual(c.commitmentSeries.week, 1); XCTAssertEqual(c.commitmentJokersLeft.week, 1)
        XCTAssertEqual(c.commitments.first { $0.period == week }?.result?.declared, true)
        XCTAssertThrowsError(try c.useCommitmentJoker(period: day)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
    }
    @MainActor func testHeldFactsAndActiveFallbackLabelStayFrozenAfterDefinitionChange() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: period, kind: .work, target: 30)
        let start = date("2026-10-04", 0), end = date("2026-10-05", 0)
        let measured = GoalongLocalAnalytics.Day(date: start, end: end, state: .ready, segments: [
            .init(start: start, end: start.addingTimeInterval(1800), kind: .unclassified, application: "Editor", bundleIdentifier: "editor", host: nil)
        ], eventCount: 1, classifierVersions: [])
        now = date("2026-10-05"); c.applyMeasurements([measured], hasDefinition: false)
        XCTAssertEqual(c.commitments[0].result?.outcome, .held); XCTAssertEqual(c.commitmentCards[0].progress.measured, 30)
        XCTAssertTrue(c.commitmentCards[0].progress.usesActiveTime)
        c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.commitmentCards[0].progress.measured, 30); XCTAssertTrue(c.commitmentCards[0].progress.usesActiveTime)
    }
    @MainActor func testStakeLocksEveryOrdinaryReleasePathAndBothModuleSwitchesButJokerReleases() throws {
        let s = try store(); var now = date("2026-10-04")
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")], action: .slowDown)
        let b = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 }, boot: { "test" })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        let value = try c.setCommitment(period: period, kind: .sessions, target: 1, stake: .init(listIds: [list.id]))
        now = date("2026-10-05"); c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(b.activeBlocks.first?.origin, .commitment(value.id)); XCTAssertEqual(b.activeBlocks.first?.lock, .locked)
        XCTAssertEqual(b.lists.first?.effectiveAction, .slowDown); XCTAssertTrue(c.hasLockedBlock); XCTAssertTrue(b.hasLocks)
        b.stop(value.id); b.stop(value.id, typed: b.typingChallenge(for: value.id)); b.delete(list.id)
        var easier = list; easier.sites = []; b.save(easier); b.shutdown()
        XCTAssertEqual(b.snapshot.sessions.count, 1); XCTAssertEqual(b.lists.first?.sites, list.sites)
        XCTAssertThrowsError(try b.startFocusBlock(id: value.id, listIDs: [list.id], until: now.addingTimeInterval(60), lock: .free)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        let modules = modules(); modules.setEnabled(.concentration, true); modules.setEnabled(.blocking, true)
        modules.blockingDisableCheck = { !b.hasLocks }
        let runtime = ConcentrationRuntime(storeFactory: { s }, factory: { _ in c }, blockingProvider: { b }, presentsPanels: false, clock: { now }, calendar: calendar)
        runtime.start(modules: modules)
        modules.setEnabled(.concentration, false); modules.setEnabled(.blocking, false)
        XCTAssertTrue(modules.isEnabled(.concentration)); XCTAssertTrue(modules.isEnabled(.blocking))
        XCTAssertThrowsError(try runtime.deleteData()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        // An unrelated free focus session can still stop; it does not own this stake.
        try c.startSession(intent: "Lire", mode: .init(minutes: 5)); XCTAssertFalse(c.hasLockedSessionBlock)
        try c.stopSession(); XCTAssertTrue(c.hasLockedBlock)
        try c.useCommitmentJoker(period: period)
        XCTAssertTrue(b.activeBlocks.isEmpty); XCTAssertFalse(c.hasLockedBlock)
        XCTAssertEqual(c.commitments[0].result?.stake.state, .cancelled)
    }
    @MainActor func testDeclarationRequiresUnmeasuredOrPlanAndEndsOnlyOwnedBlock() throws {
        let s = try store(); var now = date("2026-10-04")
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")])
        let b = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04"), week = FocusCommitmentPeriod(kind: .week, key: "2026-W40")
        _ = try c.setCommitment(period: day, kind: .work, target: 30, stake: .init(listIds: [list.id])); _ = try c.setCommitment(period: week, kind: .work, target: 60, stake: .init(listIds: [list.id]))
        now = date("2026-10-05"); c.applyMeasurements([], hasDefinition: true); XCTAssertEqual(b.activeBlocks.count, 2)
        try c.declareCommitmentHeld(period: day); XCTAssertEqual(b.activeBlocks.count, 1)
        let result = c.commitments.first { $0.period == day }!.result!
        XCTAssertTrue(result.declared); XCTAssertEqual(result.outcome, .held); XCTAssertNil(result.jokerAt)
        XCTAssertEqual(c.commitmentJokersLeft.day, 2)
        let full = GoalongLocalAnalytics.Day(date: date("2026-09-28", 0), end: date("2026-10-05", 0), state: .ready,
            segments: [.init(start: date("2026-09-28", 0), end: date("2026-10-05", 0), kind: .idle, application: nil, bundleIdentifier: nil, host: nil)], eventCount: 1, classifierVersions: [])
        let s2 = try store(); now = date("2026-10-04")
        let c2 = try ConcentrationController(store: s2, clock: { now }, calendar: calendar)
        _ = try c2.setCommitment(period: day, kind: .work, target: 30)
        now = date("2026-10-05"); c2.applyMeasurements([full], hasDefinition: true)
        XCTAssertThrowsError(try c2.declareCommitmentHeld(period: day)) { XCTAssertEqual($0 as? FocusFailure, .invalidArgument) }
        let manual = UUID(); try b.startFocusBlock(id: manual, listIDs: [list.id], until: now.addingTimeInterval(600), lock: .locked)
        XCTAssertThrowsError(try b.endCommitmentBlock(id: manual)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
    }
    @MainActor func testAppliedAndCancelledStakeRecoverAcrossBothStores() throws {
        let s = try store(); var now = date("2026-10-04")
        let bs = BlockingStore(directory: s.directory.appendingPathComponent("Blocking")), list = BlockList(name: "Sites")
        try bs.save(.init(lists: [list]))
        let b = BlockingController(clock: { now }, store: bs, calendar: calendar, continuous: { now.timeIntervalSince1970 }, boot: { "test" })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: period, kind: .sessions, target: 1, stake: .init(listIds: [list.id]))
        now = date("2026-10-05"); c.applyMeasurements([], hasDefinition: true)
        let b2 = BlockingController(clock: { now }, store: bs, calendar: calendar, continuous: { now.timeIntervalSince1970 }, boot: { "test" })
        let restored = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b2 })
        XCTAssertTrue(restored.hasLockedBlock); XCTAssertNil(restored.panel); XCTAssertEqual(b2.activeBlocks.count, 1)
        var values = try s.commitments(); let id = values[0].id
        values[0].result?.jokerAt = now; values[0].result?.stake = .init(state: .cancelled, blockId: id, at: now)
        try s.saveCommitments(values)
        let released = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b2 })
        XCTAssertFalse(released.hasLockedBlock); XCTAssertTrue(b2.activeBlocks.isEmpty); XCTAssertEqual(released.commitmentJokersLeft.day, 1)
    }
    @MainActor func testPendingApplicationReplayAndMissingListsAtSettle() throws {
        let s = try store(); var now = date("2026-10-04")
        let list = BlockList(name: "One"), removed = BlockList(name: "Removed")
        let b = BlockingController(document: .init(lists: [list, removed]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        var v = try c.setCommitment(period: period, kind: .sessions, target: 1, stake: .init(listIds: [list.id, removed.id]))
        b.delete(removed.id); now = date("2026-10-05")
        // Crash after persisted application intent, before the second-store write.
        v.result = FocusCommitmentRules.settle(v, progress: .init(), at: now, blockingOn: true, listIDs: [list.id], calendar: calendar)
        try s.saveCommitments([v])
        let restored = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        XCTAssertTrue(restored.hasLockedBlock); XCTAssertEqual(b.activeBlocks.first?.listIDs, [list.id])
        now = date("2026-10-05", 12); restored.refresh()
        XCTAssertThrowsError(try restored.useCommitmentJoker(period: period)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
    }
    @MainActor func testJokerZeroAndSkipWindowExpiryAndForwardClockProtection() throws {
        let s = try store(); var now = date("2026-10-04"), uptime = 100.0
        let list = BlockList(name: "One")
        let b = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: period, kind: .plan, target: 1, stake: .init(listIds: [list.id]))
        now = date("2026-10-05"); uptime += 86400; c.applyMeasurements([], hasDefinition: true)
        now = date("2026-10-05", 13); uptime += 1; c.refresh()
        XCTAssertTrue(c.hasLockedBlock); XCTAssertTrue(c.commitmentCards[0].canUseJoker)
        var settings = c.settings; settings.commitmentJokers = .init(day: 0, week: 0); try c.updateSettings(settings)
        XCTAssertThrowsError(try c.useCommitmentJoker(period: period)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        try c.declareCommitmentHeld(period: period); XCTAssertTrue(b.activeBlocks.isEmpty)
    }
    @MainActor func testUnappliedIntentRestoresHonestLateNoListAndBlockingOffReasons() throws {
        for reason in [FocusCommitmentResult.Stake.Reason.late, .noList, .blockingOff] {
            let s = try store(), now = date("2026-10-05", reason == .late ? 13 : 8), id = UUID()
            var v = FocusCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .sessions, target: 1,
                stake: .init(listIds: [id]), createdAt: date("2026-10-04"))
            v.result = .init(settledAt: date("2026-10-05"), measured: 0, unmeasuredMinutes: 0, outcome: .missed, stake: .init(state: .applied, blockId: v.id))
            try s.saveCommitments([v])
            let b = BlockingController(clock: { now }, calendar: calendar)
            let restored = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { reason == .blockingOff ? nil : b })
            XCTAssertEqual(restored.commitments[0].result?.stake.reason, reason)
            XCTAssertEqual(restored.commitments[0].result?.stake.state, .skipped)
        }
    }
    @MainActor func testCLIAllCommitmentRoutesRoundTripProtectedMetadataErrorsAndOffGate() throws {
        let s = try store(); var now = date("2026-10-04"), modules = modules()
        let runtime = ConcentrationRuntime(storeFactory: { s }, presentsPanels: false, clock: { now }, calendar: calendar)
        runtime.start(modules: modules)
        for action in ["show", "set", "delete", "joker", "declare"] {
            XCTAssertThrowsError(try runtime.handle(.init(command: "commitment " + action))) { XCTAssertEqual($0 as? GoalongFocusError, .moduleDisabled) }
        }
        XCTAssertThrowsError(try runtime.handle(.init(command: "commitments"))) { XCTAssertEqual($0 as? GoalongFocusError, .moduleDisabled) }
        modules.setEnabled(.concentration, true)
        func request(_ args: [String]) throws -> Data { try runtime.handle(GoalongFocusCLI.parse(command: "commitment", arguments: args)) }
        let shown = try request(["set", "--day", "today", "--kind", "work", "--target", "7h30"])
        let roundtrip = try GoalongFocusCLI.parse(command: "commitment", arguments: ["set", "--day", "today", "--file", "-"], readFile: { _ in shown })
        XCTAssertEqual(try runtime.handle(roundtrip), shown)
        let before = runtime.controller!.commitments[0]
        var object = try JSONSerialization.jsonObject(with: shown) as! [String: Any]; object["createdAt"] = "2099-01-01T00:00:00Z"; object["id"] = UUID().uuidString; object["result"] = ["outcome": "held"]
        _ = try runtime.handle(GoalongFocusCLI.parse(command: "commitment", arguments: ["set", "--day", "today", "--file", "-"], readFile: { _ in try JSONSerialization.data(withJSONObject: object) }))
        XCTAssertEqual(runtime.controller!.commitments[0], before)
        _ = try request(["delete", "--day", "today"])
        XCTAssertThrowsError(try request(["delete", "--day", "today"])) { XCTAssertEqual($0 as? GoalongFocusError, .notFound) }
        _ = try request(["set", "--day", "today", "--kind", "plan", "--target", "1"])
        _ = try request(["set", "--week", "this", "--kind", "plan", "--target", "1"])
        _ = try request(["show"]); _ = try request(["show", "--week", "next"])
        now = now.addingTimeInterval(600)
        XCTAssertThrowsError(try request(["delete", "--day", "today"])) { XCTAssertEqual($0 as? GoalongFocusError, .locked) }
        XCTAssertThrowsError(try request(["set", "--day", "today", "--kind", "work", "--target", "30m"])) { XCTAssertEqual($0 as? GoalongFocusError, .locked) }
        XCTAssertThrowsError(try request(["set", "--day", "tomorrow", "--kind", "work", "--target", "30m", "--stake", UUID().uuidString])) { XCTAssertEqual($0 as? GoalongFocusError, .moduleDisabled) }
        now = date("2026-10-05"); runtime.controller!.applyMeasurements([], hasDefinition: false)
        _ = try request(["joker", "--day", "2026-10-04"]); _ = try request(["declare", "--week", "2026-W40"])
        let history = try runtime.handle(GoalongFocusCLI.parse(command: "commitments", arguments: ["--from", "2026-10-04", "--to", "2026-10-04"]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: history) as! [String: Any])["commitments"].map { ($0 as! [Any]).count }, 2)
        XCTAssertThrowsError(try runtime.handle(.init(command: "commitment show", options: ["--from": "2026-10-04"]))) { XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument) }
    }
}
#endif
