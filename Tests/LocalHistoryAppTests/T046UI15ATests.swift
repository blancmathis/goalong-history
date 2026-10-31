#if os(macOS)
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore
import LocalHistoryQueryCLI

/// T-046 UI-15A « Réglages et fenêtre »: the texts that must fit or agree.
final class T046UI15ATests: XCTestCase {
    private func runtime(_ state: RuntimeStateKind) -> RuntimePresentation {
        RuntimePresentation(state: state, accessibilityGranted: true, inputMonitoringGranted: true,
                            eventTapRunning: true, verificationEnabled: false, verificationServer: nil, captureHealth: nil)
    }

    private var everyState: [RuntimeStateKind] {
        [.recording, .paused, .permissionsMissing, .inputTapUnavailable]
            + CaptureStorageFailureKind.allCases.map { .storageUnavailable($0) }
            + [.privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput,
               .sessionUnavailable, .manualPause, .accessibilityUnavailable].map { .suppressed($0) }
    }

    /// The sidebar status holds one line: every label is 20 characters at most.
    func testEverySidebarStatusFitsOneLine() {
        for state in everyState {
            for enabled in [true, false] {
                for paused in [true, false] {
                    let title = runtime(state).sidebarTitle(recordingEnabled: enabled, globallyPaused: paused)
                    XCTAssertLessThanOrEqual(title.count, 20, "« \(title) » for \(state)")
                    XCTAssertFalse(title.isEmpty)
                }
            }
        }
    }

    func testSidebarStatusSaysOffPauseAndRefusedWrite() {
        XCTAssertEqual(runtime(.recording).sidebarTitle(recordingEnabled: false, globallyPaused: false), "Enregistrement coupé")
        XCTAssertEqual(runtime(.recording).sidebarTitle(recordingEnabled: true, globallyPaused: true), "Tout est en pause")
        XCTAssertEqual(runtime(.recording).sidebarTitle(recordingEnabled: false, globallyPaused: true), "Tout est en pause")
        XCTAssertEqual(runtime(.storageUnavailable(.permissionDenied)).sidebarTitle(recordingEnabled: true, globallyPaused: false),
                       "Écriture impossible")
        XCTAssertEqual(runtime(.storageUnavailable(.diskFull)).sidebarTitle(recordingEnabled: true, globallyPaused: false), "Disque plein")
        XCTAssertEqual(runtime(.recording).sidebarTitle(recordingEnabled: true, globallyPaused: false), "Enregistrement actif")
    }

    /// « Historique de ce Mac » and « Temps d’écran Apple » are masculine, « Conversations locales » feminine plural.
    func testSourceStateAgreesWithItsSourceAndSaysThePause() {
        typealias O = PrivacyChoicesOverview
        XCTAssertEqual(O.sourceStateTitle(.localComputerHistory, enabled: true, paused: false), "Activé")
        XCTAssertEqual(O.sourceStateTitle(.appleScreenTime, enabled: false, paused: false), "Désactivé")
        XCTAssertEqual(O.sourceStateTitle(.aiConversations, enabled: true, paused: false), "Activées")
        XCTAssertEqual(O.sourceStateTitle(.aiConversations, enabled: false, paused: false), "Désactivées")
        XCTAssertEqual(O.sourceStateTitle(.localComputerHistory, enabled: true, paused: true), "En pause")
        XCTAssertEqual(O.sourceStateTitle(.aiConversations, enabled: false, paused: true), "Désactivées",
                       "a source switched off is not paused")
    }

    @MainActor func testIdleMenuNamesTheCurrentValue() {
        XCTAssertEqual(SettingsPage.idleOptions(current: 300).count, 6)
        let custom = SettingsPage.idleOptions(current: 45)
        XCTAssertEqual(custom.count, 7)
        XCTAssertEqual(custom.last?.1, "45 secondes, personnalisé")
    }

    @MainActor func testTerminalExampleQuestionIsInFrench() throws {
        let ask = try XCTUnwrap(GoalongCLIContract.quickStartCommands.first { $0.command.hasPrefix("goalong ask") })
        let shown = CLIHelpPage.displayCommand(ask)
        XCTAssertTrue(shown.hasPrefix("goalong ask --days 1 \""), shown)
        XCTAssertFalse(shown.contains("Summarize"), shown)
        let status = try XCTUnwrap(GoalongCLIContract.quickStartCommands.first { $0.command == "goalong status" })
        XCTAssertEqual(CLIHelpPage.displayCommand(status), "goalong status")
    }

    @MainActor func testUnknownLoginStateSaysWhatToCheckNotTheSameFactAgain() {
        let text = BackgroundContinuitySettings.unknownStateText
        XCTAssertTrue(text.contains(LoginItemsPanel.path), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("inconnu"), text)
    }
}
#endif
