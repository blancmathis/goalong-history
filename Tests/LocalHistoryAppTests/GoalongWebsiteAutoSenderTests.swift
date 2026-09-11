#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

final class GoalongWebsiteAutoSenderTests: XCTestCase {
    @MainActor func testExplicitScheduleSendsOnceAndExcludesUnreviewableDailyText() async throws {
        let suite = "goalong-auto-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-auto-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        var exported = 0, sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, options in
            exported += 1
            XCTAssertFalse(options.includeRecap); XCTAssertNil(options.recapText); XCTAssertFalse(options.includeWebsites)
            XCTAssertEqual(options.maskedApplications, ["Secret"])
            return Data("synthetic".utf8)
        }, sender: { _, origin, path in
            XCTAssertEqual(origin, "https://goalong.example"); XCTAssertEqual(path, token)
            sent += 1; return Data()
        }, sourceConsent: { _ in true })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 0)
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: .init(deviceIDs: ["mac"], includeRecap: true, maskedApplications: ["Secret"], recapText: "Do not repeat this"))
        await sender.tick(now: date); await sender.tick(now: date)
        XCTAssertEqual(exported, 1); XCTAssertEqual(sent, 1)
        sender.stop()
        await sender.tick(now: date.addingTimeInterval(86400))
        XCTAssertEqual(sent, 1); XCTAssertFalse(sender.enabled)
    }

    @MainActor func testFailureDisablesAutomaticRetriesIncludingAfterRestart() async throws {
        let suite = "goalong-auto-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"])
        let configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: options)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, _, _ in Data() }, sender: { _, _, _ in
            sent += 1; throw GoalongSiteExportError.invalid("Receipt unknown")
        }, sourceConsent: { _ in true })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date); await sender.tick(now: date.addingTimeInterval(86400))
        XCTAssertEqual(sent, 1); XCTAssertFalse(sender.enabled)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults)
        XCTAssertFalse(restarted.enabled)
    }
    @MainActor func testSourceConsentRevokedDuringPreparationPreventsSending() async throws {
        let suite = "goalong-auto-consent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]))
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var consent = true, sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, _, _ in
            consent = false
            return Data()
        }, sender: { _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in consent })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(sender.enabled)
        XCTAssertTrue(sender.status.contains("source est désactivée"))
    }
}
#endif
