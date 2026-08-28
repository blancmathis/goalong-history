#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class PermissionStatusTests: XCTestCase {
        func testAccessibilityProvidesEffectiveInputMonitoringWithoutMasqueradingAsDirectGrant() {
            let status = PermissionStatus.resolved(
                accessibilityPreflight: true,
                accessibilityFunctionalProbe: true,
                inputMonitoringDirectlyGranted: false
            )

            XCTAssertTrue(status.allGranted)
            XCTAssertTrue(status.canAttemptInputTap)
            XCTAssertEqual(status.inputMonitoringStatusLabel, "via Accessibility")
        }

        func testSetupRemainsIncompleteWithoutAccessibility() {
            let status = PermissionStatus(
                accessibility: false,
                inputMonitoring: true,
                accessibilityPreflight: false,
                accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: true,
                inputMonitoringProvidedByAccessibility: false
            )

            XCTAssertFalse(status.allGranted)
            XCTAssertEqual(status.inputMonitoringStatusLabel, "on")
        }
    }
#endif
