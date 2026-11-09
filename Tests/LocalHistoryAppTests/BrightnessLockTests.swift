#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import XCTest
@testable import LocalHistoryApp

/// Fake screens: no test reads or changes the real brightness of this Mac.
final class FakeBrightness: DisplayBrightnessDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [UInt32: Double]
    private let screens: [BrightnessDisplay]
    let available: Bool
    private(set) var sets = 0
    init(screens: [BrightnessDisplay] = [BrightnessDisplay(id: 1, builtIn: true, controllable: true)], level: Double = 0.8, available: Bool = true) {
        self.screens = screens; self.available = available
        levels = Dictionary(uniqueKeysWithValues: screens.filter(\.controllable).map { ($0.id, level) })
    }
    var isAvailable: Bool { available }
    func displays() -> [BrightnessDisplay] { screens }
    func brightness(of display: UInt32) -> Double? { lock.withLock { levels[display] } }
    func setBrightness(_ value: Double, of display: UInt32) -> Bool {
        lock.withLock { guard levels[display] != nil else { return false }; levels[display] = value; sets += 1; return true }
    }
    /// Someone pressed F1/F2 or moved the Control Centre slider.
    func userSets(_ value: Double, of display: UInt32 = 1) { lock.withLock { levels[display] = value } }
}

