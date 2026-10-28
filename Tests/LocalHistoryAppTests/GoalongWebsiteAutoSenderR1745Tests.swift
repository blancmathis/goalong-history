#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

/// Review R174-5: Goalong quits or crashes while it prepares or sends a day. At the next launch the
/// day is sent again (within the catch-up window, and only when the plan and the sources still allow it).
final class GoalongWebsiteAutoSenderR1745Tests: XCTestCase {
    private let key = "goalong.website.autoSend.v1"
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!

    @MainActor private func scheduled(_ name: String, root: URL) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-r1745-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "America/Chicago")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configuration.lastAttempt = "2026-09-11"; configuration.lastSuccess = "2026-09-11"
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
        return (defaults, suite)
    }

    /// Runs one tick and copies what was saved at the moment of the send: this is what a crash leaves.
    @MainActor private func savedAtCrash(_ name: String, root: URL, duringExport: Bool) async throws -> Data {
        let (defaults, suite) = try scheduled(name, root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved: Data?
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root,
            exporter: { _, day, _ in if duringExport { saved = defaults.data(forKey: self.key) }; return Data(day.utf8) },
            sender: { payload, _, _, _ in if !duringExport { saved = defaults.data(forKey: self.key) }; return payload },
            sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        return try XCTUnwrap(saved)
    }

    @MainActor private func relaunch(_ name: String, root: URL, saved: Data, consent: Bool = true) async -> (GoalongWebsiteAutoSender, [String], UserDefaults, String) {
        let suite = "goalong-auto-r1745-\(name)-relaunch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(saved, forKey: key)
        var sent: [String] = []
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sender: { payload, _, _, _ in sent.append(String(decoding: payload, as: UTF8.self)); return payload },
            sourceConsent: { _ in consent }, sharingRulesReadable: { true })
        await scheduler.tick(now: now.addingTimeInterval(600))
        return (scheduler, sent, defaults, suite)
    }

    @MainActor func testCrashDuringTheSendResendsTheDayAtNextLaunch() async throws {
        let root = hermeticDataRoot()
        let saved = try await savedAtCrash("send", root: root, duringExport: false)
        let (scheduler, sent, defaults, suite) = await relaunch("send", root: root, saved: saved)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(sent, ["2026-09-12"], "The interrupted day is sent again, never lost")
        XCTAssertEqual(scheduler.savedConfiguration?.lastSuccess, "2026-09-12")
        XCTAssertTrue(scheduler.enabled)
    }

    @MainActor func testCrashDuringThePreparationResendsTheDayAtNextLaunch() async throws {
        let root = hermeticDataRoot()
        let saved = try await savedAtCrash("export", root: root, duringExport: true)
        let (scheduler, sent, defaults, suite) = await relaunch("export", root: root, saved: saved)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(sent, ["2026-09-12"])
        XCTAssertEqual(scheduler.savedConfiguration?.lastSuccess, "2026-09-12")
    }

    @MainActor func testInterruptedDayIsNotResentWhenASourceWasTurnedOff() async throws {
        let root = hermeticDataRoot()
        let saved = try await savedAtCrash("consent", root: root, duringExport: false)
        let (scheduler, sent, defaults, suite) = await relaunch("consent", root: root, saved: saved, consent: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(sent, [])
        XCTAssertFalse(scheduler.enabled)
    }

    @MainActor func testAHandledSendLeavesNoInterruptionBehind() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled("handled", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sender: { payload, _, _, _ in payload }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        let (_, sent, relaunched, relaunchSuite) = await relaunch("handled", root: root, saved: try XCTUnwrap(defaults.data(forKey: key)))
        defer { relaunched.removePersistentDomain(forName: relaunchSuite) }
        XCTAssertEqual(sent, [], "A day already received is not sent twice by a normal restart")
    }
}
#endif
