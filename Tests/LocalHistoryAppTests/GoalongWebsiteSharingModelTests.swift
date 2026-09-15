#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongWebsiteSharingModelTests: XCTestCase {
    private let catalogBytes = Data(#"{"days":[{"telemetry":{"timezone":"Europe/Paris","devices":[{"id":"mac","name":"Mac de démonstration","kind":"computer","screenSeconds":3600,"apps":[{"id":"editor","name":"Éditeur","seconds":1800},{"id":"private","name":"Application privée","seconds":1800}]}],"websites":null}}]}"#.utf8)

    @MainActor private func fixture(consent: @escaping @MainActor (GoalongSiteExportOptions) -> Bool = { _ in true },
                                   onSend: @escaping (Data) -> Void = { _ in }) throws -> (GoalongWebsiteSharingModel, URL, UserDefaults, String) {
        let suite = "goalong-sharing-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-credential-only".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: consent)
        let bytes = catalogBytes
        let model = GoalongWebsiteSharingModel(autoSender: scheduler, root: root,
            catalogLoader: { _, _, _ in try GoalongSiteSelectionCatalog(payload: bytes) },
            exporter: { _, _, options in
                XCTAssertEqual(options.deviceIDs, ["mac"])
                XCTAssertEqual(options.selectedApplicationIDs, ["editor"])
                XCTAssertEqual(options.strictSelection, true)
                return Data(#"{"version":2,"source":"goalong-history","days":[{"date":"2026-09-14","title":"Goalong","summary":"","outcomes":[],"activities":[],"telemetry":{"devices":[{"id":"device-test","name":"Ordinateur","screenSeconds":null,"hourly":null,"apps":[{"id":"editor","name":"Éditeur","seconds":1800}]}],"websites":null,"agent":null}}]}"#.utf8)
            }, sender: { data, origin, path, fingerprint in
                XCTAssertEqual(origin, "https://goalong.example"); XCTAssertEqual(path, token)
                XCTAssertFalse(fingerprint.isEmpty)
                onSend(data)
                return Data(#"{"imported":1,"updated":0,"skipped":0,"verification":"unverified"}"#.utf8)
            }, sourceConsent: consent)
        return (model, token, defaults, suite)
    }

    @MainActor func testPauseAndResumeCannotSendAnOldPreview() async throws {
        let (model, token, _, _) = try fixture(onSend: { _ in XCTFail("Old preview must not be sent") })
        defer { try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog()
        model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertNotNil(model.preview)
        model.reviewed = true
        try GoalongGlobalPause.setPaused(true, in: token.deletingLastPathComponent())
        try GoalongGlobalPause.setPaused(false, in: token.deletingLastPathComponent())
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertNotNil(model.error)
    }

    func testPreviewDayUsesTheSavedTimezoneInsteadOfAnImplicitUTCDay() {
        var draft = GoalongWebsiteShareDraft()
        draft.date = ISO8601DateFormatter().date(from: "2026-09-14T02:00:00Z")!
        draft.timezone = "America/Chicago"
        XCTAssertEqual(draft.day, "2026-09-13")
        draft.timezone = "Europe/Paris"
        XCTAssertEqual(draft.day, "2026-09-14")
    }

    @MainActor func testCatalogDoesNotSelectAnythingAndOnlyConfirmedBytesAreSent() async throws {
        var received: Data?
        let (model, token, _, _) = try fixture(onSend: { received = $0 })
        defer { try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog()
        XCTAssertEqual(model.catalog?.devices.count, 1)
        XCTAssertTrue(model.draft.deviceIDs.isEmpty)
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertNil(model.preview)
        model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        let bytes = try XCTUnwrap(model.preview?.payload)
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertNil(received, "A preview does not authorize sending")
        model.reviewed = true
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertEqual(received, bytes)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.autoSender.enabled)
    }

    @MainActor func testEditingSelectionInvalidatesPreviewAndConfirmation() async throws {
        let (model, token, _, _) = try fixture(onSend: { _ in XCTFail("Stale preview") })
        defer { try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog(); model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        model.reviewed = true; model.draft.includeHourly = true
        XCTAssertNil(model.preview); XCTAssertFalse(model.reviewed)
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
    }

    @MainActor func testDestinationAndCredentialChangesCannotReuseConsent() async throws {
        let (model, token, _, _) = try fixture(onSend: { _ in XCTFail("Account changed") })
        defer { try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog(); model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        model.reviewed = true
        await model.confirm(origin: "https://another.example", tokenPath: token.path)
        XCTAssertNil(model.preview)
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        model.reviewed = true
        try Data("different-synthetic-upload-access".utf8).write(to: token)
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertTrue(model.error?.contains("accès au compte a changé") == true)
    }

    @MainActor func testRevokingSourceAfterPreviewPreventsAnySend() async throws {
        var consent = true
        let (model, token, _, _) = try fixture(consent: { _ in consent }, onSend: { _ in XCTFail("Source revoked") })
        defer { try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog(); model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        model.reviewed = true; consent = false
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertNil(model.preview); XCTAssertNotNil(model.error)
    }

    @MainActor func testEnablingDailyScheduleDoesNotUploadTheExampleDay() async throws {
        let (model, token, _, _) = try fixture(onSend: { _ in XCTFail("Activating a plan must not send the example") })
        defer { model.autoSender.forget(); try? FileManager.default.removeItem(at: token.deletingLastPathComponent()) }
        await model.loadCatalog(); model.draft.deviceIDs = ["mac"]; model.draft.includeApplications = true; model.draft.applicationIDs = ["editor"]; model.draft.delivery = .daily; model.draft.timezone = "Europe/Paris"
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        model.reviewed = true
        await model.confirm(origin: "https://goalong.example", tokenPath: token.path)
        XCTAssertTrue(model.autoSender.enabled)
        XCTAssertNil(model.autoSender.savedConfiguration?.options.recapSectionIndices)
        model.draft.includeHourly = true
        XCTAssertFalse(model.autoSender.enabled, "Editing a running scope must pause it until reviewed")
    }
}
#endif
