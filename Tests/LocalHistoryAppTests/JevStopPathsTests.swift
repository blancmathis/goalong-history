#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 B1 correction 9: every free command that cuts Jev goes through the stop of what runs. Pure: no alert, no real
/// controller, no window. Paths that live in AppKit/SwiftUI actions are checked in their source.
@MainActor final class JevStopPathsTests: XCTestCase {
    private func focus() throws -> ConcentrationController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-jev-paths-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try store.saveSettings(settings)
        let now = Date(timeIntervalSince1970: 1_791_716_400)
        return try ConcentrationController(store: store, clock: { now })
    }

    /// `session stop` (CLI) and every caller that did not pass the stop are refused while the surveillance is protected.
    func testControllerRefusesAnUnconfirmedStopOfAProtectedSession() throws {
        let controller = try focus()
        var lock = BlockLock.typing
        controller.surveillanceLock = { _ in lock }
        try controller.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertThrowsError(try controller.stopSession()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertNotNil(controller.currentSession)
        try controller.stopSession(surveillanceConfirmed: true)
        XCTAssertNil(controller.currentSession)
        lock = .free
        try controller.startSession(intent: "Lire", mode: FocusMode(minutes: 5))
        XCTAssertNoThrow(try controller.stopSession(), "a free surveillance stops as before")
    }

    func testTheCLIStopDoesNotPassTheStop() throws {
        let runtime = try source("Concentration/ConcentrationRuntime.swift")
        let line = try XCTUnwrap(runtime.components(separatedBy: "\n").first { $0.contains("case \"session stop\":") })
        XCTAssertTrue(line.contains("stopSession(")); XCTAssertFalse(line.contains("surveillanceConfirmed"))
        XCTAssertTrue(runtime.contains("value.surveillanceLock = "))
        XCTAssertTrue(runtime.contains("controller?.surveillanceProtected"), "deleting the data does not cut it either")
    }

    func testConcentrationStopAsksTheSessionStop() throws {
        let page = try source("Concentration/ConcentrationPage.swift")
        XCTAssertTrue(page.contains("guard JevStopGate.confirm(action: \"Arrêter la séance\", step: JevStopGate.focusStep()) else { return }"))
        XCTAssertTrue(page.contains("act { try controller.stopSession(surveillanceConfirmed: true) }"))
    }

    /// Correction 1: the menu, the panel, the dashboard and ⌘P all pause through `toggleManualPause`, gated once.
    func testEveryManualPauseGoesThroughTheStop() throws {
        let delegate = try source("AppDelegate.swift")
        let pause = try XCTUnwrap(delegate.range(of: "func toggleManualPause()"))
        let body = String(delegate[pause.lowerBound...].prefix(2_500))
        let gate = try XCTUnwrap(body.range(of: "JevStopGate.confirm(action: \"Mettre en pause\")"))
        let paused = try XCTUnwrap(body.range(of: "continuityPreferences.manuallyPaused = true"))
        XCTAssertLessThan(gate.lowerBound, paused.lowerBound, "asked before anything pauses")
        let menu = try source("MenuBarController.swift")
        XCTAssertFalse(menu.contains("JevStopGate.confirm(action: \"Mettre en pause\")"), "asked once, not twice")
        XCTAssertTrue(menu.contains("togglePause()"))
    }

    /// Correction 3: removing or replacing the key, and turning the local history consent off.
    func testKeyAndConsentAskTheStop() throws {
        let sheet = try source("JevConnectionSheet.swift")
        XCTAssertTrue(sheet.contains("guard JevStopGate.confirm(action: \"Supprimer la clé\") else { return }"))
        XCTAssertTrue(sheet.contains("if monitor.hasKey, !JevStopGate.confirm(action: \"Remplacer la clé\") { return }"))
        XCTAssertTrue(try source("SourceActivation.swift")
            .contains("capability != .localComputerHistory || JevStopGate.confirm(action: \"Désactiver l’enregistrement\")"))
    }

    func testTurningAModuleOffAsksItsSessionsStop() throws {
        let settings = try source("GoalongModulesSettings.swift")
        XCTAssertTrue(settings.contains("case .concentration: return JevStopGate.focusStep()"))
        XCTAssertTrue(settings.contains("case .blocking: return JevStopGate.blockStep()"))
        XCTAssertTrue(settings.contains("!JevStopGate.confirm(action: \"Désactiver \\(module.title)\", step: step)"))
    }

    func testTheMessagesSayTheWayOut() {
        XCTAssertTrue(JevStopGate.noBlockingText.contains("Réglages › Modules"))
        XCTAssertFalse(JevStopGate.lockedText.contains("avant sa fin"))
        XCTAssertEqual(JevStopGate.step(lock: .free, jevEnabled: true), .allow)
        XCTAssertEqual(JevStopGate.step(lock: .password, jevEnabled: true), .password)
        XCTAssertEqual(JevStopGate.step(lock: .password, jevEnabled: false), .allow)
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
