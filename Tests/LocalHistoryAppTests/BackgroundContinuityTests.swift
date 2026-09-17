#if os(macOS)
    import AppKit
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class BackgroundContinuityTests: XCTestCase {
        private func isolatedDefaults() -> UserDefaults {
            let name = "goalong-background-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            return defaults
        }

        func testBackgroundProtectionDefaultsOnWithoutPersistingAChoice() {
            let defaults = isolatedDefaults()
            let preferences = BackgroundContinuityPreferences(defaults: defaults)
            XCTAssertTrue(preferences.keepRunning)
            XCTAssertNil(defaults.object(forKey: BackgroundContinuityPreferences.keepRunningKey))
            XCTAssertFalse(preferences.manuallyPaused)
        }

        func testBackgroundOptOutSurvivesRecreation() {
            let defaults = isolatedDefaults()
            BackgroundContinuityPreferences(defaults: defaults).keepRunning = false
            XCTAssertFalse(BackgroundContinuityPreferences(defaults: defaults).keepRunning)
        }

        func testBackgroundProtectionCanBeEnabledAgain() {
            let preferences = BackgroundContinuityPreferences(defaults: isolatedDefaults())
            preferences.keepRunning = false
            preferences.keepRunning = true
            XCTAssertTrue(preferences.keepRunning)
        }

        func testPauseSurvivesRestartAndDoesNotChangeBackgroundPreference() {
            let defaults = isolatedDefaults()
            let preferences = BackgroundContinuityPreferences(defaults: defaults)
            preferences.manuallyPaused = true
            let restarted = BackgroundContinuityPreferences(defaults: defaults)
            XCTAssertTrue(restarted.manuallyPaused)
            XCTAssertTrue(restarted.keepRunning)
            restarted.manuallyPaused = false
            XCTAssertFalse(BackgroundContinuityPreferences(defaults: defaults).manuallyPaused)
        }

        func testChangingAvailabilityDoesNotResumeManualPause() {
            let preferences = BackgroundContinuityPreferences(defaults: isolatedDefaults())
            preferences.manuallyPaused = true
            preferences.keepRunning = false
            preferences.keepRunning = true
            XCTAssertTrue(preferences.manuallyPaused)
        }

        func testUndecidedSetupVisiblyDefaultsStartupOn() {
            XCTAssertTrue(BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: nil, consentEnabled: false, consentWasRecorded: false, systemEnabled: false
            ))
        }

        func testLegacyStartupOptOutIsPreserved() {
            XCTAssertFalse(BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: false, consentEnabled: false, consentWasRecorded: false, systemEnabled: false
            ))
        }

        func testExplicitConsentOptOutWinsOverAnOldEnabledPreference() {
            XCTAssertFalse(BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: true, consentEnabled: false, consentWasRecorded: true, systemEnabled: true
            ))
        }

        func testExplicitConsentOptInWinsOverAnOldMigrationPreference() {
            XCTAssertTrue(BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: false, consentEnabled: true, consentWasRecorded: true, systemEnabled: false
            ))
        }

        func testExistingNativeLoginItemRemainsSelected() {
            XCTAssertTrue(BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: nil, consentEnabled: false, consentWasRecorded: false, systemEnabled: true
            ))
        }

        func testQuitConfirmationRequiresProtectionAndAnEnabledSource() {
            for protected in [false, true] {
                for enabled in [false, true] {
                    XCTAssertEqual(BackgroundContinuityPreferences.shouldConfirmQuit(
                        keepRunning: protected, hasEnabledSources: enabled
                    ), protected && enabled)
                }
            }
        }

        func testFirstSessionIsNotReportedAsInterrupted() {
            let journal = BackgroundSessionJournal(defaults: isolatedDefaults())
            XCTAssertFalse(journal.begin())
        }

        func testUnclosedSessionIsDetectedOnNextStart() {
            let defaults = isolatedDefaults()
            XCTAssertFalse(BackgroundSessionJournal(defaults: defaults).begin())
            XCTAssertTrue(BackgroundSessionJournal(defaults: defaults).begin())
        }

        func testOrderlyQuitAndUpdateDoNotReportAnInterruption() {
            for reason in ["user_quit", "update", "permission_restart", "system_or_application_exit"] {
                let defaults = isolatedDefaults()
                let journal = BackgroundSessionJournal(defaults: defaults)
                journal.begin()
                journal.finish(reason: reason)
                XCTAssertEqual(defaults.string(forKey: BackgroundSessionJournal.exitReasonKey), reason)
                XCTAssertFalse(journal.begin(), reason)
            }
        }

        func testJournalStoresOnlyOneHeartbeatWithoutGrowingAHistory() {
            let defaults = isolatedDefaults()
            let journal = BackgroundSessionJournal(defaults: defaults)
            journal.begin(now: Date(timeIntervalSince1970: 10))
            for timestamp in 11...100 { journal.heartbeat(now: Date(timeIntervalSince1970: Double(timestamp))) }
            XCTAssertEqual(defaults.double(forKey: BackgroundSessionJournal.heartbeatKey), 100)
            let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("goalong.runtime.") }
            XCTAssertEqual(Set(keys), Set([BackgroundSessionJournal.runningKey, BackgroundSessionJournal.heartbeatKey]))
        }

        @MainActor
        func testRealDelegateKeepsRunningAfterLastWindowClosesUnlessDisabled() {
            let defaults = UserDefaults.standard
            let key = BackgroundContinuityPreferences.keepRunningKey
            let old = defaults.object(forKey: key)
            defer {
                if let old { defaults.set(old, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            let delegate = AppDelegate()
            defaults.removeObject(forKey: key)
            XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
            defaults.set(false, forKey: key)
            XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        }

        @MainActor
        func testUnattributedOrSystemTerminationIsNotBlocked() {
            // No fabricated user Quit event, no modal dialog and no restart.
            let delegate = AppDelegate()
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        }
    }
#endif
