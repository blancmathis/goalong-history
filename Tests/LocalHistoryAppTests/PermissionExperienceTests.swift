#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class PermissionExperienceTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "goalong-permission-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testSetupReturnExpiresAndCanBeCancelledWithoutChangingConsent() {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertNil(PermissionRecovery.pendingSetup(defaults: defaults, now: now))
        PermissionRecovery.rememberSetup(.appleScreenTime, defaults: defaults, now: now)
        XCTAssertEqual(PermissionRecovery.pendingSetup(defaults: defaults, now: now.addingTimeInterval(1)), .appleScreenTime)
        XCTAssertNil(PermissionRecovery.pendingSetup(defaults: defaults, now: now.addingTimeInterval(601)))
        PermissionRecovery.clearSetup(defaults: defaults)
        XCTAssertNil(PermissionRecovery.pendingSetup(defaults: defaults, now: now))
    }
    func testSetupReturnRejectsUnrelatedCapabilityAndClockRollback() {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 10000)
        PermissionRecovery.rememberSetup(.chatGPTAnalysis, defaults: defaults, now: now)
        XCTAssertNil(PermissionRecovery.pendingSetup(defaults: defaults, now: now))
        PermissionRecovery.rememberSetup(.localComputerHistory, defaults: defaults, now: now)
        XCTAssertNil(PermissionRecovery.pendingSetup(defaults: defaults, now: now.addingTimeInterval(-1)))
    }
    func testOnlyExplicitSettingsQuitInFreshSessionCanArmRelaunch() {
        XCTAssertTrue(PermissionRecovery.shouldAssistSettingsQuit(senderBundleID: "com.apple.systempreferences", pendingSetup: true, alreadyRestarting: false))
        for sender: String? in [nil, "ai.goalong.localhistory", "com.apple.loginwindow", "org.sparkle-project.Sparkle.Updater", "unrelated"] {
            XCTAssertFalse(PermissionRecovery.shouldAssistSettingsQuit(senderBundleID: sender, pendingSetup: true, alreadyRestarting: false))
        }
        XCTAssertFalse(PermissionRecovery.shouldAssistSettingsQuit(senderBundleID: "com.apple.systempreferences", pendingSetup: false, alreadyRestarting: false))
        XCTAssertFalse(PermissionRecovery.shouldAssistSettingsQuit(senderBundleID: "com.apple.systempreferences", pendingSetup: true, alreadyRestarting: true))
    }
    func testPostRestartInspectionNeverEnablesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
        let flow = SourceActivationFlow(store: store, check: { _, done in done(.ready) })
        flow.inspect(.appleScreenTime)
        XCTAssertEqual(flow.result, .ready)
        XCTAssertFalse(flow.completed)
        XCTAssertFalse(store.isEnabled(.appleScreenTime))
        var prepared = 0
        flow.checkAndEnable(.appleScreenTime, surface: .settings) { prepared += 1 }
        XCTAssertEqual(prepared, 1)
        XCTAssertTrue(store.isEnabled(.appleScreenTime))
        XCTAssertTrue(flow.completed)
    }
    func testRecoveryCopyNamesRealPermissionAndDisclosesBroadDiskAccess() {
        let screenTime = PermissionSetupCopy(capability: .appleScreenTime, status: .fullDiskAccess)
        XCTAssertEqual(screenTime.permission, "Accès complet au disque")
        XCTAssertTrue(screenTime.privacy.contains("L’accès complet au disque est large"))
        let computer = PermissionSetupCopy(capability: .localComputerHistory, status: .accessibility)
        XCTAssertEqual(computer.permission, "Accessibilité")
        XCTAssertTrue(computer.privacy.contains("Pas de captures d’écran"))
        XCTAssertFalse(computer.purpose.contains("record what you type"))
    }
    func testUIU05SheetTitleAndBadgeCopy() {
        XCTAssertEqual(PermissionSetupCopy(capability: .localComputerHistory, status: .accessibility).title, "Autoriser l’historique de ce Mac")
        XCTAssertEqual(PermissionSetupCopy(capability: .appleScreenTime, status: .fullDiskAccess).title, "Autoriser Temps d’écran Apple")
        XCTAssertEqual(PermissionSetupStatusCard.badge(checking: false, ready: false, unavailable: false), "À autoriser")
        XCTAssertEqual(PermissionSetupStatusCard.badge(checking: false, ready: false, unavailable: true), "Non confirmé")
        XCTAssertEqual(PermissionSetupStatusCard.badge(checking: true, ready: false, unavailable: true), "Vérification")
        XCTAssertEqual(PermissionSetupStatusCard.badge(checking: false, ready: true, unavailable: true), "Autorisé")
    }
    func testUIU05RetentionTitlesAreDistinctAndPlain() {
        let titles = HistoryDataClass.allCases.map { $0.retentionTitle }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains("Preuves locales"))
        XCTAssertFalse(titles.contains("Résumés d’Activité"))
    }
}
#endif
