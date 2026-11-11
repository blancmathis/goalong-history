#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 lot B1 points 3 and 4: the « Surveillance » store, its migration and what runs. Pure: suite defaults, no
/// real controller, no window.
@MainActor final class JevSurveillanceTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    private func defaults() -> UserDefaults {
        let name = "jev-surveillance-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    private func scope(_ value: JevMonitoringScope, in d: UserDefaults) -> JevMonitoringPreferences {
        let p = JevMonitoringPreferences(defaults: d); p.setScope(value); return p
    }
    private var strong: JevInterventionSettings {
        var s = JevInterventionSettings(); s.applyStrength(.strong); s.effectsEnabled = true; return s
    }

    // MARK: Migration (point 4)

    func testMigrationAlwaysBecomesAnAlwaysRuleWithTheSameSettingsAndAFreeStop() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d)
        XCTAssertEqual(store.migrateIfNeeded(consent: true, scope: scope(.always, in: d), settings: strong), .alwaysRule)
        let range = try? XCTUnwrap(store.document.ranges.first)
        XCTAssertEqual(store.document.ranges.count, 1)
        XCTAssertEqual(range?.weekdays, Set(1...7)); XCTAssertEqual(range?.startMinute, 0); XCTAssertEqual(range?.endMinute, 1_440)
        XCTAssertEqual(range?.lock, .free); XCTAssertEqual(range?.settings, strong)
        XCTAssertTrue(range.map { $0.key.isAlways } ?? false, "read back as « Toujours »")
        XCTAssertFalse(store.document.sessionDefault)
        // Nothing starts or stops: it runs at any hour, with or without a session, as « Toujours » did.
        for hours in [0.0, 3, 10, 23.5] {
            let at = now.addingTimeInterval(hours * 3_600)
            XCTAssertEqual(store.active(sessions: JevRunningSessions(), now: at, calendar: paris).map(\.settings), [strong])
        }
        XCTAssertEqual(JevSurveillanceStore(defaults: d).document, store.document, "written once, read back")
    }

    func testMigrationSessionsOnlyBecomesTheSessionDefaultWithTheSameSettings() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d)
        XCTAssertEqual(store.migrateIfNeeded(consent: true, scope: scope(.sessionsOnly, in: d), settings: strong), .sessionDefault)
        XCTAssertTrue(store.document.ranges.isEmpty); XCTAssertTrue(store.document.sessionDefault)
        XCTAssertEqual(store.document.sessionSettings, strong)
        XCTAssertTrue(store.active(sessions: JevRunningSessions(), now: now, calendar: paris).isEmpty, "no session, no surveillance")
        XCTAssertEqual(store.active(sessions: JevRunningSessions(focus: UUID()), now: now, calendar: paris).map(\.settings), [strong],
                       "a Concentration session runs it, as « Pendant mes séances » did")
    }

    func testMigrationWithoutConsentOrWithAnUnreadableScopeCreatesNothing() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d)
        XCTAssertEqual(store.migrateIfNeeded(consent: false, scope: scope(.always, in: d), settings: strong), .nothing)
        XCTAssertTrue(store.document.ranges.isEmpty); XCTAssertFalse(store.document.sessionDefault)
        XCTAssertEqual(store.document.sessionSettings, strong, "the settings are kept for a later rule")
        XCTAssertTrue(store.active(sessions: JevRunningSessions(focus: UUID()), now: now, calendar: paris).isEmpty)

        let bad = defaults(); bad.set(Data("bad".utf8), forKey: JevMonitoringPreferences.storageKey)
        let badStore = JevSurveillanceStore(defaults: bad)
        XCTAssertEqual(badStore.migrateIfNeeded(consent: true, scope: JevMonitoringPreferences(defaults: bad), settings: strong), .nothing)
        XCTAssertTrue(badStore.document.ranges.isEmpty); XCTAssertFalse(badStore.document.sessionDefault)
    }

    func testSecondLaunchDoesNothingAndTheOldKeysStay() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d), p = scope(.always, in: d)
        XCTAssertEqual(store.migrateIfNeeded(consent: true, scope: p, settings: strong), .alwaysRule)
        store.apply(.delete(store.document.ranges[0].id))
        let again = JevSurveillanceStore(defaults: d)
        XCTAssertEqual(again.migrateIfNeeded(consent: true, scope: p, settings: JevInterventionSettings()), .alreadyDone)
        XCTAssertTrue(again.document.ranges.isEmpty, "a removed rule never comes back")
        XCTAssertNotNil(d.object(forKey: JevMonitoringPreferences.storageKey), "the old scope key stays")
    }

    func testUnreadableDocumentRunsNothingAndIsKeptUntilTheNextSave() {
        let d = defaults(); d.set(Data("bad".utf8), forKey: JevSurveillanceStore.storageKey)
        let store = JevSurveillanceStore(defaults: d)
        XCTAssertEqual(store.error, JevSurveillanceStore.unreadableText)
        XCTAssertTrue(store.active(sessions: JevRunningSessions(focus: UUID()), now: now).isEmpty)
        XCTAssertEqual(store.migrateIfNeeded(consent: true, scope: scope(.always, in: d), settings: strong), .alreadyDone)
        XCTAssertEqual(d.data(forKey: JevSurveillanceStore.storageKey), Data("bad".utf8))
    }

    // MARK: What runs (point 3)

    func testRulesAndSessionsCarryTheirOwnSurveillanceAndTheStrongestWins() {
        var document = JevSurveillanceDocument()
        let block = UUID(), focus = UUID(), own = UUID()
        document.ranges = [JevSurveillanceRange(weekdays: [3], startMinute: 9 * 60, endMinute: 11 * 60, lock: .password,
                                                settings: JevInterventionSettings())]
        document.marks = [
            JevSessionMark(id: block, kind: .block, on: true, lock: .typing, settings: strong),
            JevSessionMark(id: focus, kind: .focus, on: false, lock: .free, settings: strong),
            JevSessionMark(id: own, kind: .own, on: true, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60),
                           lock: .free, settings: JevInterventionSettings()),
        ]
        document.sessionDefault = true
        let running = JevSurveillanceStore.active(document, sessions: JevRunningSessions(focus: focus, blocks: [block]), now: now,
                                                  calendar: paris)
        XCTAssertEqual(running.map(\.lock), [.password, .typing, .free], "rule, block session, own session; the focus mark is off")
        XCTAssertEqual(JevSurveillanceStore.strongest(running.map(\.settings)), strong)
        // A block mark runs only while its block runs: same instant, block not running.
        XCTAssertEqual(JevSurveillanceStore.active(document, sessions: JevRunningSessions(focus: focus), now: now, calendar: paris)
                        .map(\.lock), [.password, .free])
        XCTAssertNil(JevSurveillanceStore.strongest([]))
    }

    func testMonitorSeesABlockSessionWithoutIntention() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d), block = UUID()
        store.mark(JevSessionMark(id: block, kind: .block, on: true, lock: .free, settings: strong), now: now, alive: JevRunningSessions(blocks: [block]))
        var blocks: Set<UUID> = []
        let monitor = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: d), surveillance: store,
                                 sessionProvider: { nil }, blocksProvider: { blocks },
                                 legacySettings: { JevInterventionSettings() },
                                 inbox: JevIngress(notificationCenter: NotificationCenter()), loadLocalSettings: false)
        XCTAssertTrue(monitor.currentActivity(now: now).isEmpty)
        blocks = [block]
        XCTAssertEqual(monitor.currentActivity(now: now).map(\.settings), [strong])
    }

    /// Correction 8: only a Concentration session changes the default of the next sessions.
    func testOnlyAFocusMarkBecomesTheNextSessionDefault() {
        let store = JevSurveillanceStore(defaults: defaults()), focus = UUID(), block = UUID()
        store.mark(JevSessionMark(id: block, kind: .block, on: true, lock: .free, settings: strong), now: now,
                   alive: JevRunningSessions(blocks: [block]))
        XCTAssertFalse(store.document.sessionDefault, "a Blocage session keeps its choice for itself")
        store.mark(JevSessionMark(id: focus, kind: .focus, on: true, lock: .free, settings: strong), now: now,
                   alive: JevRunningSessions(focus: focus, blocks: [block]))
        XCTAssertTrue(store.document.sessionDefault); XCTAssertEqual(store.document.sessionSettings, strong)
        store.mark(JevSessionMark(id: UUID(), kind: .block, on: false, lock: .free, settings: strong), now: now,
                   alive: JevRunningSessions(focus: focus, blocks: [block]))
        XCTAssertTrue(store.document.sessionDefault, "a Blocage session off does not turn the default off")
        store.mark(JevSessionMark(id: UUID(), kind: .focus, on: false, lock: .free, settings: strong), now: now, alive: JevRunningSessions())
        XCTAssertFalse(store.document.sessionDefault)
    }

    /// Correction 4: a mark of a running session is never dropped; finished marks are.
    func testARunningLockedMarkSurvivesLaterSessionsAndFinishedMarksArePruned() {
        let store = JevSurveillanceStore(defaults: defaults()), locked = UUID(), gone = UUID()
        store.mark(JevSessionMark(id: gone, kind: .block, on: true, lock: .free, settings: strong), now: now,
                   alive: JevRunningSessions(blocks: [gone]))
        store.mark(JevSessionMark(id: locked, kind: .block, on: true, lock: .locked, settings: strong), now: now,
                   alive: JevRunningSessions(blocks: [locked, gone]))
        var alive: Set<UUID> = [locked]
        for _ in 0..<10 {
            let id = UUID(); alive.insert(id)
            store.mark(JevSessionMark(id: id, kind: .block, on: true, lock: .free, settings: strong), now: now,
                       alive: JevRunningSessions(blocks: alive))
        }
        XCTAssertEqual(store.document.marks.count, 11, "the 10 later sessions and the locked one, all running")
        XCTAssertFalse(store.document.marks.contains { $0.id == gone }, "a finished block's mark is removed")
        XCTAssertEqual(store.sessionLock(kind: .block, ids: [locked]), .locked)
        XCTAssertEqual(JevSurveillanceStore.active(store.document, sessions: JevRunningSessions(blocks: [locked]), now: now,
                                                   calendar: paris).map(\.lock), [.locked])
        let own = JevSessionMark(id: UUID(), kind: .own, on: true, start: now, end: now.addingTimeInterval(60), lock: .free,
                                 settings: strong)
        XCTAssertEqual(JevSurveillanceStore.pruned([own], now: now, alive: JevRunningSessions()).count, 1)
        XCTAssertTrue(JevSurveillanceStore.pruned([own], now: now.addingTimeInterval(61), alive: JevRunningSessions()).isEmpty)
    }

    /// Corrections 5-6: weakening or removing a running protected rule goes through its stop; « Verrouillé » refuses.
    func testARunningProtectedRuleKeepsItsHoursAndStop() {
        let store = JevSurveillanceStore(defaults: defaults())
        let range = JevSurveillanceRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: .typing,
                                         settings: strong)
        store.apply(.save(range))
        XCTAssertEqual(store.check(.delete(range.id), now: now), .stop(.typing))
        var weaker = range; weaker.lock = .free
        XCTAssertEqual(store.check(.save(weaker), now: now), .stop(.typing))
        var softer = range; softer.settings = JevInterventionSettings()
        XCTAssertEqual(store.check(.save(softer), now: now), .stop(.typing), "weaker settings")
        var shorter = range; shorter.endMinute = 600
        XCTAssertEqual(store.check(.save(shorter), now: now), .stop(.typing), "other hours")
        var stronger = range; stronger.lock = .password
        XCTAssertEqual(store.check(.save(stronger), now: now), .allow, "a stronger rule is immediate")
        var locked = range; locked.lock = .locked; store.apply(.save(locked))
        XCTAssertEqual(store.check(.delete(range.id), now: now), .refused(JevSurveillanceStore.protectedText))
        XCTAssertFalse(JevSurveillanceStore.protectedText.contains("avant sa fin"), "a « Toujours » rule has no end")
        XCTAssertEqual(store.check(.save(stronger), now: now), .refused(JevSurveillanceStore.protectedText))
    }

    func testWeakeningThroughTheEditorAsksTheStopOnceAndAPassedStopDeletes() {
        let store = JevSurveillanceStore(defaults: defaults())
        let range = JevSurveillanceRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: .password, settings: strong)
        store.apply(.save(range))
        var asked: [BlockLock] = []
        var writes = BlockRulePlan.Writes(); writes.jev = [.delete(range.id)]
        XCTAssertEqual(BlockRulePlan.apply(writes, blocking: nil, braise: nil, surveillance: store, now: now,
                                           confirmStop: { asked.append($0); return false }), JevStopGate.keptText)
        XCTAssertEqual(store.document.ranges, [range], "stop not passed: nothing changes")
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: nil, braise: nil, surveillance: store, now: now,
                                         confirmStop: { asked.append($0); return true }))
        XCTAssertTrue(store.document.ranges.isEmpty, "stop passed: the rule is removed")
        XCTAssertEqual(asked, [.password, .password])
        var stronger = range; stronger.lock = .locked; store.apply(.save(range))
        writes.jev = [.save(stronger)]
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: nil, braise: nil, surveillance: store, now: now,
                                         confirmStop: { _ in XCTFail("stronger asks nothing"); return false }))
    }

    /// Correction 7: the store built at launch is already migrated, so a first write cannot drop the « Toujours » rule.
    func testTheLaunchedStoreIsMigratedBeforeAnyWrite() {
        let d = defaults()
        let store = JevSurveillanceStore.launched(defaults: d, consent: true, scope: scope(.always, in: d), settings: strong)
        XCTAssertEqual(store.document.ranges.count, 1)
        store.mark(JevSessionMark(id: UUID(), kind: .focus, on: false, lock: .free, settings: strong), now: now, alive: JevRunningSessions())
        XCTAssertEqual(JevSurveillanceStore(defaults: d).document.ranges.map(\.settings), [strong])
    }

    func testOnlyStartedBlocksRunTheirSurveillance() {
        let started = BlockingActiveBlock(id: UUID(), listIDs: [], start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60),
                                          lock: .free, origin: .manual)
        var later = started; later.id = UUID(); later.start = now.addingTimeInterval(600); later.end = now.addingTimeInterval(900)
        XCTAssertEqual(JevMonitor.runningBlockIDs([started, later], now: now), [started.id])
    }

    func testOwnSessionEndsWhenStopped() {
        let store = JevSurveillanceStore(defaults: defaults()), id = UUID()
        store.mark(JevSessionMark(id: id, kind: .own, on: true, start: now, end: now.addingTimeInterval(3_600), lock: .free,
                                  settings: strong), now: now, alive: JevRunningSessions())
        XCTAssertEqual(store.runningOwn(now: now.addingTimeInterval(60))?.id, id)
        store.endOwn(id, now: now.addingTimeInterval(120))
        XCTAssertNil(store.runningOwn(now: now.addingTimeInterval(180)))
    }
}
#endif

