#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-064 lot 7 (H3b): a « non » stays « non », and a context already built never leaves after a consent or pause change.
final class T064ConsentTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t064-consent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// « Personnaliser le bilan », « Données » and « Voir les données qui partiront » save without granting.
    @MainActor func testSavingTheSheetOutsideTheAllowSwitchKeepsANo() throws {
        let store = GoalongCapabilityConsentStore(fileURL: try root().appendingPathComponent("capability-consent.json"))
        XCTAssertFalse(store.isEnabled(.chatGPTAnalysis))
        XCTAssertTrue(GoalongAnalysisSelectionSheet.applyConsent(grantsConsent: false, store: store))
        XCTAssertFalse(store.isEnabled(.chatGPTAnalysis), "A sheet opened to edit choices must not switch the analysis back on")
        XCTAssertTrue(GoalongAnalysisSelectionSheet.applyConsent(grantsConsent: true, store: store))
        XCTAssertTrue(store.isEnabled(.chatGPTAnalysis), "« Autoriser les analyses » still grants on save")
    }

    @MainActor func testTheFooterSaysWhenSavingGrants() {
        XCTAssertEqual(GoalongAnalysisSelectionSheet.readyFooterNote(grantsConsent: false), "Aucun envoi en configurant ces choix.")
        XCTAssertTrue(GoalongAnalysisSelectionSheet.readyFooterNote(grantsConsent: true).contains("autorise les analyses"))
    }

    func testASourceConsentChangeAfterTheContextWasBuiltStopsTheSend() throws {
        let root = try root()
        let store = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json"))
        store.set(.aiConversations, enabled: true, surface: .settings)
        let captured = store.snapshot, pause = try GoalongGlobalPause.admit(in: root)
        XCTAssertTrue(ChatGPTRecapRuntime.sendAuthorityUnchanged(consents: captured, pauseRevision: pause,
                                                                  current: store.snapshot, pauseRoot: root))
        store.set(.aiConversations, enabled: false, surface: .settings)
        XCTAssertFalse(ChatGPTRecapRuntime.sendAuthorityUnchanged(consents: captured, pauseRevision: pause,
                                                                   current: store.snapshot, pauseRoot: root))
    }

    func testAGlobalPauseAfterTheContextWasBuiltStopsTheSend() throws {
        let root = try root()
        let store = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json"))
        let captured = store.snapshot, pause = try GoalongGlobalPause.admit(in: root)
        try GoalongGlobalPause.setPaused(true, in: root)
        XCTAssertFalse(ChatGPTRecapRuntime.sendAuthorityUnchanged(consents: captured, pauseRevision: pause,
                                                                   current: store.snapshot, pauseRoot: root))
        try GoalongGlobalPause.setPaused(false, in: root)
        XCTAssertFalse(ChatGPTRecapRuntime.sendAuthorityUnchanged(consents: captured, pauseRevision: pause,
                                                                   current: store.snapshot, pauseRoot: root),
                       "A pause switched on then off during the send still stops it")
    }

    @MainActor func testVisibleTextOffWithdrawsTheJevExcerptChoice() throws {
        let suite = "t064-jev-excerpt-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: JevMonitor.excerptKey)
        defaults.set(true, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
        XCTAssertFalse(JevMonitor.withdrawExcerptWithoutVisibleText(defaults))
        XCTAssertTrue(defaults.bool(forKey: JevMonitor.excerptKey))
        defaults.set(false, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
        XCTAssertTrue(JevMonitor.withdrawExcerptWithoutVisibleText(defaults))
        defaults.set(true, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
        XCTAssertFalse(defaults.bool(forKey: JevMonitor.excerptKey), "Turning « Texte affiché » back on needs a new confirmation")
    }
}
#endif
