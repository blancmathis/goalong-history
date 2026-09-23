#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class JevMonitoringUXTests: XCTestCase {
    func testMonitoringIsItsOwnPrimaryDestination() {
        XCTAssertEqual(DashboardSection.primarySections, [.overview, .history, .monitoring, .settings])
        XCTAssertEqual(DashboardSection.monitoring.sidebarParent, .monitoring)
        XCTAssertEqual(DashboardSection.monitoring.simpleTitle, "Surveillance temps réel")
        XCTAssertEqual(DashboardSection(rawValue: "monitoring"), .monitoring)
        XCTAssertEqual(DashboardSection.analytics.sidebarParent, .overview)
        XCTAssertEqual(DashboardSection.privacy.sidebarParent, .settings)
    }

    func testSettingsNoLongerContainMonitoringOrItsConnection() throws {
        XCTAssertEqual(SettingsPane.matches(""), [.applications, .permissions, .storage])
        for query in ["jev", "typesafe", "surveillance", "minuterie"] {
            XCTAssertTrue(SettingsPane.matches(query).isEmpty, query)
        }
        let settings = try source("SettingsPage.swift")
        XCTAssertFalse(settings.contains("JevSettingsView"))
        XCTAssertFalse(settings.contains("case .jev"))
        XCTAssertFalse(settings.contains("JevMonitoringPage"))
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
        XCTAssertTrue(root.contains("case .monitoring:\n                JevMonitoringPage"))
        XCTAssertTrue(root.contains("wraps: section == .monitoring"))
        XCTAssertTrue(root.contains(".lineLimit(wraps ? 2 : 1)"))
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
