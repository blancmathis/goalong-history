#!/usr/bin/env python3
"""Source integration boundaries complement the runtime Swift continuity tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'Sources/LocalHistoryApp'

class BackgroundContinuityIntegrationTests(unittest.TestCase):
    def test_privacy_migration_preserves_existing_startup_choice(self):
        migration = (APP / 'LegacyInstallationMigrator.swift').read_text()
        self.assertNotIn('SMAppService.mainApp.unregister()', migration)
        self.assertNotIn('set(false, forKey: "launchAtLoginPreference")', migration)
        self.assertIn('ActivityAnalysisPreferences.richContextEnabledKey', migration)

    def test_settings_and_onboarding_use_the_same_explicit_startup_write(self):
        onboarding = (APP / 'OnboardingView.swift').read_text()
        settings = (APP / 'BackgroundContinuitySettings.swift').read_text()
        self.assertIn('suggestedOnboardingPreference', onboarding)
        self.assertIn('setUserPreference(launchAtLoginPreference, surface: .onboarding)', onboarding)
        self.assertIn('setUserPreference($0, surface: .settings)', settings)
        self.assertIn('BackgroundContinuitySettings()', (APP / 'SettingsPage.swift').read_text())

    def test_refresh_never_silently_reregisters_a_login_item(self):
        manager = (APP / 'LaunchAtLoginManager.swift').read_text()
        refresh = manager.split('func refresh() {')[1].split('@discardableResult')[0]
        self.assertNotIn('.register()', refresh)
        self.assertNotIn('.unregister()', refresh)

    def test_continuity_has_no_external_process_or_sleep_inhibitor(self):
        controller = (APP / 'BackgroundContinuityController.swift').read_text()
        for forbidden in ['Process()', 'launchctl', 'SMAppService', '.idleSystemSleepDisabled', '.idleDisplaySleepDisabled', '.userInitiated', 'NSWorkspace.shared.open']:
            self.assertNotIn(forbidden, controller)
        self.assertIn('.automaticTerminationDisabled', controller)
        self.assertIn('.suddenTerminationDisabled', controller)

    def test_both_app_quit_commands_are_guarded(self):
        delegate = (APP / 'AppDelegate.swift').read_text()
        self.assertEqual(delegate.count('onQuit: { [weak self] in self?.requestUserQuit() }'), 2)
        self.assertIn('senderID == "com.apple.dock"', delegate)
        self.assertIn('return .terminateNow', delegate)

    def test_sparkle_is_not_destroyed_during_update_handoff(self):
        manager = (APP / 'SoftwareUpdateManager.swift').read_text()
        stop = manager.split('func stop() {')[1].split('func refreshAvailableUpdate')[0]
        self.assertLess(stop.index('guard !isRelaunchingForUpdate'), stop.index('updaterController = nil'))
        self.assertIn('func updaterWillRelaunchApplication(', manager)
        self.assertIn('func updater(_ updater: SPUUpdater, didAbortWithError', manager)

    def test_session_is_marked_clean_only_after_recorder_close(self):
        delegate = (APP / 'AppDelegate.swift').read_text()
        self.assertLess(delegate.index('recorder?.close()'), delegate.index('BackgroundContinuityController.shared.stop(reason: reason)'))
        self.assertIn('continuityPreferences.keepRunning && captureState.isCapturing', delegate)
        self.assertIn('let paused = continuityPreferences.manuallyPaused', delegate)

if __name__ == '__main__':
    unittest.main()
