#if os(macOS)
    import XCTest
    import Sparkle
    @testable import LocalHistoryApp

    final class SoftwareUpdatePresentationStateTests: XCTestCase {
        func testSparkleComparatorRecognizesMigrationAndEveryNextBuild() {
            let comparator = SUStandardVersionComparator()
            let first = "20260913.3476827.178501"
            XCTAssertEqual(comparator.compareVersion(first, toVersion: "20260912.4"), .orderedDescending)
            XCTAssertEqual(comparator.compareVersion(first, toVersion: "5000.0.66"), .orderedDescending)
            XCTAssertEqual(comparator.compareVersion("20260913.3476827.178502", toVersion: first), .orderedDescending)
            XCTAssertEqual(comparator.compareVersion("20260913.3476828.101", toVersion: first), .orderedDescending)
        }

        @MainActor
        func testNoUpdateIsASuccessfulResultNotANetworkFailure() {
            XCTAssertTrue(SoftwareUpdateManager.isNoUpdateResult(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))))
            XCTAssertFalse(SoftwareUpdateManager.isNoUpdateResult(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
            XCTAssertFalse(SoftwareUpdateManager.isNoUpdateResult(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))))
        }

        @MainActor
        func testSourceBuildAndUntrustedFeedFailClosed() {
            XCTAssertFalse(SoftwareUpdateManager.hasValidSparkleConfiguration(info: [:], isApp: true))
            var info: [String: Any] = [
                "SUFeedURL": SoftwareUpdateManager.releaseFeedURL,
                "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
                "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
                "SUAllowsAutomaticUpdates": false, "SUEnableSystemProfiling": false,
            ]
            XCTAssertTrue(SoftwareUpdateManager.hasValidSparkleConfiguration(info: info, isApp: true))
            XCTAssertFalse(SoftwareUpdateManager.hasValidSparkleConfiguration(info: info, isApp: false))
            info["SUFeedURL"] = "https://example.com/appcast.xml"
            XCTAssertFalse(SoftwareUpdateManager.hasValidSparkleConfiguration(info: info, isApp: true))
            info["SUFeedURL"] = SoftwareUpdateManager.releaseFeedURL
            info["SURequireSignedFeed"] = false
            XCTAssertFalse(SoftwareUpdateManager.hasValidSparkleConfiguration(info: info, isApp: true))
        }

        @MainActor
        func testWindowActivationDoesNotRepeatedlyHitFeed() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(SoftwareUpdateManager.shouldCheckInBackground(lastCheck: nil, now: now))
            XCTAssertFalse(SoftwareUpdateManager.shouldCheckInBackground(lastCheck: now, now: now.addingTimeInterval(30)))
            XCTAssertFalse(SoftwareUpdateManager.shouldCheckInBackground(lastCheck: now, now: now.addingTimeInterval(-5)))
            XCTAssertTrue(SoftwareUpdateManager.shouldCheckInBackground(lastCheck: now, now: now.addingTimeInterval(3600)))
        }

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
