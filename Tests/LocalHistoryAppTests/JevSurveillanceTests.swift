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
        // A Continu session of the Blocage engine (no intention) is seen through its block id.
        XCTAssertTrue(JevSurveillanceStore.active(document, sessions: JevRunningSessions(), now: now.addingTimeInterval(3 * 3_600),
                                                  calendar: paris).isEmpty)
        XCTAssertNil(JevSurveillanceStore.strongest([]))
    }

    func testMonitorSeesABlockSessionWithoutIntention() {
        let d = defaults(), store = JevSurveillanceStore(defaults: d), block = UUID()
        store.mark(JevSessionMark(id: block, kind: .block, on: true, lock: .free, settings: strong), now: now)
        var blocks: Set<UUID> = []
        let monitor = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: d), surveillance: store,
                                 sessionProvider: { nil }, blocksProvider: { blocks },
                                 legacySettings: { JevInterventionSettings() },
                                 inbox: JevIngress(notificationCenter: NotificationCenter()), loadLocalSettings: false)
        XCTAssertTrue(monitor.currentActivity(now: now).isEmpty)
        blocks = [block]
        XCTAssertEqual(monitor.currentActivity(now: now).map(\.settings), [strong])
    }

    func testAMarkBecomesTheNextSessionDefaultAndOnlyEightAreKept() {
        let store = JevSurveillanceStore(defaults: defaults())
        for _ in 0..<10 { store.mark(JevSessionMark(id: UUID(), kind: .block, on: true, lock: .free, settings: strong), now: now) }
        XCTAssertEqual(store.document.marks.count, 8)
        XCTAssertTrue(store.document.sessionDefault); XCTAssertEqual(store.document.sessionSettings, strong)
        store.mark(JevSessionMark(id: UUID(), kind: .focus, on: false, lock: .free, settings: strong), now: now)
        XCTAssertFalse(store.document.sessionDefault)
    }

    func testARunningProtectedRuleKeepsItsHoursAndStop() {
        let store = JevSurveillanceStore(defaults: defaults())
        let range = JevSurveillanceRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: .typing,
                                         settings: JevInterventionSettings())
        store.apply(.save(range))
        XCTAssertEqual(store.refusal(.delete(range.id), now: now), JevSurveillanceStore.protectedText)
        var weaker = range; weaker.lock = .free
        XCTAssertEqual(store.refusal(.save(weaker), now: now), JevSurveillanceStore.protectedText)
        var stronger = range; stronger.settings = strong; stronger.lock = .password
        XCTAssertNil(store.refusal(.save(stronger), now: now), "a stronger rule is always allowed")
        var free = range; free.lock = .free; store.apply(.save(free))
        XCTAssertNil(store.refusal(.delete(range.id), now: now))
    }

    func testOwnSessionEndsWhenStopped() {
        let store = JevSurveillanceStore(defaults: defaults()), id = UUID()
        store.mark(JevSessionMark(id: id, kind: .own, on: true, start: now, end: now.addingTimeInterval(3_600), lock: .free,
                                  settings: strong), now: now)
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
