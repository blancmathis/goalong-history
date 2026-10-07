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
        XCTAssertEqual(DashboardSection.monitoring.simpleTitle, "Surveillance temps réel")
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
        XCTAssertTrue(model.contains("if section == .monitoring {\n                selectSection(.settings)\n                settingsPane = .jev"))
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
        XCTAssertTrue(page.contains("Autoriser les envois à TypeSafe"))
        XCTAssertTrue(page.contains("monitor.setEnabled(false)"))
        XCTAssertTrue(page.contains(".sheet(isPresented: $showingConnection)"))
        XCTAssertFalse(page.contains("monitor.start()"))
        XCTAssertFalse(page.contains(".set(.localComputerHistory"))
        let connection = try source("JevConnectionSheet.swift")
        XCTAssertTrue(connection.contains("SecureField("))
        XCTAssertFalse(connection.contains("monitor.setEnabled(true)"))
        XCTAssertTrue(connection.contains("if monitor.error == nil { key = \"\"; dismiss() }"))
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

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
