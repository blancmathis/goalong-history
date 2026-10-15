#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class DashboardSettingsAuditTests: XCTestCase {
    func testSubMinuteDurationsNeverBecomeOneMinute() {
        let nbsp = "\u{00A0}"
        XCTAssertEqual(DashboardFormatters.duration(seconds: 0), "0\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 5), "<\(nbsp)1\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 59.9), "<\(nbsp)1\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 60), "1\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 89), "1\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 90), "2\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 3660), "1\(nbsp)h\(nbsp)01")
        XCTAssertEqual(DashboardFormatters.duration(seconds: -1), "0\(nbsp)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: .nan), "0\(nbsp)min")
    }

    func testParentDomainRuleMatchesLikeTheRedactor() {
        XCTAssertEqual(GoalongApplicationsSettings.parentDomainRule(for: "docs.example.fr", in: ["example.fr"]), "example.fr")
        XCTAssertEqual(GoalongApplicationsSettings.parentDomainRule(for: "docs.example.fr", in: ["Example.FR."]), "example.fr")
        XCTAssertNil(GoalongApplicationsSettings.parentDomainRule(for: "notexample.fr", in: ["example.fr"]))
        XCTAssertNil(GoalongApplicationsSettings.parentDomainRule(for: "example.fr", in: ["example.fr"]), "The host's own rule is not a parent")
        XCTAssertNil(GoalongApplicationsSettings.parentDomainRule(for: "example.fr", in: [" ", ""]))
    }

    func testAnExclusionUpdateThatChangesNothingKeepsTheRevision() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("goalong-exclusion-noop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongExclusionStore(root: root)
        XCTAssertTrue(store.update { $0.domains = ["example.fr"] })
        let revision = store.policy.revision, effective = store.policy.effectiveFrom
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .goalongExclusionsDidChange, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(store.update { $0.domains.removeAll { $0 == "docs.example.fr" } })
        XCTAssertEqual(store.policy.revision, revision)
        XCTAssertEqual(store.policy.effectiveFrom, effective)
        XCTAssertEqual(posted, 0)
        XCTAssertTrue(store.update { $0.domains.append("other.fr") })
        XCTAssertNotEqual(store.policy.revision, revision)
        XCTAssertEqual(posted, 1)
    }

    @MainActor func testConcentrationDeleteFailureThenSuccessClearsTheError() throws {
        let parent = URL(fileURLWithPath: "/private/tmp/goalong-delete-\(UUID().uuidString)")
        let directory = parent.appendingPathComponent("Focus")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let runtime = ConcentrationRuntime(storeFactory: { FocusStore(directory: directory) }, presentsPanels: false)
        // A read-only parent makes the removal fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        XCTAssertThrowsError(try runtime.deleteData())
        XCTAssertNotNil(runtime.error)
        XCTAssertFalse(runtime.error?.contains("NSCocoaErrorDomain") ?? true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertNoThrow(try runtime.deleteData())
        XCTAssertNil(runtime.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testConcentrationStartFailureIsFrenchAndClearsOnDisable() {
        let runtime = ConcentrationRuntime(storeFactory: { FocusStore(directory: URL(fileURLWithPath: "/private/tmp/goalong-none-\(UUID().uuidString)")) },
            factory: { _ in throw FocusFailure.storageFailed }, presentsPanels: false)
        runtime.apply(enabled: true)
        XCTAssertNil(runtime.controller)
        XCTAssertEqual(runtime.error, FocusUIError.message(FocusFailure.storageFailed))
        runtime.apply(enabled: false)
        XCTAssertNil(runtime.error)
        XCTAssertNil(runtime.measurementError)
    }

    func testShareBuildErrorsKeepTheirReasonInAlerts() {
        let text = DashboardViewModel.userFacingMessage(ShareBuildError.exclusionsUnreadable)
        XCTAssertTrue(text.contains("Les exclusions sont illisibles"), text)
    }

    func testGlobalPauseResumeWordingDiffersFromRecordingResume() {
        XCTAssertNotEqual(GoalongGlobalPauseText.resume, "Reprendre le suivi")
        XCTAssertEqual(GoalongGlobalPauseText.failureTitle, "Pause non modifiée")
    }

    func testSettingsPointersNameRealPanes() {
        let applications = SettingsPane.applications.title
        XCTAssertTrue(GoalongActivityGaps.help(.excludedApplication)?.contains(applications) ?? false)
        XCTAssertTrue(GoalongActivityGaps.help(.excludedDomain)?.contains(applications) ?? false)
    }
}
#endif
