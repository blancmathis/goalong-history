#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

@MainActor
final class DevAppUXTests: XCTestCase {
    private let dev = GoalongBuildChannel(info: [GoalongBuildChannel.channelKey: "dev"])

    // B1-02: turning the login item off in Goalong Dev has nothing to change, so it must succeed.
    func testDevCanTurnLaunchAtLoginOffButNotOn() {
        let manager = LaunchAtLoginManager()
        XCTAssertTrue(manager.setEnabled(false, channel: dev))
        XCTAssertFalse(manager.setEnabled(true, channel: dev))
    }

    // B1-03: the permission text names the running build.
    func testPermissionTextUsesBuildName() {
        XCTAssertTrue(SourceAccessStatus.accessibility.message(appName: "Goalong Dev").contains("Autorisez Goalong Dev dans"))
        XCTAssertTrue(SourceAccessStatus.fullDiskAccess.message(appName: "Goalong Dev").contains("Autorisez Goalong Dev dans"))
        XCTAssertFalse(SourceAccessStatus.accessibility.message(appName: "Goalong Dev").contains("Goalong History"))
    }

    // B1-04: free disk space uses French units and decimal comma whatever the system language.
    func testFreeSpaceUsesFrenchFormat() {
        let bytes: Int64 = 7_630_000_000
        XCTAssertEqual(StorageHealth.formatted(bytes), GoalongUIFormat.bytes(bytes))
        XCTAssertTrue(StorageHealth.formatted(bytes).contains("Go"))
    }

    // B1-05: one alert per state change, not one per visit.
    func testAccessAlertOncePerStateChange() {
        let memory = SourceAccessAlertMemory()
        XCTAssertTrue(memory.shouldAlert(.localComputerHistory, .accessibility))
        XCTAssertFalse(memory.shouldAlert(.localComputerHistory, .accessibility))
        XCTAssertTrue(memory.shouldAlert(.localComputerHistory, .fullDiskAccess))
        XCTAssertFalse(memory.shouldAlert(.localComputerHistory, .ready))
        XCTAssertTrue(memory.shouldAlert(.localComputerHistory, .fullDiskAccess))
    }
}
#endif
