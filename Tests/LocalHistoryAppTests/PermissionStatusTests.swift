#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class PermissionStatusTests: XCTestCase {
        func testAccessibilityCanProvideEffectiveInputMonitoring() {
            let status = PermissionStatus(
                accessibility: true,
                inputMonitoring: true,
                accessibilityPreflight: true,
                accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: false,
                inputMonitoringProvidedByAccessibility: true
            )

            XCTAssertTrue(status.allGranted)
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
