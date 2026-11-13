#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// Fake keyboard: no test reads or changes this Mac's real backlight.
final class FakeKeyboardBrightness: KeyboardBrightnessDriving, @unchecked Sendable {
    var isAvailable = true
    var level: Double = 0.5
    var writes: [Double] = []
    private(set) var handler: (@Sendable () -> Void)?
    func brightness() -> Double? { isAvailable ? level : nil }
    func setBrightness(_ value: Double) -> Bool { writes.append(value); level = value; return true }
    func observe(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func stopObserving() { handler = nil }
}

final class KeyboardBacklightLimitTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute))!
    }

    // MARK: - Clamp

    func testOffNeverCorrects() {
        let limit = KeyboardBacklightLimit(enabled: false, maximum: 0.01)
        XCTAssertNil(limit.correctedLevel(for: 1, at: at(23), calendar: calendar))
    }

    func testOverCeilingComesDownUnderStaysAsIs() {
        let limit = KeyboardBacklightLimit(enabled: true, maximum: 0.01)
        // macOS's first step (1/16) is over a ceiling below it: Goalong writes the ceiling.
        XCTAssertEqual(limit.correctedLevel(for: KeyboardBacklightLimit.firstMacStep, at: at(12), calendar: calendar), 0.01)
        XCTAssertNil(limit.correctedLevel(for: 0.005, at: at(12), calendar: calendar), "under the ceiling: left alone")
        XCTAssertNil(limit.correctedLevel(for: 0, at: at(12), calendar: calendar), "off stays off")
        XCTAssertNil(limit.correctedLevel(for: 0.01001, at: at(12), calendar: calendar), "within tolerance: no write loop")
        XCTAssertNil(limit.correctedLevel(for: .nan, at: at(12), calendar: calendar))
    }

    func testZeroCeilingKeepsKeyboardDark() {
        let limit = KeyboardBacklightLimit(enabled: true, maximum: 0)
        XCTAssertEqual(limit.correctedLevel(for: 0.0625, at: at(12), calendar: calendar), 0)
    }

    func testMaximumAndMinutesAreClamped() {
        XCTAssertEqual(KeyboardBacklightLimit(maximum: 3).maximum, KeyboardBacklightLimit.range.upperBound)
        XCTAssertEqual(KeyboardBacklightLimit(maximum: -1).maximum, 0)
        XCTAssertEqual(KeyboardBacklightLimit(maximum: .infinity).maximum, KeyboardBacklightLimit.defaultMaximum)
        XCTAssertEqual(KeyboardBacklightLimit(startMinute: 1440 + 30).startMinute, 30)
        XCTAssertEqual(KeyboardBacklightLimit(endMinute: -60).endMinute, 1380)
    }

    func testDefaultsRoundTripAndAbsentKeys() throws {
        let suite = "goalong-keyboard-backlight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyboardBacklightLimit(defaults: defaults), KeyboardBacklightLimit(), "absent keys: off, defaults")
        defaults.set(true, forKey: KeyboardBacklightLimit.enabledKey)
        defaults.set(0.02, forKey: KeyboardBacklightLimit.maximumKey)
        defaults.set(true, forKey: KeyboardBacklightLimit.scheduledKey)
        defaults.set(21 * 60, forKey: KeyboardBacklightLimit.startMinuteKey)
        defaults.set(6 * 60 + 30, forKey: KeyboardBacklightLimit.endMinuteKey)
        XCTAssertEqual(KeyboardBacklightLimit(defaults: defaults),
                       KeyboardBacklightLimit(enabled: true, maximum: 0.02, scheduled: true, startMinute: 21 * 60, endMinute: 390))
    }

    // MARK: - Time range

    func testRangeOverMidnight() {
        let night = KeyboardBacklightLimit(enabled: true, scheduled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertFalse(night.isActive(at: at(21, 59), calendar: calendar))
        XCTAssertTrue(night.isActive(at: at(22), calendar: calendar), "start is inside")
        XCTAssertTrue(night.isActive(at: at(23, 30), calendar: calendar))
        XCTAssertTrue(night.isActive(at: at(3), calendar: calendar))
        XCTAssertTrue(night.isActive(at: at(6, 59), calendar: calendar))
        XCTAssertFalse(night.isActive(at: at(7), calendar: calendar), "end is outside")
        XCTAssertFalse(night.isActive(at: at(12), calendar: calendar))
        XCTAssertNil(night.correctedLevel(for: 1, at: at(12), calendar: calendar), "outside the range: macOS decides")
        XCTAssertEqual(night.correctedLevel(for: 1, at: at(23), calendar: calendar), night.maximum)
    }

    func testRangeWithinOneDay() {
        let afternoon = KeyboardBacklightLimit(enabled: true, scheduled: true, startMinute: 13 * 60, endMinute: 14 * 60 + 30)
        XCTAssertFalse(afternoon.isActive(at: at(12, 59), calendar: calendar))
        XCTAssertTrue(afternoon.isActive(at: at(13), calendar: calendar))
        XCTAssertTrue(afternoon.isActive(at: at(14, 29), calendar: calendar))
        XCTAssertFalse(afternoon.isActive(at: at(14, 30), calendar: calendar))
    }

    func testEqualStartAndEndMeansAllDayAndNoRangeMeansAlways() {
        let allDay = KeyboardBacklightLimit(enabled: true, scheduled: true, startMinute: 600, endMinute: 600)
        let always = KeyboardBacklightLimit(enabled: true, scheduled: false)
        for hour in [0, 9, 10, 18, 23] {
            XCTAssertTrue(allDay.isActive(at: at(hour), calendar: calendar))
            XCTAssertTrue(always.isActive(at: at(hour), calendar: calendar))
        }
        XCTAssertNil(allDay.nextBoundary(after: at(9), calendar: calendar))
        XCTAssertNil(always.nextBoundary(after: at(9), calendar: calendar))
    }

    func testNextBoundaryIsTheNearestStartOrEnd() {
        let night = KeyboardBacklightLimit(enabled: true, scheduled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertEqual(night.nextBoundary(after: at(12), calendar: calendar), at(22))
        XCTAssertEqual(night.nextBoundary(after: at(23), calendar: calendar),
                       calendar.date(byAdding: .day, value: 1, to: at(7)))
        XCTAssertEqual(night.nextBoundary(after: at(3), calendar: calendar), at(7))
        XCTAssertNil(KeyboardBacklightLimit(enabled: false, scheduled: true).nextBoundary(after: at(12), calendar: calendar))
    }

    // MARK: - Limiter

    @MainActor private func limiter(_ driver: FakeKeyboardBrightness, _ defaults: UserDefaults, now: @escaping () -> Date) -> KeyboardBacklightLimiter {
        KeyboardBacklightLimiter(driver: driver, defaults: defaults, calendar: calendar, now: now)
    }

    @MainActor func testLimiterBringsKeyDownBackAndReleasesWhenOff() throws {
        let suite = "goalong-keyboard-backlight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FakeKeyboardBrightness()
        driver.level = 0.3
        let subject = limiter(driver, defaults, now: { self.at(23) })
        subject.start()
        defer { subject.stop() }
        XCTAssertEqual(driver.writes, [], "off by default: nothing written")
        XCTAssertNil(driver.handler, "off: nothing observed")

        defaults.set(true, forKey: KeyboardBacklightLimit.enabledKey)
        defaults.set(0.01, forKey: KeyboardBacklightLimit.maximumKey)
        subject.settingsMayHaveChanged()
        XCTAssertEqual(driver.writes, [0.01], "on: the level comes down to the ceiling at once")
        XCTAssertNotNil(driver.handler)

        // The brightness-up key: macOS raises one step, Goalong brings it back.
        driver.level = 0.01 + KeyboardBacklightLimit.firstMacStep
        subject.backlightChanged()
        XCTAssertEqual(driver.writes, [0.01, 0.01])
        // Our own write notifies again: no second write.
        subject.backlightChanged()
        XCTAssertEqual(driver.writes.count, 2)

        defaults.set(false, forKey: KeyboardBacklightLimit.enabledKey)
        subject.settingsMayHaveChanged()
        XCTAssertNil(driver.handler, "off: macOS has the backlight again")
        driver.level = 0.5
        subject.backlightChanged()
        XCTAssertEqual(driver.writes.count, 2, "off: no write")
    }

    @MainActor func testLimiterFollowsTheRange() throws {
        let suite = "goalong-keyboard-backlight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeyboardBacklightLimit.enabledKey)
        defaults.set(0.005, forKey: KeyboardBacklightLimit.maximumKey)
        defaults.set(true, forKey: KeyboardBacklightLimit.scheduledKey)
        defaults.set(22 * 60, forKey: KeyboardBacklightLimit.startMinuteKey)
        defaults.set(7 * 60, forKey: KeyboardBacklightLimit.endMinuteKey)
        var clock = at(12)
        let driver = FakeKeyboardBrightness()
        driver.level = 0.25
        let subject = limiter(driver, defaults, now: { clock })
        subject.start()
        defer { subject.stop() }
        XCTAssertEqual(driver.writes, [], "midday: outside the range")
        XCTAssertNil(driver.handler)

        clock = at(22, 0)
        subject.evaluate()
        XCTAssertEqual(driver.writes, [0.005], "the range starts: down to the ceiling")
        XCTAssertNotNil(driver.handler)

        clock = calendar.date(byAdding: .day, value: 1, to: at(7))!
        subject.evaluate()
        XCTAssertNil(driver.handler, "the range ends: Goalong lets go")
        XCTAssertEqual(driver.level, 0.005, "no level restored at the end of the range")
    }

    @MainActor func testLimiterWithoutKeyboardDoesNothing() throws {
        let suite = "goalong-keyboard-backlight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeyboardBacklightLimit.enabledKey)
        let driver = FakeKeyboardBrightness()
        driver.isAvailable = false
        let subject = limiter(driver, defaults, now: { self.at(23) })
        subject.start()
        defer { subject.stop() }
        XCTAssertEqual(subject.isAvailable, false)
        XCTAssertNil(driver.handler)
        XCTAssertEqual(driver.writes, [])
    }

    func testRealDriverIsInertUnderTests() {
        XCTAssertFalse(CoreBrightnessKeyboard().isAvailable, "tests never touch this Mac's keyboard backlight")
    }

    // MARK: - Slider stops

    func testStopsAreIncreasingWithinRangeAndFineAtTheBottom() {
        let stops = KeyboardBacklightLimit.stops
        XCTAssertEqual(stops.first, 0, "far left = off")
        XCTAssertEqual(stops.last, KeyboardBacklightLimit.range.upperBound)
        XCTAssertEqual(stops[1], KeyboardBacklightLimit.lowestLitStop)
        XCTAssertTrue(zip(stops, stops.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing")
        XCTAssertTrue(stops.allSatisfy { KeyboardBacklightLimit.range.contains($0) })
        XCTAssertEqual(stops.filter { $0 > 0 && $0 < 0.005 }, [0.0005, 0.002], "lit stops under the old 0,5 % floor")
        XCTAssertTrue(stops.contains(KeyboardBacklightLimit.defaultMaximum))
        XCTAssertTrue(stops.contains(KeyboardBacklightLimit.firstMacStep))
        // Each lit stop is visibly brighter than the one before (+15 %, far above the ~7 % that cannot be seen).
        let nits = stops.dropFirst().map(KeyboardBacklightLimit.modelNits)
        for (lower, upper) in zip(nits, nits.dropFirst()) { XCTAssertGreaterThanOrEqual(upper / lower, 1.15, "\(lower) → \(upper) nit") }
        // The measured points (mesure 2026-11-13) match the model.
        XCTAssertEqual(KeyboardBacklightLimit.modelNits(0.0005), 0.1073, accuracy: 0.001)
        XCTAssertEqual(KeyboardBacklightLimit.modelNits(0.005), 0.1728, accuracy: 0.001)
        XCTAssertEqual(KeyboardBacklightLimit.modelNits(0), 0, "only 0 is off")
    }

    func testStopRoundTripAndOldValues() {
        for (index, stop) in KeyboardBacklightLimit.stops.enumerated() {
            XCTAssertEqual(KeyboardBacklightLimit.stopIndex(for: stop), index)
            XCTAssertEqual(KeyboardBacklightLimit.level(atStop: index), stop)
        }
        XCTAssertEqual(KeyboardBacklightLimit.level(atStop: -3), 0)
        XCTAssertEqual(KeyboardBacklightLimit.level(atStop: 99), KeyboardBacklightLimit.range.upperBound)
        XCTAssertEqual(KeyboardBacklightLimit.stopIndex(for: -1), 0)
        XCTAssertEqual(KeyboardBacklightLimit.stopIndex(for: 9), KeyboardBacklightLimit.stops.count - 1)
        // Every old half-percent value still loads unchanged, and sits on its nearest stop.
        var previous = 0
        for step in 0...50 {
            let old = Double(step) * 0.005
            XCTAssertEqual(KeyboardBacklightLimit(maximum: old).maximum, old, accuracy: 1e-12)
            let index = KeyboardBacklightLimit.stopIndex(for: old)
            XCTAssertGreaterThanOrEqual(index, previous, "monotonic")
            XCTAssertLessThanOrEqual(abs(KeyboardBacklightLimit.level(atStop: index) - old), 0.025 + 1e-12)
            previous = index
        }
        XCTAssertEqual(KeyboardBacklightLimit.stopIndex(for: 0.005), 3)
        XCTAssertEqual(KeyboardBacklightLimit.stopIndex(for: 0.0004), 1, "a stray low value shows on the lowest lit stop")
    }

    func testSliderMoveFromAStop() {
        typealias L = KeyboardBacklightLimit
        let index = L.stopIndex(for: 0.01)
        XCTAssertNil(L.maximum(movingSliderTo: index, from: 0.01), "same stop: nothing written")
        XCTAssertEqual(L.maximum(movingSliderTo: index - 1, from: 0.01), 0.005)
        XCTAssertEqual(L.maximum(movingSliderTo: index + 1, from: 0.01), 0.02)
        XCTAssertEqual(L.maximum(movingSliderTo: 0, from: 0.01), 0, "far left = off")
        XCTAssertEqual(L.maximum(movingSliderTo: 99, from: 0.01), L.range.upperBound)
        XCTAssertEqual(L.maximum(movingSliderTo: -5, from: 0.01), 0)
    }

    /// An old 0.005-step ceiling between two stops (0.035, 0.045, 0.015…) is kept until the slider moves, and one step
    /// never skips the stop next to it, whichever way the tie of `stopIndex` goes.
    func testSliderMoveFromAnOldOffStopValue() {
        typealias L = KeyboardBacklightLimit
        for old in stride(from: 0.0, through: 0.25, by: 0.005) where !L.stops.contains(where: { abs($0 - old) < 1e-9 }) {
            let shown = L.stopIndex(for: old)
            XCTAssertNil(L.maximum(movingSliderTo: shown, from: old), "\(old): same position keeps the value")
            let below = L.stops.last { $0 < old }!, above = L.stops.first { $0 > old }!
            XCTAssertEqual(L.maximum(movingSliderTo: shown - 1, from: old), below, "\(old): one step left")
            XCTAssertEqual(L.maximum(movingSliderTo: 0, from: old), 0, "\(old): far left is off")
            if shown < L.stops.count - 1 { // 0.23…0.245 show on the top stop: no step right exists
                XCTAssertEqual(L.maximum(movingSliderTo: shown + 1, from: old), above, "\(old): one step right")
            }
            if shown + 1 < L.stops.count - 1 { // a jump of two or more to the far right lands on the top stop
                XCTAssertEqual(L.maximum(movingSliderTo: L.stops.count - 1, from: old), L.range.upperBound, "\(old): far right")
            }
        }
        XCTAssertEqual(L.maximum(movingSliderTo: L.stopIndex(for: 0.035) - 1, from: 0.035), 0.03)
        XCTAssertEqual(L.maximum(movingSliderTo: L.stopIndex(for: 0.035) + 1, from: 0.035), 0.04)
        XCTAssertEqual(L.maximum(movingSliderTo: 0, from: 0.001), 0.0005, "one step left from 0.1 % is the lowest lit stop")
        XCTAssertEqual(L.maximum(movingSliderTo: 0, from: 0.035), 0, "a jump to the far left is off")
    }

    func testLowestStopIsStillCorrected() {
        let limit = KeyboardBacklightLimit(enabled: true, maximum: 0.0005)
        XCTAssertEqual(limit.correctedLevel(for: 0.001, at: at(12), calendar: calendar), 0.0005)
        XCTAssertNil(limit.correctedLevel(for: 0.0005, at: at(12), calendar: calendar))
    }

    func testPercentLabels() {
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.0005), "0,05\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.001), "0,1\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.0075), "0,75\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.0625), "6,25\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.25), "25\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.005), "0,5\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.01), "1\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.025), "2,5\u{00A0}%")
        XCTAssertTrue(KeyboardBacklightSettings.matches("clavier"))
        XCTAssertTrue(KeyboardBacklightSettings.matches("luminosite"))
        XCTAssertFalse(KeyboardBacklightSettings.matches("agenda"))
    }
}
#endif
