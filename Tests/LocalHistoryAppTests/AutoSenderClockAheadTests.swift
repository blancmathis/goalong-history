#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-05): a date set ahead for a minute tries a day without a record; once the clock is back, that
/// attempt must not skip the real days.
final class AutoSenderClockAheadTests: XCTestCase {
    @MainActor func testAttemptMadeWhileClockAheadDoesNotSkipRealDays() async throws {
        let root = hermeticDataRoot()
        XCTAssertTrue(GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json")).set(.appleScreenTime, enabled: true, surface: .settings))
        let suite = "goalong-auto-f2-ahead-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "Europe/Paris")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configuration.lastAttempt = "2026-11-26"; configuration.lastSuccess = "2026-11-26"
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        var sentDays: [String] = []
        func make() -> GoalongWebsiteAutoSender {
            GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { root, day, options in
                // Days after the real today have no record: the real exporter says so.
                if day > "2026-11-27" { return try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options) }
                return Data(day.utf8)
            }, sender: { payload, _, _, _ in sentDays.append(String(decoding: payload, as: UTF8.self)); return Data() },
               sourceConsent: { _ in true }, sharingRulesReadable: { true })
        }
        let iso = ISO8601DateFormatter()
        await make().tick(now: iso.date(from: "2026-12-04T08:01:00Z")!)   // 09:01 Paris, clock ahead
        XCTAssertTrue(sentDays.isEmpty, "nothing is sent for a day without a record")
        let back = make()                                                 // relaunch, clock back
        await back.tick(now: iso.date(from: "2026-11-27T08:01:10Z")!)
        XCTAssertTrue(sentDays.isEmpty, "26/11 was already sent")
        XCTAssertTrue(back.enabled, back.status)
        await make().tick(now: iso.date(from: "2026-11-28T08:01:00Z")!)
        XCTAssertEqual(sentDays, ["2026-11-27"], "the real day 27/11 still goes")
        await make().tick(now: iso.date(from: "2026-11-28T08:05:00Z")!)
        XCTAssertEqual(sentDays, ["2026-11-27"], "a received day is never sent twice")
    }
}
#endif
