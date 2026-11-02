#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-043 Q4a: no test depends on this Mac's real account, real home or TCC grants.
final class T043Q4aMacIndependenceTests: XCTestCase {
    func testGuardGateHomeIsTheThrowawayHomeUnderXCTest() {
        XCTAssertTrue(GoalongTestEnvironment.isXCTest)
        // `make check` runs with a throwaway HOME; getpwuid would return the real one.
        XCTAssertEqual(GoalongGuardGate.realHome.path, URL(fileURLWithPath: NSHomeDirectory()).path)
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir, String(cString: dir) != NSHomeDirectory() {
            XCTAssertNotEqual(GoalongGuardGate.realHome.path, String(cString: dir), "the account's real home was used")
        }
    }

    func testPermissionProbeIsNeutralAndReadsNothingFromTheMac() {
        let before = PermissionManager.systemReadCount
        let status = PermissionManager.guardedProbe(includeFunctionalCheck: true)
        XCTAssertEqual(PermissionManager.systemReadCount, before, "TCC or other processes were read")
        XCTAssertFalse(status.accessibilityPreflight)
        XCTAssertFalse(status.accessibilityCrossProcessProbe)
        XCTAssertFalse(status.inputMonitoringDirectlyGranted)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), .accessibility)
    }

    @MainActor func testAccessibilityTrustIsFalseUnderXCTestWhateverTheMacGrants() {
        XCTAssertFalse(GoalongAccessibilityTrust.isTrusted)
        XCTAssertFalse(StandardBlockingBackend().accessibilityAvailable, "the backend reads this Mac's grant")
    }
}
#endif
