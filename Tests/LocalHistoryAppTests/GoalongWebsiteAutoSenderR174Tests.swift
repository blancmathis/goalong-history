#if os(macOS)
import XCTest
import Foundation
import Darwin
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

/// Review of PR #174: the real send marks the request as started, a pause during a step keeps its
/// own text, the skipped days stay named after a global pause, and local texts do not repeat themselves.
final class GoalongWebsiteAutoSenderR174Tests: XCTestCase {
    @MainActor private func scheduled(_ name: String, root: URL, configure: (inout GoalongWebsiteAutoSender.Configuration) -> Void = { _ in }) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-r174-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "America/Chicago")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configuration.lastAttempt = "2026-09-11"; configuration.lastSuccess = "2026-09-11"
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        return (defaults, suite)
    }
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!

    /// A loopback server that answers one request with HTTP 409. Returns its port.
    private func conflictServer() throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) == 0 && Darwin.listen(listener, 1) == 0 && Darwin.getsockname(listener, $0, &length) == 0 }
        }
        guard bound else { close(listener); throw XCTSkip("No loopback socket") }
        Thread.detachNewThread {
            let client = accept(listener, nil, nil)
            defer { close(listener) }
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            _ = recv(client, &buffer, buffer.count, 0)
            let response = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            _ = response.withCString { Darwin.send(client, $0, strlen($0), 0) }
            shutdown(client, SHUT_RDWR); close(client)
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// The request left this Mac and the site answered with an error: the receipt is uncertain.
    /// The day is never retried by itself and the user is sent to the site history.
    @MainActor func testRealSendThatReachedTheSiteStaysUncertain() async throws {
        let root = hermeticDataRoot()
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let port = try conflictServer()
        let (defaults, suite) = try scheduled("reached", root: root) {
            $0.origin = "http://127.0.0.1:\(port)"; $0.tokenPath = token.path
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        XCTAssertFalse(scheduler.enabled)
        let reason = try XCTUnwrap(scheduler.pauseReason)
        XCTAssertTrue(reason.contains("historique du site"), reason)
        XCTAssertFalse(reason.contains("Rien n’a été envoyé"), reason)
        XCTAssertEqual(scheduler.savedConfiguration?.lastAttempt, "2026-09-12", "A day that may be received is never sent again by itself")
    }

    /// The user pauses while the day is being read and the day has no record: the plan stays paused
    /// and the text never says the daily send continues.
    @MainActor func testPauseDuringAMissingDayKeepsThePauseText() async throws {
        let root = hermeticDataRoot()
        XCTAssertTrue(GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json")).set(.appleScreenTime, enabled: true, surface: .settings))
        let (defaults, suite) = try scheduled("missing-pause", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        var scheduler: GoalongWebsiteAutoSender!
        scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { root, day, options in
            DispatchQueue.main.sync { MainActor.assumeIsolated { scheduler.stop() } }
            return try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options)
        }, sender: { _, _, _, _ in XCTFail("Nothing to send"); return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        XCTAssertFalse(scheduler.enabled)
        XCTAssertFalse(scheduler.status.contains("continue"), scheduler.status)
        XCTAssertTrue(scheduler.status.contains("pause"), scheduler.status)
    }

    /// The user pauses while the site cannot be reached: no "new try in 5 min" on a paused plan.
    @MainActor func testPauseDuringAnUnreachableSendKeepsThePauseText() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled("unreachable-pause", root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        var scheduler: GoalongWebsiteAutoSender!
        scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) }, sender: { _, _, _, _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { scheduler.stop() } }
            throw GoalongSiteSubmissionError.unreachable
        }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        XCTAssertFalse(scheduler.enabled)
        XCTAssertFalse(scheduler.status.contains("Nouvel essai"), scheduler.status)
        XCTAssertEqual(scheduler.savedConfiguration?.lastAttempt, "2026-09-11", "Nothing left this Mac: the day stays to send")
    }

    /// Skipped days stay named once a global pause ends, as after a restart.
    @MainActor func testSkippedDaysStayNamedAfterAGlobalPause() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled("global-pause", root: root) { $0.lastAttempt = "2026-09-12"; $0.missingDay = "2026-09-12" }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in XCTFail("Nothing to send"); return Data() },
            sourceConsent: { _ in true }, sharingRulesReadable: { true })
        let day = GoalongUIFormat.day(key: "2026-09-12")
        XCTAssertTrue(scheduler.status.contains(day), scheduler.status)
        try GoalongGlobalPause.setPaused(true, in: root)
        await scheduler.tick(now: now)
        try GoalongGlobalPause.setPaused(false, in: root)
        await scheduler.tick(now: now.addingTimeInterval(60))
        XCTAssertTrue(scheduler.status.hasPrefix("Activée"), scheduler.status)
        XCTAssertTrue(scheduler.status.contains(day), scheduler.status)
    }

    /// The account changed: the text says once that nothing was sent.
    @MainActor func testAccountChangeSaysNothingWasSentOnce() async throws {
        let root = hermeticDataRoot()
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let (defaults, suite) = try scheduled("account", root: root) { $0.tokenPath = token.path; $0.credentialFingerprint = "another-account" }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        let reason = try XCTUnwrap(scheduler.pauseReason)
        XCTAssertTrue(reason.contains("L’accès au compte a changé"), reason)
        XCTAssertTrue(reason.contains("Rien n’a été envoyé"), reason)
        XCTAssertFalse(reason.contains("Aucun envoi n’a été effectué"), reason)
        XCTAssertEqual(scheduler.savedConfiguration?.lastAttempt, "2026-09-11")
    }
}
#endif
