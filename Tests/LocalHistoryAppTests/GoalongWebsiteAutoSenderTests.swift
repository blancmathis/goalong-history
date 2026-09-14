#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

final class GoalongWebsiteAutoSenderTests: XCTestCase {
    @MainActor func testOldUnscopedScheduleIsSuspendedUntilReviewed() async throws {
        let suite = "goalong-auto-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/unused", options: .init(deviceIDs: ["mac"], includeRecap: true))
        value.policyVersion = nil
        defaults.set(try JSONEncoder().encode(value), forKey: "goalong.website.autoSend.v1")
        var sends = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, _, _ in XCTFail("Legacy policy must not read source data"); return Data() },
            sender: { _, _, _, _ in sends += 1; return Data() }, sourceConsent: { _ in true })
        XCTAssertFalse(scheduler.enabled)
        await scheduler.tick()
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(scheduler.status.contains("suspendue"))
    }

    @MainActor func testDailyPolicyRequiresAllowlistsAndRemovesOneOffContext() throws {
        XCTAssertThrowsError(try GoalongWebsiteAutoSender.dailyOptions(.init(deviceIDs: ["mac"], includeApplications: true)))
        XCTAssertThrowsError(try GoalongWebsiteAutoSender.dailyOptions(.init(deviceIDs: ["mac"], includeWebsites: true)))
        var options = GoalongSiteExportOptions(deviceIDs: ["mac"], includeApplications: true, includeWebsites: true,
            includeRecap: true, recapText: "private one-off", recapSectionIndices: [0], rhythmProject: "private context",
            rhythmApplications: ["Private app"], includeRhythmTimeline: true, includeRhythmTimes: true, includeRhythmContext: true,
            selectedApplicationIDs: ["selected.app"], selectedWebsiteDomains: ["allowed.example"])
        options = try GoalongWebsiteAutoSender.dailyOptions(options)
        XCTAssertEqual(options.selectedApplicationIDs, ["selected.app"])
        XCTAssertEqual(options.selectedWebsiteDomains, ["allowed.example"])
        XCTAssertFalse(options.includeRecap); XCTAssertNil(options.recapText); XCTAssertNil(options.recapSectionIndices)
        XCTAssertNil(options.rhythmProject); XCTAssertTrue(options.rhythmApplications.isEmpty)
        XCTAssertFalse(options.includeRhythmTimeline); XCTAssertFalse(options.includeRhythmContext)
    }

    @MainActor func testScheduleHonorsMinuteAndSavedTimezoneAcrossRestart() async throws {
        let suite = "goalong-auto-time-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 45, timeZoneIdentifier: "America/Chicago")
        defaults.set(try JSONEncoder().encode(config), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, day, _ in XCTAssertEqual(day, "2026-09-13"); return Data() },
            sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true })
        let parser = ISO8601DateFormatter()
        await scheduler.tick(now: parser.date(from: "2026-09-14T14:44:59Z")!); XCTAssertEqual(sent, 0)
        await scheduler.tick(now: parser.date(from: "2026-09-14T14:45:00Z")!); XCTAssertEqual(sent, 1)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, _, _ in XCTFail("Already received"); return Data() },
            sender: { _, _, _, _ in XCTFail("Already received"); return Data() }, sourceConsent: { _ in true })
        XCTAssertEqual(restarted.lastSuccess, "2026-09-13")
        await restarted.tick(now: parser.date(from: "2026-09-14T16:00:00Z")!)
    }

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
        }, sender: { _, origin, path, _ in
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

    @MainActor func testDailyDomainsFollowConfiguredHourButFutureRecapTextIsNeverAuthorized() async throws {
        let suite = "goalong-auto-fields-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-auto-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        var sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, date, options in
            XCTAssertEqual(date, "2026-09-10")
            XCTAssertFalse(options.includeRecap); XCTAssertTrue(options.includeWebsites)
            XCTAssertNil(options.recapSectionIndices); XCTAssertNil(options.recapText)
            XCTAssertNil(options.contextualRhythm)
            return Data()
        }, sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true })
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: .init(deviceIDs: ["mac"], includeWebsites: true, includeRecap: true, recapText: "One-off comment", recapSectionIndices: [0, 2], selectedWebsiteDomains: ["example.org"]), hour: 15)
        let early = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 14))!
        await sender.tick(now: early); XCTAssertEqual(sent, 0)
        await sender.tick(now: early.addingTimeInterval(3600)); XCTAssertEqual(sent, 1)
        await sender.tick(now: early.addingTimeInterval(7200)); XCTAssertEqual(sent, 1)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults)
        XCTAssertTrue(restarted.status.contains("15:00"))
    }

    @MainActor func testFailureDisablesAutomaticRetriesIncludingAfterRestart() async throws {
        let suite = "goalong-auto-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"])
        let configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: options)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, exporter: { _, _, _ in Data() }, sender: { _, _, _, _ in
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
        }, sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in consent })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(sender.enabled)
        XCTAssertTrue(sender.status.contains("source est désactivée"))
    }
}
#endif
