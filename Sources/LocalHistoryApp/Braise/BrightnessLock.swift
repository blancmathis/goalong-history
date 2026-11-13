#if os(macOS)
import CoreGraphics
import Darwin
import Foundation

/// « Limite de luminosité » (T-048 D2, upper limit since T-059 2026-11-13): the hardware brightness of the screens Goalong
/// can drive stays at or below `level`. Below is free; above is brought back to `level`. A file written when the lock held
/// one exact level decodes unchanged: that level is now the limit.
/// Stored in `Braise/ranges.json` next to the red screen's ranges (same protections, same continuous clock).
/// While `end` is ahead and `lock` is not « Libre », turning it off or raising the level follows the stop rule of a
/// protected red-screen range (docs/BLOCKING.md « Range lock »).
struct BrightnessLockState: Codable, Equatable {
    /// Upper limit of the hardware brightness 0…1 (`BrightnessLockRules.levelRange`). Key kept as `level` (old files).
    var level: Double
    /// Stop rule while protected; nil = « Libre ».
    var lock: BlockLock?
    /// End of the protection (wall frame). Nil = never protected.
    var end: Date?
    /// `BlockingClock.continuous` seconds at which the protection ends, valid in `boot` only (same rule as a range hold).
    var deadline: Double?
    var boot: String?

    var effectiveLock: BlockLock { lock ?? .free }
}

/// One change the page or the menu asks of the lock.
enum BrightnessLockChange: Equatable {
    case off
    case set(BrightnessLockState)
}

/// Pure rules of the brightness lock.
enum BrightnessLockRules {
    /// Below 5 % a built-in panel is almost black: never limit lower (the member may still go lower by hand).
    static let levelRange: ClosedRange<Double> = 0.05...1
    /// A protection lasts at most 24 h, like a freeze.
    static let maximumProtection: TimeInterval = 24 * 3_600
    /// Difference under which a reading already is the target (a brightness key step is 1/16 = 0.0625).
    static let tolerance = 0.004

    static func clamp(_ value: Double) -> Double {
        min(levelRange.upperBound, max(levelRange.lowerBound, value.isFinite ? value : levelRange.upperBound))
    }

    /// The stop rule in force at `now` (password rule of a range: no password = « Verrouillé »), nil when not protected.
    static func protection(_ state: BrightnessLockState?, now: Date, hasPassword: Bool) -> (lock: BlockLock, end: Date)? {
        guard let state, let end = state.end, end > now, state.effectiveLock != .free else { return nil }
        return (RedScreenRules.effectiveLock(state.effectiveLock, hasPassword: hasPassword), end)
    }

    /// While protected, a change may only make the lock stricter: same or lower limit, same or stronger stop rule,
    /// same or later end. Raising or removing the limit is a weakening. Nil = allowed.
    static func weakening(from current: BrightnessLockState?, to next: BrightnessLockState?, now: Date, hasPassword: Bool) -> String? {
        guard let held = protection(current, now: now, hasPassword: hasPassword), let current else { return nil }
        guard let next else { return "la limite reste en place jusqu’à la fin de sa protection." }
        if next.level > current.level + tolerance { return "la limite de luminosité peut seulement baisser." }
        let nextLock = RedScreenRules.effectiveLock(next.effectiveLock, hasPassword: hasPassword)
        if nextLock.strength < held.lock.strength || (next.end ?? .distantPast) < held.end.addingTimeInterval(-1) {
            return "la protection du verrou peut seulement monter."
        }
        return nil
    }

    /// The limit in force: the lowest of the manual limit and the ranges in progress that carry a brightness.
    static func target(manual: BrightnessLockState?, windows: [RedScreenWindow]) -> Double? {
        ([manual?.level] + windows.map(\.brightness)).compactMap { $0 }.map(clamp).min()
    }

    /// A screen at `current` under `limit`: the level to set, nil = leave it. At or below the limit (rounding included)
    /// the member's choice stays. `exact` (a preview) sets the level itself, up or down.
    static func correction(current: Double, limit: Double, exact: Bool = false) -> Double? {
        let gap = current - limit
        return (exact ? abs(gap) : gap) > tolerance ? limit : nil
    }

    /// The next end time of « HH:MM » after `now` (today, or tomorrow when already past).
    static func nextOccurrence(minute: Int, after now: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: now)
        guard let today = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}

/// One screen as the lock sees it.
struct BrightnessDisplay: Equatable, Identifiable {
    var id: UInt32
    var builtIn: Bool
    /// DisplayServices can set its brightness (built-in panels, some Apple displays). External monitors usually not.
    var controllable: Bool
}

