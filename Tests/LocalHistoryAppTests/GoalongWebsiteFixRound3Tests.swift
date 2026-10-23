#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongWebsiteFixRound3Tests: XCTestCase {
    private let catalogBytes = Data(#"{"days":[{"telemetry":{"timezone":"Europe/Paris","devices":[{"id":"mac","name":"Mac","kind":"computer","screenSeconds":60,"apps":[{"id":"com.example.editor","name":"Editeur","seconds":60},{"id":"com.example.dating","name":"Rencontres","seconds":30}]}],"websites":{"rows":[{"domain":"secret.example","seconds":60}]}}}]}"#.utf8)
    private let okPayload = Data(#"{"version":2,"source":"goalong-history","days":[{"date":"2026-09-14","title":"G","summary":"","outcomes":[],"activities":[],"telemetry":{"devices":[{"id":"d","name":"O","screenSeconds":null,"hourly":null,"apps":[{"id":"e","name":"E","seconds":60}]}],"websites":null,"agent":null}}]}"#.utf8)

    private func env() throws -> (UserDefaults, URL, URL) {
        let suite = "goalong-r3-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-credential-only".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        return (defaults, root, token)
    }
    private let noSite: () -> (String) -> Bool = { { _ in false } }

    @MainActor func testApplicationsHiddenInEveryShareAreNeitherListedPreselectedNorSent() async throws {
        let (defaults, root, _) = try env()
        let bytes = catalogBytes, ok = okPayload
        let hiddenApp: () -> (String?, String) -> Bool = { { id, _ in id == "com.example.dating" } }
        var exported: [GoalongSiteExportOptions] = []
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: hiddenApp)
        let model = GoalongWebsiteSharingModel(autoSender: sender, root: root,
            catalogLoader: { _, _, _ in try GoalongSiteSelectionCatalog(payload: bytes) },
            exporter: { _, _, options in exported.append(options); return ok },
            sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: hiddenApp)
        await model.loadCatalog()
        XCTAssertEqual(model.catalog?.devices.first?.applications.map(\.id), ["com.example.editor"])
        XCTAssertEqual(model.draft.applicationIDs, ["com.example.editor"])
        model.draft.applicationIDs = ["com.example.editor", "com.example.dating"]
        await model.prepare(origin: "", tokenPath: "")
        XCTAssertEqual(exported.last?.selectedApplicationIDs, ["com.example.editor"])
    }

    @MainActor func testHiddenDefaultHidesEveryApplication() async throws {
        let (defaults, root, _) = try env()
        let bytes = catalogBytes
        let model = GoalongWebsiteSharingModel(autoSender: GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in true } }), root: root,
            catalogLoader: { _, _, _ in try GoalongSiteSelectionCatalog(payload: bytes) },
            exporter: { _, _, _ in XCTFail("Nothing may be exported"); return Data() },
            sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in true } })
        await model.loadCatalog()
        XCTAssertEqual(model.catalog?.devices.first?.applications.count, 0)
        XCTAssertTrue(model.draft.applicationIDs.isEmpty)
        model.draft.applicationIDs = ["com.example.editor"]
        await model.prepare(origin: "", tokenPath: "")
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.error, GoalongWebsiteAutoSender.nothingSelectedMessage)
    }

    @MainActor func testSavedPlanDropsAnApplicationHiddenLaterAtTickTime() async throws {
        let (defaults, root, token) = try env()
        var hiddenIDs = Set<String>()
        var exported: [GoalongSiteExportOptions] = []
        let ok = okPayload
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root,
            exporter: { _, _, options in exported.append(options); return ok },
            sender: { _, _, _, _ in Data(#"{"imported":1}"#.utf8) },
            sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { id, _ in hiddenIDs.contains(id ?? "") } })
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path,
            options: .init(deviceIDs: ["mac"], includeApplications: true, selectedApplicationIDs: ["a", "b"]), hour: 0, minute: 0)
        XCTAssertNotNil(sender.hasTimer ? true : nil)
        hiddenIDs = ["b"]
        await sender.tick(now: Date().addingTimeInterval(86_400))
        XCTAssertEqual(exported.last?.selectedApplicationIDs, ["a"])
    }

    @MainActor func testPlanWhoseSubjectsAreAllHiddenPausesWithAReasonAndSendsNothing() async throws {
        let (defaults, root, token) = try env()
        var hidden = false
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root,
            exporter: { _, _, _ in XCTFail("An empty day must not be exported"); return Data() },
            sender: { _, _, _, _ in XCTFail("An empty day must not be sent"); return Data() },
            sourceConsent: { _ in true }, hiddenWebsites: { { _ in hidden } }, hiddenApplications: { { _, _ in false } })
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"], includeApplications: false, includeWebsites: true, selectedWebsiteDomains: ["secret.example"])
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: options, hour: 0, minute: 0)
        hidden = true
        XCTAssertThrowsError(try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: options, hour: 0, minute: 0))
        await sender.tick(now: Date().addingTimeInterval(86_400))
        XCTAssertFalse(sender.enabled)
        XCTAssertEqual(sender.pauseReason, "Synchronisation arrêtée : les applications et sites choisis sont désormais masqués.")
        // The reason survives a relaunch; a user stop clears it.
        let again = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true })
        XCTAssertEqual(again.pauseReason, sender.pauseReason)
        again.stop()
        XCTAssertNil(again.pauseReason)
        XCTAssertNil(GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }).pauseReason)
    }

    @MainActor func testFailedSendSetsReasonAndEnableClearsIt() async throws {
        let (defaults, root, token) = try env()
        let ok = okPayload
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in ok },
            sender: { _, _, _, _ in throw GoalongSiteExportError.invalid("offline") },
            sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in false } })
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"], includeApplications: true, selectedApplicationIDs: ["a"])
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: options, hour: 0, minute: 0)
        await sender.tick(now: Date().addingTimeInterval(86_400))
        XCTAssertFalse(sender.enabled)
        XCTAssertNotNil(sender.pauseReason)
        XCTAssertEqual(GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }).pauseReason, sender.pauseReason)
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: options, hour: 0, minute: 0)
        XCTAssertNil(sender.pauseReason)
    }

    @MainActor func testDisabledSenderIgnoresTicksAndEnabledOneKeepsPauseStatus() async throws {
        let (defaults, root, token) = try env()
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in false } })
        let initial = sender.status
        try GoalongGlobalPause.setPaused(true, in: root)
        await sender.tick()
        XCTAssertEqual(sender.status, initial)
        try GoalongGlobalPause.setPaused(false, in: root)
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"], includeApplications: true, selectedApplicationIDs: ["a"])
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: options, hour: 23, minute: 59)
        let active = sender.status
        try GoalongGlobalPause.setPaused(true, in: root)
        await sender.tick()
        XCTAssertEqual(sender.status, "Pause globale : envoi suspendu, programmation conservée.")
        try GoalongGlobalPause.setPaused(false, in: root)
        await sender.tick()
        XCTAssertTrue(sender.status.hasPrefix("Activée"), sender.status)
        _ = active
    }

    @MainActor func testWebsiteFallbackExplanationSurvivesTheFlagChangeReload() async throws {
        let (defaults, root, _) = try env()
        let bytes = catalogBytes
        var calls = 0
        let model = GoalongWebsiteSharingModel(autoSender: GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in false } }), root: root,
            catalogLoader: { _, _, includeWebsites in
                calls += 1
                if includeWebsites { throw GoalongSiteExportError.invalid("Website details are unavailable") }
                return try GoalongSiteSelectionCatalog(payload: bytes)
            }, sourceConsent: { _ in true }, hiddenWebsites: noSite, hiddenApplications: { { _, _ in false } })
        model.draft.includeWebsites = true
        await model.loadCatalog()
        XCTAssertFalse(model.draft.includeWebsites)
        XCTAssertNotNil(model.error)
        // What the sheet's onChange does after the model's own change.
        await model.includeWebsitesChanged()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(calls, 2)
        // A real user toggle still reloads.
        model.draft.includeWebsites = true
        await model.includeWebsitesChanged()
        XCTAssertEqual(calls, 4)
    }

    func testShareBuildErrorsAreFrench() {
        let all: [ShareBuildError] = [.noSeals, .brokenSeal(3), .missingEvents(1), .brokenEvent("abcdef0123456789"),
                                                         .cancelled, .sourceIncomplete("x"), .exclusionsUnreadable, .exclusionsChanged]
        for error in all {
            let text = DashboardViewModel.userFacingMessage(error)
            XCTAssertFalse(text.isEmpty)
            for english in ["failed", "available", "Share source", "No sealed", "Completely private", "cancelled"] {
                XCTAssertFalse(text.contains(english), "\(error): \(text)")
            }
        }
        XCTAssertEqual(DashboardViewModel.userFacingMessage(ShareBuildError.noSeals), "Aucune minute scellée n’est disponible pour ce jour.")
    }
}
#endif
