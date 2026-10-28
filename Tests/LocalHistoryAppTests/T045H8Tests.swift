#if os(macOS)
@testable import LocalHistoryApp
import AppKit
import XCTest

/// T-045 H8: first-launch, menu bar and settings texts and controls.
final class T045H8Tests: XCTestCase {
    /// Every other text addresses the user with « vous »; the Braise colour filter said « Vérifie » and « apps ».
    func testBraiseRejectedFilterMessageUsesVous() throws {
        let text = try XCTUnwrap(GammaError.rejected.errorDescription)
        XCTAssertFalse(text.contains("Vérifie "), text)
        XCTAssertFalse(text.contains(" apps"), text)
        XCTAssertTrue(text.contains("Vérifiez les autres applications"), text)
    }

    /// Return must never erase the history from the menu bar: « Annuler » is the default button
    /// (first), and « Effacer » is marked destructive.
    func testMenuBarEraseConfirmationDefaultsToCancel() {
        let alert = MenuBarController.destructiveConfirmationAlert(title: "Effacer ?", message: "Test")
        XCTAssertEqual(alert.buttons.map(\.title), ["Annuler", "Effacer"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        XCTAssertFalse(alert.buttons[0].hasDestructiveAction)
    }

    /// The icon-only refresh button of « Temps d’écran » must be named for VoiceOver and the tooltip.
    func testScreenTimeRefreshButtonHasAName() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp/AppleScreenTime/ScreenTimePage.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "screenTime.refresh()"))
        let tail = String(source[start.upperBound...].prefix(900))
        XCTAssertTrue(tail.contains(".accessibilityLabel(\"Actualiser le temps d’écran\")"), tail)
        XCTAssertTrue(tail.contains(".help(\"Actualiser le temps d’écran\")"), tail)
    }
}
#endif
