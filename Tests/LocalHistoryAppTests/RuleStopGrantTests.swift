#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-059 (P3): a rule whose stop is stronger than « Libre » is protected at all times, running or not. Each path that
/// weakens it is refused without its stop, accepted with it, and hardening stays free. The engines are the gate:
/// each test writes to the engine itself, without the page. Test controllers only: no window, no focus taken.
@MainActor final class RuleStopGrantTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris: the 21:00 → 23:00 rules are scheduled, not running.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!
    private var up: TimeInterval = 1_000

    private func grant() -> RuleStopGrant {
        RuleStopGrant(uptime: { [unowned self] in self.up }, verifyPassword: { $0 == "pw" ? .ok : .wrong(remaining: 3) })
    }
    /// Passes the stop the way the alert does: the shown text retyped, or the right password.
    private func pass(_ grant: RuleStopGrant, _ lock: BlockLock) -> Bool {
        switch lock {
        case .typing: let text = grant.newChallenge(); return grant.pass(.typing, proof: .typed(text, challenge: text)) == nil
        case .password: return grant.pass(.password, proof: .password("pw")) == nil
        case .free: return true
        case .locked: return grant.pass(.locked, proof: .none) == nil
        }
    }
    private func range(_ start: Int, _ end: Int, lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...5), startMinute: start * 60, endMinute: end * 60, lock: lock)
    }
    private func list(_ ranges: [BlockProgramRange], sites: [String] = ["jeux.example"]) -> BlockList {
        BlockList(name: "Jeux", sites: sites.map { BlockSiteRule(pattern: $0) }, program: BlockProgram(ranges: ranges))
    }
    private func blocking(_ lists: [BlockList], grant: RuleStopGrant, password: Bool = true) -> BlockingController {
        let now = self.now
        let credential = password ? BlockPasswordLock.make("motdepasse-test", at: now) : nil
        let c = BlockingController(document: BlockingDocument(lists: lists, passwordLock: credential), clock: { now }, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 })
        c.stopGrant = grant
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func braise(grant: RuleStopGrant, password: Bool = true) throws -> BraiseController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-stop-grant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        let now = self.now
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { now }, calendar: paris,
                                     continuous: { now.timeIntervalSince1970 }, boot: { "boot-1" }, hasPassword: { password },
                                     verifyPassword: { $0 == "pw" ? .ok : .wrong(remaining: 3) })
        c.stopGrant = grant
        for range in c.ranges.program.ranges { try c.deleteRange(range.id, asking: false) }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func rules(_ blocking: BlockingController?, _ braise: BraiseController?) -> [BlockRule] {
        BlockRules.current(blocking: blocking, braise: braise, now: now, calendar: paris)
    }

    // MARK: The grant

    func testTheGrantChecksItsProofAndEndsAlone() {
        let g = grant()
        XCTAssertFalse(g.covers(.typing))
        XCTAssertEqual(g.pass(.typing, proof: .typed("x", challenge: "x")), RuleStopGrant.wrongText, "a text the grant did not issue")
        let text = g.newChallenge()
        XCTAssertEqual(g.pass(.typing, proof: .typed(text + "?", challenge: text)), RuleStopGrant.wrongText)
        XCTAssertNotNil(g.pass(.password, proof: .password("non")))
        XCTAssertFalse(g.covers(.typing))
        XCTAssertNil(g.pass(.typing, proof: .typed(text, challenge: text)))
        XCTAssertTrue(g.covers(.typing)); XCTAssertFalse(g.covers(.password), "« Difficile » does not pass « Mot de passe »")
        up += 61
        XCTAssertFalse(g.covers(.typing), "a grant ends alone after a minute")
        XCTAssertTrue(pass(g, .password)); XCTAssertTrue(g.covers(.typing))
        g.revoke(); XCTAssertFalse(g.covers(.typing))
        XCTAssertEqual(g.pass(.locked, proof: .password("pw")), RuleStopGrant.lockedText)
        XCTAssertFalse(g.covers(.locked))
        XCTAssertFalse(RuleStopGrant.confirm(.password, grant: g), "tests never show the alert: no proof, refused")
    }

    // MARK: Lists (BlockingController is the gate)

    /// Mathis's bug: a « Mot de passe » rule scheduled for 21:00 edited to « Libre », then turned off for free.
    func testAScheduledPasswordRuleCannotBecomeFreeWithoutThePassword() throws {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .password)])], grant: g)
        let rule = try XCTUnwrap(rules(lists, nil).first)
        var draft = BlockRuleDraft(rule); draft.lock = .free
        let writes = BlockRulePlan.writes(draft, replacing: rule, lists: lists.lists, red: nil)
        var asked: [BlockLock] = []
        XCTAssertEqual(BlockRulePlan.apply(writes, blocking: lists, braise: nil, grant: g,
                                           confirmStop: { asked.append($0); return false }), RuleStopGrant.keptText)
        XCTAssertEqual(lists.lists.first?.program.ranges.first?.effectiveLock, .password, "refused: nothing changes")
        XCTAssertEqual(asked, [.password])
        // The engine alone refuses too: the page is not the gate.
        var free = lists.lists[0]; free.program.ranges[0].lock = .free
        XCTAssertEqual(lists.save(free), RuleStopGrant.needText(.password))
        XCTAssertEqual(lists.editCheck(free), .refused(RuleStopGrant.needText(.password)))
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: lists, braise: nil, grant: g,
                                         confirmStop: { [unowned self] in pass(g, $0) }))
        XCTAssertEqual(lists.lists.first?.program.ranges.first?.effectiveLock, .free, "password passed: saved")
        XCTAssertFalse(g.covers(.typing), "the grant served this change only")
    }

    func testAWeakerStopFewerHoursAndRemovedSitesGoThroughTheStopAndHardeningIsFree() {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .typing)])], grant: g)
        let current = lists.lists[0]
        var shorter = current; shorter.program.ranges[0].endMinute = 22 * 60
        var fewerDays = current; fewerDays.program.ranges[0].weekdays = [1, 2]
        var sites = current; sites.sites = []
        var lighter = current; lighter.program.ranges[0].lock = .free
        for weaker in [shorter, fewerDays, sites, lighter] {
            XCTAssertEqual(lists.save(weaker), RuleStopGrant.needText(.typing))
            XCTAssertEqual(lists.lists[0], current)
        }
        var longer = current; longer.program.ranges[0].endMinute = 24 * 60; longer.sites.append(BlockSiteRule(pattern: "video.example"))
        longer.program.ranges[0].lock = .password
        XCTAssertNil(lists.save(longer), "longer, more sites and a stronger stop ask nothing")
        XCTAssertTrue(pass(g, .password))
        XCTAssertNil(lists.save(current), "with the stop: the weaker change is saved")
    }

    func testMorePausesGoThroughTheStop() {
        let g = grant()
        var protected = range(21, 23, lock: .typing); protected.pause = PausePolicy(budgetMinutes: 10)
        let lists = blocking([list([protected])], grant: g)
        var more = lists.lists[0]; more.program.ranges[0].pause?.budgetMinutes = 30
        XCTAssertEqual(lists.save(more), RuleStopGrant.needText(.typing))
        var fewer = lists.lists[0]; fewer.program.ranges[0].pause?.budgetMinutes = 5
        XCTAssertNil(lists.save(fewer), "fewer pauses: free")
        more.program.ranges[0].pause?.budgetMinutes = 30
        XCTAssertTrue(pass(g, .typing)); XCTAssertNil(lists.save(more))
    }

    func testListsEditedFromElsewhereGoThroughTheStop() {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .typing)])], grant: g)
        let id = lists.lists[0].id
        XCTAssertEqual(lists.addException("jeux.example/aide", to: id), .refused(RuleStopGrant.needText(.typing)))
        XCTAssertNil(lists.lists[0].exceptions?.first)
        XCTAssertEqual(lists.addKeyword("poker", to: id), .allowed, "a keyword is stricter: free")
        XCTAssertTrue(pass(g, .typing))
        XCTAssertEqual(lists.addException("jeux.example/aide", to: id), .allowed)
    }

    func testDeletingAProtectedListGoesThroughItsStrongestStop() {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .typing), range(6, 7, lock: .password)])], grant: g)
        let id = lists.lists[0].id
        lists.delete(id)
        XCTAssertEqual(lists.error, RuleStopGrant.needText(.password)); XCTAssertNotNil(lists.list(id))
        XCTAssertTrue(pass(g, .typing)); lists.delete(id)
        XCTAssertNotNil(lists.list(id), "« Difficile » does not pass a « Mot de passe » range")
        XCTAssertTrue(pass(g, .password)); lists.delete(id)
        XCTAssertNil(lists.list(id))
    }

    func testDeletingARuleAndDuplicateThenDeleteGoThroughTheStop() throws {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .password)])], grant: g)
        let rule = try XCTUnwrap(rules(lists, nil).first)
        // « Dupliquer » as « Libre », saved free (it only adds), then the protected original deleted.
        var copy = BlockRulePreset(copying: rule).draft; copy.lock = .free; copy.startMinute = 20 * 60
        XCTAssertNil(BlockRulePlan.apply(BlockRulePlan.writes(copy, replacing: nil, lists: lists.lists, red: nil),
                                         blocking: lists, braise: nil, grant: g, confirmStop: { _ in XCTFail("adding asks nothing"); return false }))
        let original = try XCTUnwrap(rules(lists, nil).first { $0.key.lock == .password })
        let delete = BlockRulePlan.writes(nil, replacing: original, lists: lists.lists, red: nil)
        XCTAssertEqual(BlockRulePlan.apply(delete, blocking: lists, braise: nil, grant: g, confirmStop: { _ in false }), RuleStopGrant.keptText)
        XCTAssertTrue(lists.lists[0].program.ranges.contains { $0.effectiveLock == .password })
        XCTAssertNil(BlockRulePlan.apply(delete, blocking: lists, braise: nil, grant: g, confirmStop: { [unowned self] in pass(g, $0) }))
        XCTAssertFalse(lists.lists[0].program.ranges.contains { $0.effectiveLock == .password })
    }

    func testALockedRuleIsRefusedWithItsReasonAndNeverAsks() throws {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .locked)])], grant: g)
        let rule = try XCTUnwrap(rules(lists, nil).first)
        var draft = BlockRuleDraft(rule); draft.lock = .free
        XCTAssertEqual(BlockRulePlan.apply(BlockRulePlan.writes(draft, replacing: rule, lists: lists.lists, red: nil), blocking: lists,
                                           braise: nil, grant: g, confirmStop: { _ in XCTFail("locked never asks"); return true }),
                       RuleStopGrant.lockedText)
        XCTAssertEqual(BlockRulePlan.apply(BlockRulePlan.writes(nil, replacing: rule, lists: lists.lists, red: nil), blocking: lists,
                                           braise: nil, grant: g, confirmStop: { _ in true }), RuleStopGrant.lockedText)
        lists.delete(lists.lists[0].id)
        XCTAssertEqual(lists.error, RuleStopGrant.lockedText); XCTAssertEqual(lists.lists.count, 1)
        var longer = lists.lists[0]; longer.program.ranges[0].endMinute = 24 * 60
        XCTAssertNil(lists.save(longer), "a locked rule still hardens at once")
    }

    func testAFreeRuleStaysFree() {
        let g = grant()
        let lists = blocking([list([range(21, 23, lock: .free)])], grant: g)
        var gone = lists.lists[0]; gone.program.ranges = []; gone.sites = []
        XCTAssertNil(lists.save(gone))
        lists.delete(gone.id); XCTAssertNil(lists.list(gone.id))
    }

    // MARK: Red screen (BraiseController is the gate)

    func testWeakerRedOrBrightnessAndDisablingOrDeletingARedRangeGoThroughTheStop() throws {
        let g = grant()
        let screen = try braise(grant: g)
        let protected = range(21, 23, lock: .password)
        try screen.saveRange(protected, intensity: 0.6)
        func refusedLock(_ body: () throws -> Void) {
            XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? RedScreenRefusal)?.message, RuleStopGrant.needText(.password)) }
        }
        refusedLock { try screen.saveRange(protected, intensity: 0.3) }
        var shorter = protected; shorter.endMinute = 22 * 60
        refusedLock { try screen.saveRange(shorter, intensity: 0.6) }
        refusedLock { try screen.setRangeEnabled(protected.id, false) }
        refusedLock { try screen.deleteRange(protected.id) }
        XCTAssertEqual(screen.ranges.program.ranges, [protected]); XCTAssertTrue(screen.ranges.disabled.isEmpty)
        XCTAssertEqual(screen.ranges.intensity(of: protected.id), 0.6)
        XCTAssertNil(screen.lockedRefusal(for: screen.ranges), "the editor keeps « Enregistrer »: the stop is asked on save")
        XCTAssertNoThrow(try screen.saveRange(protected, intensity: 0.9), "more red is free")
        XCTAssertTrue(pass(g, .password))
        XCTAssertNoThrow(try screen.setRangeEnabled(protected.id, false))
        g.revoke()
        XCTAssertTrue(screen.ranges.disabled.contains(protected.id))
        XCTAssertNoThrow(try screen.setRangeEnabled(protected.id, true), "turning on is free")
        XCTAssertTrue(pass(g, .password)); XCTAssertNoThrow(try screen.deleteRange(protected.id))
        XCTAssertTrue(screen.ranges.program.ranges.isEmpty)
    }

    func testBrightnessRaisedGoesThroughTheStop() throws {
        let g = grant()
        let screen = try braise(grant: g)
        let protected = range(21, 23, lock: .typing)
        var next = screen.ranges
        next.program.ranges = [protected]; next.intensities[protected.id] = 0.6; next.brightness = [protected.id: 0.3]
        var brighter = next; brighter.brightness = [protected.id: 0.8]
        XCTAssertEqual(RedScreenRules.weakeningStop(from: next, to: brighter, hasPassword: true), .typing)
        var darker = next; darker.brightness = [protected.id: 0.2]
        XCTAssertNil(RedScreenRules.weakeningStop(from: next, to: darker, hasPassword: true))
        var locked = next; locked.program.ranges[0].lock = .locked
        var lockedBrighter = locked; lockedBrighter.brightness = [protected.id: 0.8]
        XCTAssertEqual(RedScreenRules.weakeningStop(from: locked, to: lockedBrighter, hasPassword: true), .locked)
    }

    func testTheRedSwitchPassesTheGrantAndTheCommandLineCannotSkipIt() throws {
        let g = grant()
        let screen = try braise(grant: g)
        try screen.saveRange(range(21, 23, lock: .typing), intensity: 0.6)
        let rule = try XCTUnwrap(rules(nil, screen).first)
        XCTAssertNotNil(BlockRuleSwitchAction.turnOff(rule, proof: .typed("b", challenge: "b"), blocking: nil, braise: screen, grant: g),
                        "a text the grant did not issue")
        XCTAssertThrowsError(try screen.setRangeEnabled(rule.red!.rangeID, false, asking: false), "the command line passes no stop")
        let text = BlockRuleSwitchAction.challenge(rule, blocking: nil, grant: g)
        XCTAssertNil(BlockRuleSwitchAction.turnOff(rule, proof: .typed(text, challenge: text), blocking: nil, braise: screen, grant: g))
        XCTAssertTrue(screen.ranges.disabled.contains(rule.red!.rangeID))
        XCTAssertFalse(g.covers(.typing), "the switch revokes its grant")
    }

    // MARK: Surveillance (JevSurveillanceStore is the gate)

    func testAScheduledProtectedSurveillanceGoesThroughItsStop() {
        let g = grant()
        let d = UserDefaults(suiteName: "goalong.stop-grant." + UUID().uuidString)!
        let store = JevSurveillanceStore(defaults: d); store.stopGrant = g
        var settings = JevInterventionSettings(); settings.effectsEnabled = true
        let range = JevSurveillanceRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60, lock: .typing, settings: settings)
        XCTAssertTrue(store.apply(.save(range), now: now))
        XCTAssertFalse(JevSurveillanceStore.isRunning(range, now: now, calendar: paris))
        XCTAssertEqual(store.check(.delete(range.id), now: now), .stop(.typing))
        XCTAssertFalse(store.apply(.delete(range.id), now: now), "the store refuses without the stop")
        var shorter = range; shorter.endMinute = 22 * 60
        XCTAssertEqual(store.check(.save(shorter), now: now), .stop(.typing))
        var longer = range; longer.endMinute = 24 * 60; longer.lock = .password
        XCTAssertEqual(store.check(.save(longer), now: now), .allow, "longer and stronger: free")
        XCTAssertTrue(pass(g, .typing))
        XCTAssertTrue(store.apply(.delete(range.id), now: now)); XCTAssertTrue(store.document.ranges.isEmpty)
        var locked = range; locked.lock = .locked; g.revoke(); store.apply(.save(locked), now: now)
        XCTAssertEqual(store.check(.delete(range.id), now: now), .refused(RuleStopGrant.lockedText))
    }
}
#endif