/// The hardware brightness of the screens. Only `DisplayServicesBrightness` touches real screens; tests use a fake.
protocol DisplayBrightnessDriving: AnyObject, Sendable {
    /// The private framework loaded and its three functions found.
    var isAvailable: Bool { get }
    func displays() -> [BrightnessDisplay]
    func brightness(of display: UInt32) -> Double?
    @discardableResult func setBrightness(_ value: Double, of display: UInt32) -> Bool
}

/// No screen to drive (default of `BraiseController`: a controller built without a driver never touches brightness).
final class NoDisplayBrightness: DisplayBrightnessDriving, @unchecked Sendable {
    var isAvailable: Bool { false }
    func displays() -> [BrightnessDisplay] { [] }
    func brightness(of display: UInt32) -> Double? { nil }
    func setBrightness(_ value: Double, of display: UInt32) -> Bool { false }
}

/// macOS has no public brightness API: `DisplayServices.framework` (private) is opened with `dlopen`. A missing framework
/// or symbol leaves the driver unavailable: the page says so and the lock cannot be turned on. Inert under XCTest.
final class DisplayServicesBrightness: DisplayBrightnessDriving, @unchecked Sendable {
    static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private typealias CanChangeFn = @convention(c) (UInt32) -> Bool
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private let canChange: CanChangeFn?
    private let get: GetFn?
    private let set: SetFn?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let underTests = NSClassFromString("XCTestCase") != nil || environment["XCTestConfigurationFilePath"] != nil
        guard !underTests, let handle = dlopen(Self.path, RTLD_LAZY) else { canChange = nil; get = nil; set = nil; return }
        canChange = dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeFn.self) }
        get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
    }
    var isAvailable: Bool { canChange != nil && get != nil && set != nil }
    func displays() -> [BrightnessDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { id in
            BrightnessDisplay(id: id, builtIn: CGDisplayIsBuiltin(id) != 0,
                              controllable: isAvailable && (canChange?(id) ?? false) && brightness(of: id) != nil)
        }
    }
    func brightness(of display: UInt32) -> Double? {
        guard let get else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0, value.isFinite else { return nil }
        return Double(value)
    }
    func setBrightness(_ value: Double, of display: UInt32) -> Bool {
        guard let set else { return false }
        return set(display, Float(BrightnessLockRules.clamp(value))) == 0
    }
}

/// Brings the screens back to the limit whenever anything (keys F1/F2, Control Centre, Settings, ambient light) moves
/// them above it; below it they are left alone. A preview (`exact`) holds one level. Polls every `interval` on its own
/// queue while a target is set; nothing runs without one.
final class BrightnessEnforcer: @unchecked Sendable {
    static let interval: TimeInterval = 0.1
    private let driver: DisplayBrightnessDriving
    private let runsTimer: Bool
    private let queue = DispatchQueue(label: "ai.goalong.brightness-lock", qos: .userInitiated)
    private let state = NSLock()
    private var target: Double?
    private var exact = false
    private var displays: [UInt32] = []
    private var timer: DispatchSourceTimer?
    private var correctionCount = 0

    init(driver: DisplayBrightnessDriving, runsTimer: Bool) { self.driver = driver; self.runsTimer = runsTimer }

    /// Corrections made since start (each one = a screen brought back to the limit, or to a preview's level).
    var corrections: Int { state.withLock { correctionCount } }
    var isRunning: Bool { state.withLock { timer != nil } }

    /// A new limit (nil stops); `exact` = hold that level itself (a preview). The displays are the controllable ones,
    /// read on the main thread by the controller.
    func update(target value: Double?, displays ids: [UInt32], exact isExact: Bool = false) {
        let wanted = value.map(BrightnessLockRules.clamp)
        let start: Bool
        state.lock()
        let changed = target != wanted || displays != ids || exact != isExact
        target = wanted; exact = isExact; displays = wanted == nil ? [] : ids
        if wanted == nil || ids.isEmpty { timer?.cancel(); timer = nil; start = false } else { start = runsTimer && timer == nil }
        state.unlock()
        if start {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.tick() }
            state.withLock { timer = source }
            source.resume()
        } else if changed, runsTimer, wanted != nil { queue.async { [weak self] in self?.tick() } }
    }

    /// One pass: every controllable screen above the limit is brought back to it. Called by the timer, or by tests.
    func tick() {
        let (wanted, isExact, ids) = state.withLock { (target, exact, displays) }
        guard let wanted else { return }
        for id in ids {
            guard let current = driver.brightness(of: id),
                  let level = BrightnessLockRules.correction(current: current, limit: wanted, exact: isExact) else { continue }
            if driver.setBrightness(level, of: id) { state.withLock { correctionCount += 1 } }
        }
    }

    func stop() { update(target: nil, displays: []) }
}
#endif
