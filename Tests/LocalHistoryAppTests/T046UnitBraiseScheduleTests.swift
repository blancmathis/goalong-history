#if os(macOS)
import Foundation
import XCTest
import BraiseCore
@testable import LocalHistoryApp

/// T-046 L9 lot 2 : horaires et réglages de Braise, par le contrôleur (sans vue ni écran réel).
@MainActor final class T046UnitBraiseScheduleTests: XCTestCase {
    private func controller() throws -> (BraiseController, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/t046-braise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false,
                                     clock: { Date(timeIntervalSince1970: 1_790_000_000) })
        c.update { $0.rules = [] } // l'installation neuve contient un horaire d'exemple
        return (c, root)
    }

    func testRuleRowShowsNextDayMarkerOnlyWhenItCrossesMidnight() {
        let night = ScheduleRule(startMinute: 22 * 60, endMinute: 7 * 60)
        let day = ScheduleRule(startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertTrue(night.crossesMidnight); XCTAssertEqual(night.hours, "22:00 – 07:00")
        XCTAssertFalse(day.crossesMidnight); XCTAssertEqual(day.hours, "09:00 – 17:00")
    }
    func testEnableSwitchFlipsOnlyThatRuleAndPersistsIt() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        let a = ScheduleRule(startMinute: 60, endMinute: 120), b = ScheduleRule(startMinute: 300, endMinute: 360)
        try c.saveRule(a); try c.saveRule(b)
        c.update { p in if let i = p.rules.firstIndex(where: { $0.id == a.id }) { p.rules[i].enabled = false } }
        XCTAssertEqual(c.preferences.rules.map(\.enabled), [false, true])
        c.saveNow()
        let reloaded = try BraiseController(store: BraiseStore(directory: root.appendingPathComponent("Braise"),
                                                               legacySettings: root.appendingPathComponent("missing")),
                                            gamma: BraiseTestGamma(), runsTimers: false)
        defer { reloaded.shutdown() }
        XCTAssertEqual(reloaded.preferences.rules.map(\.enabled), [false, true])
    }
    func testAddRuleStopsAtThirtyTwoAndEditingAnExistingOneStillWorks() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        var first: ScheduleRule?
        for i in 0..<32 {
            let rule = ScheduleRule(startMinute: i, endMinute: i + 30)
            if first == nil { first = rule }
            try c.saveRule(rule)
        }
        XCTAssertEqual(c.preferences.rules.count, 32)
        XCTAssertThrowsError(try c.saveRule(ScheduleRule(startMinute: 600, endMinute: 700)))
        var edited = try XCTUnwrap(first); edited.endMinute = 500
        XCTAssertNoThrow(try c.saveRule(edited))
        XCTAssertEqual(c.preferences.rules.count, 32)
        XCTAssertEqual(c.preferences.rules.first { $0.id == edited.id }?.endMinute, 500)
    }
    func testSaveRefusesAnEmptyRangeOrNoDay() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try c.saveRule(ScheduleRule(startMinute: 600, endMinute: 600)))
        XCTAssertThrowsError(try c.saveRule(ScheduleRule(weekdays: [], startMinute: 60, endMinute: 120)))
        XCTAssertTrue(c.preferences.rules.isEmpty)
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
    func testDeleteRemovesOnlyThatRule() throws {
        let (c, root) = try controller(); defer { c.shutdown(); try? FileManager.default.removeItem(at: root) }
        let a = ScheduleRule(startMinute: 60, endMinute: 120), b = ScheduleRule(startMinute: 300, endMinute: 360)
        try c.saveRule(a); try c.saveRule(b)
        c.deleteRule(a.id)
        XCTAssertEqual(c.preferences.rules.map(\.id), [b.id])
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
