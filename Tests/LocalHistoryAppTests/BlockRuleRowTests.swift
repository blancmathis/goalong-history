#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-050 lot B2b: the rule row's switch (S2, P3, P4), the templates (A1), « Dupliquer » (A8), the editor's sentence (S3)
/// and the lock alert of « Surveillance » alone. Fake gamma and test controllers only: no real screen, no real guard.
@MainActor final class BlockRuleRowTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    private func braise() throws -> BraiseController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-rule-row-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        let now = self.now
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { now }, calendar: paris,
                                     continuous: { now.timeIntervalSince1970 }, boot: { "boot-1" }, hasPassword: { false },
                                     verifyPassword: { _ in .wrong(remaining: 3) })
        for range in c.ranges.program.ranges { try c.deleteRange(range.id) }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func blocking(_ lists: [BlockList]) -> BlockingController {
        let now = self.now
        let c = BlockingController(document: BlockingDocument(lists: lists), clock: { now }, calendar: paris, continuous: { now.timeIntervalSince1970 })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func range(_ start: Int, _ end: Int, lock: BlockLock? = nil) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...5), startMinute: start * 60, endMinute: end * 60, lock: lock)
    }
    private func list(_ name: String, _ ranges: [BlockProgramRange]) -> BlockList {
        BlockList(name: name, sites: [BlockSiteRule(pattern: "\(name.lowercased()).example")], program: BlockProgram(ranges: ranges))
    }
    private func rules(_ blocking: BlockingController?, _ braise: BraiseController?) -> [BlockRule] {
        BlockRules.current(blocking: blocking, braise: braise, now: now, calendar: paris)
    }

    // MARK: Switch (S2)

    func testAListRuleInProgressTurnsOffThroughItsStopAndOutsideItsHoursHasNoSwitch() throws {
        let lists = blocking([list("Jeux", [range(9, 12, lock: .typing)]), list("Vidéo", [range(14, 16)])])
        let all = rules(lists, nil)
        let running = try XCTUnwrap(all.first { $0.key.start == 9 * 60 }), later = try XCTUnwrap(all.first { $0.key.start == 14 * 60 })
        XCTAssertEqual(BlockRuleSwitch.of(running, canVerifyPassword: true), .on(stop: .typing))
        XCTAssertEqual(BlockRuleSwitch.of(later, canVerifyPassword: true), .hidden, "no « off » for a list outside its hours (P4)")
        XCTAssertFalse(BlockRuleSwitchAction.blockIDs(running, blocking: lists).isEmpty)
        // Off without the text: refused, the block stays.
        XCTAssertNotNil(BlockRuleSwitchAction.turnOff(running, proof: .none, blocking: lists, braise: nil))
        XCTAssertNotNil(BlockRuleSwitchAction.turnOff(running, proof: .typed("faux", challenge: "faux"), blocking: lists, braise: nil))
        XCTAssertFalse(BlockRuleSwitchAction.blockIDs(running, blocking: lists).isEmpty)
        // The rule's own text passes its stop.
        let text = BlockRuleSwitchAction.challenge(running, blocking: lists)
        XCTAssertNil(BlockRuleSwitchAction.turnOff(running, proof: .typed(text, challenge: text), blocking: lists, braise: nil))
        XCTAssertTrue(BlockRuleSwitchAction.blockIDs(running, blocking: lists).isEmpty)
        let after = try XCTUnwrap(rules(lists, nil).first { $0.key.start == 9 * 60 })
        XCTAssertEqual(BlockRuleSwitch.of(after, canVerifyPassword: true), .hidden, "a stopped range has no « resume » in the engine")
    }

    func testAFreeListRuleTurnsOffAtOnceAndALockedOneHasNoSwitch() throws {
        let lists = blocking([list("Jeux", [range(9, 12)]), list("Vidéo", [range(8, 11, lock: .locked)])])
        let free = try XCTUnwrap(rules(lists, nil).first { $0.key.start == 9 * 60 })
        let locked = try XCTUnwrap(rules(lists, nil).first { $0.key.start == 8 * 60 })
        XCTAssertEqual(BlockRuleSwitch.of(locked, canVerifyPassword: true), .hidden)
        XCTAssertNil(BlockRuleSwitchAction.turnOff(free, proof: .none, blocking: lists, braise: nil))
        XCTAssertTrue(BlockRuleSwitchAction.blockIDs(free, blocking: lists).isEmpty)
        XCTAssertFalse(BlockRuleSwitchAction.blockIDs(locked, blocking: lists).isEmpty, "the locked rule is untouched")
    }

    func testARedRuleTurnsOnAtOnceAndOffThroughItsStop() throws {
        let screen = try braise()
        try screen.saveRange(range(18, 20, lock: .typing), intensity: 0.6)
        var rule = try XCTUnwrap(rules(nil, screen).first)
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: false), .on(stop: .typing))
        XCTAssertNotNil(BlockRuleSwitchAction.turnOff(rule, proof: .typed("a", challenge: "b"), blocking: nil, braise: screen))
        XCTAssertTrue(screen.ranges.disabled.isEmpty)
        XCTAssertNil(BlockRuleSwitchAction.turnOff(rule, proof: .typed("b", challenge: "b"), blocking: nil, braise: screen))
        rule = try XCTUnwrap(rules(nil, screen).first)
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: false), .off)
        XCTAssertNil(BlockRuleSwitchAction.turnOn(rule, braise: screen), "turning on asks nothing")
        XCTAssertTrue(screen.ranges.disabled.isEmpty)
    }

    func testAPasswordRuleWithoutTheBlockingModuleAndAJoinedRuleHaveNoSwitch() {
        let key = BlockRule.Key(weekdays: Set(1...5), start: 18 * 60, end: 20 * 60, lock: .password)
        let red = BlockRule.RedPart(rangeID: UUID(), intensity: 0.6, brightness: nil, enabled: true, state: .next(now))
        let rule = BlockRule(id: "r", key: key, lists: [], red: red, lock: .password, state: .next(now))
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: false), .hidden, "the password comes from Blocage")
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: true), .on(stop: .password))
        let part = BlockRule.ListPart(id: UUID(), rangeIDs: [UUID()], name: "Jeux", kind: .block, state: .running(until: now))
        let joined = BlockRule(id: "j", key: key, lists: [part], red: red, lock: .free, state: .running(until: now))
        XCTAssertEqual(BlockRuleSwitch.of(joined, canVerifyPassword: true), .hidden, "no single stop for lists and red screen")
    }

    // MARK: Templates (A1) and copies (A8)

    func testTheFourTemplatesPickTheirListsByName() {
        let social = list("Réseaux sociaux", []), news = list("Actualités", [])
        let presets = BlockRulePreset.templates(lists: [social, news])
        XCTAssertEqual(presets.map(\.title), ["Réseaux sociaux aux heures de travail", "Écran rouge le soir", "Séance de 25 min", "Journée profonde"])
        XCTAssertEqual(presets[0].draft.listIDs, [social.id]); XCTAssertEqual(presets[0].trigger, .schedule)
        XCTAssertTrue(presets[1].draft.red); XCTAssertEqual(presets[1].draft.weekdays, Set(1...7))
        XCTAssertEqual(presets[2].trigger, .session); XCTAssertEqual(presets[2].minutes, 25)
        XCTAssertEqual(presets[3].draft.listIDs, [social.id, news.id]); XCTAssertEqual(presets[3].draft.lock, .typing)
        XCTAssertEqual(presets[3].trigger, .session, "a deep day is a séance, not a schedule")
        XCTAssertEqual(presets[3].minutes, 8 * 60)
        XCTAssertTrue(BlockRulePreset.templates(lists: [])[0].draft.listIDs.isEmpty, "no list: the member picks")
    }

    func testDuplicatingARuleOpensANewRuleOnTheSameDraft() throws {
        let lists = blocking([list("Jeux", [range(9, 12, lock: .typing)])])
        let rule = try XCTUnwrap(rules(lists, nil).first)
        let copy = BlockRulePreset(copying: rule)
        XCTAssertEqual(copy.draft.listIDs, BlockRuleDraft(rule).listIDs); XCTAssertEqual(copy.draft.lock, .typing)
        XCTAssertFalse(copy.draft.paused); XCTAssertEqual(copy.trigger, .schedule)
        XCTAssertNotEqual(BlockRuleEditor.Subject.preset(copy).id, BlockRuleEditor.Subject.rule(rule).id)
    }

    func testDuplicatingAPreparedSessionAddsACopyAfterIt() {
        let suite = "goalong-rule-row-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = PreparedSessionStore(defaults: defaults)
        let a = PreparedSession(name: "Matin"), b = PreparedSession(name: "Soir")
        store.save(a); store.save(b)
        let copy = store.duplicate(a)
        XCTAssertEqual(store.document.sessions.map(\.name), ["Matin", "Matin (copie)", "Soir"])
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(PreparedSessionStore(defaults: defaults).document.sessions.count, 3, "the copy is saved")
    }

    // MARK: Sentence (S3)

    func testTheSentenceSaysWhatWhenAndTheStop() {
        let game = list("Jeux", [])
        var draft = BlockRuleDraft(); draft.listIDs = [game.id]
        let rule = BlockRuleSentence.text(trigger: .schedule, draft: draft, lists: [game], lock: .typing, now: now)
        XCTAssertEqual(rule?.hasPrefix("Bloque Jeux, "), true, rule ?? "")
        XCTAssertEqual(rule?.hasSuffix("Pour l’arrêter, il faudra recopier un texte."), true, rule ?? "")
        let end = now.addingTimeInterval(3_600)
        let locked = BlockRuleSentence.text(trigger: .session, draft: draft, lists: [game], lock: .locked,
                                            session: .init(end: end), now: now)
        XCTAssertEqual(locked?.hasSuffix("Vous ne pourrez pas l’arrêter avant \(BlockingFormat.deadline(end, now: now))."), true, locked ?? "")
        XCTAssertEqual(BlockRuleSentence.text(trigger: .always, draft: draft, lists: [game], lock: .locked, now: now)?
            .hasSuffix("Vous ne pourrez pas l’arrêter pendant ses horaires."), true)
        XCTAssertNil(BlockRuleSentence.text(trigger: .always, draft: BlockRuleDraft(), lists: [game], lock: .free, now: now),
                     "nothing chosen: no sentence")
        XCTAssertEqual(BlockRuleSentence.text(trigger: .session, draft: BlockRuleDraft(), lists: [], lock: .free,
                                              session: .init(end: end, wholeMac: true), now: now)?.hasPrefix("Bloque tout le Mac"), true)
    }

    // MARK: Alert of « Surveillance » alone (point 5)

    func testTheWatchAloneLockAlertSpeaksOfTheWatchNotOfLists() {
        let plan = BlockingNowPlan(later: false, startAt: now, minutes: 60, now: now)
        for lock in [BlockLock.password, .locked] {
            let text = plan.watchLockMessage(lock, calendar: paris)
            XCTAssertTrue(text.contains("surveillance"), text)
            XCTAssertFalse(text.contains("listes") || text.contains("blocage"), text)
            // No guard holds the watch: no promise about a restart.
            XCTAssertFalse(text.contains("redémarrer"), text)
        }
    }
}
#endif
