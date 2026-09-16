#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongRecordingDefaultsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "goalong-recording-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testEveryFirstActivationProposesAllEightWithoutPersistingAnything() {
        let preferences = defaults()
        let current = DashboardSettingsDraft(config: .default)
        for legacySourceAlreadyEnabled in [false, true] {
            preferences.set(legacySourceAlreadyEnabled, forKey: "didShowLocalHistoryConsentOnboardingV5")
            let proposal = GoalongRecordingSetup.proposal(from: current, visibleText: false, defaults: preferences)
            XCTAssertEqual(GoalongRecordingSetup.enabledCount(proposal.settings, visibleText: proposal.visibleText), 8)
            XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
            XCTAssertFalse(current.captureClicks)
            XCTAssertNil(preferences.object(forKey: ActivityAnalysisPreferences.richContextEnabledKey))
        }
    }
    func testPreviouslyReviewedOptOutSurvivesActivationAndAnotherLaunch() {
        let preferences = defaults()
        preferences.set(true, forKey: GoalongRecordingSetup.reviewedKey)
        for bits in 0..<256 {
            var saved = DashboardSettingsDraft(config: .default)
            for (index, signal) in RecordingSignal.allCases.enumerated() { saved[keyPath: signal.keyPath] = bits & (1 << index) != 0 }
            let text = bits & 128 != 0
            let first = GoalongRecordingSetup.proposal(from: saved, visibleText: text, defaults: preferences)
            let second = GoalongRecordingSetup.proposal(from: first.settings, visibleText: first.visibleText, defaults: preferences)
            XCTAssertEqual(first.settings, saved); XCTAssertEqual(first.visibleText, text)
            XCTAssertEqual(second, first, "A restart must not change any of 256 accepted profiles")
        }
    }
    func testExplicitIndividualOptOutDoesNotTurnUnreviewedDefaultsIntoOptOuts() {
        let preferences = defaults()
        let baseline = DashboardSettingsDraft(config: .default)
        var enabled = baseline; enabled.captureClicks = true
        GoalongRecordingSetup.rememberChanges(from: baseline, to: enabled, defaults: preferences)
        GoalongRecordingSetup.rememberChanges(from: enabled, to: baseline, defaults: preferences)
        GoalongRecordingSetup.rememberVisibleText(false, defaults: preferences)
        let proposed = GoalongRecordingSetup.proposal(from: baseline, visibleText: false, defaults: preferences)
        XCTAssertFalse(proposed.settings.captureClicks); XCTAssertFalse(proposed.visibleText)
        for signal in RecordingSignal.allCases where signal != .clicks { XCTAssertTrue(proposed.settings[keyPath: signal.keyPath]) }
        XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
    }
    func testRequestingCompleteProfileKeepsExclusionsPrivateBrowsingRetentionAndNetwork() {
        let preferences = defaults(); preferences.set(true, forKey: GoalongRecordingSetup.reviewedKey)
        var previous = DashboardSettingsDraft(config: .default)
        previous.excludedApplicationsText = "com.test.private"
        previous.excludedDomainsText = "private.example"
        previous.includedApplicationsText = "com.test.work"
        previous.retentionDays = 90
        let requested = GoalongRecordingSetup.proposal(from: previous, visibleText: false, complete: true, defaults: preferences)
        var expected = previous
        for signal in RecordingSignal.allCases { expected[keyPath: signal.keyPath] = true }
        XCTAssertEqual(requested.settings, expected)
        XCTAssertTrue(requested.visibleText)
        XCTAssertFalse(requested.settings.capturePrivateBrowsing)
        XCTAssertTrue(requested.settings.redactAllURLQueryValues)
        XCTAssertFalse(requested.settings.verificationEnabled)
    }
    func testOldCompleteReviewIsRespectedButOldWelcomeFlagIsNotRecordingConsent() {
        for legacyKey in [GoalongRecordingSetup.preparedKey, "goalongOnboardingPrivacyReviewedV1"] {
            let preferences = defaults(); preferences.set(true, forKey: legacyKey)
            let saved = DashboardSettingsDraft(config: .default)
            XCTAssertEqual(GoalongRecordingSetup.proposal(from: saved, visibleText: false, defaults: preferences).settings, saved)
        }
        let preferences = defaults()
        preferences.set(true, forKey: "didShowLocalHistoryConsentOnboardingV5")
        XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
    }
    func testStatusCannotCallAnIncompleteConfigurationComplete() {
        var settings = DashboardSettingsDraft(config: .default)
        XCTAssertEqual(GoalongRecordingSetup.profile(settings, visibleText: false), "Applications seules")
        settings.captureClicks = true
        XCTAssertEqual(GoalongRecordingSetup.profile(settings, visibleText: false), "Personnalisé · 1/8")
        settings = GoalongRecordingSetup.proposed(from: settings)
        XCTAssertEqual(GoalongRecordingSetup.profile(settings, visibleText: false), "Personnalisé · 7/8")
        XCTAssertEqual(GoalongRecordingSetup.profile(settings, visibleText: true), "Complet · 8/8")
    }
    private func isolatedModel(save: ((RecorderConfig) throws -> RecorderConfig)? = nil) throws -> (DashboardViewModel, ConfigManager) {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("Recording persistence tests require an isolated test HOME")
        }
        let config = ConfigManager(), original = ConfigManager().config
        addTeardownBlock { _ = try? config.save(original) }
        _ = try config.save(.default)
        let permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/recording-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "recording-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: save ?? { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        return (model, config)
    }
    @MainActor func testCompleteChoiceActuallyReachesPersistedRecorderAndPreservesRemoteConsents() throws {
        let preferences = defaults(), (model, config) = try isolatedModel()
        let remoteBefore = GoalongCapabilityConsentStore.shared.document
        let proposal = GoalongRecordingSetup.proposal(from: model.appliedSettings, visibleText: false, defaults: preferences)
        XCTAssertTrue(model.applyRecordingSetup(proposal, defaults: preferences, notifyRuntime: false))
        let readBack = try RecorderConfig.load(from: AppPaths.configFile)
        XCTAssertEqual(config.config, readBack)
        for signal in RecordingSignal.allCases { XCTAssertTrue(DashboardSettingsDraft(config: readBack)[keyPath: signal.keyPath]) }
        XCTAssertTrue(preferences.bool(forKey: ActivityAnalysisPreferences.richContextEnabledKey))
        XCTAssertTrue(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
        XCTAssertEqual(GoalongCapabilityConsentStore.shared.document, remoteBefore)
    }
    @MainActor func testSavingOptOutThenReloadingDoesNotReenableIt() throws {
        let preferences = defaults(), (model, _) = try isolatedModel()
        var proposal = GoalongRecordingSetup.proposal(from: model.appliedSettings, visibleText: false, defaults: preferences)
        proposal.settings.captureScroll = false; proposal.visibleText = false
        XCTAssertTrue(model.applyRecordingSetup(proposal, defaults: preferences, notifyRuntime: false))
        let stored = DashboardSettingsDraft(config: try RecorderConfig.load(from: AppPaths.configFile))
        let resumed = GoalongRecordingSetup.proposal(from: stored,
            visibleText: preferences.bool(forKey: ActivityAnalysisPreferences.richContextEnabledKey), defaults: preferences)
        XCTAssertEqual(resumed, proposal)
        XCTAssertFalse(resumed.settings.captureScroll); XCTAssertFalse(resumed.visibleText)
        XCTAssertTrue(resumed.settings.captureClicks)
    }
    @MainActor func testConfigurationWriteFailureDoesNotAcceptOrEnableTheProposal() throws {
        let preferences = defaults()
        let (model, config) = try isolatedModel(save: { _ in throw CocoaError(.fileWriteNoPermission) })
        let original = config.config
        let proposal = GoalongRecordingSetup.proposal(from: model.appliedSettings, visibleText: false, defaults: preferences)
        XCTAssertFalse(model.applyRecordingSetup(proposal, defaults: preferences, notifyRuntime: false))
        XCTAssertEqual(config.config, original)
        XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
        XCTAssertNil(preferences.object(forKey: ActivityAnalysisPreferences.richContextEnabledKey))
        XCTAssertNotNil(model.alert)
    }
    @MainActor func testPreferencesFailureRollsBackAllRecordingChoices() throws {
        let preferences = defaults(), (model, config) = try isolatedModel()
        let original = config.config
        let proposal = GoalongRecordingSetup.proposal(from: model.appliedSettings, visibleText: false, defaults: preferences)
        XCTAssertFalse(model.applyRecordingSetup(proposal, defaults: preferences, flushPreferences: { false }, notifyRuntime: false))
        XCTAssertEqual(config.config, original)
        XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices(defaults: preferences))
        XCTAssertNil(preferences.object(forKey: ActivityAnalysisPreferences.richContextEnabledKey))
        XCTAssertFalse(model.appliedSettings.captureClicks)
    }
    func testEveryUIActivationPathUsesTheSameReviewGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/SourceActivation.swift"))
        XCTAssertTrue(source.contains("if capability == .localComputerHistory && !GoalongRecordingSetup.hasReviewedChoices()"))
        XCTAssertTrue(source.contains("guard recordingChoicesReady() else { return }"))
        let onboarding = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/OnboardingView.swift"))
        XCTAssertTrue(onboarding.contains("model.applyRecordingSetup(choices)"))
        XCTAssertTrue(onboarding.contains("showingLocalActivation = true"))
        XCTAssertFalse(onboarding.contains("let firstReview = !privacyReviewed && !consents.isEnabled"))
    }
}
#endif
