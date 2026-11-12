#if os(macOS)
import AppKit
import AppleScreenTime

/// T-060: keeps the keyboard backlight at or under the member's ceiling while it applies. The brightness key, the
/// ambient sensor or another app may raise it; macOS tells us and Goalong writes the ceiling back. Outside the range,
/// or switch off, Goalong listens to nothing and writes nothing: macOS has the backlight again. Leaving the range does
/// not restore an earlier level (one press of the key does).
@MainActor final class KeyboardBacklightLimiter {
    static let shared = KeyboardBacklightLimiter()

    private let driver: KeyboardBrightnessDriving
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private var started = false
    private var observing = false
    private var boundary: Timer?
    private var tokens: [NSObjectProtocol] = []
    private(set) var limit: KeyboardBacklightLimit?
    /// Ceiling writes since start, for tests and diagnostics.
    private(set) var corrections = 0

    init(driver: KeyboardBrightnessDriving = CoreBrightnessKeyboard(), defaults: UserDefaults = GoalongDefaults.standard,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    /// Nil before start; then whether this Mac has a keyboard backlight Goalong can drive.
    var isAvailable: Bool? { started ? driver.isAvailable : nil }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        evaluate()
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        boundary?.invalidate(); boundary = nil
        if observing { driver.stopObserving(); observing = false }
        started = false
        limit = nil
    }

    /// Any preference write lands here: only a change of this setting costs a read of the backlight.
    func settingsMayHaveChanged() {
        guard started, KeyboardBacklightLimit(defaults: defaults) != limit else { return }
        evaluate()
    }

    /// Reads the setting and the clock, listens or not, and brings the level down when it is over the ceiling.
    func evaluate() {
        guard started else { return }
        let current = KeyboardBacklightLimit(defaults: defaults)
        limit = current
        boundary?.invalidate(); boundary = nil
        let date = now()
        let active = driver.isAvailable && current.isActive(at: date, calendar: calendar)
        if active, !observing {
            driver.observe { [weak self] in Task { @MainActor in self?.backlightChanged() } }
            observing = true
        } else if !active, observing {
            driver.stopObserving()
            observing = false
        }
        if active { backlightChanged() }
        if driver.isAvailable, let next = current.nextBoundary(after: date, calendar: calendar) {
            // One second late, so the clock is surely inside (or outside) the range when it fires.
            let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            boundary = timer
        }
    }

    /// macOS changed the level (or we just started): write the ceiling back if the level is over it.
    func backlightChanged() {
        guard started, let limit, let level = driver.brightness(),
              let corrected = limit.correctedLevel(for: level, at: now(), calendar: calendar) else { return }
        if driver.setBrightness(corrected) { corrections += 1 }
    }
}
#endif
