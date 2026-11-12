#if os(macOS)
import BraiseCore
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-059 lot 2: the paths the Codex review of PR #343 found around a protected rule's stop. One test per closed path.
/// Memory floors, temporary folders and test defaults only: no keychain, no window, no focus taken.
@MainActor final class ProtectedFloorTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris: the 21:00 → 23:00 rules are scheduled, not running.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-floor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() -> UserDefaults {
        let name = "goalong-floor-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    private func range(_ lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)
    }
    private func list(_ lock: BlockLock?, name: String = "Jeux") -> BlockList {
        BlockList(name: name, sites: [BlockSiteRule(pattern: "jeux.example")], program: BlockProgram(ranges: [range(lock)]))
    }
    private var strong: JevInterventionSettings {
        var value = JevInterventionSettings(); value.effectsEnabled = true
        value.stages = [.init(afterMinutes: 2, effect: .dim, intensity: 40), .init(afterMinutes: 5, effect: .dimAndRed, intensity: 40)]
        return value
    }
    private func jevRange(_ lock: BlockLock) -> JevSurveillanceRange {
        JevSurveillanceRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60, lock: lock, settings: strong)
    }

    // MARK: Tampered files (high)

    /// blocking.json rewritten while Goalong was closed: the protected list comes back, a « Libre » one stays removed.
    func testBlockingFileTamperedOutsideGetsTheProtectedListBack() throws {
        let directory = try root().appendingPathComponent("Blocking")
        let floor = ProtectedFloor.memory()
        let protected = list(.typing), free = list(nil, name: "Libre")
        try BlockingStore(directory: directory, floor: floor).save(BlockingDocument(lists: [protected, free]), now: now)
        var weaker = protected; weaker.program.ranges[0].lock = .free
        try BlockingStore(directory: directory).save(BlockingDocument(lists: [weaker]), now: now) // the file, by hand

        let loaded = try BlockingStore(directory: directory, floor: floor).loadRecovering(now: now)
        XCTAssertGreaterThan(loaded.restored, 0)
        XCTAssertEqual(loaded.document.lists.map(\.id), [protected.id], "the free list removed outside stays removed")
        XCTAssertEqual(loaded.document.lists.first?.program.ranges.first?.lock, .typing)
        XCTAssertEqual(try BlockingStore(directory: directory).loadRecovering(now: now).document.lists.first?.program.ranges.first?.lock,
                       .typing, "written back to the file")

        var harder = protected; harder.program.ranges[0].lock = .password
        try BlockingStore(directory: directory).save(BlockingDocument(lists: [harder]), now: now)
        let kept = try BlockingStore(directory: directory, floor: floor).loadRecovering(now: now)
        XCTAssertEqual(kept.restored, 0, "hardening is kept")
        XCTAssertEqual(kept.document.lists.first?.program.ranges.first?.lock, .password)
    }

    /// Braise ranges.json emptied outside: the protected range comes back with a notice.
    func testRedScreenFileTamperedOutsideGetsTheProtectedRangeBack() throws {
        let base = try root(), directory = base.appendingPathComponent("Braise", isDirectory: true)
        let legacy = base.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let floor = ProtectedFloor.memory()
        var value = RedScreenProgram(); value.program = BlockProgram(ranges: [range(.typing)])
        try BraiseStore(directory: directory, legacySettings: legacy, floor: floor).saveRanges(value, now: now)
        try BraiseStore(directory: directory, legacySettings: legacy).saveRanges(RedScreenProgram(), now: now)

        let loaded = try BraiseStore(directory: directory, legacySettings: legacy, floor: floor)
            .loadRanges(migratingFrom: Preferences(), now: now)
        XCTAssertEqual(loaded.ranges, value)
        XCTAssertTrue(loaded.notice?.contains(ProtectedFloor.restoredText) == true)
        var free = RedScreenProgram(); free.program = BlockProgram(ranges: [range(nil)])
        try BraiseStore(directory: directory, legacySettings: legacy, floor: floor).saveRanges(free, now: now)
        XCTAssertNil(floor.load(RedScreenProgram.self, key: ProtectedFloor.redScreenKey), "nothing protected: no copy kept")
    }

    /// The Jev pref removed, weakened or made unreadable outside: its protected range comes back.
    func testJevPreferenceTamperedOutsideGetsTheProtectedRangeBack() {
        let d = defaults(), floor = ProtectedFloor.memory()
        let protected = jevRange(.typing)
        var document = JevSurveillanceDocument(); document.ranges = [protected]
        JevSurveillanceStore(defaults: d, floor: floor).save(document)

        d.set(Data("x".utf8), forKey: JevSurveillanceStore.storageKey)
        let unreadable = JevSurveillanceStore(defaults: d, floor: floor)
        XCTAssertNil(unreadable.error)
        XCTAssertEqual(unreadable.document.ranges, [protected])
        XCTAssertEqual(unreadable.restoredNotice, ProtectedFloor.restoredText)

        var weaker = document; weaker.ranges[0].lock = .free
        d.set(try? JSONEncoder().encode(weaker), forKey: JevSurveillanceStore.storageKey)
        XCTAssertEqual(JevSurveillanceStore(defaults: d, floor: floor).document.ranges.first?.lock, .typing)
        d.removeObject(forKey: JevSurveillanceStore.storageKey)
        XCTAssertEqual(JevSurveillanceStore(defaults: d, floor: floor).document.ranges, [protected])
    }

    // MARK: Garde-fous switch (high)

    /// Switching Garde-fous off with a protected rule that has not begun asks its stop; « Verrouillé » refuses.
    func testModuleSwitchAsksTheStopOfARuleNotRunning() {
        let grant = RuleStopGrant(uptime: { 1_000 }, verifyPassword: { _ in .ok })
        let now = self.now
        func controller(_ lock: BlockLock) -> BlockingController {
            let c = BlockingController(document: BlockingDocument(lists: [list(lock)], passwordLock: BlockPasswordLock.make("motdepasse-test", at: now)),
                                       clock: { now }, calendar: paris, continuous: { now.timeIntervalSince1970 })
            c.stopGrant = grant
            addTeardownBlock { @MainActor in c.shutdown() }
            return c
        }
        let typing = controller(.typing)
        XCTAssertNil(typing.moduleOffRefusal, "nothing runs: the old check let it off")
        XCTAssertEqual(typing.moduleOffRuleStop, .typing)
        XCTAssertNotNil(typing.moduleOffRuleRefusal)
        let text = grant.newChallenge()
        XCTAssertNil(grant.pass(.typing, proof: .typed(text, challenge: text)))
        XCTAssertNil(typing.moduleOffRuleRefusal, "the stop passed")
        XCTAssertEqual(controller(.locked).moduleOffRuleRefusal, RuleStopGrant.lockedText)
        XCTAssertNil(controller(.free).moduleOffRuleRefusal)
    }

    // MARK: Quit and SIGTERM (high)

    /// « Quitter » and SIGTERM read the strongest protected rule, running or not.
    func testQuitAndTerminationReadEveryProtectedRule() {
        let now = self.now
        let c = BlockingController(document: BlockingDocument(lists: [list(.typing)]), clock: { now }, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 })
        addTeardownBlock { @MainActor in c.shutdown() }
        XCTAssertNil(c.protectedUntil, "a rule not running yet: the old predicate let quit")
        XCTAssertEqual(BlockingRuntime(controller: c, redScreenKeeper: { nil }).protectedRuleStop(), .typing)
        XCTAssertEqual(BlockingRuntime.strongestRuleStop([.free, .typing, .password]), .password)
        XCTAssertNil(BlockingRuntime.strongestRuleStop([.free]))
        XCTAssertTrue(AppDelegate.ruleQuitNeedsStop(.typing, passwordGiven: false))
        XCTAssertFalse(AppDelegate.ruleQuitNeedsStop(.typing, passwordGiven: true), "the password already given covers it")
        XCTAssertTrue(AppDelegate.ruleQuitNeedsStop(.locked, passwordGiven: true))
        XCTAssertFalse(AppDelegate.honoursTerminationSignal(severeBlock: true, sessionEnding: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(severeBlock: true, sessionEnding: false, installOverride: true))
    }

    // MARK: Jev off before its range (high)

    /// Switching Jev off, its key and quitting ask the stop of a protected range that has not begun.
    func testJevCutAsksTheStopOfARangeNotRunning() {
        XCTAssertEqual(JevStopGate.protectedStep(activity: [], ranges: [jevRange(.typing)], jevEnabled: true, challenge: { "t" }),
                       .typing("t"))
        XCTAssertEqual(JevStopGate.protectedStep(activity: [], ranges: [jevRange(.locked)], jevEnabled: true),
                       .refused(RuleStopGrant.lockedText))
        XCTAssertEqual(JevStopGate.protectedStep(activity: [], ranges: [jevRange(.typing)], jevEnabled: false), .allow)
        XCTAssertEqual(JevStopGate.protectedStep(activity: [], ranges: [jevRange(.free)], jevEnabled: true), .allow)
    }

    // MARK: Medium

    /// Jev settings compare stage by stage: one stage lighter with another heavier is a weakening.
    func testJevSettingsCannotTradeOneStageForAnother() {
        var traded = strong
        traded.stages[0].intensity = 10; traded.stages[1].intensity = 85
        XCTAssertFalse(JevSurveillanceStore.isAtLeast(traded, strong))
        XCTAssertTrue(JevSurveillanceStore.score(traded) >= JevSurveillanceStore.score(strong), "the old score let it through")
        var later = strong; later.stages[0].afterMinutes = 4
        XCTAssertFalse(JevSurveillanceStore.isAtLeast(later, strong))
        var redder = strong; redder.stages[0].effect = .dimAndRed; redder.stages[0].intensity = 50
        XCTAssertTrue(JevSurveillanceStore.isAtLeast(redder, strong))
        var range = jevRange(.typing), next = range; next.settings = traded
        XCTAssertTrue(JevSurveillanceStore.weakens(range, next))
        range.settings = traded
        XCTAssertFalse(JevSurveillanceStore.weakens(range, range))
    }

    /// A brightness raised within the tolerance keeps its old value: small saves cannot add up.
    func testBrightnessWithinToleranceDoesNotAddUp() {
        var current = RedScreenProgram(); let protected = range(.typing)
        current.program = BlockProgram(ranges: [protected])
        current.brightness = [protected.id: 0.30]
        current.brightnessLock = BrightnessLockState(level: 0.30, lock: .typing, end: now.addingTimeInterval(3_600))
        var next = current
        next.brightness = [protected.id: 0.30 + BrightnessLockRules.tolerance]
        next.brightnessLock?.level = 0.303
        let snapped = RedScreenRules.snappingBrightness(next, from: current)
        XCTAssertEqual(snapped.brightness?[protected.id], 0.30)
        XCTAssertEqual(snapped.brightnessLock?.level, 0.30)
        next.brightness = [protected.id: 0.20]
        XCTAssertEqual(RedScreenRules.snappingBrightness(next, from: current).brightness?[protected.id], 0.20, "darker is kept")
    }

    // MARK: Lot 3 (re-review of lot 2)

    /// F1: ranges.json deleted while Goalong was closed. The migration (no old range) must not replace the copy first.
    func testRedScreenFileDeletedOutsideKeepsTheCopyThroughTheMigration() throws {
        let base = try root(), directory = base.appendingPathComponent("Braise", isDirectory: true)
        let legacy = base.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let floor = ProtectedFloor.memory(), store = BraiseStore(directory: directory, legacySettings: legacy, floor: floor)
        var value = RedScreenProgram(); value.program = BlockProgram(ranges: [range(.typing)])
        try store.saveRanges(value, now: now)
        try FileManager.default.removeItem(at: store.rangesURL)

        let loaded = try store.loadRanges(migratingFrom: Preferences(), now: now)
        XCTAssertEqual(loaded.ranges, value, "the protected range comes back")
        XCTAssertTrue(loaded.notice?.contains(ProtectedFloor.restoredText) == true)
        XCTAssertEqual(floor.load(RedScreenProgram.self, key: ProtectedFloor.redScreenKey), value, "the copy is still there")
        try Data("{".utf8).write(to: store.rangesURL)
        XCTAssertEqual(try store.loadRanges(migratingFrom: Preferences(), now: now).ranges, value, "unreadable: same")
    }

    /// F2: a protected session's list without a protected range of its own, its start, and a list locked only by
    /// `lockedUntil` are all compared, content included.
    func testSessionListsAndStartComeBackFromTheCopy() throws {
        let directory = try root().appendingPathComponent("Blocking")
        let floor = ProtectedFloor.memory()
        let used = list(nil, name: "Séance")
        var locked = list(nil, name: "Verrou"); locked.program.lockedUntil = now.addingTimeInterval(7_200)
        var document = BlockingDocument(lists: [used, locked])
        let session = BlockSession(listIDs: [used.id], start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3_600), lock: .typing)
        document.sessions = [session]
        try BlockingStore(directory: directory, floor: floor).save(document, now: now)

        var emptied = document
        emptied.lists[0].sites = []; emptied.lists[1].sites = []
        emptied.sessions[0].start = session.end.addingTimeInterval(-1)
        try BlockingStore(directory: directory).save(emptied, now: now) // the file, by hand

        let loaded = try BlockingStore(directory: directory, floor: floor).loadRecovering(now: now)
        XCTAssertEqual(loaded.document.lists.map(\.sites), [used.sites, locked.sites], "both lists keep their sites")
        XCTAssertEqual(loaded.document.sessions.first?.start, session.start, "the start is not pushed back")

        var harder = document; harder.lists[0].sites.append(BlockSiteRule(pattern: "plus.example"))
        harder.sessions[0].start = session.start.addingTimeInterval(-60)
        try BlockingStore(directory: directory).save(harder, now: now)
        let kept = try BlockingStore(directory: directory, floor: floor).loadRecovering(now: now)
        XCTAssertEqual(kept.restored, 0, "a longer list and an earlier start are hardening")
    }

    /// The Jev settings of the review: 2 min at 85 %, then 5 min at 10 %, both « Assombrir + rouge ».
    private var fallingStages: JevInterventionSettings {
        var value = JevInterventionSettings(); value.effectsEnabled = true
        value.stages = [.init(afterMinutes: 2, effect: .dimAndRed, intensity: 85), .init(afterMinutes: 5, effect: .dimAndRed, intensity: 10)]
        return value
    }

    /// F3: moving the lighter second stage earlier shows 10 % from 3 to 5 min instead of 85 %: a weakening.
    func testJevLighterStageMovedEarlierIsAWeakening() {
        var earlier = fallingStages; earlier.stages[1].afterMinutes = 3
        XCTAssertTrue(earlier.isValid)
        XCTAssertFalse(JevSurveillanceStore.isAtLeast(earlier, fallingStages))
        var range = jevRange(.locked); range.settings = fallingStages
        var next = range; next.settings = earlier
        XCTAssertTrue(JevSurveillanceStore.weakens(range, next))
        XCTAssertTrue(JevSurveillanceStore.restore(.init(ranges: [next]), floor: [range]).count == 1, "the prefs are restored too")
    }

    /// F4: moving the lighter second stage later keeps 85 % one more minute: a hardening, free under « Verrouillé ».
    func testJevLighterStageMovedLaterStaysFreeUnderLocked() {
        var later = fallingStages; later.stages[1].afterMinutes = 6
        XCTAssertTrue(JevSurveillanceStore.isAtLeast(later, fallingStages))
        let d = defaults(), store = JevSurveillanceStore(defaults: d)
        var range = jevRange(.locked); range.settings = fallingStages
        var document = JevSurveillanceDocument(); document.ranges = [range]
        store.save(document)
        var next = range; next.settings = later
        XCTAssertEqual(store.check(.save(next), now: now, calendar: paris), .allow)
        XCTAssertTrue(store.apply(.save(next), now: now))
    }

    /// N1: two surveillances at the same hours. A (« Verrouillé ») 85 % then 10 %, B 45 % then 45 %: A wins. Turning off
    /// A's second stage is locally stronger, but A then loses to B, and 45 % applies instead of 85 %: refused. The same
    /// edit made outside comes back at launch. Moving the light stage later (F4) stays free; a new free rule that would
    /// win with a lighter veil is refused too.
    func testJevTwoSurveillancesAreJudgedOnTheEffectApplied() {
        var a = jevRange(.locked); a.settings = fallingStages
        var b = jevRange(.free); b.settings = fallingStages
        b.settings.stages[0].intensity = 45; b.settings.stages[1].intensity = 45
        XCTAssertEqual(JevSurveillanceStore.strongest([a.settings, b.settings]), a.settings)
        let d = defaults(), store = JevSurveillanceStore(defaults: d)
        store.save(JevSurveillanceDocument(ranges: [a, b]))

        var off = a; off.settings.stages[1].enabled = false
        XCTAssertFalse(JevSurveillanceStore.weakens(a, off), "alone, a hardening")
        XCTAssertEqual(JevSurveillanceStore.strongest([off.settings, b.settings]), b.settings, "B now wins: 45 % at 3 min")
        XCTAssertEqual(JevSurveillanceStore.combinedLoss(old: a, new: off, in: store.document), .locked)
        XCTAssertNotEqual(store.check(.save(off), now: now, calendar: paris), .allow)
        XCTAssertFalse(store.apply(.save(off), now: now))
        XCTAssertEqual(store.document.ranges.first?.settings, a.settings, "nothing written")
        XCTAssertEqual(JevSurveillanceStore.restore(.init(ranges: [off, b]), floor: [a]).count, 1, "the prefs are restored too")

        var later = a; later.settings.stages[1].afterMinutes = 6
        XCTAssertEqual(store.check(.save(later), now: now, calendar: paris), .allow, "F4 stays free beside B")

        var thief = jevRange(.free); thief.settings = b.settings; thief.settings.stages[1].intensity = 60
        XCTAssertTrue(JevSurveillanceStore.score(thief.settings) > JevSurveillanceStore.score(a.settings))
        XCTAssertEqual(store.check(.save(thief), now: now, calendar: paris), .refused(JevSurveillanceStore.combinedText))
        var elsewhere = thief; elsewhere.weekdays = [6, 7]
        XCTAssertEqual(store.check(.save(elsewhere), now: now, calendar: paris), .allow, "never at the same time")
        XCTAssertEqual(store.check(.delete(b.id), now: now, calendar: paris), .allow, "removing the free one stays free")
    }

    /// F5: a keychain that cannot read is said, not taken for « nothing protected »; one that cannot write refuses a
    /// change the launch would undo (a stop passed), and lets a hardening through.
    func testKeychainFailureIsToldAndNeverUndoesAStopLater() throws {
        let directory = try root().appendingPathComponent("Blocking")
        let floor = ProtectedFloor.memory(), backing = try XCTUnwrap(floor.backing as? MemoryFloorBacking)
        let store = BlockingStore(directory: directory, floor: floor)
        let protected = list(.typing)
        try store.save(BlockingDocument(lists: [protected]), now: now)

        backing.failsWrites = true
        var stopped = protected; stopped.program.ranges[0].lock = .free
        XCTAssertThrowsError(try store.save(BlockingDocument(lists: [stopped]), now: now)) {
            XCTAssertEqual($0 as? BlockingStore.Failure, .floorUnavailable)
        }
        XCTAssertEqual(try BlockingStore(directory: directory).loadRecovering(now: now).document.lists.first?.program.ranges.first?.lock,
                       .typing, "nothing written")
        var harder = protected; harder.program.ranges[0].lock = .password
        XCTAssertTrue(try store.save(BlockingDocument(lists: [harder]), now: now), "hardening stays free")

        backing.failsWrites = false; backing.failsReads = true
        let unread = try BlockingStore(directory: directory, floor: ProtectedFloor(backing: backing)).loadRecovering(now: now)
        XCTAssertTrue(unread.copyUnavailable)

        let d = defaults(), jevFloor = ProtectedFloor.memory()
        (jevFloor.backing as? MemoryFloorBacking)?.failsReads = true
        XCTAssertEqual(JevSurveillanceStore(defaults: d, floor: jevFloor).restoredNotice, ProtectedFloor.unavailableText)
    }
}
#endif
