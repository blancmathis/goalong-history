#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
@testable import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// Follow-up S3, S4 and S6 of T-045. No test shows a window or takes the focus.
final class T045SuiviS3S4S6Tests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T15:00:00Z")!
    private func scheduled(root: URL, configure: (inout GoalongWebsiteAutoSender.Configuration) -> Void) throws -> (UserDefaults, String) {
        let suite = "goalong-auto-suivi-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = GoalongWebsiteAutoSender.Configuration(origin: "https://goalong.example", tokenPath: "/synthetic", options: .init(deviceIDs: ["mac"]),
            hour: 9, minute: 0, timeZoneIdentifier: "America/Chicago")
        configuration.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        configuration.lastAttempt = "2026-09-11"; configuration.lastSuccess = "2026-09-11"
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "goalong.website.autoSend.v1")
        return (defaults, suite)
    }
    private func saved(_ defaults: UserDefaults) throws -> GoalongWebsiteAutoSender.Configuration {
        try JSONDecoder().decode(GoalongWebsiteAutoSender.Configuration.self, from: try XCTUnwrap(defaults.data(forKey: "goalong.website.autoSend.v1")))
    }

    /// S3: past 30 missed days, the three named days stay the real first ones.
    @MainActor func testLongAbsenceKeepsTheRealFirstThreeDays() async throws {
        let root = hermeticDataRoot()
        let old = (1...30).map { String(format: "2026-08-%02d", $0) }.joined(separator: ",")
        let (defaults, suite) = try scheduled(root: root) { $0.missingDay = old }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root,
            exporter: { _, _, _ in throw CLIError.unsafeSource(GoalongQueryCLI.missingSavedDayMessage) },
            sender: { _, _, _, _ in Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true })
        await scheduler.tick(now: now)
        let days = try XCTUnwrap(saved(defaults).missingDay).split(separator: ",").map(String.init)
        XCTAssertEqual(Array(days.prefix(3)), ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(days.last, "2026-09-12")
        XCTAssertLessThanOrEqual(days.count, 30)
        XCTAssertTrue(scheduler.status.contains(GoalongUIFormat.day(key: "2026-08-01")), scheduler.status)
        XCTAssertFalse(scheduler.status.contains(GoalongUIFormat.day(key: "2026-08-04")), scheduler.status)
    }

    /// S4: the send works, the local write fails: the skipped-day notice is told now, not only kept for a restart.
    @MainActor func testSkippedDaysAreToldWhenTheLocalWriteFailsAfterASend() async throws {
        let root = hermeticDataRoot()
        let (defaults, suite) = try scheduled(root: root) { $0.missingDay = "2026-09-10" }
        defer { defaults.removePersistentDomain(forName: suite) }
        struct Disk: Error {}
        let scheduler = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, day, _ in Data(day.utf8) },
            sender: { _, _, _, _ in Data() }, sourceConsent: { _ in true }, sharingRulesReadable: { true },
            beforeStore: { if $0.lastSuccess != "2026-09-11" { throw Disk() } })
        await scheduler.tick(now: now)
        XCTAssertTrue(scheduler.status.contains("reçue par le site"), scheduler.status)
        XCTAssertTrue(scheduler.status.contains("Aucun relevé enregistré"), scheduler.status)
    }

    /// S6: every non-zero exit of --unregister-guard except a clean 0 is told by each script, and the script goes on.
    func testScriptsTellAnyFailedGuardExit() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["install.sh", "uninstall.sh", "scripts/install_from_source.sh"] {
            let text = try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "release_blocking_guard() {"), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex), name)
            let function = String(text[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true")
            for (code, expectsWarning) in [(0, false), (1, true), (3, true), (139, true)] {
                let app = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-guard-\(UUID()).app")
                let exe = app.appendingPathComponent("Contents/MacOS/Fake")
                try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: app) }
                try "#!/bin/bash\n# --unregister-guard\nexit \(code)\n".write(to: exe, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
                let process = Process(), err = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", "set -euo pipefail; EXECUTABLE_NAME=Fake; BUNDLE_ID=test.invalid; \(function)\nrelease_blocking_guard \"$1\"; echo done", "x", app.path]
                process.standardError = err; process.standardOutput = Pipe()
                try process.run(); process.waitUntilExit()
                let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, "\(name) exit \(code): the script goes on")
                XCTAssertEqual(!message.isEmpty, expectsWarning, "\(name) exit \(code): \(message)")
            }
        }
    }
}
#endif
