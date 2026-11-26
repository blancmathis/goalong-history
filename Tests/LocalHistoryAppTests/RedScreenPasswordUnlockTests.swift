#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// Mathis' rule (2026-11-21): a block protected by the password is a commitment until that password is entered in the
/// app; then it ends, guard included. The night range « 21:00 → 06:00, Mot de passe » as ranges.json held it.
/// Test controllers only: no window, no focus taken.
@MainActor final class RedScreenPasswordUnlockTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Saturday 2026-11-21, 23:00 in Paris; the night range ends Sunday 06:00.
    private let now = ISO8601DateFormatter().date(from: "2026-11-21T22:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-11-22T05:00:00Z")!
    private let night = UUID(uuidString: "D0F94687-77ED-44BC-BDCA-CFA08D27C629")!
    private let password = "motdepasse-test"

    private func json(lock: String) -> String {
        """
        {"version": 1, "follows": true, "fullDayPaused": false, "skips": [], "holds": [], "disabled": [],
         "brightness": [], "intensities": ["\(night.uuidString)", 1],
         "program": {"ranges": [{"id": "\(night.uuidString)", "startMinute": 1260, "endMinute": 360,
                                 "weekdays": [1, 2, 3, 4, 5, 6, 7], "lock": "\(lock)"}]}}
        """
    }

    private func braise(lock: String = "password", directory: URL? = nil) throws -> (BraiseController, URL) {
        let dir: URL
        if let directory { dir = directory } else {
            let root = URL(fileURLWithPath: "/private/tmp/goalong-red-unlock-" + UUID().uuidString)
            dir = root.appendingPathComponent("Braise", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try Data(json(lock: lock).utf8).write(to: dir.appendingPathComponent("ranges.json"))
        }
        let store = BraiseStore(directory: dir, legacySettings: dir.appendingPathComponent("missing"))
        let now = self.now, password = self.password
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { now }, calendar: paris,
                                     continuous: { 50_000 }, boot: { "boot-1" }, hasPassword: { true },
                                     verifyPassword: { $0 == password ? .ok : .wrong(remaining: 3) })
        addTeardownBlock { @MainActor in c.shutdown() }
        c.evaluate()
        return (c, dir)
    }

    private func blocking(_ lists: [BlockList] = []) -> BlockingController {
        let now = self.now
        let c = BlockingController(document: BlockingDocument(lists: lists, passwordLock: BlockPasswordLock.make(password, at: now)),
                                   clock: { now }, calendar: paris, continuous: { now.timeIntervalSince1970 })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }

    private func nightRule(_ braise: BraiseController) throws -> BlockRule {
        try XCTUnwrap(BlockRules.current(blocking: nil, braise: braise, now: now, calendar: paris).first { $0.red?.rangeID == night })
    }

    func testThePasswordEndsTheNightRangeAndItsGuard() throws {
        let (c, dir) = try braise()
        XCTAssertEqual(c.protectedWindow?.lock, .password)
        XCTAssertEqual(c.guardUntil, end)

        XCTAssertEqual(c.stopRange(night, password: "faux"), .password(.wrong(remaining: 3)))
        XCTAssertEqual(c.guardUntil, end, "a wrong password changes nothing")
        XCTAssertTrue(c.ranges.skips.isEmpty)

        XCTAssertEqual(c.stopRange(night, password: password), .stopped)
        XCTAssertNil(c.protectedWindow); XCTAssertNil(c.guardUntil, "the guard marker is released")
        XCTAssertEqual(c.ranges.skips[night], end); XCTAssertNil(c.ranges.holds[night])

        // Persisted: a relaunch reads the skip and does not bring the range back before its next start.
        c.shutdown()
        let (again, _) = try braise(directory: dir)
        XCTAssertNil(again.protectedWindow); XCTAssertNil(again.guardUntil)
    }

    func testTheRuleSwitchOfARunningPasswordRangeEndsItThenTurnsItOff() throws {
        let (c, _) = try braise()
        let lists = blocking()
        let grant = RuleStopGrant(uptime: { 1_000 }, verifyPassword: { [password] in $0 == password ? .ok : .wrong(remaining: 3) })
        c.stopGrant = grant
        let rule = try nightRule(c)
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: true), .on(stop: .password))
        XCTAssertEqual(BlockRuleSwitch.of(rule, canVerifyPassword: false), .hidden, "the password comes from Blocage")

        XCTAssertNotNil(BlockRuleSwitchAction.turnOff(rule, proof: .password("faux"), blocking: lists, braise: c, grant: grant))
        XCTAssertEqual(c.guardUntil, end); XCTAssertFalse(c.ranges.disabled.contains(night))

        XCTAssertNil(BlockRuleSwitchAction.turnOff(rule, proof: .password(password), blocking: lists, braise: c, grant: grant))
        XCTAssertNil(c.guardUntil); XCTAssertNil(c.protectedWindow)
        XCTAssertTrue(c.ranges.disabled.contains(night))
    }

    /// Bug of 2026-11-21: « Supprimer » on the running night rule did nothing. Now the password ends the range and the
    /// same password passes the rule's stop: one prompt, then the rule is gone.
    func testDeletingARunningPasswordRuleAsksThePasswordThenDeletes() throws {
        let (c, _) = try braise()
        let grant = RuleStopGrant(uptime: { 1_000 }, verifyPassword: { [password] in $0 == password ? .ok : .wrong(remaining: 3) })
        c.stopGrant = grant
        let writes = BlockRulePlan.writes(nil, replacing: try nightRule(c), lists: [], red: c.ranges)
        XCTAssertEqual(c.runningPasswordRanges(writes.red, deleting: writes.deleting), [night])
        var asked = 0
        let noSecondPrompt: (BlockLock) -> Bool = { _ in XCTFail("the password was already given"); return false }

        XCTAssertEqual(BlockRulePlan.apply(writes, blocking: nil, braise: c, grant: grant, confirmStop: noSecondPrompt,
                                           askPassword: { _ in asked += 1; return nil }), RuleStopGrant.keptText)
        XCTAssertNotNil(BlockRulePlan.apply(writes, blocking: nil, braise: c, grant: grant, confirmStop: noSecondPrompt,
                                            askPassword: { _ in asked += 1; return "faux" }))
        XCTAssertEqual(c.guardUntil, end, "cancel or a wrong password change nothing")
        XCTAssertTrue(c.ranges.program.ranges.contains { $0.id == night })

        XCTAssertNil(BlockRulePlan.apply(writes, blocking: nil, braise: c, grant: grant, confirmStop: noSecondPrompt,
                                         askPassword: { _ in asked += 1; return self.password }))
        XCTAssertEqual(asked, 3)
        XCTAssertNil(c.guardUntil); XCTAssertFalse(c.ranges.program.ranges.contains { $0.id == night })
        XCTAssertFalse(grant.covers(.password), "the grant ends with the change")
    }

    /// T-057 L4 (blocage-05): a joined rule (list + red, both « Mot de passe ») running at 23:00. Deleting it with the
    /// right password is refused by the running list: the red window must not be ended first. A refusal changes nothing.
    func testARefusedDeletionOfAJoinedRuleKeepsTheRedScreenRunning() throws {
        let (c, _) = try braise()
        let grant = RuleStopGrant(uptime: { 1_000 }, verifyPassword: { [password] in $0 == password ? .ok : .wrong(remaining: 3) })
        c.stopGrant = grant
        let range = BlockProgramRange(weekdays: Set(1...7), startMinute: 21 * 60, endMinute: 6 * 60, lock: .password)
        let lists = blocking([BlockList(name: "Jeux", sites: [BlockSiteRule(pattern: "jeux.example")], program: BlockProgram(ranges: [range]))])
        lists.stopGrant = grant
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: c, now: now, calendar: paris).first { $0.red?.rangeID == night })
        XCTAssertFalse(rule.lists.isEmpty, "the list and the red range form one rule")
        let before = (lists.lists, c.ranges)
        let writes = BlockRulePlan.writes(nil, replacing: rule, lists: lists.lists, red: c.ranges)
        let refusal = BlockRulePlan.apply(writes, blocking: lists, braise: c, grant: grant, confirmStop: { _ in false },
                                          askPassword: { _ in self.password })
        if refusal != nil {
            XCTAssertEqual(c.guardUntil, end, "the red window still runs: \(refusal ?? "")")
            XCTAssertNotNil(c.protectedWindow)
            XCTAssertEqual(c.ranges, before.1, "no skip written"); XCTAssertEqual(lists.lists, before.0)
        } else {
            XCTAssertFalse(c.ranges.program.ranges.contains { $0.id == night })
            XCTAssertTrue(lists.lists.allSatisfy { $0.program.ranges.isEmpty }, "both parts gone together")
        }
        XCTAssertFalse(grant.covers(.password), "the grant ends with the change")
    }

    func testARunningLockedRuleIsNotOfferedThePassword() throws {
        let (c, _) = try braise(lock: "locked")
        let writes = BlockRulePlan.writes(nil, replacing: try nightRule(c), lists: [], red: c.ranges)
        XCTAssertTrue(c.runningPasswordRanges(writes.red, deleting: writes.deleting).isEmpty)
        XCTAssertNotNil(BlockRulePlan.apply(writes, blocking: nil, braise: c, confirmStop: { _ in false },
                                            askPassword: { _ in XCTFail("no password for « Verrouillé »"); return nil }))
        XCTAssertEqual(c.guardUntil, end)
    }

    /// Bug 2 of 2026-11-21: an installer's SIGTERM, refused by a protection, opens the « Quitter » prompt only when
    /// the member can pass it; « Verrouillé » keeps it ignored, and nothing to ask means nothing quits.
    func testAnInstallSignalAsksOnlyAPassableStop() {
        typealias D = AppDelegate
        XCTAssertTrue(D.signalQuitAsks(prompt: .password, ruleStop: nil, jevStep: .allow))
        XCTAssertTrue(D.signalQuitAsks(prompt: .quit, ruleStop: .password, jevStep: .allow), "an idle « Mot de passe » rule")
        XCTAssertTrue(D.signalQuitAsks(prompt: .quit, ruleStop: nil, jevStep: .password))
        XCTAssertFalse(D.signalQuitAsks(prompt: .quit, ruleStop: nil, jevStep: .allow), "nothing to ask: no quit")
        XCTAssertFalse(D.signalQuitAsks(prompt: .password, ruleStop: .locked, jevStep: .allow))
        XCTAssertFalse(D.signalQuitAsks(prompt: .locked(redScreen: true), ruleStop: .password, jevStep: .allow))
        XCTAssertFalse(D.signalQuitAsks(prompt: .redScreenPage, ruleStop: nil, jevStep: .password))
        XCTAssertFalse(D.signalQuitAsks(prompt: .password, ruleStop: nil, jevStep: .refused("verrouillé")))
    }

    func testOtherStopsKeepTheirRules() throws {
        for (lock, name) in [("locked", "Verrouillé"), ("typing", "Difficile")] {
            let (c, _) = try braise(lock: lock)
            XCTAssertEqual(BlockRuleSwitch.of(try nightRule(c), canVerifyPassword: true), .hidden, name)
            XCTAssertNotEqual(c.stopRange(night, password: password), .stopped, name)
            XCTAssertEqual(c.guardUntil, end, name)
            XCTAssertFalse(PasswordDisengagement.hasSomething(blocking: nil, braise: c), name)
        }
    }

    func testDisengagementEndsListsAndRedScreenTogether() throws {
        let (c, _) = try braise()
        let range = BlockProgramRange(weekdays: Set(1...7), startMinute: 21 * 60, endMinute: 24 * 60, lock: .password)
        let list = BlockList(name: "Jeux", sites: [BlockSiteRule(pattern: "jeux.example")], program: BlockProgram(ranges: [range]))
        let lists = blocking([list])
        XCTAssertTrue(lists.activeBlocks.contains { $0.lock == .password })
        XCTAssertTrue(PasswordDisengagement.hasSomething(blocking: lists, braise: c))

        XCTAssertEqual(PasswordDisengagement.end(password: "", blocking: lists, braise: c), BlockingController.emptyPasswordText)
        XCTAssertNotNil(PasswordDisengagement.end(password: "faux", blocking: lists, braise: c))
        XCTAssertFalse(lists.activeBlocks.isEmpty); XCTAssertEqual(c.guardUntil, end)

        XCTAssertNil(PasswordDisengagement.end(password: password, blocking: lists, braise: c))
        XCTAssertTrue(lists.activeBlocks.isEmpty); XCTAssertNil(c.guardUntil)
        XCTAssertFalse(PasswordDisengagement.hasSomething(blocking: lists, braise: c))
        XCTAssertNotNil(PasswordDisengagement.end(password: password, blocking: lists, braise: c), "nothing left to end")
    }
}
#endif
