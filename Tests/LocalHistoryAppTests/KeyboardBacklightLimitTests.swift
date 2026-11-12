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
        XCTAssertNil(limit.correctedLevel(for: 0.0102, at: at(12), calendar: calendar), "within tolerance: no write loop")
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

    func testPercentLabels() {
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.005), "0,5\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.01), "1\u{00A0}%")
        XCTAssertEqual(KeyboardBacklightSettings.percent(0.025), "2,5\u{00A0}%")
        XCTAssertTrue(KeyboardBacklightSettings.matches("clavier"))
        XCTAssertTrue(KeyboardBacklightSettings.matches("luminosite"))
        XCTAssertFalse(KeyboardBacklightSettings.matches("agenda"))
    }
}
#endif
