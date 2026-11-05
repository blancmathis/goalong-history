#if os(macOS)
import Foundation
import XCTest
import BraiseCore
@testable import LocalHistoryApp

/// T-046 L9 lot 2 : horaires et réglages de Braise, par le contrôleur (sans vue ni écran réel).
private extension BlockProgramRange {
    func with(_ change: (inout BlockProgramRange) -> Void) -> BlockProgramRange { var copy = self; change(&copy); return copy }
}

@MainActor final class T046UnitBraiseScheduleTests: XCTestCase {
    private func controller() throws -> (BraiseController, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/t046-braise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false,
                                     clock: { Date(timeIntervalSince1970: 1_790_000_000) })
        return (c, root)
    }

    func testRuleRowShowsNextDayMarkerOnlyWhenItCrossesMidnight() {
        let night = ScheduleRule(startMinute: 22 * 60, endMinute: 7 * 60)
        let day = ScheduleRule(startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertTrue(night.crossesMidnight); XCTAssertEqual(night.hours, "22:00 – 07:00")
        XCTAssertFalse(day.crossesMidnight); XCTAssertEqual(day.hours, "09:00 – 17:00")
    }
    private func range(_ start: Int, _ end: Int, days: Set<Int> = Set(1...7)) -> BlockProgramRange {
        BlockProgramRange(weekdays: days, startMinute: start, endMinute: end, lock: nil)
    }
    private func clearRanges(_ c: BraiseController) throws {
        for range in c.ranges.program.ranges { try c.deleteRange(range.id) }
    }
    /// T-048 B2: the Braise rules became the red screen's ranges (BlockProgram model).
    func testEnableSwitchFlipsOnlyThatRangeAndPersistsIt() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        try clearRanges(c)
        let a = range(60, 120), b = range(300, 360)
        try c.saveRange(a, intensity: 1); try c.saveRange(b, intensity: 1)
        try c.setRangeEnabled(a.id, false)
        XCTAssertEqual(c.ranges.disabled, [a.id])
        c.saveNow()
        let reloaded = try BraiseController(store: BraiseStore(directory: root.appendingPathComponent("Braise"),
                                                               legacySettings: root.appendingPathComponent("missing")),
                                            gamma: BraiseTestGamma(), runsTimers: false)
        defer { reloaded.shutdown() }
        XCTAssertEqual(reloaded.ranges.program.ranges.map(\.id), [a.id, b.id]); XCTAssertEqual(reloaded.ranges.disabled, [a.id])
    }
    func testAddRangeStopsAtThirtyTwoAndEditingAnExistingOneStillWorks() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        try clearRanges(c)
        var first: BlockProgramRange?
        for i in 0..<32 {
            let item = range(i, i + 30)
            if first == nil { first = item }
            try c.saveRange(item, intensity: 1)
        }
        XCTAssertEqual(c.ranges.program.ranges.count, 32)
        XCTAssertThrowsError(try c.saveRange(range(600, 700), intensity: 1))
        var edited = try XCTUnwrap(first); edited.endMinute = 500
        XCTAssertNoThrow(try c.saveRange(edited, intensity: 0.5))
        XCTAssertEqual(c.ranges.program.ranges.count, 32)
        XCTAssertEqual(c.ranges.program.ranges.first { $0.id == edited.id }?.endMinute, 500)
        XCTAssertEqual(c.ranges.intensity(of: edited.id), 0.5, accuracy: 0.0001)
    }
    func testSaveRefusesAnEmptyRangeOrNoDay() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        try clearRanges(c)
        XCTAssertThrowsError(try c.saveRange(range(600, 600), intensity: 1))
        XCTAssertThrowsError(try c.saveRange(range(60, 120, days: []), intensity: 1))
        XCTAssertThrowsError(try c.saveRange(range(0, 1_440).with { $0.startMinute = 0; $0.endMinute = 0 }, intensity: 1))
        XCTAssertTrue(c.ranges.program.ranges.isEmpty)
    }
    func testDayPresetsMatchTheirLabels() {
        let all = ScheduleRule(weekdays: Set(1...7)), week = ScheduleRule(weekdays: Set(2...6)), weekend = ScheduleRule(weekdays: Set([1, 7]))
        XCTAssertEqual(all.dayLabel, "Tous les jours")
        XCTAssertEqual(week.dayLabel, "Du lundi au vendredi")
        XCTAssertEqual(weekend.dayLabel, "Le week-end")
        XCTAssertEqual(ScheduleRule(weekdays: [2, 4]).dayLabel, "Lun · Mer")
    }
    func testDayToggleKeepsOnlyRealWeekdaysAndInvalidatesWhenEmpty() {
        var rule = ScheduleRule(weekdays: [2])
        rule.weekdays.remove(2)
        XCTAssertFalse(rule.isValid)
        rule.weekdays.insert(7); XCTAssertTrue(rule.isValid)
        XCTAssertEqual(ScheduleRule(weekdays: [0, 8, 3]).weekdays, [3])
    }
    func testDeleteRemovesOnlyThatRange() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        try clearRanges(c)
        let a = range(60, 120), b = range(300, 360)
        try c.saveRange(a, intensity: 1); try c.saveRange(b, intensity: 1)
        try c.deleteRange(a.id)
        XCTAssertEqual(c.ranges.program.ranges.map(\.id), [b.id])
    }
    func testSlidersAreClampedBySanitize() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        c.update { $0.intensity = 5; $0.brightness = -3 }
        XCTAssertLessThanOrEqual(c.preferences.intensity, 1); XCTAssertGreaterThanOrEqual(c.preferences.intensity, 0)
        XCTAssertGreaterThanOrEqual(c.preferences.brightness, 0.2); XCTAssertLessThanOrEqual(c.preferences.brightness, 1)
        c.update { $0.intensity = 0.4; $0.brightness = 0.6 }
        XCTAssertEqual(c.preferences.intensity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(c.preferences.brightness, 0.6, accuracy: 0.0001)
    }
}
#endif
