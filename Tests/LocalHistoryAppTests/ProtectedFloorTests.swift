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
}
#endif
