#if os(macOS)
import Foundation
import XCTest
import AppleScreenTime
@testable import LocalHistoryApp

/// T-043 Q4a: no test depends on this Mac's real account, real home or TCC grants.
final class T043Q4aMacIndependenceTests: XCTestCase {
    func testGuardGateHomeIsTheThrowawayHomeUnderXCTest() throws {
        XCTAssertTrue(GoalongTestEnvironment.isXCTest)
        // The test sets its own throwaway home, so it fails without the guard whatever HOME the run started with.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("goalong-test-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        let saved = ["HOME", "CFFIXED_USER_HOME"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(atPath: temp)
        }
        setenv("HOME", temp, 1); setenv("CFFIXED_USER_HOME", temp, 1)
        XCTAssertEqual(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: temp).resolvingSymlinksInPath().path, "precondition: the test home is in force")
        XCTAssertEqual(GoalongGuardGate.realHome.resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: temp).resolvingSymlinksInPath().path, "the account's real home was used")
    }

    @MainActor func testSystemPromptsNeverOpenUnderXCTest() {
        let before = PermissionManager.systemReadCount
        XCTAssertFalse(PermissionManager.shared.requestAccessibility(), "AXIsProcessTrustedWithOptions(prompt) was called")
        XCTAssertFalse(PermissionManager.shared.requestInputMonitoring(), "CGRequestListenEventAccess was called")
        XCTAssertEqual(PermissionManager.systemReadCount, before, "a system prompt path ran")
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