#if os(macOS)
/// T-050 lot B1 point 7: cutting Jev goes through the strongest stop that runs. Pure: no alert, no real controller.
@MainActor final class JevStopGateTests: XCTestCase {
    private func activity(_ locks: [BlockLock]) -> [JevSurveillanceActivity] {
        locks.map { JevSurveillanceActivity(settings: JevInterventionSettings(), lock: $0) }
    }

    func testFreeOrNothingRunningChangesNothing() {
        XCTAssertEqual(JevStopGate.step([], jevEnabled: true), .allow)
        XCTAssertEqual(JevStopGate.step(activity([.free, .free]), jevEnabled: true), .allow)
        XCTAssertEqual(JevStopGate.step(activity([.locked]), jevEnabled: false), .allow, "Jev off: nothing to cut")
        XCTAssertNil(JevStopGate.refusal(.allow, typed: "", verify: nil))
    }

    func testTheStrongestStopWins() {
        XCTAssertEqual(JevStopGate.step(activity([.free, .typing]), jevEnabled: true, challenge: { "abc" }), .typing("abc"))
        XCTAssertEqual(JevStopGate.step(activity([.typing, .password, .free]), jevEnabled: true), .password)
        XCTAssertEqual(JevStopGate.step(activity([.password, .locked]), jevEnabled: true), .refused(JevStopGate.lockedText))
    }

