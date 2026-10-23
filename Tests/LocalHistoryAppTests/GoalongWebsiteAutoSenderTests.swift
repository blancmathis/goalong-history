#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongWebsiteAutoSenderTests: XCTestCase {
    @MainActor func testOldUnscopedScheduleIsSuspendedUntilReviewed() async throws {
        let suite = "goalong-auto-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = hermeticDataRoot()
        var value = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/unused", options: .init(deviceIDs: ["mac"], includeRecap: true))
        value.policyVersion = nil
        defaults.set(try JSONEncoder().encode(value), forKey: "goalong.website.autoSend.v1")
        var sends = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in XCTFail("Legacy policy must not read source data"); return Data() },
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

    @MainActor func testPausedFileInAnotherRootDoesNotChangeTheSchedulerResult() async throws {
        let suite = "goalong-auto-roots-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pausedRoot = hermeticDataRoot(), root = hermeticDataRoot()
        try GoalongGlobalPause.setPaused(true, in: pausedRoot)
        XCTAssertTrue(GoalongGlobalPause.isPaused(in: pausedRoot)); XCTAssertFalse(GoalongGlobalPause.isPaused(in: root))
        var config = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 45, timeZoneIdentifier: "America/Chicago")
        config.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        defaults.set(try JSONEncoder().encode(config), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in Data() },
            sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true })
        await scheduler.tick(now: ISO8601DateFormatter().date(from: "2026-09-14T14:45:00Z")!)
        XCTAssertEqual(sent, 1)
    }

    /// The Makefile and CI run tests with a throwaway home (GOALONG_TEST_HOME). Then the data root must stay inside it.
    func testDataRootStaysInsideTheThrowawayHomeWhenOneIsConfigured() throws {
        guard let home = ProcessInfo.processInfo.environment["GOALONG_TEST_HOME"], !home.isEmpty else {
            throw XCTSkip("No throwaway home configured; use `make test`.")
        }
        let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        XCTAssertTrue(AppPaths.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(resolved + "/"),
                      "\(AppPaths.applicationSupportDirectory.path) is outside \(resolved)")
    }

    @MainActor func testScheduleHonorsMinuteAndSavedTimezoneAcrossRestart() async throws {
        let suite = "goalong-auto-time-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = hermeticDataRoot()
        var config = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 45, timeZoneIdentifier: "America/Chicago")
        config.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        defaults.set(try JSONEncoder().encode(config), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in XCTAssertEqual(day, "2026-09-13"); return Data() },
            sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true })
        let parser = ISO8601DateFormatter()
        await scheduler.tick(now: parser.date(from: "2026-09-14T14:44:59Z")!); XCTAssertEqual(sent, 0)
        await scheduler.tick(now: parser.date(from: "2026-09-14T14:45:00Z")!); XCTAssertEqual(sent, 1)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in XCTFail("Already received"); return Data() },
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
        // Reopen the same isolated privacy-policy root, never the maintainer’s real settings.
        let restarted = GoalongWebsiteAutoSender(defaults: defaults, root: root)
        XCTAssertTrue(restarted.status.contains("15:00"))
    }

    @MainActor func testFailureDisablesAutomaticRetriesIncludingAfterRestart() async throws {
        let suite = "goalong-auto-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = hermeticDataRoot()
        let options = GoalongSiteExportOptions(deviceIDs: ["mac"])
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: options)
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in Data() }, sender: { _, _, _, _ in
            sent += 1; throw GoalongSiteExportError.invalid("Receipt unknown")
        }, sourceConsent: { _ in true })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date); await sender.tick(now: date.addingTimeInterval(86400))
        XCTAssertEqual(sent, 1); XCTAssertFalse(sender.enabled)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults, root: root)
        XCTAssertFalse(restarted.enabled)
    }
    @MainActor func testSourceConsentRevokedDuringPreparationPreventsSending() async throws {
        let suite = "goalong-auto-consent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = hermeticDataRoot()
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]))
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var consent = true, sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in
            consent = false
            return Data()
        }, sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in consent })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(sender.enabled)
        XCTAssertTrue(sender.status.contains("source est désactivée"))
    }
    @MainActor private func scheduledDefaults(_ name: String, root: URL, configure: (inout GoalongWebsiteAutoSender.Configuration) -> Void = { _ in }) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]))
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        return (defaults, suite)
    }

    @MainActor func testUnreachableSiteRetriesTheSameDayWithBackoffThenPauses() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduledDefaults("network", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent = 0, reachable = false
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in Data() }, sender: { _, _, _, _ in
            sent += 1
            if !reachable { throw GoalongSiteSubmissionError.unreachable }
            return Data()
        }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 1); XCTAssertTrue(sender.enabled); XCTAssertNil(sender.savedConfiguration?.lastAttempt)
        XCTAssertTrue(sender.status.contains("Nouvel essai dans 5 min"), sender.status)
        await sender.tick(now: date.addingTimeInterval(60)); XCTAssertEqual(sent, 1, "No retry before the delay")
        await sender.tick(now: date.addingTimeInterval(5 * 60)); XCTAssertEqual(sent, 2)
        reachable = true
        await sender.tick(now: date.addingTimeInterval(5 * 60 + 15 * 60)); XCTAssertEqual(sent, 3)
        XCTAssertEqual(sender.lastSuccess, "2026-09-10"); XCTAssertTrue(sender.enabled)
        // Next day: the site stays unreachable for five tries, then the plan pauses with its cause.
        reachable = false
        var now = date.addingTimeInterval(86400)
        for delay in GoalongWebsiteAutoSender.networkRetryDelays { await sender.tick(now: now); now.addTimeInterval(delay) }
        XCTAssertTrue(sender.enabled)
        await sender.tick(now: now)
        XCTAssertEqual(sent, 8); XCTAssertFalse(sender.enabled)
        XCTAssertEqual(sender.pauseReason, GoalongWebsiteAutoSender.unreachableReason)
    }

    @MainActor func testRefusedAccessPausesWithItsCauseAndIsRemembered() async throws {
        let root = hermeticDataRoot()
        let token = root.appendingPathComponent("refused.token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let fingerprint = SHA256Digest.hashHex(Data("synthetic-upload-token-for-test".utf8))
        let (defaults, suite) = try scheduledDefaults("refused", root: root) { $0.tokenPath = token.path; $0.credentialFingerprint = fingerprint }
        defer { defaults.removePersistentDomain(forName: suite) }
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in Data() }, sender: { _, _, _, _ in
            throw GoalongSiteSubmissionError.accessRefused
        }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        XCTAssertFalse(GoalongWebsiteAutoSender.accessWasRefused(tokenPath: token.path, defaults: defaults))
        // The account card listens for this notice to show « Accès refusé par le site » at once.
        let notice = expectation(forNotification: .goalongWebsiteAccessRefused, object: nil)
        await sender.tick(now: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!)
        await fulfillment(of: [notice], timeout: 1)
        XCTAssertFalse(sender.enabled)
        XCTAssertEqual(sender.pauseReason, GoalongWebsiteAutoSender.accessRefusedReason)
        XCTAssertTrue(GoalongWebsiteAutoSender.accessWasRefused(tokenPath: token.path, defaults: defaults))
        // Pairing the same account again binds the plan to the new access, keeps it, and waits for a review.
        sender.rebind(tokenPath: "/new.token", credentialFingerprint: "new")
        XCTAssertFalse(GoalongWebsiteAutoSender.accessWasRefused(tokenPath: token.path, defaults: defaults))
        XCTAssertEqual(sender.savedConfiguration?.tokenPath, "/new.token")
        XCTAssertEqual(sender.savedConfiguration?.credentialFingerprint, "new")
        XCTAssertEqual(sender.savedConfiguration?.options.deviceIDs, ["mac"])
        XCTAssertFalse(sender.enabled); XCTAssertEqual(sender.pauseReason, GoalongWebsiteAutoSender.reboundReason)
    }

    @MainActor func testGlobalPauseDuringExportKeepsThePlanAndSendsAfterThePause() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduledDefaults("pause", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent = 0, pauseDuringExport = true
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { root, _, _ in
            if pauseDuringExport { try GoalongGlobalPause.setPaused(true, in: root) }
            return Data()
        }, sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        await sender.tick(now: date)
        XCTAssertEqual(sent, 0); XCTAssertTrue(sender.enabled); XCTAssertNil(sender.pauseReason)
        XCTAssertNil(sender.savedConfiguration?.lastAttempt)
        pauseDuringExport = false
        try GoalongGlobalPause.setPaused(false, in: root)
        await sender.tick(now: date.addingTimeInterval(60))
        XCTAssertEqual(sent, 1); XCTAssertEqual(sender.lastSuccess, "2026-09-10")
    }

    @MainActor func testExclusionsChangedWhileClosedPauseWithAPersistentReason() throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduledDefaults("exclusions", root: root) { $0.privacyRevision = "an-older-revision" }
        defer { defaults.removePersistentDomain(forName: suite) }
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, sharingRulesReadable: { true })
        XCTAssertFalse(sender.enabled)
        XCTAssertEqual(sender.pauseReason, GoalongWebsiteAutoSender.exclusionsChangedReason)
        XCTAssertEqual(sender.savedConfiguration?.paused, true)
        let restarted = GoalongWebsiteAutoSender(defaults: defaults, root: root, sharingRulesReadable: { true })
        XCTAssertEqual(restarted.pauseReason, GoalongWebsiteAutoSender.exclusionsChangedReason)
    }

    @MainActor func testUnreadableSharingRulesStopThePlanBeforeAnyExport() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduledDefaults("rules", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in XCTFail("No export with unreadable rules"); return Data() },
            sender: { _, _, _, _ in XCTFail("No send"); return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { false })
        await sender.tick(now: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!)
        XCTAssertFalse(sender.enabled)
        XCTAssertEqual(sender.pauseReason, GoalongWebsiteAutoSender.sharingRulesUnreadableReason)
    }

    func testDamagedSharingRulesHideEverythingAndAreKeptAsideBeforeARewrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-rules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sharing-rules.json")
        let missing = SharingRulesStore(fileURL: file)
        XCTAssertFalse(missing.isDamaged)
        XCTAssertFalse(missing.hiddenWebsiteFilter()("example.org"))
        let damagedBytes = Data(#"{"schemaVersion":1,"defaultVisibility":"categoryOnly","rules":{"site:secret.example":"newerValue"}}"#.utf8)
        try damagedBytes.write(to: file)
        // B03-R2-01: a write that fails (full disk) keeps the damaged file in place: the next launch still hides everything.
        let fullDisk = SharingRulesStore(fileURL: file, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try fullDisk.set(.identity, for: "site:allowed.example"))
        XCTAssertTrue(fullDisk.isDamaged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["sharing-rules.json"])
        XCTAssertEqual(try Data(contentsOf: file), damagedBytes)
        XCTAssertEqual(SharingRulesStore(fileURL: file).defaultVisibility, .hidden)
        let damaged = SharingRulesStore(fileURL: file)
        XCTAssertTrue(damaged.isDamaged)
        XCTAssertTrue(damaged.hiddenWebsiteFilter()("example.org"))
        XCTAssertTrue(damaged.hiddenApplicationFilter()("com.example.app", "Example"))
        // Signed shares and the screen read `rules` and `defaultVisibility` directly: they must stay private too.
        XCTAssertEqual(damaged.defaultVisibility, .hidden)
        XCTAssertEqual(damaged.rules, [:])
        XCTAssertEqual(damaged.visibility(for: "app:com.example.app"), .hidden)
        try damaged.set(.identity, for: "site:allowed.example")
        XCTAssertFalse(damaged.isDamaged)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("sharing-rules.damaged-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(kept[0])), damagedBytes)
        let rewritten = SharingRulesStore(fileURL: file)
        XCTAssertEqual(rewritten.rules, ["site:allowed.example": .identity])
        // The rewrite starts from a hidden default, so former hidden rules do not turn into « Catégorie seulement ».
        XCTAssertEqual(rewritten.defaultVisibility, .hidden)
    }

    @MainActor func testOverviewNeverShowsAPausedPlanAsOnDemand() {
        XCTAssertEqual(GoalongDataStatus.websiteStatus(enabled: true, hasPlan: true, pauseReason: nil), "Chaque jour")
        XCTAssertEqual(GoalongDataStatus.websiteStatus(enabled: false, hasPlan: true, pauseReason: "Réseau"), "À reprendre")
        XCTAssertEqual(GoalongDataStatus.websiteStatus(enabled: false, hasPlan: true, pauseReason: nil), "En pause")
        XCTAssertEqual(GoalongDataStatus.websiteStatus(enabled: false, hasPlan: false, pauseReason: nil), "À la demande")
    }
}
#endif
