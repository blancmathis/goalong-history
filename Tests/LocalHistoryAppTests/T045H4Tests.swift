#if os(macOS)
@testable import LocalHistoryApp
import XCTest

/// T-045 H4: Apple Santé import sheet (Réglages › Avancé › Importer Apple Santé…).
final class T045H4Tests: XCTestCase {
    /// The preview showed « 16 count/min » (English unit) and « 97 % » with a breakable space.
    func testHealthPreviewUnitsAreFrench() {
        XCTAssertEqual(GoalongHealthImportSheet.formatted(["value": 16.0, "unit": "count/min"]), "16\u{00A0}resp./min")
        XCTAssertEqual(GoalongHealthImportSheet.formatted(["value": 97.0, "unit": "%"]), "97\u{00A0}%")
        XCTAssertEqual(GoalongHealthImportSheet.formatted(["value": 62.0, "unit": "bpm"]), "62\u{00A0}bpm")
    }

    /// The confirmation said « Retirer les données Santé du 2026-10-26 » while the picker said « 26 octobre 2026 ».
    func testTrashConfirmationNamesTheDayInFrench() {
        let title = GoalongHealthImportSheet.trashTitle(day: "2026-10-26")
        XCTAssertTrue(title.contains("du 26 octobre 2026 de ce Mac"), title)
        XCTAssertFalse(title.contains("2026-10-26"))
    }

    /// A failed permission relaunch said « La relance n’a pas pu être préparé » and could append
    /// the system error text (English or with a file name) to the alert.
    func testPermissionRelaunchFailureTextIsFrenchAndClean() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/PermissionRecovery.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("PermissionRelaunchHandshake"))
        XCTAssertFalse(text.contains("pu être préparé.") || text.contains("pu être préparé :"), "accord : la relance … préparée")
        XCTAssertFalse(text.contains("localizedDescription"), "aucun texte d’erreur système dans le message")
    }

    /// Two help texts named a settings path that does not exist: « Réglages › Général › Ouverture »
    /// (it is the macOS one) and « Réglages › Aide et diagnostic » (the group sits in Avancé).
    func testSettingsPathsInHelpTextsAreComplete() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/LocalHistoryApp")
        let blocking = try String(contentsOf: sources.appendingPathComponent("Blocking/BlockingPage.swift"), encoding: .utf8)
        XCTAssertFalse(blocking.contains("dans Réglages › Général › Ouverture"), "chemin macOS : Réglages Système › Général › Ouverture")
        XCTAssertTrue(blocking.contains("Autorisez Goalong dans \\(LoginItemsPanel.path)."), "le panneau vient de la constante unique (UI-13)")
        // macOS 15 renamed the pane; before it, « Ouverture » (never « Ouverture de session »).
        if #available(macOS 15, *) {
            XCTAssertEqual(LoginItemsPanel.path, "Réglages Système › Général › Ouverture et extensions")
        } else {
            XCTAssertEqual(LoginItemsPanel.path, "Réglages Système › Général › Ouverture")
        }
        let support = try String(contentsOf: sources.appendingPathComponent("SupportRequest.swift"), encoding: .utf8)
        XCTAssertFalse(support.contains("Réglages › Aide et diagnostic"), "chemin complet : Réglages › Avancé › Aide et diagnostic")
        XCTAssertTrue(support.contains("« Conserver les journaux techniques sur ce Mac » dans Réglages › Avancé › Aide et diagnostic"))
    }
}
#endif