/// T-048 D2 « Verrou de luminosité ».
@MainActor final class BrightnessLockTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 22:00 in Paris.
    private let wednesday22h = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000; var boot = "boot-1"
        init(_ now: Date) { self.now = now }
        func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); up += seconds }
    }
    private func store(_ root: URL) -> BraiseStore {
        BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-brightness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func controller(_ clocks: Clocks, screens: FakeBrightness = FakeBrightness(), root: URL? = nil,
                            password: String? = nil, keepsRanges: Bool = false) throws -> BraiseController {
        let c = try BraiseController(store: store(root ?? self.root()), gamma: BraiseTestGamma(), runsTimers: false,
                                     clock: { clocks.now }, calendar: paris, continuous: { clocks.up }, boot: { clocks.boot },
                                     brightness: screens, hasPassword: { password != nil },
                                     verifyPassword: { $0 == password ? .ok : .wrong(remaining: 3) })
        if !keepsRanges { for range in c.ranges.program.ranges { try c.deleteRange(range.id) } }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func protected(_ level: Double, _ lock: BlockLock, hours: Double, from now: Date) -> BrightnessLockState {
        BrightnessLockState(level: level, lock: lock, end: now.addingTimeInterval(hours * 3_600))
    }

    func testLockPutsAnyChangeBack() throws {
        let clocks = Clocks(wednesday22h), screens = FakeBrightness(), c = try controller(clocks, screens: screens)
        XCTAssertTrue(c.canControlBrightness)
        XCTAssertEqual(try c.setBrightnessLock(BrightnessLockState(level: 0.3)), .applied)
        c.enforceBrightnessNow()
        XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.3, accuracy: 0.0001)
        screens.userSets(0.9); c.enforceBrightnessNow()
        XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.3, accuracy: 0.0001, "F2 is undone")
        let corrections = c.brightnessCorrections
        c.enforceBrightnessNow(); XCTAssertEqual(c.brightnessCorrections, corrections, "nothing to do at the target")
        try c.setBrightnessLock(nil); screens.userSets(0.9); c.enforceBrightnessNow()
        XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.9, accuracy: 0.0001, "off: the keys work again")
        XCTAssertNil(c.brightnessTarget)
    }

    func testLevelIsClampedAndNeverBlack() throws {
        let c = try controller(Clocks(wednesday22h))
        try c.setBrightnessLock(BrightnessLockState(level: 0))
        XCTAssertEqual(try XCTUnwrap(c.brightnessLock?.level), BrightnessLockRules.levelRange.lowerBound, accuracy: 0.0001)
    }

    func testNoControllableScreenRefusesTheLock() throws {
        let external = FakeBrightness(screens: [BrightnessDisplay(id: 7, builtIn: false, controllable: false)])
        let c = try controller(Clocks(wednesday22h), screens: external)
        XCTAssertFalse(c.canControlBrightness)
        XCTAssertThrowsError(try c.setBrightnessLock(BrightnessLockState(level: 0.5)))
        XCTAssertNil(c.brightnessLock)
        let missing = try controller(Clocks(wednesday22h), screens: FakeBrightness(available: false))
        XCTAssertThrowsError(try missing.setBrightnessLock(BrightnessLockState(level: 0.5)), "framework missing: fail safe")
    }

    func testExternalScreenIsLeftAlone() throws {
        let screens = FakeBrightness(screens: [BrightnessDisplay(id: 1, builtIn: true, controllable: true),
                                               BrightnessDisplay(id: 7, builtIn: false, controllable: false)])
        let c = try controller(Clocks(wednesday22h), screens: screens)
        try c.setBrightnessLock(BrightnessLockState(level: 0.4)); c.enforceBrightnessNow()
        XCTAssertEqual(screens.sets, 1, "only the built-in screen is set")
        XCTAssertEqual(c.brightnessDisplays.filter(\.controllable).map(\.id), [1])
    }

    func testProtectedLockFollowsTheStopRule() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.setBrightnessLock(protected(0.4, .typing, hours: 2, from: clocks.now))
        let held = try XCTUnwrap(c.brightnessProtection)
        XCTAssertEqual(held.lock, .typing); XCTAssertEqual(c.guardUntil, held.end); XCTAssertEqual(c.guardLock, .typing)
        // Lowering is stricter: at once.
        XCTAssertEqual(c.slideBrightnessLock(0.3), .applied)
        XCTAssertEqual(try XCTUnwrap(c.brightnessLock?.level), 0.3, accuracy: 0.0001)
        // Raising stops at the locked level and says so.
        c.slideBrightnessLock(0.9)
        XCTAssertEqual(try XCTUnwrap(c.brightnessLock?.level), 0.3, accuracy: 0.0001); XCTAssertNotNil(c.brightnessNotice)
        // Off waits for the text.
        XCTAssertEqual(try c.setBrightnessLock(nil), .needsStop(lock: .typing, end: held.end))
        XCTAssertEqual(c.pendingBrightness, .off); XCTAssertNotNil(c.brightnessLock)
        XCTAssertEqual(c.stopBrightnessLock(typed: "faux", challenge: "vrai texte"), .wrongText); XCTAssertNotNil(c.brightnessLock)
        XCTAssertEqual(c.stopBrightnessLock(typed: "vrai texte", challenge: "vrai texte"), .stopped)
        XCTAssertNil(c.brightnessLock); XCTAssertNil(c.guardUntil); XCTAssertEqual(c.guardLock, .free)
    }

    func testLockedProtectionRefusesUntilItsEnd() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        try c.setBrightnessLock(protected(0.4, .locked, hours: 1, from: clocks.now))
        let end = try XCTUnwrap(c.brightnessProtection?.end)
        XCTAssertEqual(try c.setBrightnessLock(nil), .locked(until: end))
        XCTAssertEqual(c.stopBrightnessLock(), .locked(until: end))
        var weaker = try XCTUnwrap(c.brightnessLock); weaker.lock = .typing
        XCTAssertEqual(try c.setBrightnessLock(weaker), .locked(until: end), "a weaker stop rule is a weakening")
        clocks.pass(3_600 + 1); c.evaluate()
        XCTAssertNil(c.brightnessProtection); XCTAssertNotNil(c.brightnessLock, "after the end the lock stays on, « Libre »")
        XCTAssertEqual(try c.setBrightnessLock(nil), .applied); XCTAssertNil(c.brightnessLock)
    }

    func testPasswordProtectionNeedsAndChecksThePassword() throws {
        let clocks = Clocks(wednesday22h)
        let without = try controller(clocks)
        XCTAssertThrowsError(try without.setBrightnessLock(protected(0.4, .password, hours: 1, from: clocks.now)))
        let c = try controller(clocks, password: "secret")
        try c.setBrightnessLock(protected(0.4, .password, hours: 1, from: clocks.now))
        XCTAssertEqual(try c.setBrightnessLock(nil), .needsStop(lock: .password, end: try XCTUnwrap(c.brightnessProtection?.end)))
        XCTAssertEqual(c.stopBrightnessLock(password: "non"), .password(.wrong(remaining: 3)))
        XCTAssertEqual(c.stopBrightnessLock(password: "secret"), .stopped); XCTAssertNil(c.brightnessLock)
    }

    func testProtectionLimits() throws {
        let clocks = Clocks(wednesday22h), c = try controller(clocks)
        XCTAssertThrowsError(try c.setBrightnessLock(protected(0.4, .typing, hours: 25, from: clocks.now)), "24 h at most")
        XCTAssertThrowsError(try c.setBrightnessLock(BrightnessLockState(level: 0.4, lock: .typing, end: nil)), "an end is required")
    }

    /// Same continuous clock as a range hold: a clock set forward does not end the protection; real time does.
    func testProtectionSurvivesAClockJumpAndAKill() throws {
        let root = try root(), clocks = Clocks(wednesday22h)
        let first = try controller(clocks, root: root)
        try first.setBrightnessLock(protected(0.4, .locked, hours: 1, from: clocks.now))
        clocks.now = wednesday22h.addingTimeInterval(5 * 3_600); clocks.up += 60
        let second = try controller(clocks, root: root, keepsRanges: true)
        let end = try XCTUnwrap(second.brightnessProtection?.end, "killed, relaunched, clock +5 h: still protected")
        XCTAssertEqual(end.timeIntervalSince(clocks.now), 3_600 - 60, accuracy: 2)
        XCTAssertEqual(second.guardLock, .locked)
        clocks.pass(3_600); second.evaluate()
        XCTAssertNil(second.brightnessProtection)
    }

    /// A range may carry a brightness: while it runs the darkest of the lock and the ranges wins.
    func testRangeBrightnessIsHeldAndCanOnlyGoDown() throws {
        let clocks = Clocks(wednesday22h), screens = FakeBrightness(), c = try controller(clocks, screens: screens)
        let range = BlockProgramRange(weekdays: [3], startMinute: 21 * 60, endMinute: 23 * 60, lock: .locked)
        try c.saveRange(range, intensity: 0.5, brightness: .some(0.25)); c.setFollows(true)
        XCTAssertEqual(try XCTUnwrap(c.brightnessTarget), 0.25, accuracy: 0.0001)
        c.enforceBrightnessNow(); XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.25, accuracy: 0.0001)
        try c.setBrightnessLock(BrightnessLockState(level: 0.6))
        XCTAssertEqual(try XCTUnwrap(c.brightnessTarget), 0.25, accuracy: 0.0001, "the darkest wins")
        XCTAssertThrowsError(try c.saveRange(range, intensity: 0.5, brightness: .some(0.5)), "brighter during the range")
        XCTAssertThrowsError(try c.saveRange(range, intensity: 0.5, brightness: .some(nil)), "dropping it during the range")
        XCTAssertNoThrow(try c.saveRange(range, intensity: 0.5, brightness: .some(0.2)), "darker is allowed")
        clocks.pass(3_600 + 1); c.evaluate()
        XCTAssertEqual(try XCTUnwrap(c.brightnessTarget), 0.6, accuracy: 0.0001, "range over: the manual lock alone")
    }

    func testOldRangesFileStillLoads() throws {
        let json = #"{"program":{"ranges":[]},"follows":false,"disabled":[],"intensities":{},"holds":{},"skips":{}}"#
        if let value = try? JSONDecoder().decode(RedScreenProgram.self, from: Data(json.utf8)) {
            XCTAssertNil(value.brightnessLock); XCTAssertNil(value.brightness)
        }
        let state = BrightnessLockState(level: 0.4, lock: .typing, end: wednesday22h, deadline: 12, boot: "b")
        XCTAssertEqual(try JSONDecoder().decode(BrightnessLockState.self, from: JSONEncoder().encode(state)), state)
    }

    func testRealDriverIsInertUnderTests() {
        let driver = DisplayServicesBrightness()
        XCTAssertFalse(driver.isAvailable); XCTAssertFalse(driver.setBrightness(0.5, of: 1)); XCTAssertNil(driver.brightness(of: 1))
    }

    func testEnforcerWithoutTimerNeverStartsOne() {
        let screens = FakeBrightness(), enforcer = BrightnessEnforcer(driver: screens, runsTimer: false)
        enforcer.update(target: 0.5, displays: [1]); XCTAssertFalse(enforcer.isRunning)
        enforcer.tick(); XCTAssertEqual(screens.brightness(of: 1) ?? -1, 0.5, accuracy: 0.0001)
        enforcer.stop(); screens.userSets(0.9); enforcer.tick()
        XCTAssertEqual(screens.brightness(of: 1) ?? -1, 0.9, accuracy: 0.0001)
    }

    func testNextOccurrence() throws {
        let at = try XCTUnwrap(BrightnessLockRules.nextOccurrence(minute: 23 * 60, after: wednesday22h, calendar: paris))
        XCTAssertEqual(at.timeIntervalSince(wednesday22h), 3_600)
        let tomorrow = try XCTUnwrap(BrightnessLockRules.nextOccurrence(minute: 7 * 60, after: wednesday22h, calendar: paris))
        XCTAssertEqual(tomorrow.timeIntervalSince(wednesday22h), 9 * 3_600)
    }
}
#endif
