#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class SettingsHomeIconsTests: XCTestCase {
    func testSettingsPanesUseDistinctSymbols() {
        let panes = SettingsPane.primary + [.advanced]
        let symbols = panes.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertNotEqual(SettingsPane.advanced.symbol, "slider.horizontal.3")
        XCTAssertNotEqual(SettingsPane.recording.symbol, SettingsPane.storage.symbol)
    }

    func testHomeRowsUseTheirOwnSymbols() {
        let symbols = [GoalongHomeRows.recordingSymbol, GoalongHomeRows.sendSymbol, GoalongHomeRows.chatGPTSymbol]
        XCTAssertEqual(Set(symbols).count, 3)
        XCTAssertEqual(GoalongHomeRows.recordingSymbol, SettingsPane.recording.symbol)
        XCTAssertNotEqual(GoalongHomeRows.recordingSymbol, "internaldrive")
        XCTAssertNotEqual(GoalongHomeRows.recordingSymbol, SettingsPane.storage.symbol)
        XCTAssertEqual(GoalongHomeRows.jevSummary(enabled: false), "Surveillance de vos séances")
        XCTAssertEqual(GoalongHomeRows.jevSummary(enabled: true), "Activé")
    }

    func testPermissionRowsShareTheSourceSymbols() {
        let caps = [GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]
        for capability in caps {
            XCTAssertEqual(GoalongHomeRows.permissionSymbol(capability), PermissionSetupCopy(capability: capability, status: .ready).symbol)
        }
        XCTAssertEqual(GoalongHomeRows.permissionSymbol(.appleScreenTime), "chart.bar.xaxis")
        XCTAssertEqual(Set(caps.map(GoalongHomeRows.permissionSymbol)).count, caps.count)
    }

    func testReplacementExampleIgnoresEmptyRules() {
        let sample = "Bonjour Charlie — travail sur le projet"
        XCTAssertEqual(GoalongAnalysisSelectionSheet.exampleResult(rules: [], sample: sample), "Aucun remplacement défini.")
        XCTAssertEqual(GoalongAnalysisSelectionSheet.exampleResult(rules: [GoalongTextReplacement()], sample: sample), "Aucun remplacement défini.")
        XCTAssertEqual(GoalongAnalysisSelectionSheet.exampleResult(rules: [GoalongTextReplacement(search: "Zoé", replacement: "X")], sample: sample), "Aucun texte remplacé dans cet exemple.")
        XCTAssertEqual(GoalongAnalysisSelectionSheet.exampleResult(rules: [GoalongTextReplacement(search: "Bonjour Charlie", replacement: "Projet A")], sample: sample), "Projet A — travail sur le projet")
    }
}
#endif
