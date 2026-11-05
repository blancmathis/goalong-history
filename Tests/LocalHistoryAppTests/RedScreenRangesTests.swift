#if os(macOS)
import AppKit
import BraiseCore
import Combine
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-048 B2: the red screen's ranges use the blocking model (BlockProgram, range locks, « stricter only »).
/// Fake gamma only: no test changes the colors of this Mac.
@MainActor final class RedScreenRangesTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 22:00 in Paris.
    private let wednesday22h = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-ranges-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func store(_ root: URL) -> BraiseStore {
        BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
    }
    /// Wall clock, continuous clock (`BlockingClock.continuous`: counts during sleep) and boot.
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000; var boot = "boot-1"
        init(_ now: Date) { self.now = now }
        /// Both clocks move: the Mac lived (awake or asleep) `seconds`.
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
    /// Wednesday (ISO 3) 22:00 – Thursday 07:00.
    private func night(_ lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: [3], startMinute: 22 * 60, endMinute: 7 * 60, lock: lock)
    }

    // MARK: Migration of the Braise schedule

    func testMigrationKeepsDaysMidnightAndDisabledRules() throws {
        var preferences = Preferences(); preferences.mode = .auto; preferences.intensity = 0.6
        let night = ScheduleRule(weekdays: [2, 4, 6], startMinute: 22 * 60, endMinute: 7 * 60) // Mon, Wed, Fri (Foundation)
        let toMidnight = ScheduleRule(weekdays: [1], startMinute: 20 * 60, endMinute: 0)       // Sunday 20:00–00:00
        var off = ScheduleRule(weekdays: [7], startMinute: 9 * 60, endMinute: 10 * 60); off.enabled = false
        let empty = ScheduleRule(weekdays: [3], startMinute: 600, endMinute: 600)
        preferences.rules = [night, toMidnight, off, empty]
        let value = RedScreenProgram.migrated(from: preferences)
        XCTAssertTrue(value.follows, "Braise « auto » follows the ranges")
        XCTAssertEqual(value.program.ranges.map(\.id), [night.id, toMidnight.id, off.id, empty.id], "same ids, same order")
        XCTAssertEqual(value.program.ranges[0].weekdays, [1, 3, 5], "Foundation Mon/Wed/Fri become ISO 1/3/5")
        XCTAssertEqual(value.program.ranges[0].endMinute, 7 * 60); XCTAssertTrue(value.program.ranges[0].crossesMidnight)
        XCTAssertEqual(value.program.ranges[1].weekdays, [7], "Foundation Sunday = 1 is ISO 7")
        XCTAssertEqual(value.program.ranges[1].endMinute, 1_440, "00:00 end = 24:00 the same day")
        XCTAssertEqual(value.disabled, [off.id, empty.id])
        XCTAssertEqual(value.intensity(of: night.id), 0.6, accuracy: 0.0001)
        XCTAssertNil(value.program.ranges[0].lock, "a migrated range is free, as Braise was")
        // The same windows as Braise: Monday 22:00 → Tuesday 07:00 in Paris, Sunday 20:00 → midnight.
        let monday23h = ISO8601DateFormatter().date(from: "2026-11-02T22:00:00Z")!
        let tuesday6h = ISO8601DateFormatter().date(from: "2026-11-03T05:00:00Z")!
        let tuesday8h = ISO8601DateFormatter().date(from: "2026-11-03T07:00:00Z")!
        let sunday2330 = ISO8601DateFormatter().date(from: "2026-11-08T22:30:00Z")!
        let monday0030 = ISO8601DateFormatter().date(from: "2026-11-08T23:30:00Z")!
        let activeAt = { (date: Date) in Set(RedScreenRules.activeWindows(value, at: date, calendar: self.paris, hasPassword: false).map(\.rangeID)) }
        XCTAssertEqual(activeAt(monday23h), [night.id]); XCTAssertEqual(activeAt(tuesday6h), [night.id]); XCTAssertEqual(activeAt(tuesday8h), [])
        XCTAssertEqual(activeAt(sunday2330), [toMidnight.id]); XCTAssertEqual(activeAt(monday0030), [])
        let window = try XCTUnwrap(RedScreenRules.activeWindows(value, at: sunday2330, calendar: paris, hasPassword: false).first)
        XCTAssertEqual(window.end, ISO8601DateFormatter().date(from: "2026-11-08T23:00:00Z"), "ends at midnight Paris")
    }

    /// Fall back in Paris (2026-10-25, 03:00 → 02:00): like Braise, a range ending in the repeated hour ends at its second pass.
    func testMigratedRangeAcrossTheClockChangeEndsAtTheLastPass() throws {
        var preferences = Preferences(); preferences.mode = .auto
        let rule = ScheduleRule(weekdays: [1], startMinute: 90, endMinute: 150) // Sunday 01:30–02:30
        preferences.rules = [rule]
        let value = RedScreenProgram.migrated(from: preferences)
        let firstPass = ISO8601DateFormatter().date(from: "2026-10-25T00:45:00Z")!  // 02:45 summer time
        let secondPass = ISO8601DateFormatter().date(from: "2026-10-25T01:15:00Z")! // 02:15 winter time
        let after = ISO8601DateFormatter().date(from: "2026-10-25T01:31:00Z")!
        for date in [firstPass, secondPass] {
            XCTAssertEqual(RedScreenRules.activeWindows(value, at: date, calendar: paris, hasPassword: false).map(\.rangeID), [rule.id])
        }
        XCTAssertEqual(RedScreenRules.activeWindows(value, at: after, calendar: paris, hasPassword: false), [])
    }

    func testStoreMigratesOnceAndKeepsTheOldRules() throws {
        let store = store(try root())
        var preferences = Preferences(); preferences.mode = .auto
        preferences.rules = [ScheduleRule(weekdays: [2], startMinute: 60, endMinute: 120)]
        _ = try store.load(); try store.save(preferences)
        let first = try store.loadRanges(migratingFrom: preferences)
        XCTAssertEqual(first.ranges.program.ranges.count, 1); XCTAssertNil(first.notice)
        preferences.rules = []
        XCTAssertEqual(try store.loadRanges(migratingFrom: preferences).ranges, first.ranges, "ranges.json wins after the first load")
        XCTAssertEqual(try store.load().rules.count, 1, "settings.json keeps the Braise rules for an older Goalong")
        try Data("{".utf8).write(to: store.rangesURL)
        let damaged = try store.loadRanges(migratingFrom: try store.load())
        XCTAssertEqual(damaged.ranges.program.ranges.count, 1); XCTAssertNotNil(damaged.notice)
    }

    // MARK: Cumul and B1 commands

    func testManualAndRangesAddUpTheStrongestWins() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(evening(nil), intensity: 0.8); c.setFollows(true)
        XCTAssertTrue(c.active); XCTAssertEqual(c.appliedIntensity, 0.8, accuracy: 0.0001)
        c.update { $0.intensity = 0.4 }; c.setManual(true)
        XCTAssertEqual(c.appliedIntensity, 0.8, accuracy: 0.0001, "manual 40 % under a range at 80 %: 80 %")
        c.update { $0.intensity = 0.95 }; c.evaluate()
        XCTAssertEqual(c.appliedIntensity, 0.95, accuracy: 0.0001)
    }

    func testFreeRangeCommandsActAtOnce() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let range = evening(nil)
        try c.saveRange(range, intensity: 1); c.setFollows(true); XCTAssertTrue(c.active)
        XCTAssertEqual(c.emergencyOff(), .applied); XCTAssertFalse(c.active)
        XCTAssertEqual(c.ranges.skips[range.id], ISO8601DateFormatter().date(from: "2026-11-04T22:00:00Z"), "stopped until the range's end")
        XCTAssertTrue(c.ranges.follows, "« Rétablir » never drops the ranges")
        clocks.now = ISO8601DateFormatter().date(from: "2026-11-11T21:00:00Z")!; c.evaluate()
        XCTAssertTrue(c.active, "next week the range is back")
    }

    func testManualSwitchOffNeverDropsTheRanges() throws {
        let clocks = Clocks(wednesday22h.addingTimeInterval(-3 * 3600)), c = try controller(clocks)
        try c.saveRange(evening(nil), intensity: 1); c.setFollows(true)
        c.setManual(true); XCTAssertTrue(c.active)
        c.setManual(false); XCTAssertFalse(c.active); XCTAssertTrue(c.ranges.follows)
        clocks.now = wednesday22h; c.evaluate(); XCTAssertTrue(c.active, "the range still turns red on")
    }

    // MARK: Locks

    func testLockedRangeRefusesEveryWeakeningAndAllowsStricter() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        let range = evening(.locked)
        try c.saveRange(range, intensity: 0.7); c.setFollows(true); XCTAssertTrue(c.active)
        let end = ISO8601DateFormatter().date(from: "2026-11-04T22:00:00Z")!
        for result in [c.setManual(false), c.emergencyOff(), c.pause(), c.setFollows(false), c.setIntensity(0.2)] {
            XCTAssertEqual(result, .locked(until: end))
        }
        XCTAssertTrue(c.active); XCTAssertEqual(c.appliedIntensity, 0.7, accuracy: 0.0001); XCTAssertTrue(c.ranges.follows)
        XCTAssertTrue(c.errorMessage?.contains("Verrouillé jusqu’à") == true)
        XCTAssertThrowsError(try c.deleteRange(range.id)) { XCTAssertEqual(($0 as? RedScreenRefusal)?.isLock, true) }
        XCTAssertThrowsError(try c.setRangeEnabled(range.id, false))
        XCTAssertThrowsError(try c.saveRange(range, intensity: 0.5), "lower intensity is a weakening")
        var shorter = range; shorter.endMinute = 22 * 60 + 30
        XCTAssertThrowsError(try c.saveRange(shorter, intensity: 0.7))
        // Stricter is free: longer, stronger, a new range.
        var longer = range; longer.endMinute = 23 * 60 + 30
        XCTAssertNoThrow(try c.saveRange(longer, intensity: 0.9))
        XCTAssertNoThrow(try c.saveRange(BlockProgramRange(weekdays: [4], startMinute: 60, endMinute: 120, lock: nil), intensity: 1))
        XCTAssertEqual(c.setIntensity(0.95), .applied, "above the range: allowed, the range is strengthened")
        XCTAssertEqual(c.appliedIntensity, 0.95, accuracy: 0.0001)
        guard case .locked = c.stopActiveRanges() else { return XCTFail("a locked range cannot be stopped") }
        XCTAssertTrue(c.active)
    }

    /// The editor asks `refusal(for:)` from its body: asking must not publish, or each body asks for the next one
    /// (the editor spun the main thread; gallery watchdog). Both outside and during a protected range.
    func testRefusalAskedFromTheEditorBodyPublishesNothing() throws {
        let clocks = Clocks(wednesday22h), rangesStore = try store(root()), c = try controller(clocks, store: rangesStore)
        let range = evening(.locked)
        try c.saveRange(range, intensity: 0.7); c.setFollows(true); XCTAssertTrue(c.active)
        var published = 0
        let watch = c.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }
        var next = c.ranges; next.intensities[range.id] = 0.2
        for _ in 0..<3 { XCTAssertNotNil(c.refusal(for: next)); XCTAssertNil(c.refusal(for: c.ranges)) }
        XCTAssertEqual(published, 0)
        // Review B2 point 6: even when the hold's end must move (wall clock set forward 2 min), asking changes nothing.
        let before = c.ranges, file = try Data(contentsOf: rangesStore.rangesURL)
        clocks.now = clocks.now.addingTimeInterval(120)
        for _ in 0..<3 { XCTAssertNotNil(c.refusal(for: next)) }
        XCTAssertEqual(published, 0); XCTAssertEqual(c.ranges, before)
        XCTAssertEqual(try Data(contentsOf: rangesStore.rangesURL), file, "ranges.json is not written from the editor's body")
    }

    func testTypingRangeNeedsTheTextThenRunsTheWaitingCommand() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        var opened = 0; c.onStopRequired = { opened += 1 }
        try c.saveRange(evening(.typing), intensity: 1); c.setFollows(true)
        let end = ISO8601DateFormatter().date(from: "2026-11-04T22:00:00Z")!
        XCTAssertEqual(c.emergencyOff(), .needsStop(lock: .typing, end: end))
        XCTAssertEqual(opened, 1); XCTAssertEqual(c.pendingStop, .emergency); XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(typed: "faux", challenge: "vrai"), .wrongText); XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(typed: "vrai", challenge: "vrai"), .stopped)
        XCTAssertFalse(c.active); XCTAssertNil(c.pendingStop); XCTAssertTrue(c.ranges.follows)
    }

    func testPasswordRangeAndNoPasswordCountsAsLocked() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks, password: "secret")
        try c.saveRange(evening(.password), intensity: 1); c.setFollows(true)
        XCTAssertEqual(c.pause(), .needsStop(lock: .password, end: ISO8601DateFormatter().date(from: "2026-11-04T22:00:00Z")!))
        XCTAssertEqual(c.stopActiveRanges(password: "non"), .password(.wrong(remaining: 3))); XCTAssertTrue(c.active)
        XCTAssertEqual(c.stopActiveRanges(password: "secret"), .stopped)
        XCTAssertTrue(c.isPaused); XCTAssertFalse(c.active)

        let other = try controller(Clocks(wednesday22h))
        XCTAssertThrowsError(try other.saveRange(evening(.password), intensity: 1), "no blocking password: no « Mot de passe » range")
        XCTAssertEqual(RedScreenRules.effectiveLock(.password, hasPassword: false), .locked)
    }

    /// A protected window is held until its end even if the wall clock jumps forward; the continuous clock decides.
    func testProtectedRangeSurvivesAClockJump() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(evening(.locked), intensity: 1); c.setFollows(true); XCTAssertTrue(c.active)
        clocks.now = wednesday22h.addingTimeInterval(5 * 3600); clocks.up += 60; c.evaluate()
        XCTAssertTrue(c.active, "the wall clock moved 5 h, the Mac lived 1 min: still red")
        XCTAssertEqual(c.setManual(false), .locked(until: try XCTUnwrap(c.protectedWindow?.end)))
        clocks.pass(3_600); c.evaluate()
        XCTAssertFalse(c.active, "the hour really passed")
        XCTAssertTrue(c.ranges.holds.isEmpty)
    }

    /// Review B2 point 1: the Mac sleeps from 23:00 to 08:00 during a 22:00–07:00 « Verrouillé » range. Sleep counts:
    /// at wake the range is over and every command acts at once (B2 held it until 16:00).
    func testSleepCountsTowardsTheEndOfAProtectedRange() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(night(.locked), intensity: 0.8); c.setFollows(true)
        clocks.pass(3_600); c.evaluate()
        XCTAssertTrue(c.active); XCTAssertNotNil(c.ranges.holds.values.first?.deadline)
        clocks.pass(9 * 3_600); c.evaluate() // asleep 23:00 → 08:00: wall and continuous clocks both moved 9 h
        XCTAssertFalse(c.active, "the range ended at 07:00"); XCTAssertNil(c.protectedWindow); XCTAssertTrue(c.ranges.holds.isEmpty)
        XCTAssertEqual(c.setManual(true), .applied); XCTAssertTrue(c.active)
        XCTAssertEqual(c.setManual(false), .applied); XCTAssertFalse(c.active)
        XCTAssertEqual(c.emergencyOff(), .applied); XCTAssertEqual(c.setFollows(false), .applied)
    }

    /// Review B2 point 7: a clock set back a day keeps the time left, it does not add a day.
    func testClockSetBackDoesNotStretchAProtectedRange() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(evening(.locked), intensity: 1); c.setFollows(true); XCTAssertTrue(c.active)
        clocks.now = wednesday22h.addingTimeInterval(-86_400); clocks.up += 60; c.evaluate()
        let end = try XCTUnwrap(c.protectedWindow?.end)
        XCTAssertEqual(end.timeIntervalSince(clocks.now), 59 * 60, accuracy: 2, "59 min left, as before the change")
        clocks.pass(59 * 60 + 1); c.evaluate()
        XCTAssertFalse(c.active); XCTAssertEqual(c.setManual(false), .applied)
    }

    /// Review B2 point 2: the hold is in ranges.json with its continuous end. App killed at 22:00 (the guardian gives
    /// the colors back), clock set to 23:30, relaunch in the same boot: still protected until the real end (23:00 + 30 s).
    func testHoldSurvivesAKillAndAClockSetForward() throws {
        let root = try root(), clocks = Clocks(wednesday22h)
        let first = try controller(clocks, store: store(root))
        try first.saveRange(evening(.locked), intensity: 1); first.setFollows(true); XCTAssertTrue(first.active)
        // Killed: no shutdown, nothing more saved. The next run reads what the hold wrote.
        clocks.now = ISO8601DateFormatter().date(from: "2026-11-04T22:30:00Z")!; clocks.up += 30
        let second = try controller(clocks, store: store(root), keepsRanges: true)
        XCTAssertTrue(second.active, "23:30 on the clock, 30 s lived: the range still holds")
        let end = try XCTUnwrap(second.protectedWindow?.end)
        XCTAssertEqual(end.timeIntervalSince(clocks.now), 3_600 - 30, accuracy: 2)
        XCTAssertEqual(second.setManual(false), .locked(until: end))
        clocks.pass(3_600 - 30 + 1); second.evaluate()
        XCTAssertFalse(second.active, "the real end passed")
        // After a reboot the continuous end means nothing: the wall clock decides (the blocks' rule without a sample).
        clocks.now = wednesday22h; clocks.up = 10; clocks.boot = "boot-2"
        let third = try controller(clocks, store: store(root), keepsRanges: true)
        XCTAssertTrue(third.active, "22:00 again after a reboot: the range itself is scheduled")
    }

    /// A technical fault gives the colors back at once, even during a locked range.
    func testTechnicalFaultGivesTheColorsBackDuringALockedRange() throws {
        let clocks = Clocks(wednesday22h), gamma = BraiseTestGamma(), c = try controller(clocks, gamma: gamma)
        try c.saveRange(evening(.locked), intensity: 1); c.setFollows(true); XCTAssertTrue(c.active)
        gamma.onError?("macOS n’a pas conservé le filtre.")
        XCTAssertFalse(c.active); XCTAssertNotNil(c.errorMessage); XCTAssertTrue(c.ranges.holds.isEmpty)
    }

    func testRuntimeCommandsDuringALockedRangeAreRefused() throws {
        let root = try root(), clocks = Clocks(wednesday22h)
        let name = "red-ranges-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store = store(root)
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(clocks, store: store) })
        defer { runtime.shutdown() }
        runtime.setRedScreenFollowsSchedule(true)
        let c = try XCTUnwrap(runtime.controller)
        try c.saveRange(evening(.locked), intensity: 1)
        XCTAssertTrue(runtime.redScreen.on); XCTAssertTrue(runtime.redScreen.isProtected)
        runtime.restoreColors(); XCTAssertTrue(c.active, "« Rétablir les couleurs » is a weakening during a locked range")
        runtime.setRedScreen(false); XCTAssertTrue(c.active)
        XCTAssertThrowsError(try runtime.handle(.init(command: "braise off")))
        XCTAssertTrue(c.active)
    }

    // MARK: Sliders (review B2 points 3 and 4)

    /// During a protected range the sliders never open the page or a sheet: they stop at the range's intensity, with a text in place.
    func testSliderStopsAtAProtectedRangeWithoutOpeningAnything() throws {
        let root = try root(), clocks = Clocks(wednesday22h)
        let name = "red-slider-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store = store(root)
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(clocks, store: store) })
        defer { runtime.shutdown() }
        var opened = 0; runtime.onOpen = { opened += 1 }
        runtime.setRedScreenFollowsSchedule(true)
        let c = try XCTUnwrap(runtime.controller)
        try c.saveRange(night(.typing), intensity: 0.8)
        let menu = RedScreenMenu(control: runtime, onOpenSettings: {})
        XCTAssertTrue(menu.noticeItem.isHidden)
        for value in [0.75, 0.6, 0.4, 0.2, 0] { menu.slider.simulateDrag(to: value) } // one drag from 80 to 0 %
        XCTAssertEqual(opened, 0, "no page in the middle of the gesture"); XCTAssertNil(c.pendingStop)
        XCTAssertEqual(c.appliedIntensity, 0.8, accuracy: 0.0001); XCTAssertEqual(menu.slider.value, 0.8, accuracy: 0.0001)
        let notice = try XCTUnwrap(runtime.redScreen.notice)
        XCTAssertTrue(notice.hasPrefix("Plage protégée jusqu’à 07:00 : 80"), notice); XCTAssertTrue(notice.hasSuffix("au moins"))
        XCTAssertFalse(menu.noticeItem.isHidden); XCTAssertEqual(menu.noticeItem.title.filter { !$0.isWhitespace }, notice.filter { !$0.isWhitespace }) // NSMenuItem normalizes the narrow spaces
        runtime.setRedScreenIntensity(0.3) // the panel's slider
        XCTAssertEqual(opened, 0); XCTAssertNil(c.pendingStop)
        menu.slider.simulateDrag(to: 0.9)
        XCTAssertNil(runtime.redScreen.notice); XCTAssertTrue(menu.noticeItem.isHidden)
        XCTAssertEqual(c.appliedIntensity, 0.9, accuracy: 0.0001)
        // « Verrouillé »: same stop, no refusal text.
        let other = try controller(Clocks(wednesday22h))
        try other.saveRange(night(.locked), intensity: 0.7); other.setFollows(true)
        XCTAssertEqual(other.slideIntensity(0.1), .applied); XCTAssertNil(other.errorMessage)
        XCTAssertEqual(other.appliedIntensity, 0.7, accuracy: 0.0001); XCTAssertNotNil(other.sliderNotice)
        // The CLI keeps the rule of a weakening.
        XCTAssertEqual(other.setIntensity(0.1), .locked(until: try XCTUnwrap(other.protectedWindow?.end)))
    }

    /// Raising the slider during a range strengthens that range until its end only: the manual red never turns on.
    func testSliderRaiseEndsWithTheRange() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.saveRange(night(nil), intensity: 0.8); c.setFollows(true)
        clocks.pass(3_600); c.evaluate()
        XCTAssertEqual(c.slideIntensity(0.9), .applied)
        XCTAssertEqual(c.appliedIntensity, 0.9, accuracy: 0.0001); XCTAssertNotEqual(c.preferences.mode, .on)
        clocks.pass(8 * 3_600); c.evaluate() // Thursday 07:00
        XCTAssertFalse(c.active, "red ends with the range"); XCTAssertNil(c.ranges.raise)
        XCTAssertFalse(c.nextEvent.contains("manuellement"))
        // Same after a stop that carried the intensity: the range stops, the manual red stays off.
        let other = try controller(Clocks(wednesday22h))
        try other.saveRange(evening(.typing), intensity: 0.8); other.setFollows(true)
        guard case .needsStop = other.setIntensity(0.3) else { return XCTFail("below a « Difficile » range: the page's stop") }
        XCTAssertEqual(other.stopActiveRanges(typed: "a", challenge: "a"), .stopped)
        XCTAssertFalse(other.active); XCTAssertNotEqual(other.preferences.mode, .on)
        XCTAssertEqual(other.preferences.intensity, 0.3, accuracy: 0.0001)
    }

    // MARK: Menu (review B1 points 4 and 5)

    func testRestoreItemIsGreyedWhileRedIsOffAndSliderAnnouncesItsValue() throws {
        let control = GalleryRedScreen(RedScreenState(on: false, intensity: 0.7, followsSchedule: false))
        let menu = RedScreenMenu(control: control, onOpenSettings: {})
        let real = NSMenu(); real.autoenablesItems = true; menu.items.forEach(real.addItem)
        real.update()
        XCTAssertFalse(menu.restoreItem.isEnabled, "the real menu, auto-enabled, greys « Rétablir les couleurs »")
        XCTAssertFalse(menu.validateMenuItem(menu.restoreItem))
        control.setRedScreen(true); real.update()
        XCTAssertTrue(menu.restoreItem.isEnabled)
        menu.slider.simulateDrag(to: 0.3)
        XCTAssertEqual(menu.slider.accessibilityValueText?.filter(\.isNumber), "30")
        menu.slider.simulateDrag(to: 0.85)
        XCTAssertEqual(menu.slider.accessibilityValueText?.filter(\.isNumber), "85", "VoiceOver hears each move")
    }
}

