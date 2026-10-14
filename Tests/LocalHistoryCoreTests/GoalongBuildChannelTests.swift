import Foundation
import LocalHistoryCore
import XCTest

final class GoalongBuildChannelTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)

    func testReleaseBundleKeepsHistoricalPathsAndLooks() {
        for info in [nil, [:], ["CFBundleIdentifier": "ai.goalong.localhistory"],
                     [GoalongBuildChannel.dataModeKey: "isolated"]] as [[String: Any]?] {
            let channel = GoalongBuildChannel(info: info)
            XCTAssertFalse(channel.isDevelopment)
            XCTAssertEqual(channel.dataMode, .real)
            XCTAssertEqual(channel.dataRoot(base: base).path, "/Users/someone/Library/Application Support/LocalHistory")
            XCTAssertNil(channel.developmentLabel)
            XCTAssertEqual(channel.windowTitle("Goalong History"), "Goalong History")
        }
        // The test runner has no channel key, like every release.
        XCTAssertFalse(GoalongBuildChannel.current.isDevelopment)
        XCTAssertEqual(GoalongBuildChannel.dataRoot, GoalongBuildChannel.realDataRoot)
        XCTAssertEqual(GoalongBuildChannel.realDataRoot.lastPathComponent, "LocalHistory")
        XCTAssertEqual(GoalongGlobalPause.defaultRoot, GoalongBuildChannel.realDataRoot)
    }

    func testDevBundleIsIsolatedUnlessExplicitlyReal() {
        let isolated = GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev", GoalongBuildChannel.dataModeKey: "isolated"])
        XCTAssertEqual(isolated.dataRoot(base: base).lastPathComponent, "LocalHistory-Dev")
        XCTAssertEqual(isolated.developmentLabel, "Copie de développement · données isolées")
        XCTAssertEqual(isolated.windowTitle("Goalong History"), "Goalong History — Dev")

        for mode in [nil, "", "bogus"] as [String?] {
            var info: [String: Any] = [GoalongBuildChannel.channelKey: "dev"]
            info[GoalongBuildChannel.dataModeKey] = mode
            XCTAssertEqual(GoalongBuildChannel(info: info).dataMode, .isolated)
        }

        let real = GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev", GoalongBuildChannel.dataModeKey: "real"])
        XCTAssertEqual(real.dataRoot(base: base).lastPathComponent, "LocalHistory")
        XCTAssertEqual(real.developmentLabel, "Copie de développement · vraies données")
    }
}
