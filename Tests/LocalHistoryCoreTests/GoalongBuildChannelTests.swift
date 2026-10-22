import Foundation
import LocalHistoryCore
import XCTest

final class GoalongBuildChannelTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
    private let dev: [String: Any] = [
        GoalongBuildChannel.channelKey: "dev", GoalongBuildChannel.dataModeKey: "clone",
        GoalongBuildChannel.sourceBranchKey: "feat/x", GoalongBuildChannel.sourceCommitKey: "4cb75dc+dirty",
        GoalongBuildChannel.builtAtKey: "2026-10-22T10:00:00Z",
    ]

    func testReleaseBundleKeepsHistoricalPathsAndLooks() {
        for info in [nil, [:], ["CFBundleIdentifier": "ai.goalong.localhistory"],
                     [GoalongBuildChannel.dataModeKey: "clone", GoalongBuildChannel.serverKey: "on"],
                     [GoalongBuildChannel.channelKey: "release"]] as [[String: Any]?] {
            let channel = GoalongBuildChannel(info: info)
            XCTAssertFalse(channel.isDevelopment)
            XCTAssertNil(channel.devDataMode)
            XCTAssertNil(channel.sourceCommit)
            XCTAssertEqual(channel.dataRoot(base: base).path, "/Users/someone/Library/Application Support/LocalHistory")
            XCTAssertNil(channel.developmentLabel)
            XCTAssertEqual(channel.windowTitle("Goalong History"), "Goalong History")
            XCTAssertEqual(channel.menuBarAutosaveName("goalong-menu"), "goalong-menu")
            XCTAssertTrue(channel.allowsServerTraffic)
            XCTAssertTrue(channel.allowsLoginItems)
            XCTAssertTrue(channel.allowsAgentHookChanges)
            XCTAssertNoThrow(try GoalongDevServerDisabledError.check(channel))
        }
        // The test runner has no channel key, like every release.
        XCTAssertFalse(GoalongBuildChannel.current.isDevelopment)
        XCTAssertEqual(GoalongBuildChannel.dataRoot, GoalongBuildChannel.realDataRoot)
        XCTAssertEqual(GoalongBuildChannel.realDataRoot.lastPathComponent, "LocalHistory")
        XCTAssertEqual(GoalongGlobalPause.defaultRoot, GoalongBuildChannel.realDataRoot)
        XCTAssertNoThrow(try GoalongDevServerDisabledError.check())
    }

    func testGoalongDevNeverUsesTheRealDataFolder() {
        // Every mode, including the removed "real" one and unknown values, stays in LocalHistory-Dev.
        for mode in [nil, "", "clone", "keep", "fresh", "real", "isolated", "bogus"] as [String?] {
            var info: [String: Any] = [GoalongBuildChannel.channelKey: "dev"]
            info[GoalongBuildChannel.dataModeKey] = mode
            let channel = GoalongBuildChannel(info: info)
            XCTAssertTrue(channel.isDevelopment)
            XCTAssertEqual(channel.dataRoot(base: base).lastPathComponent, "LocalHistory-Dev")
            XCTAssertNotEqual(channel.dataRoot(base: base).path, "/Users/someone/Library/Application Support/LocalHistory")
        }
    }

    func testGoalongDevLabelsAndAutosaveName() {
        let channel = GoalongBuildChannel(info: dev)
        XCTAssertEqual(channel.devDataMode, "clone")
        XCTAssertEqual(channel.sourceBranch, "feat/x")
        XCTAssertEqual(channel.sourceCommit, "4cb75dc+dirty")
        XCTAssertEqual(channel.builtAt, "2026-10-22T10:00:00Z")
        XCTAssertEqual(channel.developmentLabel, "Goalong Dev · feat/x · 4cb75dc+dirty · données clone")
        XCTAssertEqual(channel.windowTitle("Goalong History"), "Goalong History — Dev")
        XCTAssertEqual(channel.menuBarAutosaveName("goalong-menu"), "goalong-menu-dev")
        XCTAssertEqual(channel.menuBarAutosaveName("goalong-braise"), "goalong-braise-dev")
        XCTAssertFalse(channel.allowsAgentHookChanges)
    }

    /// make dev NO_LAUNCH=1 prepares no data: the banner must not claim clone/keep/fresh.
    func testUnseededDevCopySaysSo() {
        var info = dev
        info[GoalongBuildChannel.dataModeKey] = GoalongBuildChannel.unseededDataMode
        XCTAssertEqual(GoalongBuildChannel(info: info).developmentLabel,
                       "Goalong Dev · feat/x · 4cb75dc+dirty · données non préparées")
        info[GoalongBuildChannel.dataModeKey] = nil
        XCTAssertEqual(GoalongBuildChannel(info: info).developmentLabel, "Goalong Dev · feat/x · 4cb75dc+dirty · données isolées")
    }

    func testGoalongDevHasNoServerTrafficOrLoginItemByDefault() {
        let channel = GoalongBuildChannel(info: dev)
        XCTAssertFalse(channel.allowsServerTraffic)
        XCTAssertFalse(channel.allowsLoginItems)
        XCTAssertThrowsError(try GoalongDevServerDisabledError.check(channel)) {
            XCTAssertEqual($0 as? GoalongDevServerDisabledError, GoalongDevServerDisabledError())
        }
        for value in [true, "on"] as [Any] {
            var info = dev
            info[GoalongBuildChannel.serverKey] = value
            let server = GoalongBuildChannel(info: info)
            XCTAssertTrue(server.allowsServerTraffic)
            XCTAssertFalse(server.allowsLoginItems)
            XCTAssertEqual(server.developmentLabel, "Goalong Dev · feat/x · 4cb75dc+dirty · données clone · serveur actif")
        }
        for value in [false, "off", "", "yes"] as [Any] {
            var info = dev
            info[GoalongBuildChannel.serverKey] = value
            XCTAssertFalse(GoalongBuildChannel(info: info).allowsServerTraffic)
        }
    }

    func testBundleIdentityFamilyAndSelf() {
        XCTAssertEqual(GoalongBundleIdentity.release, "ai.goalong.localhistory")
        XCTAssertEqual(GoalongBundleIdentity.development, "ai.goalong.localhistory.dev")
        for id in ["ai.goalong.localhistory", "ai.goalong.localhistory.dev", "AI.Goalong.LocalHistory.DEV"] {
            XCTAssertTrue(GoalongBundleIdentity.isGoalong(id), id)
        }
        for id in [nil, "", "ai.goalong.localhistory.relauncher", "ai.goalong.localhistory.devx", "com.apple.finder"] as [String?] {
            XCTAssertFalse(GoalongBundleIdentity.isGoalong(id))
        }
        XCTAssertEqual(GoalongBundleIdentity.resolve("ai.goalong.localhistory.dev"), "ai.goalong.localhistory.dev")
        XCTAssertEqual(GoalongBundleIdentity.resolve("ai.goalong.localhistory"), "ai.goalong.localhistory")
        XCTAssertEqual(GoalongBundleIdentity.resolve(nil), "ai.goalong.localhistory")
        XCTAssertEqual(GoalongBundleIdentity.resolve("com.apple.dt.xctest.tool"), "ai.goalong.localhistory")
        // The test runner, like a release, is "the release".
        XCTAssertEqual(GoalongBundleIdentity.current, "ai.goalong.localhistory")
    }

    func testRecorderNeverCapturesAnyGoalongCopy() {
        // The default exclusion of the installed Goalong also covers Goalong Dev.
        var config = RecorderConfig.default
        XCTAssertTrue(config.excludedBundleIdentifiers.contains("ai.goalong.localhistory"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "ai.goalong.localhistory"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "ai.goalong.localhistory.dev"))
        XCTAssertTrue(config.allowsApplication(bundleIdentifier: "com.apple.Safari"))
        // Release unchanged: without any Goalong exclusion, nothing changes.
        config.excludedBundleIdentifiers = ["com.apple.Safari"]
        XCTAssertTrue(config.allowsApplication(bundleIdentifier: "ai.goalong.localhistory"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "com.apple.Safari"))
    }
}
