#if os(macOS)
import XCTest
import Foundation
import LocalHistoryQueryCLI
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-046 L9 lot 4: the options chosen in the website sharing card reach the export unchanged,
/// except that hidden websites never leave.
final class T046UnitSiteSharingTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t046-site-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func exported(_ options: GoalongSiteExportOptions, hidden: Set<String> = []) throws -> GoalongSiteExportOptions {
        var seen: GoalongSiteExportOptions?
        _ = try GoalongWebsiteConnectionSheet.reviewedExport(root: try tempRoot(), day: "2026-09-14", options: options,
            isHidden: { hidden.contains($0) }, export: { _, _, o in seen = o; return Data() })
        return try XCTUnwrap(seen)
    }

    func testToggleFlagsAndTextFieldsReachTheExport() throws {
        var options = GoalongSiteExportOptions(includeApplications: true, includeHourly: true, includeRecap: true, structuredReport: true)
        options.maskedApplications = ["Notes", "Mail"]
        options.rhythmProject = "Projet A"
        options.rhythmApplications = ["Xcode"]
        options.includeRhythmTimeline = true
        options.includeRhythmTimes = true
        let out = try exported(options)
        XCTAssertTrue(out.includeApplications && out.includeHourly && out.includeRecap && out.structuredReport)
        XCTAssertFalse(out.includeWebsites)
        XCTAssertEqual(out.maskedApplications, ["Notes", "Mail"])
        XCTAssertEqual(out.rhythmProject, "Projet A")
        XCTAssertEqual(out.rhythmApplications, ["Xcode"])
        XCTAssertTrue(out.includeRhythmTimeline && out.includeRhythmTimes)
    }

    func testHiddenWebsitesAreRemovedFromTheSelection() throws {
        var options = GoalongSiteExportOptions(includeWebsites: true)
        options.selectedWebsiteDomains = ["a.example", "secret.example"]
        let out = try exported(options, hidden: ["secret.example"])
        XCTAssertEqual(out.selectedWebsiteDomains, ["a.example"])
    }

    func testDeviceSelectionIsKept() throws {
        let out = try exported(GoalongSiteExportOptions(deviceIDs: ["mac-1"], includeApplications: true))
        XCTAssertEqual(out.deviceIDs, ["mac-1"])
    }

    @MainActor func testDisconnectMessageDependsOnWhoOwnsTheTokenFile() {
        let chosen = GoalongWebsiteConnectionCard.disconnectMessage(tokenPath: "/Users/x/Downloads/goalong-token.txt")
        XCTAssertTrue(chosen.contains("restera à sa place"))
        XCTAssertTrue(GoalongWebsiteConnectionCard.disconnectMessage(tokenPath: "").contains("restera à sa place"))
    }
}
#endif
