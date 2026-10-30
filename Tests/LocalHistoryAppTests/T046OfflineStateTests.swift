#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-046 L4c: rows the hard-case runner cannot reach (real Sparkle install, ChatGPT account).
    final class T046OfflineStateTests: XCTestCase {
        /// J-0675: sidebar « Mise à jour disponible » button (DashboardRootView.updateButton → showAvailableUpdate).
        /// Label and enabled state read `isPreparingAvailableUpdate`, i.e. `hasPendingRequest`.
        func testAvailableUpdateButtonPreparesThenPresentsOnce() {
            var state = SoftwareUpdatePresentationState()
            state.recordDetected(version: "0.6.200")
            XCTAssertFalse(state.hasPendingRequest, "« Mise à jour disponible », enabled")
            XCTAssertEqual(state.requestAvailableUpdate(hasActiveSession: false), .prepare)
            XCTAssertTrue(state.hasPendingRequest, "« Préparation… », disabled while Sparkle prepares")
            XCTAssertTrue(state.recordReady(version: "0.6.200"), "the same click presents the update when ready")
            XCTAssertEqual(state.requestAvailableUpdate(hasActiveSession: true), .present)
            state.recordUserAttention()
            XCTAssertFalse(state.hasPendingRequest, "back to « Mise à jour disponible » after the alert")
            XCTAssertEqual(state.availableVersion, "0.6.200")
        }

        /// J-0676: footer « Version … » button (DashboardRootView.footer → checkForUpdates), offline result.
        func testFooterCheckStartsWaitsAndClearsAfterAFailedCheck() {
            var state = SoftwareUpdatePresentationState()
            XCTAssertEqual(state.requestUpdateCheck(hasActiveSession: false), .check)
            XCTAssertTrue(state.hasPendingRequest, "footer shows its progress indicator")
            XCTAssertEqual(state.requestUpdateCheck(hasActiveSession: true), .wait, "a second click waits for the running check")
            // Network failure (updater didFinishUpdateCycle with an error): the request is dropped.
            state.cancelPendingRequest()
            XCTAssertFalse(state.hasPendingRequest, "footer back to « Version … », clickable again")
            XCTAssertNil(state.availableVersion)
            XCTAssertEqual(state.requestUpdateCheck(hasActiveSession: false), .check)
        }

        /// J-0961: « Analyser cette journée » offline. Codex, not the app, talks to the network: offline it
        /// fails with a server or timeout error. The manual alert gets a readable French message; the
        /// automatic recap retries later instead of giving up.
        func testOfflineCodexFailuresAreReadableAndRetried() {
            let offline: [CodexAppServerError] = [
                .server("stream disconnected before completion: error sending request"),
                .timeout("starting the recap agent"),
                .processExited("codex exited: network unreachable"),
            ]
            for error in offline {
                let message = GoalongUserFacingError.message(error)
                XCTAssertNotEqual(message, GoalongUserFacingError.genericMessage, "\(error)")
                XCTAssertFalse(message.contains("Domain="), message)
                XCTAssertTrue(ChatGPTRecapRuntime.isRetryableAutomaticError(error), "\(error)")
            }
            XCTAssertTrue(GoalongUserFacingError.message(offline[0]).hasPrefix("Codex a signalé une erreur"))
            XCTAssertTrue(GoalongUserFacingError.message(offline[1]).contains("Réessayez"))
            // A raw network error never reaches the recap; if it did, it is not retried blindly.
            XCTAssertFalse(ChatGPTRecapRuntime.isRetryableAutomaticError(URLError(.notConnectedToInternet)))
            XCTAssertFalse(GoalongUserFacingError.message(URLError(.notConnectedToInternet)).isEmpty)
        }
    }
#endif
