#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import XCTest
@testable import LocalHistoryApp

/// Page « Blocages » (2026-11-10): a rule is a view of what the two engines hold (`BlockRules`), and a saved
/// rule is a set of writes to them (`BlockRulePlan`). Nothing new is stored: the migration is "nothing moves".
/// Fake gamma only: no test changes the colors of this Mac.
@MainActor final class BlockRuleTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let wednesday10h = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-block-rule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func braise(_ now: @escaping () -> Date, root: URL? = nil) throws -> BraiseController {
        let root = try root ?? self.root()
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: now, calendar: paris,
                                     continuous: { now().timeIntervalSince1970 }, boot: { "boot-1" }, hasPassword: { false },
                                     verifyPassword: { _ in .wrong(remaining: 3) })
        for range in c.ranges.program.ranges { try c.deleteRange(range.id) }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func blocking(_ lists: [BlockList], _ now: @escaping () -> Date) -> BlockingController {
        let c = BlockingController(document: BlockingDocument(lists: lists), clock: now, calendar: paris, continuous: { now().timeIntervalSince1970 })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func morning(_ lock: BlockLock? = nil) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...5), startMinute: 9 * 60, endMinute: 12 * 60, lock: lock)
    }
    private func list(_ name: String, _ ranges: [BlockProgramRange], action: BlockList.Action? = nil) -> BlockList {
        BlockList(name: name, sites: [BlockSiteRule(pattern: "\(name.lowercased()).example")], program: BlockProgram(ranges: ranges), action: action)
    }
    private func red(_ ranges: [BlockProgramRange], intensity: Double = 0.6, follows: Bool = true) -> RedScreenProgram {
        var program = RedScreenProgram(); program.program.ranges = ranges; program.follows = follows
        for range in ranges { program.intensities[range.id] = intensity }
        return program
    }
    private func rules(_ lists: [BlockList], _ red: RedScreenProgram? = nil, running: Set<UUID> = [], stopped: Set<UUID> = [],
                       windows: [UUID: Date] = [:], hasPassword: Bool = false) -> [BlockRule] {
        BlockRules.rules(.init(lists: lists, red: red, runningRanges: running, stoppedRanges: stopped, redWindows: windows, hasPassword: hasPassword,
                               now: wednesday10h, calendar: paris))
    }

    // MARK: Projection

    func testRangesWithTheSameHoursAndLockAreOneRuleAndEveryRangeIsInOneRule() {
        let saturday = BlockProgramRange(weekdays: [6], startMinute: 600, endMinute: 660)
        let a = list("Jeux", [morning(.locked), saturday]), b = list("Vidéo", [morning(.locked)])
        let screen = red([morning(.locked)])
        let result = rules([a, b], screen)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].lists.map(\.name), ["Jeux", "Vidéo"]); XCTAssertEqual(result[0].red?.rangeID, screen.program.ranges[0].id)
        XCTAssertEqual(result[0].key.lock, .locked); XCTAssertFalse(result[0].isRedOnly)
        XCTAssertEqual(result[1].lists.map(\.name), ["Jeux"]); XCTAssertNil(result[1].red)
        let shown = result.flatMap { $0.lists.flatMap(\.rangeIDs) + ($0.red.map { [$0.rangeID] } ?? []) }
        let stored = (a.program.ranges + b.program.ranges + screen.program.ranges).map(\.id)
        XCTAssertEqual(shown.sorted { $0.uuidString < $1.uuidString }, stored.sorted { $0.uuidString < $1.uuidString }, "each stored range is in one rule, once")
        // The same state gives the same rules, in the same order.
        XCTAssertEqual(rules([a, b], screen), result); XCTAssertEqual(rules([b, a], screen).map(\.id), result.map(\.id))
        // A different lock is another rule, even with the same hours.
        XCTAssertEqual(rules([a, list("Infos", [morning(.typing)])]).count, 3)
    }

    func testARedRangeJoinsTheListsOnlyWhenItIsOnAndAlone() {
        let a = list("Jeux", [morning()])
        var off = red([morning()]); off.disabled = [off.program.ranges[0].id]
        var result = rules([a], off)
        XCTAssertEqual(result.count, 2); XCTAssertNil(result.first { !$0.isRedOnly }?.red)
        XCTAssertEqual(result.first { $0.isRedOnly }?.state, .paused); XCTAssertEqual(result.first { $0.isRedOnly }?.red?.enabled, false)
        result = rules([a], red([morning(), morning()]))
        XCTAssertEqual(result.filter(\.isRedOnly).count, 2, "two red ranges with the same hours stay two rules")
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
        // No list rule with these hours: the red range is its own rule.
        XCTAssertEqual(rules([list("Jeux", [])], red([morning()])).map(\.isRedOnly), [true])
        // No red screen (module off): the lists' rules stay.
        XCTAssertEqual(rules([a], nil).count, 1)
    }

    func testTheKeyHoldsTheStoredLockAndTheRowShowsTheAppliedOne() {
        let a = list("Jeux", [morning(.password)])
        let without = rules([a], hasPassword: false), with = rules([a], hasPassword: true)
        XCTAssertEqual(without[0].key.lock, .password); XCTAssertEqual(without[0].lock, .locked)
        XCTAssertEqual(with[0].lock, .password)
        XCTAssertEqual(without[0].id, with[0].id, "a password set or removed does not move the rule")
        XCTAssertEqual(BlockRuleDraft(without[0]).lock, .password, "the editor keeps the stored lock")
    }

    func testStatesOfTheListsAndOfTheRedRange() throws {
        let range = morning(), saturday = BlockProgramRange(weekdays: [6], startMinute: 600, endMinute: 660)
        let noon = try XCTUnwrap(paris.date(bySettingHour: 12, minute: 0, second: 0, of: wednesday10h))
        XCTAssertEqual(rules([list("Jeux", [range])], running: [range.id])[0].state, .running(until: noon))
        XCTAssertEqual(rules([list("Jeux", [range])], stopped: [range.id])[0].state, .stopped(until: noon), "stopped by the member for today")
        XCTAssertEqual(rules([list("Jeux", [range])])[0].state, .running(until: noon), "inside its hours before the engine's tick: it runs")
        guard case .next(let start) = rules([list("Jeux", [saturday])])[0].state else { return XCTFail("a later range gives its next start") }
        XCTAssertEqual(paris.component(.weekday, from: start), 7); XCTAssertEqual(paris.component(.hour, from: start), 10)

        let screen = red([range])
        XCTAssertEqual(rules([], screen, windows: [range.id: noon])[0].state, .running(until: noon))
        var skipped = screen; skipped.skips[range.id] = noon
        XCTAssertEqual(rules([], skipped)[0].state, .stopped(until: noon))
        // The row shows what runs first, then what is stopped today, then the next start.
        let later = wednesday10h.addingTimeInterval(86_400)
        XCTAssertEqual(BlockRules.combined([.next(later), .stopped(until: noon), .running(until: noon)]), .running(until: noon))
        XCTAssertEqual(BlockRules.combined([.next(later), .stopped(until: noon)]), .stopped(until: noon))
        XCTAssertEqual(BlockRules.combined([.paused, .next(later)]), .next(later))
        XCTAssertEqual(BlockRules.combined([]), .idle)
    }

    func testTheRowSaysWhenWhatSafetyAndState() {
        let range = morning(.typing)
        let rule = rules([list("Jeux", [range]), list("Vidéo", [range].map { var r = $0; r.id = UUID(); return r }),
                          list("Infos", [morning(.typing)], action: .slowDown)], red([morning(.typing)]), running: [range.id])[0]
        XCTAssertEqual(rule.title, "\(BlockingFormat.weekdays(Set(1...5))), \(BlockingFormat.range(range))")
        XCTAssertEqual(rule.summary, "Bloque Jeux et Vidéo · Ralentit Infos · écran rouge à \(GoalongUIFormat.percent(60))")
        XCTAssertEqual(BlockRule.joined(["A", "B", "C"]), "A, B et C")
        let spoken = rule.spokenLabel(now: wednesday10h)
        XCTAssertTrue(spoken.contains(rule.title)); XCTAssertTrue(spoken.contains("Sécurité : \(BlockLock.typing.title)"))
        XCTAssertTrue(spoken.contains("En cours jusqu’à"), "the state is in words: \(spoken)")
        var held = red([morning()], intensity: 0); held.brightness = [held.program.ranges[0].id: 0.3]
        XCTAssertEqual(rules([], held)[0].summary, "Luminosité à \(GoalongUIFormat.percent(30))")
    }

    // MARK: Plan

    func testEditingTheHoursKeepsTheRangeIdentifiersAndTheStoredLocks() throws {
        let a = list("Jeux", [morning(), BlockProgramRange(weekdays: [6], startMinute: 600, endMinute: 660)]), b = list("Vidéo", [morning()])
        let screen = red([morning()])
        let rule = try XCTUnwrap(rules([a, b], screen).first { $0.lists.count == 2 })
        var draft = BlockRuleDraft(rule)
        XCTAssertEqual(draft.listIDs, [a.id, b.id]); XCTAssertTrue(draft.red); XCTAssertEqual(draft.intensity, 0.6, accuracy: 0.0001)
        XCTAssertTrue(BlockRulePlan.writes(draft, replacing: rule, lists: [a, b], red: screen).isEmpty, "an unchanged rule writes nothing")
        draft.startMinute = 8 * 60
        let writes = BlockRulePlan.writes(draft, replacing: rule, lists: [a, b], red: screen)
        XCTAssertEqual(writes.lists.map(\.id), [a.id, b.id])
        XCTAssertEqual(writes.lists[0].program.ranges.map(\.id), a.program.ranges.map(\.id)); XCTAssertEqual(writes.lists[0].program.ranges[0].startMinute, 480)
        XCTAssertEqual(writes.lists[0].program.ranges[1], a.program.ranges[1], "the other ranges of the list do not move")
        XCTAssertNil(writes.lists[0].program.ranges[0].lock, "a lock that does not change is not rewritten")
        XCTAssertEqual(writes.red.map(\.range.id), [screen.program.ranges[0].id]); XCTAssertEqual(writes.red[0].range.startMinute, 480)
        XCTAssertTrue(writes.deleting.isEmpty)
        // A harder lock is written on every range of the rule.
        draft.lock = .locked
        let harder = BlockRulePlan.writes(draft, replacing: rule, lists: [a, b], red: screen)
        XCTAssertEqual(harder.lists.map { $0.program.ranges[0].lock }, [.locked, .locked]); XCTAssertEqual(harder.red[0].range.lock, .locked)
        XCTAssertNil(harder.lists[0].program.ranges[1].lock)
    }

    func testAddingAndRemovingAListAndTheRedPart() throws {
        let a = list("Jeux", [morning()]), b = list("Vidéo", [])
        let screen = red([morning()])
        let rule = try XCTUnwrap(rules([a, b], screen).first)
        var draft = BlockRuleDraft(rule); draft.listIDs = [b.id]; draft.red = false; draft.brightness = nil
        let writes = BlockRulePlan.writes(draft, replacing: rule, lists: [a, b], red: screen)
        XCTAssertEqual(Set(writes.lists.map(\.id)), [a.id, b.id])
        XCTAssertTrue(try XCTUnwrap(writes.lists.first { $0.id == a.id }).program.ranges.isEmpty)
        let added = try XCTUnwrap(writes.lists.first { $0.id == b.id }).program.ranges
        XCTAssertEqual(added.map(BlockRule.Key.init), [rule.key]); XCTAssertNotEqual(added[0].id, a.program.ranges[0].id)
        XCTAssertTrue(writes.red.isEmpty); XCTAssertEqual(writes.deleting, [screen.program.ranges[0].id])
        // The brightness alone: a red range with no red.
        draft.brightness = 0.3
        let held = BlockRulePlan.writes(draft, replacing: rule, lists: [a, b], red: screen)
        XCTAssertEqual(held.red[0].intensity, 0); XCTAssertEqual(held.red[0].brightness, .some(.some(0.3))); XCTAssertTrue(held.deleting.isEmpty)
        // Removing the rule removes its ranges, and only them.
        let other = BlockProgramRange(weekdays: [6], startMinute: 600, endMinute: 660)
        let c = list("Infos", [morning(), other])
        let whole = try XCTUnwrap(rules([c], screen).first { $0.key == BlockRule.Key(morning()) })
        let removal = BlockRulePlan.writes(nil, replacing: whole, lists: [c], red: screen)
        XCTAssertEqual(removal.lists.map { $0.program.ranges }, [[other]]); XCTAssertEqual(removal.deleting, [screen.program.ranges[0].id])
    }

    func testTheDraftSaysWhatIsMissing() {
        var draft = BlockRuleDraft()
        XCTAssertEqual(draft.problem, "Choisissez ce que la règle fait.", "T-050 B1: « Surveillance » alone is a rule too")
        draft.red = true; XCTAssertNil(draft.problem)
        draft.weekdays = []; XCTAssertEqual(draft.problem, "Choisissez au moins un jour et deux heures différentes.")
        draft.weekdays = [1]; draft.endMinute = draft.startMinute; XCTAssertNotNil(draft.problem)
        draft = BlockRuleDraft(); draft.brightness = 0.4; XCTAssertNil(draft.problem, "the brightness alone is a rule")
    }

    func testANewRuleIsSavedInBothEnginesAndTheFirstRedRangeFollowsTheHours() throws {
        var now = wednesday10h
        let lists = blocking([list("Jeux", []), list("Vidéo", [])], { now }), screen = try braise({ now })
        XCTAssertTrue(screen.ranges.follows, "T-050 A3-11: the ranges always follow their hours")
        var draft = BlockRuleDraft(); draft.weekdays = [6]; draft.listIDs = Set(lists.lists.map(\.id)); draft.red = true; draft.lock = .typing
        var writes = BlockRulePlan.writes(draft, replacing: nil, lists: lists.lists, red: screen.ranges)
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: lists, braise: screen))
        XCTAssertTrue(screen.ranges.follows)
        let saved = BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].lists.count, 2); XCTAssertNotNil(saved[0].red); XCTAssertEqual(saved[0].lock, .typing)
        guard case .next = saved[0].state else { return XCTFail("the rule waits for Saturday: \(saved[0].state)") }
        // A second red rule waits for its own day: no « non suivis » state any more.
        draft = BlockRuleDraft(); draft.weekdays = [7]; draft.red = true
        writes = BlockRulePlan.writes(draft, replacing: nil, lists: lists.lists, red: screen.ranges)
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: lists, braise: screen))
        let all = BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris)
        guard case .next = all.first(where: { $0.isRedOnly })?.state else { return XCTFail("the red rule waits for Sunday") }
        now = now.addingTimeInterval(1)
    }

    func testARefusalOfOneEngineWritesNothingInTheOther() throws {
        // Wednesday 10:00: the red range 09:00–12:00 is « Verrouillé » and in progress. The lists' range is free.
        let now = wednesday10h
        let lists = blocking([list("Jeux", [morning()])], { now }), screen = try braise({ now })
        try screen.saveRange(morning(), intensity: 0.7)
        var locked = screen.ranges.program.ranges[0]; locked.lock = .locked
        try screen.saveRange(locked, intensity: 0.7); XCTAssertTrue(screen.active)
        // Two rules (different locks): edit the red one and add the list to it, with shorter hours.
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris).first { $0.isRedOnly })
        XCTAssertEqual(rule.lock, .locked)
        var draft = BlockRuleDraft(rule); draft.endMinute = 11 * 60; draft.listIDs = [lists.lists[0].id]
        let before = (lists.lists, screen.ranges)
        let refusal = BlockRulePlan.apply(BlockRulePlan.writes(draft, replacing: rule, lists: lists.lists, red: screen.ranges), blocking: lists, braise: screen)
        XCTAssertNotNil(refusal); XCTAssertEqual(lists.lists, before.0, "the lists are not written when the red screen refuses")
        XCTAssertEqual(screen.ranges, before.1)
        // Removing the protected rule is refused the same way.
        XCTAssertNotNil(BlockRulePlan.apply(BlockRulePlan.writes(nil, replacing: rule, lists: lists.lists, red: screen.ranges), blocking: lists, braise: screen))
        XCTAssertEqual(screen.ranges, before.1)
        // A longer rule is a strengthening: it is saved.
        draft = BlockRuleDraft(rule); draft.endMinute = 13 * 60
        XCTAssertNil(BlockRulePlan.apply(BlockRulePlan.writes(draft, replacing: rule, lists: lists.lists, red: screen.ranges), blocking: lists, braise: screen))
        XCTAssertEqual(screen.ranges.program.ranges.map(\.id), before.1.program.ranges.map(\.id)); XCTAssertEqual(screen.ranges.program.ranges[0].endMinute, 13 * 60)
    }

    func testALockedProgramRefusesAShorterRuleAndTheRedScreenStaysAsItWas() throws {
        let now = wednesday10h
        var game = list("Jeux", [morning()]); game.program.lockedUntil = now.addingTimeInterval(3_600)
        let lists = blocking([game], { now }), screen = try braise({ now })
        try screen.saveRange(BlockProgramRange(weekdays: [6], startMinute: 600, endMinute: 660), intensity: 0.5)
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris).first { !$0.isRedOnly })
        var draft = BlockRuleDraft(rule); draft.endMinute = 11 * 60; draft.red = true
        let before = screen.ranges
        let refusal = try XCTUnwrap(BlockRulePlan.apply(BlockRulePlan.writes(draft, replacing: rule, lists: lists.lists, red: screen.ranges), blocking: lists, braise: screen))
        XCTAssertTrue(refusal.hasPrefix("« Jeux » :"), refusal)
        XCTAssertEqual(lists.lists, [game]); XCTAssertEqual(screen.ranges, before, "no red range is added when the lists refuse")
    }

    // MARK: Migration: nothing moves

    func testReadingTheRulesWritesNoFile() throws {
        let root = try root(), now = wednesday10h
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking"))
        let first = BlockingController(clock: { now }, store: store, calendar: paris, continuous: { now.timeIntervalSince1970 })
        XCTAssertNil(first.save(list("Jeux", [morning(.typing)]))); first.shutdown()
        let screen = try braise({ now }, root: root)
        try screen.saveRange(morning(.typing), intensity: 0.6)
        let files = [root.appendingPathComponent("Blocking/blocking.json"), root.appendingPathComponent("Braise/ranges.json")]
        let lists = BlockingController(clock: { now }, store: store, calendar: paris, continuous: { now.timeIntervalSince1970 })
        addTeardownBlock { @MainActor in lists.shutdown() }
        let before = try files.map { try Data(contentsOf: $0) } // after launch: a launch may stamp its clock state
        let guardBefore = (GoalongProtectionProbe.until(lists, screen), screen.protectedWindow?.end)
        let result = BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris)
        XCTAssertEqual(result.count, 1, "the old lists' range and the old red range are one rule"); XCTAssertNotNil(result[0].red)
        _ = BlockRulePlan.writes(BlockRuleDraft(result[0]), replacing: result[0], lists: lists.lists, red: screen.ranges)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before, "reading the rules leaves both files byte for byte")
        let guardAfter = (GoalongProtectionProbe.until(lists, screen), screen.protectedWindow?.end)
        XCTAssertEqual(guardBefore.0, guardAfter.0); XCTAssertEqual(guardBefore.1, guardAfter.1)
        XCTAssertNotNil(guardAfter.1, "the armed range still protects after the page reads it")
    }
}

/// The protection end as the two engines give it, for the comparison before and after.
@MainActor private enum GoalongProtectionProbe {
    static func until(_ lists: BlockingController, _ screen: BraiseController) -> [Date?] {
        [lists.activeBlocks.filter { $0.lock != .free }.map(\.end).max(), screen.guardUntil]
    }
}
#endif