    func testTypingNeedsTheExactText() {
        XCTAssertNil(JevStopGate.refusal(.typing("abc"), typed: "abc", verify: nil))
        XCTAssertEqual(JevStopGate.refusal(.typing("abc"), typed: "ab", verify: nil), JevStopGate.wrongText)
    }

    func testPasswordUsesTheBlockingPasswordAndLockedRefusesWithItsReason() {
        var tried: [String] = []
        let verify: (String) -> BlockingPasswordResult = { tried.append($0); return $0 == "ok" ? .ok : .wrong(remaining: 3) }
        XCTAssertNil(JevStopGate.refusal(.password, typed: "ok", verify: verify))
        XCTAssertEqual(JevStopGate.refusal(.password, typed: "no", verify: verify), RedScreenPasswordSheet.text(.wrong(remaining: 3)))
        XCTAssertEqual(tried, ["ok", "no"])
        XCTAssertEqual(JevStopGate.refusal(.password, typed: "ok", verify: nil), JevStopGate.noBlockingText)
        XCTAssertEqual(JevStopGate.refusal(.refused(JevStopGate.lockedText), typed: "", verify: verify), JevStopGate.lockedText)
        XCTAssertEqual(tried.count, 2, "a locked stop asks for nothing")
    }

    func testTheEditorSaysItUnderTheStopOnlyWithSurveillanceAndAStop() {
        var draft = BlockRuleDraft()
        XCTAssertNil(BlockRuleEditor.surveillanceStopNote(draft, stop: .password))
        draft.surveillance = JevInterventionSettings()
        XCTAssertNil(BlockRuleEditor.surveillanceStopNote(draft, stop: .free))
        for lock in [BlockLock.typing, .password, .locked] {
            XCTAssertEqual(BlockRuleEditor.surveillanceStopNote(draft, stop: lock), JevStopGate.editorText)
        }
    }
}
#endif
