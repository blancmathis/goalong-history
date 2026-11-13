import Foundation

/// T-060: « Luminosité max du clavier ». The member's ceiling for the keyboard backlight, optionally only during a
/// daily time range. Pure value: what to do with a level read from macOS, and when the range starts or ends.
/// Brightness is macOS's own scale, 0…1; one press of the key moves 1/16, so a ceiling under 1/16 lights the keyboard
/// dimmer than macOS's first step allows.
struct KeyboardBacklightLimit: Equatable, Sendable {
    static let enabledKey = "goalong.keyboardBacklight.enabled"
    static let maximumKey = "goalong.keyboardBacklight.maximum"
    static let scheduledKey = "goalong.keyboardBacklight.scheduled"
    static let startMinuteKey = "goalong.keyboardBacklight.startMinute"
    static let endMinuteKey = "goalong.keyboardBacklight.endMinute"

    /// macOS's first step of the brightness key (1/16 of the full scale).
    static let firstMacStep = 1.0 / 16
    /// What a stored ceiling may be: off (0) up to four macOS steps. Any value in it keeps its meaning (old 0.005 steps too).
    static let range: ClosedRange<Double> = 0...0.25
    /// The slider's stops, off first. Measured 2026-11-13 (T-060): the keys light at about 0.100 + 14.56 × level nit, so
    /// 0.5 % (0.17 nit) and 1 % (0.25 nit) look alike. Fine stops at the bottom; under 0.05 % (0.107 nit) a step changes
    /// the light by less than 7 %, so 0.05 % is the lowest lit stop. Only 0 turns the light off.
    static let stops: [Double] = [
        0, 0.0005, 0.001, 0.002, 0.003, 0.005, 0.0075, 0.01, 0.015, 0.02, 0.03, 0.04, 0.05,
        0.0625, 0.08, 0.1, 0.125, 0.15, 0.2, 0.25,
    ]
    static let lowestLitStop = 0.0005
    static let defaultMaximum = 0.01
    static let defaultStartMinute = 22 * 60
    static let defaultEndMinute = 7 * 60
    /// Levels closer than this count as equal: no write, no loop on our own change notification. Far under the lowest lit
    /// stop (0.0005); the driver reads back what it wrote (Float precision).
    static let tolerance = 0.00002

    var enabled = false
    var maximum = defaultMaximum
    var scheduled = false
    /// Minutes after midnight, 0..<1440. Start after end = the range ends the next day; start == end = all day.
    var startMinute = defaultStartMinute
    var endMinute = defaultEndMinute

    init(enabled: Bool = false, maximum: Double = defaultMaximum, scheduled: Bool = false,
         startMinute: Int = defaultStartMinute, endMinute: Int = defaultEndMinute) {
        self.enabled = enabled
        self.maximum = Self.clampedMaximum(maximum)
        self.scheduled = scheduled
        self.startMinute = Self.clampedMinute(startMinute)
        self.endMinute = Self.clampedMinute(endMinute)
    }

    init(defaults: UserDefaults) {
        self.init(
            enabled: defaults.bool(forKey: Self.enabledKey),
            maximum: defaults.object(forKey: Self.maximumKey) == nil ? Self.defaultMaximum : defaults.double(forKey: Self.maximumKey),
            scheduled: defaults.bool(forKey: Self.scheduledKey),
            startMinute: defaults.object(forKey: Self.startMinuteKey) == nil ? Self.defaultStartMinute : defaults.integer(forKey: Self.startMinuteKey),
            endMinute: defaults.object(forKey: Self.endMinuteKey) == nil ? Self.defaultEndMinute : defaults.integer(forKey: Self.endMinuteKey))
    }

    static func clampedMaximum(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMaximum }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Slider position (stop index) for a stored ceiling: the nearest stop, a tie going to the lower one.
    static func stopIndex(for value: Double) -> Int {
        let clamped = clampedMaximum(value)
        var best = 0
        for (index, stop) in stops.enumerated() where abs(stop - clamped) < abs(stops[best] - clamped) { best = index }
        return best
    }

    /// Ceiling for a slider position, clamped to the stops.
    static func level(atStop index: Int) -> Double { stops[min(max(index, 0), stops.count - 1)] }

    static func clampedMinute(_ value: Int) -> Int { ((value % 1440) + 1440) % 1440 }

    /// True when the ceiling applies at `date`: switch on, and inside the range when there is one.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        guard scheduled, startMinute != endMinute else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return startMinute < endMinute
            ? minute >= startMinute && minute < endMinute
            : minute >= startMinute || minute < endMinute
    }

    /// The level to write, or nil to leave macOS's level as it is (ceiling off, outside the range, or already under).
    func correctedLevel(for current: Double, at date: Date, calendar: Calendar = .current) -> Double? {
        guard isActive(at: date, calendar: calendar), current.isFinite, current > maximum + Self.tolerance else { return nil }
        return maximum
    }

    /// The next start or end of the range after `date`, to check again then. Nil without a range.
    func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, scheduled, startMinute != endMinute else { return nil }
        return [startMinute, endMinute].compactMap { minute in
            calendar.nextDate(after: date, matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                              matchingPolicy: .nextTime)
        }.min()
    }
}
