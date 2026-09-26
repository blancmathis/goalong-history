import Foundation
import XCTest
@testable import LocalHistoryCore

final class JevStrongerEffectsTests: XCTestCase {
    func testDurationIsAbsentBeforeTenMinutesInBothPopupAndStatus() {
        for seconds in [Int.min, -1, 0, 15, 30, 60, 120, 300, 585, 599] {
            XCTAssertNil(JevReminderPresentation.displayedDuration(after: seconds))
            XCTAssertNil(JevReminderPresentation.detail(after: seconds))
            XCTAssertEqual(JevReminderPresentation.status(after: seconds), "Procrastination détectée")
        }
        XCTAssertEqual(JevReminderPresentation.displayedDuration(after: 600), "10 min")
        XCTAssertEqual(JevReminderPresentation.detail(after: 600), "Ça fait 10 min que tu procrastines.")
        XCTAssertEqual(JevReminderPresentation.status(after: 600), "Procrastination détectée · 10 min")
        XCTAssertEqual(JevReminderPresentation.detail(after: 615), "Ça fait 10 min 15 s que tu procrastines.")
        XCTAssertEqual(JevReminderPresentation.displayedDuration(after: 3600), "60 min")
        XCTAssertNotNil(JevReminderPresentation.detail(after: Int.max))
    }
    func testHiddenDurationDoesNotPostponeEffectsAndAResetHidesItAgain() {
        var settings = JevInterventionSettings(), streak = JevStreak()
        settings.effectsEnabled = true
        settings.applyStrength(.veryStrong)
        let zero = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<41 {
            _ = streak.accept(.procrastination, start: zero.addingTimeInterval(Double(index * 15)),
                              end: zero.addingTimeInterval(Double((index + 1) * 15)))
            let seconds = streak.observedSeconds
            XCTAssertEqual(JevReminderPresentation.detail(after: seconds) != nil, seconds >= 600)
            XCTAssertEqual(settings.stage(at: seconds)?.intensity, seconds < 120 ? nil : seconds < 300 ? 65 : 85)
        }
        streak.reset()
        XCTAssertNil(JevReminderPresentation.detail(after: streak.observedSeconds))
        XCTAssertNil(settings.stage(at: streak.observedSeconds))
    }
    func testFullIntensityRangeIsValidatedAndRoundTrips() throws {
        for intensity in JevInterventionSettings.intensityRange {
            var value = JevInterventionSettings()
            value.effectsEnabled = true
            value.stages[0].intensity = intensity
            value.stages[1].intensity = intensity
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(value.stage(at: 600)?.intensity, intensity)
            XCTAssertEqual(try JSONDecoder().decode(JevInterventionSettings.self,
                from: JSONEncoder().encode(value)), value)
        }
        for intensity in [Int.min, 0, 9, 86, 100, Int.max] {
            var value = JevInterventionSettings()
            value.effectsEnabled = true
            value.stages[1].intensity = intensity
            XCTAssertFalse(value.isValid)
            XCTAssertNil(value.stage(at: Int.max))
        }
    }
    func testRenderOpacityNoLongerClampsAtFortyAndCannotBlackOut() {
        XCTAssertEqual(JevInterventionSettings.overlayOpacity(intensity: 85), 0.85, accuracy: 0.00001)
        XCTAssertEqual(JevInterventionSettings.overlayOpacity(intensity: 65), 0.65, accuracy: 0.00001)
        XCTAssertEqual(JevInterventionSettings.overlayOpacity(intensity: Int.max), 0.85, accuracy: 0.00001)
        XCTAssertEqual(JevInterventionSettings.overlayOpacity(intensity: Int.min), 0.10, accuracy: 0.00001)
    }
    func testStrengthPresetsOnlyChangeIntensityWithoutEnablingAnything() {
        for enabled in [true, false] {
            for strength in JevEffectStrength.allCases {
                var value = JevInterventionSettings()
                value.effectsEnabled = enabled
                value.moveAfterSecondAppearance = false
                value.stages[0].afterMinutes = 3
                value.stages[1].afterMinutes = 9
                value.stages[0].effect = .red
                value.stages[1].enabled = false
                let before = value
                value.applyStrength(strength)
                XCTAssertEqual(value.stages.map(\.intensity), strength.intensities)
                XCTAssertEqual(value.effectsEnabled, before.effectsEnabled)
                XCTAssertEqual(value.moveAfterSecondAppearance, before.moveAfterSecondAppearance)
                XCTAssertEqual(value.stages.map(\.enabled), before.stages.map(\.enabled))
                XCTAssertEqual(value.stages.map(\.afterMinutes), before.stages.map(\.afterMinutes))
                XCTAssertEqual(value.stages.map(\.effect), before.stages.map(\.effect))
                XCTAssertTrue(value.isValid)
                if !enabled { XCTAssertNil(value.stage(at: Int.max)) }
            }
        }
    }
    func testV2MigrationPreservesAllChoicesAndValidatesOldLimits() throws {
        for enabled in [true, false] {
            var old = JevInterventionSettings()
            old.schemaVersion = 2
            old.effectsEnabled = enabled
            old.moveAfterSecondAppearance = false
            old.stages[0].afterMinutes = 4
            old.stages[0].intensity = 40
            old.stages[1].enabled = false
            old.stages[1].afterMinutes = 8
            let next = try XCTUnwrap(old.migratingLegacy())
            XCTAssertEqual(next.schemaVersion, 3)
            XCTAssertEqual(next.effectsEnabled, old.effectsEnabled)
            XCTAssertEqual(next.moveAfterSecondAppearance, old.moveAfterSecondAppearance)
            XCTAssertEqual(next.stages, old.stages)
            XCTAssertTrue(next.isValid)
            old.stages[0].intensity = 45
            XCTAssertNil(old.migratingLegacy(), "Previously corrupt data must not become newly enabled effects")
        }
        var invalid = JevInterventionSettings()
        invalid.schemaVersion = 2
        invalid.stages[1].effect = .red
        XCTAssertNil(invalid.migratingLegacy())
        invalid.schemaVersion = 99
        XCTAssertNil(invalid.migratingLegacy())
    }
}
