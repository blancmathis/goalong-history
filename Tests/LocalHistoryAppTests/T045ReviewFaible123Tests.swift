#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// Review of 6a4ab69, findings Faible 1 to 3. No test shows a window or takes the focus.
final class T045ReviewFaible123Tests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!
    @MainActor private func scheduled(root: URL, configure: (inout GoalongWebsiteAutoSender.Configuration) -> Void = { _ in }) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-faible-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "America/Chicago")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configuration.lastAttempt = "2026-09-11"; configuration.lastSuccess = "2026-09-11"
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        return (defaults, suite)
    }

    /// F1: the site has the day, the local record fails. The text must not say nothing was sent, and no resend loop.
    @MainActor func testLocalStoreFailureAfterASuccessfulSendIsNotReportedAsNothingSent() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled(root: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        struct Disk: Error {}
        var sends = 0
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sender: { _, _, _, _ in sends += 1; return Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true },
            beforeStore: { if $0.lastSuccess != "2026-09-11" { throw Disk() } })
        await scheduler.tick(now: now)
        XCTAssertEqual(sends, 1)
        XCTAssertFalse(scheduler.status.contains("Rien n’a été envoyé"), scheduler.status)
        XCTAssertTrue(scheduler.status.contains("reçue par le site"), scheduler.status)
        await scheduler.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(sends, 1, "No resend by itself")
    }

    /// F2: many skipped days give a short text.
    @MainActor func testManySkippedDaysGiveAShortText() throws {
        let root = hermeticDataRoot()
        let days = (10...25).map { "2026-08-\($0)" }.joined(separator: ",")
        let (defaults, suite) = try scheduled(root: root) { $0.missingDay = days }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        XCTAssertLessThan(scheduler.status.count, 400, scheduler.status)
        XCTAssertTrue(scheduler.status.contains("…"), scheduler.status)
        XCTAssertTrue(scheduler.status.contains(GoalongUIFormat.day(key: "2026-08-12")), scheduler.status)
        XCTAssertFalse(scheduler.status.contains(GoalongUIFormat.day(key: "2026-08-13")), scheduler.status)
    }

    /// F3: exit 4 of --unregister-guard is told by each script, and the script goes on.
    func testScriptsWarnWhenTheGuardIsStillRegistered() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["install.sh", "uninstall.sh", "scripts/install_from_source.sh"] {
            let text = try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "release_blocking_guard() {"), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex), name)
            // No real launchctl call from a test.
            let function = String(text[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true")
            let app = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-guard-\(UUID()).app")
            let exe = app.appendingPathComponent("Contents/MacOS/Fake")
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: app) }
            try "#!/bin/bash\n# --unregister-guard\nexit 4\n".write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let process = Process(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "set -euo pipefail; EXECUTABLE_NAME=Fake; BUNDLE_ID=test.invalid; \(function)\nrelease_blocking_guard \"$1\"; echo done", "x", app.path]
            process.standardError = err; process.standardOutput = Pipe()
            try process.run(); process.waitUntilExit()
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "\(name): the script goes on")
            XCTAssertTrue(message.contains("still registered"), "\(name): \(message)")
        }
    }
}
#endif
