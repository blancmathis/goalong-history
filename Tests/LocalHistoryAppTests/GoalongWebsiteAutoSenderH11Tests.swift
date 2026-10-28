#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-045 H11: a day without a saved record, a pause during preparation and local errors.
final class GoalongWebsiteAutoSenderH11Tests: XCTestCase {
    @MainActor private func scheduled(_ name: String, root: URL, configure: (inout GoalongWebsiteAutoSender.Configuration) -> Void = { _ in }) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-h11-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "America/Chicago")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        return (defaults, suite)
    }

    /// D-AS1: the real exporter finds no saved Screen Time record (Mac off that day). The plan stays
    /// active, nothing is sent for that day (no invented zero), the user reads which day, and later days go.
    @MainActor func testDayWithoutSavedRecordIsSkippedAndThePlanContinues() async throws {
        let root = hermeticDataRoot()
        XCTAssertTrue(GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json")).set(.appleScreenTime, enabled: true, surface: .settings))
        let (defaults, suite) = try scheduled("missing", root: root) { $0.lastAttempt = "2026-09-10"; $0.lastSuccess = "2026-09-10" }
        defer { defaults.removePersistentDomain(forName: suite) }
        var payloadDays: [String] = [], sentDays: [String] = []
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { root, day, options in
            if day == "2026-09-11" { return try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options) }
            payloadDays.append(day); return Data(day.utf8)
        }, sender: { payload, _, _, _ in sentDays.append(String(decoding: payload, as: UTF8.self)); return Data() },
           sourceConsent: { _ in true }, sharingRulesReadable: { true })
        let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!
        await scheduler.tick(now: now)
        XCTAssertTrue(scheduler.enabled, scheduler.status); XCTAssertNil(scheduler.pauseReason)
        XCTAssertTrue(sentDays.isEmpty, "Nothing is invented for a day without a record")
        XCTAssertTrue(scheduler.status.contains(GoalongUIFormat.day(key: "2026-09-11")), scheduler.status)
        XCTAssertTrue(scheduler.status.contains("Aucun relevé"), scheduler.status)
        XCTAssertFalse(scheduler.status.contains("historique du site"), scheduler.status)
        await scheduler.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(sentDays, ["2026-09-12"]); XCTAssertEqual(scheduler.lastSuccess, "2026-09-12")
        XCTAssertTrue(scheduler.status.contains(GoalongUIFormat.day(key: "2026-09-11")), "The skipped day stays named: \(scheduler.status)")
        await scheduler.tick(now: now.addingTimeInterval(120))
        XCTAssertEqual(sentDays, ["2026-09-12"], "The skipped day is not retried")
    }

    /// The skipped day stays named after a restart, until the next received day names it.
    @MainActor func testSkippedDayNoticeSurvivesARestart() async throws {
        let root = hermeticDataRoot()
        XCTAssertTrue(GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json")).set(.appleScreenTime, enabled: true, surface: .settings))
        let (defaults, suite) = try scheduled("restart", root: root) { $0.lastAttempt = "2026-09-10"; $0.lastSuccess = "2026-09-10" }
        defer { defaults.removePersistentDomain(forName: suite) }
        var sentDays: [String] = []
        func make() -> GoalongWebsiteAutoSender {
            GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { root, day, options in
                if day == "2026-09-11" { return try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options) }
                return Data(day.utf8)
            }, sender: { payload, _, _, _ in sentDays.append(String(decoding: payload, as: UTF8.self)); return Data() },
               sourceConsent: { _ in true }, sharingRulesReadable: { true })
        }
        let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!
        await make().tick(now: now)
        let restarted = make()
        XCTAssertTrue(restarted.enabled, restarted.status)
        XCTAssertTrue(restarted.status.contains("Aucun relevé"), restarted.status)
        XCTAssertTrue(restarted.status.contains(GoalongUIFormat.day(key: "2026-09-11")), restarted.status)
        await restarted.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(sentDays, ["2026-09-12"])
        XCTAssertTrue(restarted.status.contains(GoalongUIFormat.day(key: "2026-09-11")), restarted.status)
        let again = make()
        XCTAssertFalse(again.status.contains("Aucun relevé"), "Named once with the next received day: \(again.status)")
    }

    /// D-AS2: the user pauses while the day is being prepared. The day is not marked as tried,
    /// so it goes once the plan runs again.
    @MainActor func testPauseDuringPreparationKeepsTheDayToSendLater() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled("pause", root: root) { $0.lastAttempt = "2026-09-11"; $0.lastSuccess = "2026-09-11" }
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent = 0
        var scheduler: GoalongWebsiteAutoSender!
        scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { scheduler.stop() } }
            return Data()
        }, sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!)
        XCTAssertEqual(sent, 0); XCTAssertFalse(scheduler.enabled)
        XCTAssertEqual(scheduler.savedConfiguration?.lastAttempt, "2026-09-11", "The interrupted day is not marked as tried")
    }

    /// D-AS3: a local error (nothing left this Mac) never sends the user to the site history.
    @MainActor func testLocalErrorSaysNothingWasSentWhileAnUncertainSendPointsToTheSite() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled("local", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in
            throw GoalongSiteExportError.invalid("La sélection dépasse 2 Mio.")
        }, sender: { _, _, _, _ in XCTFail("Nothing to send"); return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!
        await local.tick(now: now)
        XCTAssertFalse(local.enabled)
        let reason = try XCTUnwrap(local.pauseReason)
        XCTAssertFalse(reason.contains("historique du site"), reason)
        XCTAssertTrue(reason.contains("Rien n’a été envoyé"), reason)
        XCTAssertTrue(reason.contains("2 Mio"), reason)
        XCTAssertNil(local.savedConfiguration?.lastAttempt, "Nothing left this Mac: the day is not marked as tried")

        let root2 = hermeticDataRoot()
        let (defaults2, suite2) = try scheduled("uncertain", root: root2)
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let uncertain = GoalongWebsiteAutoSender(defaults: defaults2, root: root2, exporter: { _, _, _ in Data() },
            sender: { _, _, _, _ in throw GoalongSiteExportError.invalid("Receipt unknown") }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await uncertain.tick(now: now)
        XCTAssertFalse(uncertain.enabled)
        XCTAssertTrue(try XCTUnwrap(uncertain.pauseReason).contains("historique du site"))
    }
}
#endif
