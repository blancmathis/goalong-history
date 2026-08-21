#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class SoftwareUpdatePresentationStateTests: XCTestCase {
        func testDetectedUpdateIsNotClickableUntilSparkleAlertIsReady() {
            var state = SoftwareUpdatePresentationState()

            state.recordDetected(version: "5000.0.6")

            XCTAssertEqual(state.detectedVersion, "5000.0.6")
            XCTAssertNil(state.availableVersion)
            XCTAssertFalse(state.isReady)
        }

        func testReadyUpdateCanBePresentedImmediately() {
            var state = SoftwareUpdatePresentationState()
            state.recordDetected(version: "5000.0.6")
            XCTAssertFalse(state.recordReady(version: "5000.0.6"))

            XCTAssertEqual(state.availableVersion, "5000.0.6")
            XCTAssertEqual(state.requestAvailableUpdate(hasActiveSession: true), .present)
            XCTAssertEqual(state.pendingRequest, .presentAvailableUpdate)

            state.recordUserAttention()

            XCTAssertNil(state.pendingRequest)
        }

        func testDismissedUpdateReusesOneClickAfterQuietSessionIsRearmed() {
            var state = SoftwareUpdatePresentationState()
            state.recordReady(version: "5000.0.6")
            state.recordSessionFinished()

            XCTAssertEqual(state.availableVersion, "5000.0.6")
            XCTAssertEqual(state.requestAvailableUpdate(hasActiveSession: false), .prepare)
            XCTAssertEqual(state.pendingRequest, .presentAvailableUpdate)
            XCTAssertTrue(state.recordReady(version: "5000.0.6"))
            XCTAssertTrue(state.isReady)
            XCTAssertEqual(state.pendingRequest, .presentAvailableUpdate)

            state.recordUserAttention()

            XCTAssertNil(state.pendingRequest)
        }

        func testPresentationRequestSurvivesAClosingSessionUntilUserAttention() {
            var state = SoftwareUpdatePresentationState()
            state.recordReady(version: "5000.0.6")

            XCTAssertEqual(state.requestAvailableUpdate(hasActiveSession: true), .present)

            state.recordSessionFinished()

            XCTAssertFalse(state.isReady)
            XCTAssertEqual(state.pendingRequest, .presentAvailableUpdate)
            XCTAssertTrue(state.recordReady(version: "5000.0.6"))
        }

        func testManualCheckWaitsForAnActiveBackgroundSession() {
            var state = SoftwareUpdatePresentationState()

            XCTAssertEqual(state.requestUpdateCheck(hasActiveSession: true), .wait)
            XCTAssertEqual(state.pendingRequest, .checkForUpdates)
            XCTAssertTrue(state.recordReady(version: "5000.0.6"))
        }

        func testManualCheckStartsImmediatelyWithoutAnActiveSession() {
            var state = SoftwareUpdatePresentationState()

            XCTAssertEqual(state.requestUpdateCheck(hasActiveSession: false), .check)
            XCTAssertEqual(state.pendingRequest, .checkForUpdates)
        }

        func testNoUpdateCancelsStaleBadgeRequestButPreservesManualCheck() {
            var badgeState = SoftwareUpdatePresentationState()
            badgeState.recordReady(version: "5000.0.6")
            _ = badgeState.requestAvailableUpdate(hasActiveSession: false)

            badgeState.recordNoUpdate()

            XCTAssertNil(badgeState.availableVersion)
            XCTAssertNil(badgeState.pendingRequest)

            var manualCheckState = SoftwareUpdatePresentationState()
            _ = manualCheckState.requestUpdateCheck(hasActiveSession: true)

            manualCheckState.recordNoUpdate()

            XCTAssertNil(manualCheckState.availableVersion)
            XCTAssertEqual(manualCheckState.pendingRequest, .checkForUpdates)
        }

        func testNoUpdateClearsStalePresentationState() {
            var state = SoftwareUpdatePresentationState()
            state.recordReady(version: "5000.0.6")
            state.recordSessionFinished()
            _ = state.requestAvailableUpdate(hasActiveSession: false)

            state.clear()

            XCTAssertEqual(state, SoftwareUpdatePresentationState())
        }
    }
#endif
