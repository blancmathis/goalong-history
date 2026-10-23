import AgentActivity
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

    /// Blocking and Focus follow the channel's data root: in Goalong Dev they live under LocalHistory-Dev,
    /// never in the installed Goalong's real stakes (spec A §4). The paths are resolved, not searched in source.
    func testBlockingAndFocusFollowTheChannelDataRoot() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        let dev = GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"])
        let release = GoalongBuildChannel(info: nil)
        XCTAssertEqual(BlockingStore.standard(channel: dev, base: base).directory.path,
                       "/Users/someone/Library/Application Support/LocalHistory-Dev/Blocking")
        XCTAssertEqual(FocusStore.standard(channel: dev, base: base).directory.path,
                       "/Users/someone/Library/Application Support/LocalHistory-Dev/Focus")
        XCTAssertEqual(BlockingStore.standard(channel: release, base: base).directory.path,
                       "/Users/someone/Library/Application Support/LocalHistory/Blocking")
        XCTAssertEqual(FocusStore.standard(channel: release, base: base).directory.path,
                       "/Users/someone/Library/Application Support/LocalHistory/Focus")
        // The stores the app uses are exactly these, for the running channel.
        let actualBase = GoalongBuildChannel.applicationSupportBase
        XCTAssertEqual(BlockingStore.standard.directory, BlockingStore.standard(channel: .current, base: actualBase).directory)
        XCTAssertEqual(FocusStore.standard.directory, FocusStore.standard(channel: .current, base: actualBase).directory)
        XCTAssertEqual(AppPaths.applicationSupportDirectory, GoalongBuildChannel.current.dataRoot(base: actualBase))
    }

    /// Agent hooks sit in the agents' shared configuration files: Goalong Dev neither installs nor removes them.
    func testGoalongDevNeverChangesAgentHooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalongDevHooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try AgentActivityRuntime(
            rootDirectory: root.appendingPathComponent("agent-activity-v2", isDirectory: true),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            performInitialDiscovery: false,
            sourceDiscovery: { [] },
            channel: GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"]),
            onCaptured: { _ in }
        )
        XCTAssertFalse(runtime.allowsHookChanges)
        let before = runtime.integrationStatuses
        for kind in AgentIntegrationKind.allCases {
            runtime.alert = nil
            runtime.installIntegration(kind)
            XCTAssertEqual(runtime.alert?.title, AgentActivityRuntime.devHookChangeRefused.title, kind.rawValue)
            runtime.alert = nil
            runtime.uninstallIntegration(kind)
            XCTAssertEqual(runtime.alert?.title, AgentActivityRuntime.devHookChangeRefused.title, kind.rawValue)
        }
        XCTAssertEqual(runtime.integrationStatuses.map(\.isInstalled), before.map(\.isInstalled))
    }

    /// `--uninstall-agent-integrations` from Goalong Dev removes nothing (the hooks belong to the installed Goalong).
    func testGoalongDevCommandLineNeverRemovesAgentHooks() {
        var removed: [AgentIntegrationKind] = []
        XCTAssertFalse(AgentHookCommandLine.uninstallAll(
            channel: GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"])) { removed.append($0) })
        XCTAssertEqual(removed, [])
        XCTAssertTrue(AgentHookCommandLine.uninstallAll(channel: GoalongBuildChannel(info: nil)) { removed.append($0) })
        XCTAssertEqual(removed, AgentIntegrationKind.allCases)
    }

    /// Proof capsule keys sit in the shared login keychain: Goalong Dev never reads or deletes the release's.
    func testGoalongDevUsesItsOwnEvidenceKeychainService() {
        XCTAssertEqual(AnalysisEvidenceCapsuleStore.keychainService(for: GoalongBuildChannel(info: nil)), "goalong.evidence.v1")
        XCTAssertEqual(AnalysisEvidenceCapsuleStore.keychainService(
            for: GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"])), "goalong.evidence.v1.dev")
        XCTAssertEqual(AnalysisEvidenceCapsuleStore.service, "goalong.evidence.v1")
    }

    /// A freeze in one Goalong hides every other regular app except kept apps and the Goalong family.
    func testFreezeNeverHidesTheOtherGoalong() {
        let kept: Set<String> = ["com.apple.TextEdit"]
        XCTAssertFalse(StandardBlockingBackend.hidesBehindKeptApps("ai.goalong.localhistory.dev", kept: kept))
        XCTAssertFalse(StandardBlockingBackend.hidesBehindKeptApps("ai.goalong.localhistory", kept: kept))
        XCTAssertFalse(StandardBlockingBackend.hidesBehindKeptApps("com.apple.TextEdit", kept: kept))
        XCTAssertTrue(StandardBlockingBackend.hidesBehindKeptApps("com.apple.Safari", kept: kept))
        XCTAssertTrue(StandardBlockingBackend.hidesBehindKeptApps(nil, kept: kept))
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
}
