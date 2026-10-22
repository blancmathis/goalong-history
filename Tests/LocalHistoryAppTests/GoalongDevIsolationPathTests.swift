@testable import LocalHistoryApp
import LocalHistoryCore
import XCTest

final class GoalongDevIsolationPathTests: XCTestCase {
    func testReleasePathsAndIdentityAreUnchanged() {
        let real = GoalongBuildChannel.realDataRoot
        XCTAssertEqual(AppPaths.applicationSupportDirectory, real)
        XCTAssertEqual(ActivityAnalysisPaths.applicationSupportDirectory, real)
        XCTAssertEqual(BlockingStore.standard.directory, real.appendingPathComponent("Blocking", isDirectory: true))
        XCTAssertEqual(FocusStore.standard.directory, real.appendingPathComponent("Focus"))
        XCTAssertEqual(ProductIdentity.windowTitle("Signaler un problème"), "Signaler un problème")
        XCTAssertEqual(ProductIdentity.mainWindowTitle, ProductIdentity.displayName)
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "ai.goalong.localhistory")
        XCTAssertEqual(PermissionRepair.bundleIdentifier, "ai.goalong.localhistory")
        XCTAssertEqual(GoalongDevChannelMarks.autosaveName("goalong-menu"), "goalong-menu")
        XCTAssertTrue(GoalongLoginItemGate.isAllowed)
    }

    /// Blocking and Focus follow the data root: in Goalong Dev they live under LocalHistory-Dev,
    /// never in the installed Goalong's real stakes (spec A §4).
    func testBlockingAndFocusFollowTheChannelDataRoot() throws {
        let source = try String(contentsOf: Self.sourceRoot.appendingPathComponent("Sources/LocalHistoryApp/AppPaths.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("realApplicationSupportDirectory"))
        for file in ["Blocking/BlockingStore.swift", "Concentration/ConcentrationStore.swift"] {
            let text = try String(contentsOf: Self.sourceRoot.appendingPathComponent("Sources/LocalHistoryApp/" + file), encoding: .utf8)
            XCTAssertTrue(text.contains("AppPaths.applicationSupportDirectory.appendingPathComponent"), file)
            XCTAssertFalse(text.contains("realDataRoot"), file)
        }
    }

    func testGoalongDevSkipsLoginItemChanges() {
        let dev = GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"])
        var calls = 0
        XCTAssertFalse(GoalongLoginItemGate.perform(channel: dev) { calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(GoalongLoginItemGate.perform(channel: GoalongBuildChannel(info: nil)) { calls += 1 })
        XCTAssertEqual(calls, 1)
    }

    func testNoGoalongCopyBlocksOrRecordsTheOther() {
        XCTAssertTrue(BlockingRules.neverBlocked.contains("ai.goalong.localhistory"))
        XCTAssertTrue(BlockingRules.neverBlocked.contains("ai.goalong.localhistory.dev"))
        XCTAssertTrue(ProductIdentity.isGoalong("ai.goalong.localhistory.dev"))
        XCTAssertTrue(ProductIdentity.isGoalong("ai.goalong.localhistory"))
        XCTAssertFalse(ProductIdentity.isGoalong("com.apple.Safari"))
    }

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
