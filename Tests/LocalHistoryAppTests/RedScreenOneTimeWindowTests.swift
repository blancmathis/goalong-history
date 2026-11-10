#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import XCTest
@testable import LocalHistoryApp

/// Page « Blocages » (2026-11-10): a rule « Maintenant » with the red screen is a one-time window, a hold that belongs
/// to no range (`BraiseController.holdNow`). It keeps every safety of a protected range, without « Suivre mes
/// horaires ». A rule « Horaire » writes its ranges in one validated change (`saveRanges`).
/// Fake gamma only: no test changes the colors of this Mac.
@MainActor final class RedScreenOneTimeWindowTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 22:00 in Paris.
    private let wednesday22h = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-once-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func store(_ root: URL) -> BraiseStore {
        BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
    }
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000; var boot = "boot-1"
        init(_ now: Date) { self.now = now }
        func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); up += seconds }
    }
    private func controller(_ clocks: Clocks, gamma: BraiseGammaDriving = BraiseTestGamma(), store: BraiseStore? = nil,
                            password: String? = nil, keepsRanges: Bool = false) throws -> BraiseController {
        let store = try store ?? self.store(root())
        let c = try BraiseController(store: store, gamma: gamma, runsTimers: false, clock: { clocks.now }, calendar: paris,
                                     continuous: { clocks.up }, boot: { clocks.boot }, hasPassword: { password != nil },
                                     verifyPassword: { $0 == password ? .ok : .wrong(remaining: 3) })
        if !keepsRanges { for range in c.ranges.program.ranges { try c.deleteRange(range.id) } }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    /// Wednesday (ISO 3) 21:00–23:00.
    private func evening(_ lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: [3], startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)
    }
    private func hold(_ end: Date, _ lock: BlockLock, _ intensity: Double = 0.7) -> RedScreenProgram.Hold {
        RedScreenProgram.Hold(end: end, lock: lock, intensity: intensity)
    }

    // MARK: Rules: a hold of no range counts without « Suivre mes horaires »

    func testActiveWindowsCountAnOrphanHoldWithoutFollowing() {
        let end = wednesday22h.addingTimeInterval(3_600), orphan = UUID(), range = evening(.locked)
        var value = RedScreenProgram(); value.program.ranges = [range]; value.intensities[range.id] = 1
        value.holds = [orphan: hold(end, .locked), range.id: hold(end, .locked, 1)]
        XCTAssertFalse(value.follows)
        let windows = RedScreenRules.activeWindows(value, at: wednesday22h, calendar: paris, hasPassword: true)
        XCTAssertEqual(windows.map(\.rangeID), [orphan], "the hold of no range runs; the range and its own hold wait for « Suivre mes horaires »")
        XCTAssertEqual(windows.first?.lock, .locked); XCTAssertEqual(windows.first?.end, end)
        XCTAssertEqual(windows.first?.intensity ?? 0, 0.7, accuracy: 0.0001)
        value.follows = true
        XCTAssertEqual(Set(RedScreenRules.activeWindows(value, at: wednesday22h, calendar: paris, hasPassword: true).map(\.rangeID)), [orphan, range.id])
        // A stop (skip) ends it, and « Mot de passe » without a password holds as « Verrouillé ».
        value.follows = false; value.skips[orphan] = end
        XCTAssertTrue(RedScreenRules.activeWindows(value, at: wednesday22h, calendar: paris, hasPassword: true).isEmpty)
        value.skips = [:]; value.holds[orphan] = hold(end, .password)
        XCTAssertEqual(RedScreenRules.activeWindows(value, at: wednesday22h, calendar: paris, hasPassword: false).first?.lock, .locked)
    }

    func testNextBoundaryIsTheOrphanHoldEndWithoutFollowing() {
        let end = wednesday22h.addingTimeInterval(1_800), range = evening(nil)
        var value = RedScreenProgram(); value.program.ranges = [range]
        value.holds = [range.id: hold(wednesday22h.addingTimeInterval(600), .locked)]
        XCTAssertNil(RedScreenRules.nextBoundary(value, after: wednesday22h, calendar: paris), "not followed: no range, no range hold")
        value.holds[UUID()] = hold(end, .free)
        XCTAssertEqual(RedScreenRules.nextBoundary(value, after: wednesday22h, calendar: paris), end)
        value.follows = true
        XCTAssertEqual(RedScreenRules.nextBoundary(value, after: wednesday22h, calendar: paris), wednesday22h.addingTimeInterval(600))
    }

    // MARK: One-time window

    func testLockedOneTimeWindowRefusesEveryWeakeningAndEndsOnTime() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let end = wednesday22h.addingTimeInterval(3_600)
        let id = try c.holdNow(intensity: 0.7, until: end, lock: .locked)
        XCTAssertTrue(c.active); XCTAssertEqual(c.appliedIntensity, 0.7, accuracy: 0.0001)
        XCTAssertFalse(c.ranges.follows, "a one-time window never turns the ranges on")
        XCTAssertEqual(c.oneTimeWindows.map(\.rangeID), [id])
        // The guard and « Quitter » read these two: armed as for a severe block.
        XCTAssertEqual(c.guardUntil, end); XCTAssertEqual(c.guardLock, .locked)
        for result in [c.setManual(false), c.emergencyOff(), c.pause(), c.setIntensity(0.2)] {
            XCTAssertEqual(result, .locked(until: end))
        }
        XCTAssertEqual(c.slideIntensity(0.1), .applied, "the slider stops at the window's level, in place")
        XCTAssertTrue(c.active); XCTAssertEqual(c.appliedIntensity, 0.7, accuracy: 0.0001)
        guard case .locked = c.stopActiveRanges() else { return XCTFail("a locked window cannot be stopped") }
        XCTAssertEqual(c.setIntensity(0.9), .applied, "stronger is free")
        XCTAssertEqual(c.appliedIntensity, 0.9, accuracy: 0.0001)
        clocks.pass(3_601); c.evaluate()
        XCTAssertFalse(c.active, "the window ended on time"); XCTAssertTrue(c.ranges.holds.isEmpty); XCTAssertNil(c.guardUntil)
        XCTAssertEqual(c.setManual(false), .applied)
    }

    func testOneTimeWindowLeavesTheRangesAndTheManualRedAlone() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(evening(nil), intensity: 0.9)
        XCTAssertFalse(c.active, "ranges are not followed")
        try c.holdNow(intensity: 0.5, until: wednesday22h.addingTimeInterval(1_800), lock: .free)
        XCTAssertTrue(c.active); XCTAssertEqual(c.appliedIntensity, 0.5, accuracy: 0.0001, "the range at 90 % stays off")
        XCTAssertFalse(c.ranges.follows); XCTAssertEqual(c.preferences.mode, .off)
        XCTAssertNil(c.guardUntil, "« Libre » arms nothing")
        clocks.pass(1_801); c.evaluate()
        XCTAssertFalse(c.active, "a free window still ends on time")
    }

    func testFreeOneTimeWindowStopsAtOnce() throws {
        let clocks = Clocks(wednesday22h), gamma = BraiseTestGamma(), c = try controller(clocks, gamma: gamma)
        try c.holdNow(intensity: 0.6, until: wednesday22h.addingTimeInterval(3_600), lock: .free)
        XCTAssertTrue(c.active)
        XCTAssertEqual(c.emergencyOff(), .applied); XCTAssertFalse(c.active); XCTAssertGreaterThan(gamma.restores, 0)
        XCTAssertTrue(c.ranges.holds.isEmpty)
    }

    func testTypingOneTimeWindowNeedsTheText() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let end = wednesday22h.addingTimeInterval(3_600)
        try c.holdNow(intensity: 1, until: end, lock: .typing)
        // The guard and « Quitter » read it as a range of the same lock.
        XCTAssertEqual(c.guardUntil, end); XCTAssertEqual(c.guardLock, .typing)
        XCTAssertEqual(GoalongProtection.quit(blocksLocked: false, blocksPassword: false, redScreenLock: c.guardLock), .redScreenPage)
        XCTAssertEqual(c.setManual(false), .needsStop(lock: .typing, end: end)); XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(typed: "non", challenge: "oui"), .wrongText); XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(typed: "oui", challenge: "oui"), .stopped)
        XCTAssertFalse(c.active); XCTAssertTrue(c.ranges.holds.isEmpty)
    }

    func testPasswordOneTimeWindowNeedsAPasswordToStartAndToStop() throws {
        let clocks = Clocks(wednesday22h), end = wednesday22h.addingTimeInterval(3_600)
        let without = try controller(clocks)
        XCTAssertThrowsError(try without.holdNow(intensity: 1, until: end, lock: .password)) {
            XCTAssertTrue(($0 as? RedScreenRefusal)?.message.contains("mot de passe") == true)
        }
        XCTAssertFalse(without.active); XCTAssertTrue(without.ranges.holds.isEmpty)
        let c = try controller(clocks, password: "secret")
        try c.holdNow(intensity: 1, until: end, lock: .password)
        XCTAssertEqual(c.guardUntil, end); XCTAssertEqual(c.guardLock, .password)
        XCTAssertEqual(GoalongProtection.quit(blocksLocked: false, blocksPassword: false, redScreenLock: c.guardLock), .password)
        guard case .password = c.stopActiveRanges(password: "faux") else { return XCTFail("a wrong password stops nothing") }
        XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(password: "secret"), .stopped); XCTAssertFalse(c.active)
    }

    /// A one-time window does not depend on « Suivre mes horaires »: unchecking it asks nothing and stops nothing.
    func testUncheckingFollowLeavesAOneTimeWindowAlone() throws {
        for lock in [BlockLock.typing, .locked] {
            let clocks = Clocks(wednesday22h), c = try controller(clocks)
            let end = wednesday22h.addingTimeInterval(3_600)
            try c.holdNow(intensity: 0.7, until: end, lock: lock)
            XCTAssertEqual(c.setFollows(false), .applied, "\(lock)")
            XCTAssertFalse(c.ranges.follows); XCTAssertTrue(c.active); XCTAssertEqual(c.ranges.holds.count, 1)
            XCTAssertEqual(c.guardUntil, end); XCTAssertEqual(c.guardLock, lock)
        }
    }

    func testOneTimeWindowRefusesABadEndAndWritesNothing() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        // A red of 0 % that holds no brightness would lock « Quitter » for a screen that does not change.
        XCTAssertEqual(c.holdRefusal(intensity: 0, until: wednesday22h.addingTimeInterval(600), lock: .locked)?.message,
                       "Choisissez un rouge ou une luminosité.")
        XCTAssertThrowsError(try c.holdNow(intensity: 0, until: wednesday22h.addingTimeInterval(600), lock: .locked))
        XCTAssertNil(c.holdRefusal(intensity: BraiseController.minimumHoldIntensity, until: wednesday22h.addingTimeInterval(600), lock: .locked))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(30), lock: .locked))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(-60), lock: .free))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(25 * 3_600), lock: .locked))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, brightness: 0.4, until: wednesday22h.addingTimeInterval(600), lock: .free),
                             "no screen of the test Mac takes a brightness level")
        XCTAssertTrue(c.ranges.holds.isEmpty); XCTAssertFalse(c.active)
        for _ in 0..<BraiseController.maximumOneTimeWindows { try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(600), lock: .free) }
        // The check without a write says it first: « Maintenant » starts no block that its red screen would refuse.
        XCTAssertNotNil(c.holdRefusal(until: wednesday22h.addingTimeInterval(600), lock: .free))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(600), lock: .free))
        XCTAssertEqual(c.ranges.holds.count, BraiseController.maximumOneTimeWindows)
        // The windows have ended: their places are free again, and the check still wrote nothing.
        clocks.pass(601)
        let stored = c.ranges
        XCTAssertNil(c.holdRefusal(until: clocks.now.addingTimeInterval(600), lock: .free)); XCTAssertEqual(c.ranges, stored)
    }

    /// A technical fault gives the colors back at once, even during a locked one-time window.
    func testTechnicalFaultGivesTheColorsBackDuringALockedOneTimeWindow() throws {
        let clocks = Clocks(wednesday22h), gamma = BraiseTestGamma(), c = try controller(clocks, gamma: gamma)
        try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(3_600), lock: .locked); XCTAssertTrue(c.active)
        gamma.onError?("macOS n’a pas conservé le filtre.")
        XCTAssertFalse(c.active); XCTAssertNotNil(c.errorMessage); XCTAssertTrue(c.ranges.holds.isEmpty)
        clocks.pass(60); c.evaluate()
        XCTAssertFalse(c.active, "it does not come back before its end")
    }

    func testOneTimeWindowSurvivesAClockJump() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(3_600), lock: .locked)
        clocks.now = wednesday22h.addingTimeInterval(5 * 3_600); clocks.up += 60; c.evaluate()
        XCTAssertTrue(c.active, "the wall clock moved 5 h, the Mac lived 1 min: still red")
        let end = try XCTUnwrap(c.protectedWindow?.end)
        XCTAssertEqual(end.timeIntervalSince(clocks.now), 3_540, accuracy: 2)
        XCTAssertEqual(c.setManual(false), .locked(until: end))
        clocks.now = wednesday22h.addingTimeInterval(-86_400); clocks.up += 60; c.evaluate()
        XCTAssertEqual(try XCTUnwrap(c.protectedWindow?.end).timeIntervalSince(clocks.now), 3_480, accuracy: 2, "set back a day: the time left stays")
        clocks.pass(3_481); c.evaluate()
        XCTAssertFalse(c.active, "the hour really passed")
    }

    /// App killed (no shutdown), clock set forward, relaunch in the same boot: still protected until the real end.
    /// After a reboot the wall clock decides, as for a block.
    func testOneTimeWindowSurvivesAKillAndARestart() throws {
        let root = try root(), clocks = Clocks(wednesday22h)
        let first = try controller(clocks, store: store(root))
        let id = try first.holdNow(intensity: 0.8, until: wednesday22h.addingTimeInterval(3_600), lock: .locked)
        clocks.now = wednesday22h.addingTimeInterval(2 * 3_600); clocks.up += 30
        let second = try controller(clocks, store: store(root), keepsRanges: true)
        XCTAssertTrue(second.active, "+2 h on the clock, 30 s lived: the window still holds")
        XCTAssertFalse(second.ranges.follows); XCTAssertEqual(second.oneTimeWindows.map(\.rangeID), [id])
        let end = try XCTUnwrap(second.protectedWindow?.end)
        XCTAssertEqual(end.timeIntervalSince(clocks.now), 3_570, accuracy: 2)
        XCTAssertEqual(second.setManual(false), .locked(until: end)); XCTAssertEqual(second.guardLock, .locked)
        // Reboot 10 minutes before the end (wall frame): 10 minutes left.
        clocks.now = end.addingTimeInterval(-600); clocks.up = 10; clocks.boot = "boot-2"
        let third = try controller(clocks, store: store(root), keepsRanges: true)
        XCTAssertTrue(third.active); XCTAssertEqual(try XCTUnwrap(third.guardUntil).timeIntervalSince(end), 0, accuracy: 1)
        clocks.pass(601); third.evaluate()
        XCTAssertFalse(third.active); XCTAssertTrue(third.ranges.holds.isEmpty)
    }

    /// Range writes start from the live state: the one-time window stays. While it is protected, the ranges can only
    /// get stricter, as during a protected range.
    func testRangeWritesKeepAOneTimeWindow() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let end = wednesday22h.addingTimeInterval(3_600)
        let range = BlockProgramRange(weekdays: [5], startMinute: 600, endMinute: 660, lock: nil)
        let free = try c.holdNow(intensity: 0.7, until: end, lock: .free)
        try c.saveRange(range, intensity: 1); try c.setRangeEnabled(range.id, false); try c.deleteRange(range.id)
        XCTAssertEqual(c.oneTimeWindows.map(\.rangeID), [free]); XCTAssertTrue(c.active)
        let locked = try c.holdNow(intensity: 0.9, until: end, lock: .locked)
        try c.saveRange(range, intensity: 1)
        XCTAssertThrowsError(try c.deleteRange(range.id)) { XCTAssertEqual(($0 as? RedScreenRefusal)?.isLock, true) }
        XCTAssertEqual(Set(c.oneTimeWindows.map(\.rangeID)), [free, locked]); XCTAssertEqual(c.guardUntil, end)
        XCTAssertEqual(c.appliedIntensity, 0.9, accuracy: 0.0001)
    }

    // MARK: Grouped write

    func testSaveRangesWritesAllOrNothing() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let a = BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 660, lock: nil)
        let b = BlockProgramRange(weekdays: [2], startMinute: 600, endMinute: 660, lock: .typing)
        let empty = BlockProgramRange(weekdays: [], startMinute: 600, endMinute: 660, lock: nil)
        XCTAssertThrowsError(try c.saveRanges([.init(range: a, intensity: 0.5), .init(range: empty, intensity: 1)]))
        XCTAssertTrue(c.ranges.program.ranges.isEmpty, "one bad range: nothing is written")
        XCTAssertThrowsError(try c.checkRanges([.init(range: empty, intensity: 1)]))
        XCTAssertNoThrow(try c.checkRanges([.init(range: a, intensity: 0.5), .init(range: b, intensity: 0.8, enabled: false)]))
        XCTAssertTrue(c.ranges.program.ranges.isEmpty, "a check writes nothing")
        try c.saveRanges([.init(range: a, intensity: 0.5), .init(range: b, intensity: 0.8, enabled: false)])
        XCTAssertEqual(c.ranges.program.ranges.map(\.id), [a.id, b.id])
        XCTAssertEqual(c.ranges.intensity(of: a.id), 0.5, accuracy: 0.0001); XCTAssertEqual(c.ranges.disabled, [b.id])
        // Replace one and remove the other in the same change.
        var later = a; later.endMinute = 720
        try c.saveRanges([.init(range: later, intensity: 0.6)], deleting: [b.id])
        XCTAssertEqual(c.ranges.program.ranges, [later]); XCTAssertTrue(c.ranges.disabled.isEmpty)
        XCTAssertNil(c.ranges.intensities[b.id])
    }

    func testSaveRangesRefusesTheWholeChangeDuringAProtectedRange() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let range = evening(.locked)
        try c.saveRange(range, intensity: 0.7); c.setFollows(true); XCTAssertTrue(c.active)
        let extra = BlockProgramRange(weekdays: [4], startMinute: 60, endMinute: 120, lock: nil)
        var shorter = range; shorter.endMinute = 22 * 60 + 30
        XCTAssertThrowsError(try c.saveRanges([.init(range: extra, intensity: 1), .init(range: shorter, intensity: 0.7)])) {
            XCTAssertEqual(($0 as? RedScreenRefusal)?.isLock, true)
        }
        XCTAssertThrowsError(try c.checkRanges([], deleting: [range.id])) { XCTAssertEqual(($0 as? RedScreenRefusal)?.isLock, true) }
        XCTAssertEqual(c.ranges.program.ranges, [range], "the stricter half of a refused change is not written either")
        var longer = range; longer.endMinute = 23 * 60 + 30
        XCTAssertNoThrow(try c.saveRanges([.init(range: extra, intensity: 1), .init(range: longer, intensity: 0.9)]))
        XCTAssertEqual(c.ranges.program.ranges.count, 2)
    }

    /// A stopped engine says so: the page must not show a rule that was never written.
    func testAStoppedEngineRefusesToWrite() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        c.shutdown()
        let range = evening(nil)
        XCTAssertThrowsError(try c.saveRange(range, intensity: 1))
        XCTAssertThrowsError(try c.checkRanges([.init(range: range, intensity: 1)]))
        XCTAssertThrowsError(try c.holdNow(intensity: 1, until: wednesday22h.addingTimeInterval(600), lock: .free))
        XCTAssertTrue(c.ranges.program.ranges.isEmpty); XCTAssertTrue(c.ranges.holds.isEmpty)
    }
}
#endif
