#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongWebsiteFixRound2Tests: XCTestCase {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-r2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testReviewedExportBindsPayloadToExclusionsAndFailsClosed() throws {
        let root = try tempRoot()
        var policy = GoalongPrivacyPolicy()
        policy.domains = ["example.com"]
        try policy.save(in: root)
        let reviewed = try GoalongWebsiteConnectionSheet.reviewedExport(root: root, day: "2026-09-14", options: .init(),
            export: { _, _, _ in Data("ok".utf8) })
        XCTAssertEqual(reviewed.payload, Data("ok".utf8))
        XCTAssertEqual(reviewed.privacyRevision, policy.revision)

        XCTAssertThrowsError(try GoalongWebsiteConnectionSheet.reviewedExport(root: root, day: "2026-09-14", options: .init(),
            export: { root, _, _ in
                var changed = GoalongPrivacyPolicy(); changed.domains = ["other.example"]
                try changed.save(in: root); return Data("late".utf8)
            }))

        var blocked = GoalongPrivacyPolicy(); blocked.blocked = true
        try blocked.save(in: root)
        XCTAssertThrowsError(try GoalongWebsiteConnectionSheet.reviewedExport(root: root, day: "2026-09-14", options: .init(),
            export: { _, _, _ in XCTFail("A blocked policy must not export"); return Data() }))
    }

    @MainActor func testPauseEndRestoresActiveStatusEvenWhenNothingIsDue() async throws {
        let suite = "goalong-r2-pause-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = try tempRoot()
        let token = root.appendingPathComponent("token")
        try Data("synthetic-upload-token-for-test".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        var sent = 0
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, exporter: { _, _, _ in Data() },
            sender: { _, _, _, _ in sent += 1; return Data() }, sourceConsent: { _ in true })
        addTeardownBlock { @MainActor in sender.forget() }
        try sender.enable(origin: "https://goalong.example", tokenPath: token.path, options: .init(deviceIDs: ["mac"]), hour: 15)
        let early = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 14))!
        try GoalongGlobalPause.setPaused(true, in: root)
        await sender.tick(now: early)
        XCTAssertTrue(sender.status.hasPrefix("Pause globale"))
        try GoalongGlobalPause.setPaused(false, in: root)
        await sender.tick(now: early)
        XCTAssertTrue(sender.status.hasPrefix("Activée"), sender.status)
        XCTAssertEqual(sent, 0)
    }

    func testParentDomainExclusionIsDetectedButExactHostIsNot() {
        XCTAssertEqual(DashboardViewModel.excludingParentDomain(for: "mail.google.com", excluded: ["google.com"]), "google.com")
        XCTAssertNil(DashboardViewModel.excludingParentDomain(for: "mail.google.com", excluded: ["mail.google.com"]))
        XCTAssertNil(DashboardViewModel.excludingParentDomain(for: "mail.google.com", excluded: ["example.org"]))
    }
}
#endif
