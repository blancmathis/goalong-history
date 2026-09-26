#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class JevStrongerEffectsUXTests: XCTestCase {
    @MainActor func testV2StorageMigratesOnceAndCorruptNewestNeverFallsBack() throws {
        let name = "JevEffectsV3." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var old = JevInterventionSettings()
        old.schemaVersion = 2
        old.effectsEnabled = true
        old.stages[0].intensity = 35
        old.stages[1].enabled = false
        let oldData = try JSONEncoder().encode(old)
        defaults.set(oldData, forKey: JevInterventionPreferences.previousStorageKey)
        let migrated = JevInterventionPreferences(defaults: defaults)
        XCTAssertNil(migrated.error)
        XCTAssertEqual(migrated.settings.stages, old.stages)
        XCTAssertTrue(migrated.settings.effectsEnabled)
        XCTAssertEqual(migrated.settings.schemaVersion, 3)
        XCTAssertEqual(defaults.data(forKey: JevInterventionPreferences.previousStorageKey), oldData)
        migrated.update { $0.effectsEnabled = false; $0.applyStrength(.veryStrong) }
        let restored = JevInterventionPreferences(defaults: defaults)
        XCTAssertEqual(restored.settings.stages.map(\.intensity), [65, 85])
        XCTAssertFalse(restored.settings.effectsEnabled)
        XCTAssertFalse(restored.settings.stages[1].enabled)
        XCTAssertEqual(defaults.data(forKey: JevInterventionPreferences.previousStorageKey), oldData)
        defaults.set(Data("invalid".utf8), forKey: JevInterventionPreferences.storageKey)
        let corrupt = JevInterventionPreferences(defaults: defaults)
        XCTAssertFalse(corrupt.settings.effectsEnabled)
        XCTAssertNotNil(corrupt.error)
    }
    @MainActor func testInvalidV2DoesNotFallBackToEnabledV1OrBecomeValidV3() throws {
        let name = "JevEffectsMigrationBoundary." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var v1 = JevInterventionSettings()
        v1.schemaVersion = 1
        v1.effectsEnabled = true
        v1.stages.append(.init(afterMinutes: 10, effect: .dimAndRed, intensity: 30))
        defaults.set(try JSONEncoder().encode(v1), forKey: JevInterventionPreferences.legacyStorageKey)
        for version in [2, 3, 99] {
            var corruptV2 = JevInterventionSettings()
            corruptV2.schemaVersion = version
            corruptV2.effectsEnabled = true
            corruptV2.stages[1].intensity = 85
            defaults.set(try JSONEncoder().encode(corruptV2), forKey: JevInterventionPreferences.previousStorageKey)
            let rejected = JevInterventionPreferences(defaults: defaults)
            XCTAssertFalse(rejected.settings.effectsEnabled)
            XCTAssertNotNil(rejected.error)
            XCTAssertNil(defaults.data(forKey: JevInterventionPreferences.storageKey))
        }
    }
    @MainActor func testEightyFivePercentIsActuallyRenderedAndSafetyCleanupStillWorks() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("No display available") }
        let presenter = JevWarningPanel(ordersWindows: false)
        defer { presenter.hide() }
        var settings = JevInterventionSettings()
        settings.effectsEnabled = true
        settings.applyStrength(.veryStrong)
        for effect in JevScreenEffect.allCases {
            settings.stages[0].effect = effect
            settings.stages[0].intensity = 85
            presenter.update(seconds: 120, appearance: 1, present: true, settings: settings)
            let panel = try XCTUnwrap(presenter.panel)
            XCTAssertFalse(panel.canBecomeKey)
            for overlay in presenter.overlays {
                XCTAssertEqual(try XCTUnwrap(overlay.backgroundColor).alphaComponent, 0.85, accuracy: 0.001)
                XCTAssertTrue(overlay.ignoresMouseEvents)
                XCTAssertFalse(overlay.canBecomeKey)
                XCTAssertFalse(overlay.canBecomeMain)
                XCTAssertLessThan(overlay.level.rawValue, panel.level.rawValue)
            }
        }
        let original = try XCTUnwrap(presenter.overlays.first)
        presenter.update(seconds: 585, appearance: 1, present: false, settings: settings)
        let frame = try XCTUnwrap(presenter.panel).frame
        presenter.update(seconds: 600, appearance: 1, present: false, settings: settings)
        XCTAssertTrue(presenter.overlays.first === original)
        XCTAssertEqual(presenter.panel?.frame, frame)
        presenter.dismissPopup()
        XCTAssertFalse(presenter.overlays.isEmpty, "Close keeps effects and their original expiry")
        presenter.expire()
        XCTAssertTrue(presenter.overlays.isEmpty)
        XCTAssertNil(presenter.panel)
        presenter.update(seconds: 600, appearance: 2, present: true, settings: settings)
        settings.effectsEnabled = false
        presenter.update(seconds: 615, appearance: 2, present: false, settings: settings)
        XCTAssertTrue(presenter.overlays.isEmpty)
    }
    func testPopupAndMonitorUseTheSameDisplayPolicyAndControlsOfferStrongPresets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
        }
        let popup = try source("JevWarningPanel.swift"), monitor = try source("JevMonitor.swift")
        XCTAssertTrue(popup.contains("if let detail = JevReminderPresentation.detail(after: content.seconds)"))
        XCTAssertTrue(monitor.contains("JevReminderPresentation.status(after: self.streak.observedSeconds)"))
        XCTAssertFalse(popup.contains("JevInterventionSettings.duration(content.seconds)"))
        XCTAssertFalse(monitor.contains("JevInterventionSettings.duration(self.streak.observedSeconds)"))
        let controls = try source("JevInterventionControls.swift")
        XCTAssertTrue(controls.contains("JevEffectStrength.allCases"))
        XCTAssertTrue(controls.contains("JevInterventionSettings.intensityRange.upperBound"))
        XCTAssertFalse(controls.contains("Ça fait 15 secondes"))
        XCTAssertFalse(controls.contains(".disabled(!preferences.settings.effectsEnabled)"))
    }
}
#endif
