#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class JevInterventionUXTests: XCTestCase {
    @MainActor func testPreferencesPersistAndInvalidStorageDefaultsToNoEffects() throws {
        let name = "JevInterventionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = JevInterventionPreferences(defaults: defaults)
        XCTAssertFalse(store.settings.effectsEnabled)
        store.update { $0.effectsEnabled = true; $0.stages[0].intensity = 35 }
        XCTAssertTrue(JevInterventionPreferences(defaults: defaults).settings.effectsEnabled)
        XCTAssertEqual(JevInterventionPreferences(defaults: defaults).settings.stages[0].intensity, 35)
        store.update { $0.stages[0].intensity = 100 }
        XCTAssertEqual(store.settings.stages[0].intensity, 35)
        XCTAssertNotNil(store.error)
        defaults.set(Data("invalid".utf8), forKey: JevInterventionPreferences.storageKey)
        let corrupt = JevInterventionPreferences(defaults: defaults)
        XCTAssertFalse(corrupt.settings.effectsEnabled); XCTAssertNotNil(corrupt.error)
    }
    @MainActor func testFramesStayInsideEveryDisplayIncludingNegativeCoordinates() {
        for screen in [NSRect(x: 0, y: 0, width: 1280, height: 720),
                       NSRect(x: -1920, y: -800, width: 1920, height: 1080),
                       NSRect(x: 0, y: 0, width: 320, height: 240)] {
            for anchor in JevWarningAnchor.allCases {
                XCTAssertTrue(screen.contains(JevWarningPanel.frame(in: screen, anchor: anchor)))
            }
        }
    }
    @MainActor func testEffectsAreNonactivatingBoundedReusableAndAlwaysCleanedUp() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("No display available") }
        var expirations = 0
        let presenter = JevWarningPanel(ordersWindows: false, onExpiry: { expirations += 1 })
        defer { presenter.hide() }
        var settings = JevInterventionSettings(); settings.effectsEnabled = true
        presenter.update(seconds: 120, appearance: 1, present: true, settings: settings)
        let first = try XCTUnwrap(presenter.panel)
        XCTAssertFalse(first.canBecomeKey); XCTAssertFalse(first.canBecomeMain)
        XCTAssertEqual(first.frame.size, NSSize(width: 400, height: 156))
        let origin = first.frame.origin
        let overlay = try XCTUnwrap(presenter.overlays.first)
        XCTAssertTrue(overlay.ignoresMouseEvents); XCTAssertFalse(overlay.canBecomeKey)
        XCTAssertLessThanOrEqual(try XCTUnwrap(overlay.backgroundColor).alphaComponent, 0.4)
        presenter.update(seconds: 300, appearance: 1, present: false, settings: settings)
        XCTAssertTrue(presenter.overlays.first === overlay, "No flashing window recreation")
        XCTAssertEqual(presenter.panel?.frame.origin, origin, "Never move a visible close button")
        presenter.expire()
        XCTAssertEqual(expirations, 1); XCTAssertNil(presenter.panel); XCTAssertTrue(presenter.overlays.isEmpty)
        presenter.update(seconds: 315, appearance: 2, present: true, settings: settings)
        presenter.hide()
        XCTAssertNil(presenter.panel); XCTAssertTrue(presenter.overlays.isEmpty)
        presenter.update(seconds: 330, appearance: 3, present: true, settings: settings)
        XCTAssertNotEqual(presenter.panel?.frame.origin, origin)
        settings.effectsEnabled = false
        presenter.update(seconds: 345, appearance: 3, present: false, settings: settings)
        XCTAssertTrue(presenter.overlays.isEmpty)
    }
    func testWarningHasNoPauseAndClosingOnlyRearms() throws {
        let warning = try source("JevWarningPanel.swift")
        XCTAssertTrue(warning.contains("Arrête de procrastiner."))
        XCTAssertFalse(warning.contains("startBreak("))
        XCTAssertTrue(warning.contains("jev-warning-close"))
        XCTAssertTrue(warning.contains("jev-warning-disable"))
        XCTAssertTrue(warning.contains("RunLoop.main.add(lease, forMode: .common)"), "Timeout must also work while menus are tracking")
        let monitor = try source("JevMonitor.swift")
        let close = monitor.components(separatedBy: "func dismissWarning() {")[1].components(separatedBy: "private func resetInterventions")[0]
        XCTAssertTrue(close.contains("streak.dismissWarning()"))
        XCTAssertFalse(close.contains("streak.reset()"))
        for boundary in [".jevInterventionsDidChange", "didChangeScreenParametersNotification", "willSleepNotification", "sessionDidResignActiveNotification"] {
            XCTAssertTrue(monitor.contains(boundary))
        }
    }
    func testEverydayBreakDoesNotStopHistoryAndFullStopRequiresConfirmation() throws {
        let root = try source("DashboardRootView.swift")
        XCTAssertTrue(root.contains("JevQuickPauseControl()"))
        XCTAssertFalse(root.contains("GoalongGlobalPauseControl(model: model, compact: true)"))
        let quick = try source("JevInterventionControls.swift").components(separatedBy: "struct JevQuickPauseControl")[1]
        XCTAssertFalse(quick.contains("setPaused(")); XCTAssertFalse(quick.contains("onTogglePause"))
        XCTAssertTrue(quick.contains("monitor.startBreak(minutes:"))
        let global = try source("GoalongGlobalPauseControl.swift")
        XCTAssertTrue(global.contains("else { confirming = true }"))
        XCTAssertTrue(global.contains("Suspendre aussi l’historique ?"))
        XCTAssertTrue(try source("SettingsPage.swift").contains("settings-privacy-stop"))
    }
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
