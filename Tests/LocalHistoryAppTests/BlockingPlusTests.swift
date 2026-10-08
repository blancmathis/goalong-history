#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import LocalHistoryApp

final class BlockingPlusTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func date(_ day: Int = 8, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private let editor = BlockAppRule(bundleIdentifier: "example.editor", name: "Éditeur")
    private let secondEditor = BlockAppRule(bundleIdentifier: "example.othereditor", name: "Autre éditeur")
    private func target(_ at: Date, url: String = "example.org/a", browser: Bool = true, activation: Bool = false) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: browser ? "com.google.Chrome" : "example.game", pid: 42000,
                            windowFrame: nil, isBrowser: browser, url: browser ? url : nil, privateWindow: false,
                            at: at, isActivation: activation)
    }
    private func completed(minutes: Int, ending end: Date, reason: FocusSession.Event.Reason = .completed) -> FocusSession {
        let start = end.addingTimeInterval(-Double(minutes * 60))
        return FocusSession(intent: "Travail", mode: FocusMode(minutes: max(5, minutes)), startedAt: start,
                            events: [.init(kind: .start, at: start), .init(kind: .stop, at: end, reason: reason)])
    }
    private func store() -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp/blocking-plus-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return BlockingStore(directory: root)
    }

    func testReasonNormalizationAndLimits() {
        XCTAssertEqual(BlockingRules.normalizeReason(" \nPour écrire. \t"), "Pour écrire.")
        XCTAssertNil(BlockingRules.normalizeReason(" \n"))
        XCTAssertNotNil(BlockingRules.normalizeReason(String(repeating: "é", count: 140)))
        XCTAssertNil(BlockingRules.normalizeReason(String(repeating: "é", count: 141)))
    }
    @MainActor func testReasonSavesTrimmedAndClearsEvenUnderLock() {
        let now = date(); var list = BlockList(name: "Sites"); list.program.lockedUntil = now.addingTimeInterval(600)
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        XCTAssertEqual(c.setReason("  Mon chapitre  ", for: list.id), .allowed)
        XCTAssertEqual(c.list(list.id)?.reason, "Mon chapitre")
        XCTAssertEqual(c.feedback(for: list.id).reasonLine, "« Mon chapitre »")
        XCTAssertNotEqual(c.setReason(String(repeating: "x", count: 141), for: list.id), .allowed)
        XCTAssertEqual(c.list(list.id)?.reason, "Mon chapitre")
        XCTAssertEqual(c.setReason(" \n ", for: list.id), .allowed); XCTAssertNil(c.list(list.id)?.reason)
    }
    @MainActor func testReasonEditableDuringPasswordBlock() throws {
        let now = date(), list = BlockList(name: "Sites"), password = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let c = BlockingController(document: .init(lists: [list], passwordLock: password), clock: { now })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .password)
        XCTAssertEqual(c.setReason("Pour mon projet.", for: list.id), .allowed)
        XCTAssertTrue(c.hasLocks)
    }
    @MainActor func testAttemptDedupWithinTenSecondsAndExactlyAtBoundary() {
        var now = date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")])
        let backend = PlusBackend(), c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now)); XCTAssertEqual(c.attemptsToday[list.id], 1)
        c.observe(target(now, url: "allowed.org"))
        now = now.addingTimeInterval(9); c.observe(target(now, url: "example.org/b"))
        XCTAssertEqual(c.attemptsToday[list.id], 1)
        c.observe(target(now, url: "allowed.org"))
        now = now.addingTimeInterval(1); c.observe(target(now))
        XCTAssertEqual(c.attemptsToday[list.id], 2)
        XCTAssertEqual(backend.lastFeedback?.attemptLine, "2ᵉ tentative aujourd’hui")
    }
    @MainActor func testContinuousVeilIsOneAttemptAndDifferentHostsCountSeparately() {
        var now = date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")], reason: "Mon projet.")
        let backend = PlusBackend(), c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        c.observe(target(now, activation: true))
        now = now.addingTimeInterval(30); c.refresh()
        XCTAssertEqual(c.attemptsToday[list.id], 1) // Reenforcement is not a fresh activation.
        c.observe(target(now, url: "other.example.org/a"))
        XCTAssertEqual(c.attemptsToday[list.id], 2); XCTAssertEqual(c.totalAttemptsToday, 2)
        XCTAssertEqual(backend.lastFeedback?.reasonLine, "« Mon projet. »")
    }
    @MainActor func testAttemptsAreIndependentPerListAndAppBundle() {
        let now = date(), a = BlockList(name: "A", sites: [.init(pattern: "example.org")]), b = BlockList(name: "B", sites: [.init(pattern: "example.org")])
        let backend = PlusBackend(), c = BlockingController(document: .init(lists: [a,b]), clock: { now }, backend: backend)
        c.start(listIDs: [a.id], until: now.addingTimeInterval(600), lock: .free); c.observe(target(now))
        c.stop(c.activeBlocks[0].id)
        c.start(listIDs: [b.id], until: now.addingTimeInterval(600), lock: .free); c.observe(target(now))
        XCTAssertEqual(c.attemptsToday[a.id], 1); XCTAssertEqual(c.attemptsToday[b.id], 1); XCTAssertEqual(c.totalAttemptsToday, 2)
        let apps = BlockList(name: "Apps", apps: [.init(bundleIdentifier: "example.game", name: "Jeu")])
        let appC = BlockingController(document: .init(lists: [apps]), clock: { now }, backend: PlusBackend())
        appC.start(listIDs: [apps.id], until: now.addingTimeInterval(600), lock: .free)
        appC.observe(target(now, browser: false, activation: true)); appC.observe(target(now, browser: false, activation: true))
        XCTAssertEqual(appC.attemptsToday[apps.id], 1)
    }
    @MainActor func testNoAttemptWithoutActualPresentationOrForSlowDown() {
        let now = date(), list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")])
        let backend = PlusBackend(); backend.presents = false
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, backend: backend)
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free); c.observe(target(now))
        XCTAssertEqual(c.totalAttemptsToday, 0)
        var slow = list; slow.action = .slowDown; c.save(slow); backend.presents = true; c.observe(target(now))
        XCTAssertEqual(c.totalAttemptsToday, 0); XCTAssertEqual(c.snapshot.usage?.slowDownShown?[list.id], 1)
    }
    @MainActor func testAttemptPersistenceAndMidnightHistoryContainOnlyCounters() throws {
        var now = date(8,23,59); let day = BlockingController.dayKey(now, calendar: calendar)
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")]), s = store()
        try s.save(.init(lists: [list]))
        let c = BlockingController(clock: { now }, store: s, backend: PlusBackend(), calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free); c.observe(target(now))
        XCTAssertEqual(try s.load().usage?.blocked?[list.id], 1)
        now = now.addingTimeInterval(61); c.refresh()
        XCTAssertEqual(c.totalAttemptsToday, 0); XCTAssertEqual(c.frictionCounts(day: day).blocked?[list.id], 1)
        c.observe(target(now, url: "allowed.org")); c.observe(target(now)); XCTAssertEqual(c.totalAttemptsToday, 1)
        let json = String(data: try JSONEncoder().encode(c.snapshot), encoding: .utf8)!
        XCTAssertFalse(json.contains("host:")); XCTAssertFalse(json.contains("example.org/a"))
        XCTAssertEqual(try s.load().usageHistory?[day]?.blocked?[list.id], 1)
    }
    @MainActor func testTriggersStartFromRunningBackgroundInventoryAndEndAfterLastQuit() {
        var now = date(), running: Set<String> = [editor.bundleIdentifier]
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")], triggers: .init(apps: [editor,secondEditor]))
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, continuous: { now.timeIntervalSince1970 }, runningApps: { running })
        XCTAssertEqual(c.activeBlocks.count, 1); XCTAssertEqual(c.activeBlocks.first?.origin, .trigger(list.id)); XCTAssertEqual(c.activeBlocks.first?.lock, .free)
        let sessionID = c.activeBlocks.first?.id
        running.insert(secondEditor.bundleIdentifier); c.refresh(); XCTAssertEqual(c.activeBlocks.first?.id, sessionID)
        running.remove(editor.bundleIdentifier); c.refresh(); XCTAssertEqual(c.activeBlocks.count, 1)
        running.removeAll(); now = now.addingTimeInterval(5); c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty)
    }
    @MainActor func testExistingLaunchObservationStartsTriggerImmediatelyAndIsIdempotent() {
        let now = date(); var running: Set<String> = []
        let list = BlockList(name: "Sites", triggers: .init(apps: [editor]))
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, runningApps: { running })
        XCTAssertTrue(c.activeBlocks.isEmpty); running.insert(editor.bundleIdentifier)
        c.observe(target(now, browser: false, activation: true)); XCTAssertEqual(c.activeBlocks.count, 1)
        let id = c.activeBlocks[0].id; c.observe(target(now, browser: false, activation: true))
        XCTAssertEqual(c.activeBlocks.map(\.id), [id])
    }
    @MainActor func testTriggerQuitIsDetectedByExistingControllerTimer() async {
        var running: Set<String> = [editor.bundleIdentifier]
        let list = BlockList(name: "Sites", triggers: .init(apps: [editor]))
        let c = BlockingController(document: .init(lists: [list]), runsTimers: true, runningApps: { running })
        defer { c.shutdown() }
        XCTAssertTrue(c.hasTimer); XCTAssertEqual(c.activeBlocks.count, 1)
        let ended = expectation(description: "last triggering app quit")
        let subscription = c.$activeBlocks.dropFirst().filter(\.isEmpty).prefix(1).sink { _ in ended.fulfill() }
        running.removeAll()
        await fulfillment(of: [ended], timeout: 5.5)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(c.activeBlocks.isEmpty)
    }
    @MainActor func testStoppingFreeTriggerWaitsUntilAllTriggerAppsQuitBeforeRearming() {
        let now = date(); var running: Set<String> = [editor.bundleIdentifier]
        let list = BlockList(name: "Sites", triggers: .init(apps: [editor]))
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, runningApps: { running })
        c.stop(c.activeBlocks[0].id); c.refresh(); XCTAssertTrue(c.activeBlocks.isEmpty)
        running.removeAll(); c.refresh(); running.insert(editor.bundleIdentifier); c.refresh()
        XCTAssertEqual(c.activeBlocks.count, 1)
    }
    @MainActor func testNoTriggerInventoryReadOrTimerWithoutConfiguredApps() {
        var reads = 0; let c = BlockingController(runsTimers: true, runningApps: { reads += 1; return [] })
        c.refresh(); XCTAssertEqual(reads, 0); XCTAssertFalse(c.hasTimer); c.shutdown()
    }
    @MainActor func testStalePersistedTriggerRemovedOnRelaunchAndManualSessionPreserved() throws {
        let now = date(), list = BlockList(name: "Sites", triggers: .init(apps: [editor]))
        let trigger = BlockSession(listIDs: [list.id], start: now.addingTimeInterval(-60), end: .distantFuture, lock: .free, origin: .trigger(list.id))
        let manual = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(600), lock: .locked)
        let s = store(); try s.save(.init(lists: [list], sessions: [trigger,manual]))
        let c = BlockingController(clock: { now }, store: s, runningApps: { [] })
        XCTAssertEqual(c.activeBlocks.map(\.id), [manual.id]); XCTAssertEqual(try s.load().sessions.map(\.id), [manual.id])
    }
    @MainActor func testRefusesNeverBlockedAppsConflictsDuplicatesAndUnavailableFocus() {
        let now = date(), list = BlockList(name: "Apps", apps: [editor])
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        for id in BlockingRules.neverBlocked { XCTAssertNotEqual(c.addAppTrigger(.init(bundleIdentifier: id, name: "App"), to: list.id), .allowed) }
        XCTAssertNotEqual(c.addAppTrigger(editor, to: list.id), .allowed)
        XCTAssertNotEqual(c.setTriggers(.init(apps: [secondEditor,secondEditor]), for: list.id), .allowed)
        let focusCheck = c.setTriggers(.init(focus: true), for: list.id)
        if case .refused(let reason) = focusCheck { XCTAssertTrue(reason.contains("Focus")) }
        else { XCTFail("Unavailable Focus must return an explicit refusal") }
        XCTAssertNil(c.list(list.id)?.triggers)
        var allow = BlockList(name: "Travail", mode: .allowOnly, apps: [editor], triggers: .init(apps: [editor]))
        XCTAssertTrue(BlockingRules.validate(.init(lists: [allow])))
        allow.triggers = .init(apps: [secondEditor]); XCTAssertFalse(BlockingRules.validate(.init(lists: [allow])))
    }
    @MainActor func testTriggerLockAllowsAdditionAndRefusesEveryRemovalPath() {
        let now = date(); var list = BlockList(name: "Sites", triggers: .init(apps: [editor])); list.program.lockedUntil = now.addingTimeInterval(600)
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, runningApps: { [] })
        XCTAssertEqual(c.addAppTrigger(secondEditor, to: list.id), .allowed)
        XCTAssertNotEqual(c.removeAppTrigger(editor, from: list.id), .allowed)
        XCTAssertNotEqual(c.setTriggers(nil, for: list.id), .allowed)
        var next = c.list(list.id)!; next.triggers?.apps.removeAll(); c.save(next)
        XCTAssertEqual(c.list(list.id)?.triggers?.apps.count, 2)
    }
    func testEarnArithmeticFloorsCapsAndRejectsNonFiniteInput() {
        let earn = BlockEarn()
        XCTAssertEqual(earn.rewardSeconds(focusedSeconds: 24 * 60 + 59), 0)
        XCTAssertEqual(earn.rewardSeconds(focusedSeconds: 25 * 60), 5 * 60)
        XCTAssertEqual(earn.rewardSeconds(focusedSeconds: 76 * 60), 15 * 60)
        XCTAssertEqual(earn.rewardSeconds(focusedSeconds: 99999), 60 * 60)
        for seconds in [-1, Double.nan, Double.infinity] { XCTAssertEqual(earn.rewardSeconds(focusedSeconds: seconds), 0) }
    }
    @MainActor func testRewardsEveryEligibleListPerDayWithIndependentCaps() throws {
        let now = date(), a = BlockList(name: "A", quotaMinutesPerDay: 10, earn: .init(capMinutes: 5)), b = BlockList(name: "B", quotaMinutesPerDay: 20, earn: .init(rewardMinutes: 10, capMinutes: 30)), plain = BlockList(name: "Sans gain", quotaMinutesPerDay: 15)
        let c = BlockingController(document: .init(lists: [a,b,plain]), clock: { now }, calendar: calendar)
        let session = completed(minutes: 76, ending: now)
        XCTAssertEqual(try c.creditEarnedTime(for: session), [a.id:300,b.id:1800])
        XCTAssertEqual(c.earnedMinutesToday, [a.id:5,b.id:30]); XCTAssertNil(c.earnedMinutesToday[plain.id])
        XCTAssertTrue(try c.creditEarnedTime(for: completed(minutes: 50, ending: now)).isEmpty)
        XCTAssertEqual(c.feedback(for: b.id).earnedLine, "+30 min gagnées")
    }
    @MainActor func testRewardReceiptPersistsAndReplayCannotPayTwice() throws {
        let now = date(), list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init()), s = store()
        try s.save(.init(lists: [list]))
        let session = completed(minutes: 50, ending: now)
        let c = BlockingController(clock: { now }, store: s, calendar: calendar)
        XCTAssertEqual(try c.creditEarnedTime(for: session)[list.id], 600)
        let restored = BlockingController(clock: { now }, store: s, calendar: calendar)
        XCTAssertTrue(try restored.creditEarnedTime(for: session).isEmpty)
        XCTAssertEqual(restored.earnedMinutesToday[list.id], 10)
        XCTAssertEqual(try s.load().usage?.earnedSessionIDs, [session.id])
    }
    @MainActor func testSpanningMidnightCreditsEndingDayAndLateCompletionUsesHistory() throws {
        var now = date(9,0,10); let list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init())
        let c = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        XCTAssertEqual(try c.creditEarnedTime(for: completed(minutes: 50, ending: now))[list.id], 600)
        XCTAssertEqual(c.snapshot.usage?.day, "2026-10-09"); XCTAssertNil(c.snapshot.usageHistory?["2026-10-08"])
        now = date(10,0,10); c.refresh()
        XCTAssertEqual(c.earnedMinutesToday[list.id] ?? 0, 0)
        XCTAssertEqual(c.frictionCounts(day: "2026-10-09").earnedSeconds?[list.id], 600)
        XCTAssertEqual(try c.creditEarnedTime(for: completed(minutes: 25, ending: date(9,23,59)))[list.id], 300)
        XCTAssertEqual(c.snapshot.usageHistory?["2026-10-09"]?.earnedSeconds?[list.id], 900)
        XCTAssertEqual(c.earnedMinutesToday[list.id] ?? 0, 0)
    }
    @MainActor func testAbandonedCancelledModuleDisabledAndUnfinishedSessionsEarnNothing() throws {
        let now = date(), list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init())
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        for reason in [FocusSession.Event.Reason.member, .appClosed, .moduleDisabled] {
            XCTAssertTrue(try c.creditEarnedTime(for: completed(minutes: 50, ending: now, reason: reason)).isEmpty)
        }
        var unfinished = completed(minutes: 50, ending: now); unfinished.events.removeLast()
        XCTAssertTrue(try c.creditEarnedTime(for: unfinished).isEmpty)
        XCTAssertTrue(c.earnedMinutesToday.isEmpty); XCTAssertNil(c.snapshot.usage?.earnedSessionIDs)
    }
    func testPomodoroRewardsExcludeBreaksAndSkippedWork() {
        let start = date(), mode = FocusMode(kind: .pomodoro, workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 4, cycles: 2)
        let end = start.addingTimeInterval(55 * 60)
        var session = FocusSession(intent: "Travail", mode: mode, startedAt: start, events: [.init(kind: .start, at: start),.init(kind: .stop, at: end, reason: .completed)])
        XCTAssertEqual(BlockingRules.earnedWorkSeconds(session), 50 * 60)
        session.events.insert(.init(kind: .skip, at: start.addingTimeInterval(10 * 60)), at: 1)
        session.events[2].at = start.addingTimeInterval(40 * 60)
        XCTAssertEqual(BlockingRules.earnedWorkSeconds(session), 35 * 60)
    }
    @MainActor func testEarnStrictnessUnderLockIncludingWorkThresholdAndQuotaRemoval() {
        let now = date(); var list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init()); list.program.lockedUntil = now.addingTimeInterval(600)
        let c = BlockingController(document: .init(lists: [list]), clock: { now })
        for next in [BlockEarn(workMinutes: 24), .init(rewardMinutes: 6), .init(capMinutes: 61)] { XCTAssertNotEqual(c.setEarn(next, for: list.id), .allowed) }
        XCTAssertEqual(c.setEarn(.init(workMinutes: 30, rewardMinutes: 4, capMinutes: 50), for: list.id), .allowed)
        XCTAssertEqual(c.setEarn(nil, for: list.id), .allowed); XCTAssertNotEqual(c.setEarn(.init(), for: list.id), .allowed)
        var next = c.list(list.id)!; next.quotaMinutesPerDay = nil; c.save(next); XCTAssertNil(c.list(list.id)?.quotaMinutesPerDay)
        next.earn = .init(); c.save(next); XCTAssertNil(c.list(list.id)?.earn)
    }
    @MainActor func testEarnedQuotaAffectsAllEnforcementAndUsagePaths() throws {
        var now = date(); let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")], quotaMinutesPerDay: 1, earn: .init())
        let usage = BlockDayUsage(day: BlockingController.dayKey(now, calendar: calendar), quotaSecondsUsed: [list.id:60])
        let backend = PlusBackend(), c = BlockingController(document: .init(lists: [list], usage: usage), clock: { now }, backend: backend, calendar: calendar, continuous: { now.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(3600), lock: .free)
        c.observe(target(now)); XCTAssertEqual(c.totalAttemptsToday, 1); XCTAssertTrue(c.siteActionStillRequired(target(now)))
        _ = try c.creditEarnedTime(for: completed(minutes: 25, ending: now))
        XCTAssertEqual(c.activeBlocks.first?.quotaSecondsLeft[list.id], 300); XCTAssertFalse(c.siteActionStillRequired(target(now)))
        for _ in 0..<20 { now = now.addingTimeInterval(15); c.observe(target(now)) }
        XCTAssertEqual(c.snapshot.usage?.quotaSecondsUsed[list.id], 360)
        XCTAssertEqual(c.activeBlocks.first?.quotaSecondsLeft[list.id], 0); XCTAssertTrue(c.siteActionStillRequired(target(now)))
        XCTAssertEqual(c.totalAttemptsToday, 2)
    }
    func testOldSchemaOneDecodesWithEveryNewFieldAbsentAndNewValuesRoundTrip() throws {
        let old = BlockList(name: "Ancienne", quotaMinutesPerDay: 10)
        let data = try JSONEncoder().encode(BlockingDocument(lists: [old], usage: .init(day: "2026-10-08")))
        let decoded = try JSONDecoder().decode(BlockingDocument.self, from: data)
        XCTAssertNil(decoded.lists[0].reason); XCTAssertNil(decoded.lists[0].triggers); XCTAssertNil(decoded.lists[0].earn)
        XCTAssertNil(decoded.usage?.blocked); XCTAssertNil(decoded.usage?.earnedSeconds); XCTAssertNil(decoded.usage?.earnedSessionIDs)
        XCTAssertTrue(BlockingRules.validate(decoded))
        var next = decoded; next.lists[0].reason = "Mon projet."; next.lists[0].triggers = .init(apps: [editor]); next.lists[0].earn = .init()
        next.usage?.blocked = [old.id:3]; next.usage?.earnedSeconds = [old.id:600]; next.usage?.earnedSessionIDs = [UUID()]
        XCTAssertEqual(try JSONDecoder().decode(BlockingDocument.self, from: JSONEncoder().encode(next)), next)
        XCTAssertTrue(BlockingRules.validate(next))
        XCTAssertEqual(try JSONDecoder().decode(BlockEarn.self, from: Data("{}".utf8)), BlockEarn())
        XCTAssertEqual(try JSONDecoder().decode(BlockTriggers.self, from: Data("{}".utf8)), BlockTriggers())
    }
    func testValidationLimitsForEveryNewFieldAndHistoricalCounter() {
        let list = BlockList(name: "Sites", quotaMinutesPerDay: 10, earn: .init())
        for earn in [BlockEarn(workMinutes:9),.init(workMinutes:121),.init(rewardMinutes:0),.init(rewardMinutes:31),.init(capMinutes:4),.init(capMinutes:241)] {
            var bad = list; bad.earn = earn; XCTAssertFalse(BlockingRules.validate(.init(lists:[bad])))
        }
        var bad = list; bad.quotaMinutesPerDay = nil; XCTAssertFalse(BlockingRules.validate(.init(lists:[bad])))
        bad = list; bad.reason = " trailing "; XCTAssertFalse(BlockingRules.validate(.init(lists:[bad])))
        bad.reason = ""; XCTAssertFalse(BlockingRules.validate(.init(lists:[bad])))
        bad = list; bad.triggers = .init(apps: [.init(bundleIdentifier:"",name:"App")]); XCTAssertFalse(BlockingRules.validate(.init(lists:[bad])))
        var usage = BlockDayUsage(day:"2026-10-08"); usage.blocked = [list.id:-1]
        XCTAssertFalse(BlockingRules.validate(.init(lists:[list],usage:usage)))
        for seconds in [-1,Double.nan,Double.infinity,14401] {
            usage.blocked = nil; usage.earnedSeconds = [list.id:seconds]
            XCTAssertFalse(BlockingRules.validate(.init(lists:[list],usageHistory:[usage.day:usage])))
        }
        usage.earnedSeconds = nil; let id = UUID(); usage.earnedSessionIDs = [id,id]
        XCTAssertFalse(BlockingRules.validate(.init(lists:[list],usage:usage)))
        let malformed = BlockSession(listIDs:[list.id],start:date(),end:date().addingTimeInterval(600),lock:.locked,origin:.trigger(list.id))
        XCTAssertFalse(BlockingRules.validate(.init(lists:[list],sessions:[malformed])))
    }
}

@MainActor private final class PlusBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true, canLockScreen = false, presents = true
    var browsers: [BlockingBrowserSupport] = []
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    var onBlockPresented: ((BlockingObservation,UUID) -> BlockingListFeedback?)?
    var lastFeedback: BlockingListFeedback?
    func observeBrowser(_ target: BlockingObservation) {}
    func updateProtection(locked: Bool) -> BlockingProtectionState { .init() }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {
        if presents, let id = block.feedback?.listID { lastFeedback = onBlockPresented?(target,id) }
    }
    func blockSlowDownApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) { blockApp(target,app:app,block:block,listName:listName) }
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) {
        if presents, let id = presentation.feedback?.listID { lastFeedback = onBlockPresented?(target,id) }
    }
    func clearSite() {}
    func updateFreeze(_ freeze: BlockFreeze?) {}
    func returnToShield() {}
    func shutdown() {}
}
#endif