// MARK: Gamma (review B1 points 2 and 3)

final class RedScreenGammaOriginTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-gamma-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func noRedTableWritten(after index: Int, _ screens: FakeGammaScreens) -> Bool {
        !screens.written.dropFirst(index).contains(where: GammaController.looksTinted)
    }

    /// A screen leaves (sleep, cable) and comes back still red under a new ID. Its origin comes from its stable key.
    func testScreenBackRedWithAStableKeyGetsItsTrueOrigin() throws {
        let screens = FakeGammaScreens([1, 2]); screens.keys = [1: "610-1-11", 2: "610-2-22"]
        let gamma = GammaController(directory: try directory(), screens: screens)
        gamma.set(active: true, intensity: 1, brightness: 1, animated: false)
        XCTAssertTrue(screens.isRed(2))
        screens.unplug(2); gamma.checkAfterSystemChange()
        screens.comeBack(2, as: 7); gamma.checkAfterSystemChange()
        XCTAssertTrue(screens.isRed(7))
        let before = screens.written.count
        gamma.restore()
        XCTAssertTrue(screens.isNormal(1)); XCTAssertTrue(screens.isNormal(7))
        XCTAssertTrue(noRedTableWritten(after: before, screens), "stop writes no red table back")
    }

    /// Same, without a key: the red table read is never an origin; ColorSync gives every origin back.
    func testScreenBackRedWithoutAKeyRebuildsOriginsFromColorSync() throws {
        let screens = FakeGammaScreens([1, 2])
        let gamma = GammaController(directory: try directory(), screens: screens)
        gamma.set(active: true, intensity: 0.8, brightness: 1, animated: false)
        screens.unplug(2); gamma.checkAfterSystemChange()
        screens.comeBack(2); gamma.checkAfterSystemChange()
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2))
        let before = screens.written.count
        gamma.restore()
        XCTAssertTrue(screens.isNormal(1)); XCTAssertTrue(screens.isNormal(2))
        XCTAssertTrue(noRedTableWritten(after: before, screens))
    }

    /// Review B2 point 5: a screen plugged during red without a key, showing a faint tint `looksTinted` misses. Its table
    /// is not a sure origin: at the stop, and after a crash (guardian), ColorSync gives its colors back.
    func testUnsureOriginGetsColorSyncAtTheStop() throws {
        for crash in [false, true] {
            let dir = try directory(), screens = FakeGammaScreens([1])
            let gamma = GammaController(directory: dir, screens: screens)
            gamma.set(active: true, intensity: 0.8, brightness: 1, animated: false)
            screens.plug(2)
            let faint = FakeGammaScreens.ramp(2).scaled(Gains(r: 0.95, g: 0.93, b: 0.93))
            XCTAssertFalse(GammaController.looksTinted(faint)); XCTAssertTrue(screens.write(faint))
            gamma.checkAfterSystemChange()
            XCTAssertTrue(screens.isRed(1))
            if crash { GammaController.recoverPending(in: dir, screens: screens) } else { gamma.restore() }
            XCTAssertTrue(screens.isNormal(1), "crash: \(crash)"); XCTAssertTrue(screens.isNormal(2), "crash: \(crash)")
            if crash { gamma.restore() }
        }
    }

    func testOwnCalibrationIsNotTakenForRed() {
        XCTAssertFalse(GammaController.looksTinted(FakeGammaScreens.ramp(1)))
        let warm = GammaTable(displayID: 1, red: [0, 1], green: [0, 0.96], blue: [0, 0.93])
        XCTAssertFalse(GammaController.looksTinted(warm))
        XCTAssertTrue(GammaController.looksTinted(FakeGammaScreens.ramp(1).scaled(Gains(r: 1, g: 0.5, b: 0.2))))
    }

    /// A screen plugged during the 0.38 s fade: the end of the fade checks the screens again.
    func testScreenPluggedDuringTheFadeTurnsRedAtItsEnd() throws {
        let screens = FakeGammaScreens([1])
        let gamma = GammaController(directory: try directory(), screens: screens)
        gamma.set(active: true, intensity: 1, brightness: 1, animated: true)
        screens.plug(2); gamma.checkAfterSystemChange() // skipped: the fade runs
        XCTAssertFalse(screens.isRed(2))
        let end = Date().addingTimeInterval(2)
        while Date() < end, !screens.isRed(2) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2), "checked again at the end of the fade")
        gamma.restore(); XCTAssertTrue(screens.isNormal(2))
    }
}
#endif
