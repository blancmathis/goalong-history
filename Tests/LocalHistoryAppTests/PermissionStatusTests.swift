#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class PermissionStatusTests: XCTestCase {
        func testAccessibilityDoesNotMasqueradeAsDirectInputMonitoring() {
            let status = PermissionStatus(
                accessibility: true,
                inputMonitoring: false,
                accessibilityPreflight: true,
                accessibilityFunctionalProbe: true,
                inputMonitoringDirectlyGranted: false,
                inputMonitoringProvidedByAccessibility: false
            )

            XCTAssertFalse(status.allGranted)
            XCTAssertTrue(status.canAttemptInputTap)
            XCTAssertEqual(status.inputMonitoringStatusLabel, "off")
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
