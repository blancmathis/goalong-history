#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class JevMonitoringUXTests: XCTestCase {
    func testMonitoringIsItsOwnPrimaryDestination() {
        // Jev lives in Réglages › Jev; the old destination still opens it.
        XCTAssertEqual(DashboardSection.primarySections, [.overview, .work, .history, .concentration, .settings])
        XCTAssertEqual(DashboardSection.monitoring.sidebarParent, .settings)
        XCTAssertFalse(ConcentrationHubPage.tabs.contains(.monitoring))
        XCTAssertEqual(DashboardSection.monitoring.simpleTitle, "Jev")
        XCTAssertEqual(DashboardSection(rawValue: "monitoring"), .monitoring)
        XCTAssertEqual(DashboardSection.analytics.sidebarParent, .overview)
        XCTAssertEqual(DashboardSection.privacy.sidebarParent, .settings)
    }

    func testSettingsHoldJevAndTheOldDestinationOpensIt() throws {
        XCTAssertEqual(SettingsPane.matches(""), [.applications, .jev, .modules, .permissions, .storage, .advanced])
        for query in ["jev", "typesafe", "surveillance"] {
            XCTAssertEqual(SettingsPane.matches(query), [.jev], query)
        }
        XCTAssertTrue(try source("SettingsPage.swift").contains("JevMonitoringPage(onOpenRecording:"))
        let model = try source("DashboardViewModel.swift")
        XCTAssertTrue(model.contains("if section == .monitoring {\n                openSettingsPane(.jev)"))
    }

    func testActivationRequiresSetupButDeactivationNeverDoes() {
        for key in [true, false] {
            for history in [true, false] {
                let availability = JevActivationAvailability(hasKey: key, localHistoryEnabled: history)
                XCTAssertEqual(availability.isReady, key && history)
                XCTAssertEqual(availability.canToggle(isEnabled: false), key && history)
                XCTAssertTrue(availability.canToggle(isEnabled: true), "Turning off must always remain possible")
            }
        }
    }

    func testPagePreservesConsentAndUsesRuntimeStatusRatherThanInventingActivity() throws {
        let page = try source("JevMonitoringPage.swift")
        XCTAssertTrue(page.contains("Label(monitor.status"))
        XCTAssertTrue(page.contains("confirming = true"))
        XCTAssertFalse(page.contains("Autoriser les envois à TypeSafe"))
        XCTAssertTrue(page.contains("Autoriser les envois à Jev"))
        XCTAssertTrue(page.contains("monitor.setEnabled(false)"))
        XCTAssertTrue(page.contains(".sheet(isPresented: $showingConnection)"))
        XCTAssertFalse(page.contains("monitor.start()"))
        XCTAssertFalse(page.contains(".set(.localComputerHistory"))
        let connection = try source("JevConnectionSheet.swift")
        XCTAssertTrue(connection.contains("SecureField("))
        XCTAssertFalse(connection.contains("monitor.setEnabled(true)"))
        XCTAssertTrue(connection.contains("if keyError == nil { key = \"\"; dismiss() }"))
        XCTAssertTrue(connection.contains("isPresented: $confirmingRemoval"))
    }

    func testMenuAndSidebarReachThePageWithoutTruncatingItsName() throws {
        let root = try source("DashboardRootView.swift")
        XCTAssertTrue(root.contains("case .concentration, .distractions, .blocking:\n                ConcentrationHubPage(model: model)"))
        XCTAssertTrue(root.contains("case .settings, .monitoring:\n                SettingsPage(model: model)"))
        XCTAssertTrue(try source("Concentration/ConcentrationHubPage.swift").contains(".environment(\\.openJevSettings) { model.selectSection(.monitoring) }"))
        XCTAssertTrue(try source("AppDelegate.swift").contains("onOpenMonitoring: { [weak self] in self?.dashboardWindowController.show(section: .monitoring) }"))
        XCTAssertTrue(try source("JevControls.swift").contains("Ouvrir la surveillance…"))
    }

    func testBatchU07CopyAndControlsStayInTheViews() throws {
        let history = try source("ComputerHistoryPage.swift")
        XCTAssertFalse(history.contains("\"Aucune activité enregistrée\""))
        XCTAssertTrue(history.contains("|| model.isAnalysisPartial\n"), "A partial analysis keeps its summary")
        XCTAssertTrue(history.contains("GoalongMenuPicker(\"Ordre de la chronologie\""))
        let rules = try source("UsageRulesList.swift")
        XCTAssertTrue(rules.contains("DashboardFormatters.duration"))
        XCTAssertTrue(rules.contains("ruleColumnWidth: CGFloat = 176"))
        let controls = try source("GoalongControls.swift")
        XCTAssertTrue(controls.contains("LHTheme.switchTrackHover : LHTheme.switchTrack"))
        XCTAssertFalse(controls.contains("LHTheme.pressedBackground : LHTheme.switchTrack"))
        XCTAssertTrue(controls.contains(".opacity(isEnabled ? 1 : 0.6)"), "R7-C-01: a disabled track, on or off, is faded")
        let share = try source("SharePage.swift")
        XCTAssertTrue(share.contains("avant de créer le fichier."))
        XCTAssertFalse(share.contains("paquet") || share.contains("chaîne d’intégrité"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let focus = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryCore/JevFocus.swift"), encoding: .utf8)
        XCTAssertFalse(focus.contains("Crédit Jev"))
        XCTAssertTrue(focus.contains("Rechargez le compte TypeSafe"))
        XCTAssertTrue(try source("SupportReport.swift").contains("Rechargez le compte TypeSafe"))
        XCTAssertTrue(try source("JevConnectionSheet.swift").contains("Text(\"Clé d’accès Jev\")"))
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
