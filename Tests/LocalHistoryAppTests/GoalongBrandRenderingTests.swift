#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Opt-in native rendering. Refuses to construct any model outside an isolated home.
/// Never starts AppDelegate, capture, login items or external source discovery.
final class GoalongBrandRenderingTests: XCTestCase {
    @MainActor func testRenderIsolatedScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["GOALONG_BRAND_SNAPSHOTS"],
              let home = environment["GOALONG_BRAND_TEST_HOME"] else {
            throw XCTSkip("Opt-in native UI audit; use scripts/verify_brand_ui.sh")
        }
        guard home.hasPrefix("/tmp/goalong-brand-"),
              FileManager.default.homeDirectoryForCurrentUser.path == home,
              AppPaths.applicationSupportDirectory.path.hasPrefix(home + "/") else {
            XCTFail("Refusing to render against a real user home"); return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // Activate this test process's own accessibility tree. This does not grant
        // macOS permissions or access any other application's UI.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let config = ConfigManager()
        let permissions = PermissionManager()
        let health = CaptureHealthStore(permissions: permissions)
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/brand-preview"),
            performInitialDiscovery: false, sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions,
            configManager: config, sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "design-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        model.showWelcome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 790),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Goalong — isolated design verification"
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let scenarios: [(String, DashboardSection)] = [
            ("today", .overview), ("history", .history), ("settings", .settings),
            ("privacy", .privacy), ("cli", .cli), ("sources", .agentActivity)
        ]
        for dark in [true, false] {
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            app.appearance = NSAppearance(named: appearance)
            window.appearance = app.appearance
            for (name, section) in scenarios {
                model.selectedSection = section
                let controller = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
                window.contentViewController = controller
                let host = controller.view
                window.setContentSize(NSSize(width: 1240, height: 790))
                window.makeKeyAndOrderFront(nil)
                pump()
                try snapshot(host, to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        app.appearance = NSAppearance(named: .darkAqua)
        window.appearance = app.appearance
        model.selectedSection = .settings
        let controller = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
        window.contentViewController = controller
        let host = controller.view
        for size in [NSSize(width: 1080, height: 680), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size); pump()
            try snapshot(host, to: output.appendingPathComponent("settings-dark-\(Int(size.width)).png"))
        }
        window.setContentSize(NSSize(width: 1080, height: 680)); pump()
        app.appearance = NSAppearance(named: .aqua); window.appearance = app.appearance; pump()
        try snapshot(host, to: output.appendingPathComponent("settings-light-1080.png"))
        app.appearance = NSAppearance(named: .darkAqua)
        window.appearance = app.appearance
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        let contrastController = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
        window.contentViewController = contrastController; pump()
        try snapshot(contrastController.view, to: output.appendingPathComponent("settings-increased-contrast.png"))
        window.appearance = app.appearance
        window.contentViewController = controller; pump()
        for pane in SettingsPane.primary {
            model.selectedSection = .settings
            model.settingsPane = pane
            let page = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
            window.contentViewController = page
            for size in [NSSize(width: 900, height: 620), NSSize(width: 1240, height: 790)] {
                window.setContentSize(size); pump()
                try snapshot(page.view, to: output.appendingPathComponent("simple-\(pane)-\(Int(size.width)).png"))
                XCTAssertGreaterThanOrEqual(page.view.bounds.width, 900)
            }
        }
        model.settingsPane = .home
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1080, height: 680)); pump()
        // Exercise actual native accessibility actions, not just the underlying callbacks.
        for (identifier, destination) in [("settings-recording", SettingsPane.recording),
                                         ("settings-website", .website), ("settings-chatGPT", .chatGPT)] {
            model.selectSection(.settings); pump()
            let control = try XCTUnwrap(accessibleElement(identifier, within: window), identifier)
            let frame = control.accessibilityFrame()
            XCTAssertGreaterThanOrEqual(frame.width, 400, "Primary card needs a large clickable area")
            XCTAssertGreaterThanOrEqual(frame.height, 88)
            XCTAssertTrue(control.accessibilityPerformPress(), "The real native card must respond")
            pump()
            XCTAssertEqual(model.settingsPane, destination, "Cards must navigate to distinct functional pages")
            let back = try XCTUnwrap(accessibleElement("settings-back", within: window))
            XCTAssertTrue(back.accessibilityPerformPress()); pump()
            XCTAssertEqual(model.settingsPane, .home)
        }
        print("NATIVE_ACTIONS three primary cards and their back buttons passed")
        // First presentation must receive its action's date, not a stale optional
        // value captured before SwiftUI invalidated the parent view.
        let selectedDate = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 2))!
        model.selectDay(selectedDate)
        model.settingsPane = .website
        pump()
        let chooseDate = try XCTUnwrap(accessibleElement("website-open-selected-day", within: window))
        XCTAssertTrue(chooseDate.accessibilityPerformPress())
        pump(); pump()
        let shareSheet = try XCTUnwrap(window.attachedSheet)
        let dateControl = try XCTUnwrap(accessibleElement("sharing-selected-date", within: shareSheet))
        let nativeDate = try XCTUnwrap(dateControl.value("accessibilityValue") as? Date,
            "Date picker must expose the actual selected date")
        XCTAssertTrue(Calendar.current.isDate(nativeDate, inSameDayAs: selectedDate))
        XCTAssertTrue(try XCTUnwrap(accessibleElement("sharing-close", within: shareSheet)).accessibilityPerformPress())
        pump()
        XCTAssertNil(window.attachedSheet)
        // Each first-click shortcut owns its payload, including after a previous editor closes.
        for (action, title) in [("analysis-open-replacements", "analysis-replacements-title"),
                                ("analysis-open-guidance", "analysis-guidance-title")] {
            model.settingsPane = .chatGPT
            pump()
            XCTAssertTrue(try XCTUnwrap(accessibleElement(action, within: window)).accessibilityPerformPress())
            pump(); pump()
            let editor = try XCTUnwrap(window.attachedSheet)
            XCTAssertNotNil(accessibleElement(title, within: editor), "Correct tab must open immediately")
            XCTAssertTrue(try XCTUnwrap(accessibleElement("analysis-cancel", within: editor)).accessibilityPerformPress())
            pump()
            XCTAssertNil(window.attachedSheet)
        }
        model.settingsPane = .home
        model.selectDay(Date())
        pump()
        print("NATIVE_ACTIONS selected-day sheet and direct ChatGPT tabs passed")

        let consentBeforePause = GoalongCapabilityConsentStore.shared.document
        try GoalongGlobalPause.setPaused(true, recordingWasPaused: false)
        pump()
        try snapshot(host, to: output.appendingPathComponent("global-pause-dark.png"))
        XCTAssertEqual(GoalongCapabilityConsentStore.shared.document, consentBeforePause)
        try GoalongGlobalPause.setPaused(false)
        pump()
        XCTAssertEqual(GoalongCapabilityConsentStore.shared.document, consentBeforePause)
        var granular = GoalongAnalysisSelection()
        granular.computer = true
        var fine = GoalongAnalysisScope()
        fine.applicationIDs = ["com.apple.Safari", "com.apple.Notes"]
        fine.detailApplicationIDs = ["com.apple.Safari"]
        fine.applicationNames = ["com.apple.Safari": "Safari", "com.apple.Notes": "Notes"]
        fine.windowTitles = true; fine.websiteDomains = true
        granular.scope = fine
        granular.replacements = [GoalongTextReplacement(search: "Hi Charlie", replacement: "Projet A")]
        granular.outputGuidance = "Concentre-toi sur les progrès des projets. Ne cite pas les noms de personnes."
        for tab in 0...2 {
            let editor = NSHostingController(rootView: GoalongAnalysisSelectionSheet(model: model, selection: granular, initialTab: tab) { _ in
                XCTFail("Rendering cannot authorize an analysis")
            })
            window.contentViewController = editor
            window.setContentSize(NSSize(width: 940, height: 740)); pump()
            try snapshot(editor.view, to: output.appendingPathComponent("analysis-editor-tab-\(tab).png"))
        }
        let syntheticPreview = """
        {"applications_sur_ce_Mac":[{"application":"Projet A","secondes_actives":3600}],"details_autorises":[{"application":"Safari","titre":"Projet A — Documentation","site":"example.org"}]}
        """
        let filteredPreview = NSHostingController(rootView: ScrollView { GoalongAnalysisHumanPreview(text: syntheticPreview).padding(24) })
        window.contentViewController = filteredPreview; window.setContentSize(NSSize(width: 900, height: 620)); pump()
        try snapshot(filteredPreview.view, to: output.appendingPathComponent("analysis-filtered-preview.png"))
        model.settingsPane = .home
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1080, height: 680)); pump()
        // Exercise the existing transaction layer without claiming physical button activation.
        let originalClicks = model.settingsDraft.captureClicks
        model.settingsDraft.captureClicks.toggle(); pump()
        XCTAssertTrue(model.settingsHaveChanges)
        try snapshot(host, to: output.appendingPathComponent("settings-unsaved-dark-1080.png"))
        model.discardSettingsChanges(); pump()
        XCTAssertFalse(model.settingsHaveChanges)
        XCTAssertEqual(model.settingsDraft.captureClicks, originalClicks)
        model.settingsDraft.captureClicks.toggle()
        model.saveSettings(showConfirmation: false); pump()
        XCTAssertFalse(model.settingsHaveChanges)
        XCTAssertEqual(config.config.captureClicks, !originalClicks)
        model.settingsDraft.captureClicks = originalClicks
        model.saveSettings(showConfirmation: false); pump()
        XCTAssertEqual(config.config.captureClicks, originalClicks)
        model.selectSection(.history)
        XCTAssertEqual(model.selectedSection, .history)
        model.selectSection(.overview)
        XCTAssertEqual(model.selectedSection, .overview)
        UserDefaults.standard.set(true, forKey: "goalongOnboardingPrivacyReviewedV1")
        for setupStep in SetupStep.allCases {
            let step = setupStep.rawValue
            UserDefaults.standard.set(step, forKey: "goalongOnboardingStep")
            let onboarding = NSHostingController(rootView: LocalHistoryOnboardingView(model: model)
                .foregroundStyle(LHTheme.text).tint(LHTheme.accent).accentColor(LHTheme.accent)
                .frame(width: 1080, height: 680))
            window.contentViewController = onboarding
            window.setContentSize(NSSize(width: 1080, height: 680)); pump()
            XCTAssertEqual(onboarding.view.bounds.width, 1080)
            XCTAssertEqual(onboarding.view.bounds.height, 680)
            try snapshot(onboarding.view, to: output.appendingPathComponent("onboarding-step-\(step)-dark-1080.png"))
        }
        model.alert = nil
        model.showWelcome = false
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            model.openRecordingSettings()
            let recording = NSHostingController(rootView: LocalHistoryDashboardView(model: model)
                .environment(\.sourceAccessCheck, { _, done in done(.fullDiskAccess) }))
            window.contentViewController = recording
            window.setContentSize(NSSize(width: 1080, height: 680)); pump()
            try snapshot(recording.view, to: output.appendingPathComponent("journey-recording-\(dark ? "dark" : "light").png"))
            let retention = NSHostingController(rootView: HistoryRetentionSettingsSheet())
            window.contentViewController = retention
            window.setContentSize(NSSize(width: 700, height: 670)); pump()
            try snapshot(retention.view, to: output.appendingPathComponent("journey-retention-\(dark ? "dark" : "light").png"))
            let sharing = NSHostingController(rootView: GoalongWebsiteSharingSheet())
            window.contentViewController = sharing
            window.setContentSize(NSSize(width: 740, height: 720)); pump()
            try snapshot(sharing.view, to: output.appendingPathComponent("journey-sharing-\(dark ? "dark" : "light").png"))
        }
        // Deterministic denied-access recovery; never probes real macOS permissions.
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            for (name, capability, status): (String, GoalongCapability, SourceAccessStatus) in [
                ("computer", .localComputerHistory, .accessibility),
                ("screen-time", .appleScreenTime, .fullDiskAccess)
            ] {
                let recovery = NSHostingController(rootView: SourceActivationSheet(
                    capability: capability, surface: .settings,
                    prepare: { XCTFail("Denied preview must never prepare recording") },
                    check: { _, done in done(status) }))
                window.contentViewController = recovery
                window.setContentSize(NSSize(width: 620, height: 690)); pump()
                try snapshot(recovery.view, to: output.appendingPathComponent("permission-recovery-\(name)-\(dark ? "dark" : "light").png"))
                for (phase, initial): (String, SourceAccessStatus) in [("ready", .ready), ("restart", status)] {
                    let resumed = NSHostingController(rootView: SourceActivationSheet(
                        capability: capability, surface: .settings,
                        prepare: { XCTFail("Preview must never prepare recording") },
                        check: { _, done in done(initial) }, initialStatus: initial, resumingAfterRestart: true))
                    window.contentViewController = resumed
                    window.setContentSize(NSSize(width: 620, height: 690)); pump()
                    try snapshot(resumed.view, to: output.appendingPathComponent("permission-\(phase)-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        // Exercise the real first-activation gate with mock OS permission, never
        // with the user's recorder, protected sources, or external services.
        do {
            let defaults = UserDefaults.standard
            let keys = [GoalongRecordingSetup.reviewedKey, GoalongRecordingSetup.preparedKey,
                        GoalongRecordingSetup.explicitChoicesKey, "goalongOnboardingPrivacyReviewedV1",
                        ActivityAnalysisPreferences.richContextEnabledKey]
            let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
            let originalDraft = model.appliedSettings
            let originalLocalConsent = GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory)
            let originalRemoteConsent = GoalongCapabilityConsentStore.shared.document.consent(for: .chatGPTAnalysis)
            defer {
                _ = model.applyRecordingChoice(originalDraft)
                _ = GoalongCapabilityConsentStore.shared.set(.localComputerHistory, enabled: originalLocalConsent, surface: .settings)
                for key in keys {
                    if let value = previousDefaults[key] ?? nil { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
                _ = defaults.synchronize()
            }
            _ = GoalongCapabilityConsentStore.shared.set(.localComputerHistory, enabled: false, surface: .settings)
            model.settingsDraft = DashboardSettingsDraft(config: .default)
            model.saveSettings(showConfirmation: false)
            model.alert = nil
            for key in keys { defaults.removeObject(forKey: key) }
            defaults.set(false, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
            model.showWelcome = false; model.selectSection(.settings); model.settingsPane = .recording
            let recordingHost = NSHostingController(rootView: LocalHistoryDashboardView(model: model)
                .environment(\.sourceAccessCheck, { _, done in done(.ready) }))
            window.contentViewController = recordingHost
            window.setContentSize(NSSize(width: 1080, height: 790)); pump(); pump()
            XCTAssertTrue(try XCTUnwrap(accessibleElement("source-localComputerHistory", within: window)).accessibilityPerformPress())
            pump(); pump()
            let first = try XCTUnwrap(window.attachedSheet, "First activation must review data before enabling")
            pump(); pump()
            for signal in RecordingSignal.allCases {
                let node = try XCTUnwrap(accessibleElement("recording-\(signal.rawValue)", within: first))
                XCTAssertEqual((node.value("accessibilityValue") as? NSNumber)?.boolValue, true, signal.title)
            }
            let visible = try XCTUnwrap(accessibleElement("recording-visible-text-draft", within: first))
            XCTAssertEqual((visible.value("accessibilityValue") as? NSNumber)?.boolValue, true)
            XCTAssertFalse(config.config.captureClicks)
            XCTAssertFalse(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            try snapshot(first.contentView!, to: output.appendingPathComponent("recording-first-activation-all-on.png"))
            XCTAssertTrue(try XCTUnwrap(accessibleElement("recording-setup-cancel", within: first)).accessibilityPerformPress())
            pump(); pump()
            XCTAssertFalse(config.config.captureClicks)
            XCTAssertFalse(GoalongRecordingSetup.hasReviewedChoices())
            XCTAssertFalse(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            XCTAssertTrue(try XCTUnwrap(accessibleElement("source-localComputerHistory", within: window)).accessibilityPerformPress())
            pump(); pump()
            let accepted = try XCTUnwrap(window.attachedSheet)
            XCTAssertTrue(try XCTUnwrap(accessibleElement("recording-clicks", within: accepted)).accessibilityPerformPress())
            XCTAssertTrue(try XCTUnwrap(accessibleElement("recording-setup-confirm", within: accepted)).accessibilityPerformPress())
            pump(); pump(); pump()
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(config.config.captureClicks, "Explicitly unchecked click capture must remain off")
            for signal in RecordingSignal.allCases where signal != .clicks {
                XCTAssertTrue(model.appliedSettings[keyPath: signal.keyPath], signal.title)
            }
            XCTAssertTrue(ActivityAnalysisPreferences.richContextEnabled)
            XCTAssertTrue(GoalongRecordingSetup.hasReviewedChoices())
            XCTAssertTrue(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            XCTAssertEqual(GoalongCapabilityConsentStore.shared.document.consent(for: .chatGPTAnalysis), originalRemoteConsent)
            try snapshot(recordingHost.view, to: output.appendingPathComponent("recording-opt-out-preserved.png"))
            // Off/on resumes the accepted selection without reverting to a preset.
            XCTAssertTrue(try XCTUnwrap(accessibleElement("source-localComputerHistory", within: window)).accessibilityPerformPress())
            pump()
            XCTAssertFalse(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            XCTAssertTrue(try XCTUnwrap(accessibleElement("source-localComputerHistory", within: window)).accessibilityPerformPress())
            pump(); pump()
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            XCTAssertFalse(config.config.captureClicks)
            XCTAssertTrue(config.config.captureScroll)
            XCTAssertFalse(ConfigManager().config.captureClicks, "Fresh model reads the accepted opt-out from disk")
            print("NATIVE_RECORDING complete first proposal, cancellation, real save and off/on persistence passed")
        }
        if environment["GOALONG_JOURNEY_INTERACTIVE"] == "1" {
            app.setActivationPolicy(.regular)
            window.title = "Goalong Journey QA — synthetic data only"
            UserDefaults.standard.set(0, forKey: "goalongOnboardingStep")
            model.alert = nil; model.showWelcome = true
            let interactive = NSHostingController(rootView: LocalHistoryDashboardView(model: model)
                .environment(\.sourceAccessCheck, { _, done in done(.fullDiskAccess) }))
            window.contentViewController = interactive
            window.setContentSize(NSSize(width: 1080, height: 740))
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            print("JOURNEY_INTERACTIVE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
            let finishFile = output.appendingPathComponent("finish-interactive")
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline && !FileManager.default.fileExists(atPath: finishFile.path) { pump() }
            try snapshot(interactive.view, to: output.appendingPathComponent("journey-interactive-final.png"))
        }
        let count = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".png") }.count
        try String("\(count) actual native-view renders, isolated home, empty stores and disabled sources.\nModel save/discard and section selection assertions passed.\nPhysical interaction results are reported separately; this render count is not a user-testing claim.\n").write(to: output.appendingPathComponent("runtime-results.txt"), atomically: true, encoding: .utf8)

    }

    /// Real navigation, connection and break actions against a disposable home only.
    @MainActor func testRenderAndExerciseIsolatedMonitoring() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["GOALONG_BRAND_SNAPSHOTS"],
              let home = environment["GOALONG_BRAND_TEST_HOME"] else {
            throw XCTSkip("Opt-in native UI audit; use scripts/verify_brand_ui.sh")
        }
        guard home.hasPrefix("/tmp/goalong-brand-"),
              FileManager.default.homeDirectoryForCurrentUser.path == home,
              AppPaths.applicationSupportDirectory.path.hasPrefix(home + "/") else {
            XCTFail("Refusing to exercise monitoring against a real user home"); return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let config = ConfigManager()
        let permissions = PermissionManager()
        let health = CaptureHealthStore(permissions: permissions)
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/monitoring-preview"),
            performInitialDiscovery: false, sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions,
            configManager: config, sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "monitoring-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        model.showWelcome = false
        let monitor = JevMonitor.shared
        let consents = GoalongCapabilityConsentStore.shared
        let originalHistory = consents.isEnabled(.localComputerHistory)
        XCTAssertFalse(monitor.enabled)
        XCTAssertFalse(monitor.hasKey)
        _ = consents.set(.localComputerHistory, enabled: false, surface: .settings)
        defer {
            monitor.endBreak(); monitor.removeKey()
            _ = consents.set(.localComputerHistory, enabled: originalHistory, surface: .settings)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Goalong — isolated monitoring verification"
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let controller = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil); pump()
        let sidebar = try XCTUnwrap(accessibleElement("sidebar-monitoring", within: window))
        XCTAssertGreaterThanOrEqual(sidebar.accessibilityFrame().height, 44)
        XCTAssertTrue(sidebar.accessibilityPerformPress()); pump()
        XCTAssertEqual(model.selectedSection, .monitoring)
        let offState = consents.document
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            for size in [NSSize(width: 900, height: 620), NSSize(width: 1240, height: 790)] {
                window.setContentSize(size); pump()
                let connect = try XCTUnwrap(accessibleElement("jev-open-connection", within: window))
                XCTAssertGreaterThan(connect.accessibilityFrame().width, 70)
                XCTAssertNotNil(accessibleElement("jev-enabled", within: window))
                XCTAssertNotNil(accessibleElement("jev-break-10", within: window))
                try snapshot(controller.view, to: output.appendingPathComponent("monitoring-setup-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
            }
        }
        XCTAssertEqual(consents.document, offState, "Opening or rendering the page must not grant consent")
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-open-recording", within: window)).accessibilityPerformPress())
        pump()
        XCTAssertEqual(model.selectedSection, .settings)
        XCTAssertEqual(model.settingsPane, .recording)
        XCTAssertTrue(try XCTUnwrap(accessibleElement("sidebar-monitoring", within: window)).accessibilityPerformPress())
        pump()
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-open-connection", within: window)).accessibilityPerformPress())
        pump(); pump()
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNotNil(accessibleElement("jev-api-key", within: sheet))
        try snapshot(try XCTUnwrap(sheet.contentView), to: output.appendingPathComponent("monitoring-connection-sheet.png"))
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-connection-close", within: sheet)).accessibilityPerformPress())
        pump(); pump()
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(consents.document, offState)
        XCTAssertFalse(monitor.hasKey)

        // Simulated setup cannot send a request: the separate Jev consent stays off.
        monitor.saveKey("synthetic-monitoring-render-key")
        XCTAssertTrue(monitor.hasKey)
        XCTAssertFalse(monitor.enabled)
        _ = consents.set(.localComputerHistory, enabled: true, surface: .settings)
        let readyState = consents.document
        window.setContentSize(NSSize(width: 900, height: 620))
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance; pump()
            try snapshot(controller.view, to: output.appendingPathComponent("monitoring-ready-\(dark ? "dark" : "light")-900.png"))
        }
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-break-10", within: window)).accessibilityPerformPress())
        pump()
        XCTAssertNotNil(monitor.timedBreak)
        XCTAssertGreaterThan(monitor.remainingSeconds, 590)
        XCTAssertEqual(consents.document, readyState)
        XCTAssertNotNil(accessibleElement("jev-break-countdown", within: window))
        try snapshot(controller.view, to: output.appendingPathComponent("monitoring-timed-break-900.png"))
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-end-break", within: window)).accessibilityPerformPress())
        pump()
        XCTAssertNil(monitor.timedBreak)
        XCTAssertFalse(monitor.enabled)
        XCTAssertEqual(consents.document, readyState, "Ending a break must not activate Jev or a source")
        let preferences = JevInterventionPreferences.shared
        let originalInterventions = preferences.settings
        defer { preferences.update { $0 = originalInterventions } }
        let interventionHost = NSHostingController(rootView: ScrollView {
            JevInterventionControls().padding(28)
        }.background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent))
        window.contentViewController = interventionHost
        window.setContentSize(NSSize(width: 700, height: 800)); pump()
        XCTAssertFalse(preferences.settings.effectsEnabled)
        let effectToggle = try XCTUnwrap(accessibleElement("jev-effects-enabled", within: window))
        // NSSwitch can report false from AXPress while applying the action. Assert
        // the real state and its persistence, not that unreliable return value.
        _ = effectToggle.accessibilityPerformPress(); pump()
        XCTAssertTrue(preferences.settings.effectsEnabled)
        XCTAssertTrue(JevInterventionPreferences().settings.effectsEnabled)
        XCTAssertEqual(consents.document, readyState, "Configuring effects must never authorize monitoring or stop recording")
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance; pump()
            try snapshot(interventionHost.view, to: output.appendingPathComponent("monitoring-interventions-\(dark ? "dark" : "light").png"))
        }
        _ = try XCTUnwrap(accessibleElement("jev-effects-enabled", within: window)).accessibilityPerformPress(); pump()
        XCTAssertFalse(preferences.settings.effectsEnabled)
        XCTAssertFalse(JevInterventionPreferences().settings.effectsEnabled)
        // Render the actual panel, not a dashboard window carrying old minimum-size constraints.
        // Keep this synthetic warning offscreen; never show effects on the owner's displays.
        var reminderDismissals = 0
        let presenter = JevWarningPanel(ordersWindows: false, onDismiss: { reminderDismissals += 1 })
        defer { presenter.hide() }
        presenter.update(seconds: 30, appearance: 1, present: true, settings: .init())
        let warningWindow = try XCTUnwrap(presenter.panel)
        XCTAssertEqual(warningWindow.frame.size, NSSize(width: 400, height: 156))
        warningWindow.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        warningWindow.orderFrontRegardless(); pump()
        XCTAssertEqual(warningWindow.frame.size, NSSize(width: 400, height: 156), "SwiftUI must not expand the alert after presentation")
        XCTAssertEqual(warningWindow.contentView?.bounds.size, NSSize(width: 400, height: 156))
        XCTAssertNotNil(accessibleElement("jev-warning-close", within: warningWindow))
        XCTAssertNil(accessibleElement("jev-warning-disable", within: warningWindow))
        XCTAssertNil(accessibleElement("jev-warning-pause", within: warningWindow))
        try snapshot(try XCTUnwrap(warningWindow.contentView), to: output.appendingPathComponent("monitoring-warning-30s.png"))
        presenter.update(seconds: 315, appearance: 1, present: false, settings: .init()); pump()
        XCTAssertEqual(warningWindow.frame.size, NSSize(width: 400, height: 156), "Duration updates cannot resize the alert")
        XCTAssertEqual(warningWindow.contentView?.bounds.size, NSSize(width: 400, height: 156))
        try snapshot(try XCTUnwrap(warningWindow.contentView), to: output.appendingPathComponent("monitoring-warning-5min.png"))
        XCTAssertTrue(presenter.overlays.isEmpty)
        XCTAssertTrue(try XCTUnwrap(accessibleElement("jev-warning-close", within: warningWindow)).accessibilityPerformPress())
        pump()
        XCTAssertNil(presenter.panel)
        XCTAssertEqual(reminderDismissals, 1, "The sole popup button invokes Close")
        XCTAssertEqual(preferences.settings.stages.map(\.afterMinutes), [2, 5])
        XCTAssertEqual(preferences.settings.stages[1].effect, .dimAndRed)
        XCTAssertEqual(consents.document, readyState)
        print("NATIVE_INTERVENTIONS real effect toggle, preferences, warning controls and unchanged consents passed; no screen overlay or API request enabled")
        print("NATIVE_MONITORING sidebar, recording shortcut, protected connection sheet, timed pause and unchanged consents passed; no monitoring request enabled")
    }

    /// SwiftUI's accessibility proxy objects implement the Objective-C selectors
    /// without necessarily advertising conformance to NSAccessibilityProtocol.
    private struct NativeAccessibilityNode {
        let object: NSObject
        func value(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        func accessibilityFrame() -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return .zero }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
            return unsafeBitCast(method, to: Getter.self)(object, selector)
        }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    @MainActor private func accessibleElement(_ identifier: String, within root: Any) -> NativeAccessibilityNode? {
        var pending: [Any] = [root], seen = Set<ObjectIdentifier>(), visited = 0
        while let value = pending.popLast(), visited < 10_000 {
            guard let object = value as? NSObject else { continue }
            let identity = ObjectIdentifier(object)
            guard seen.insert(identity).inserted else { continue }
            visited += 1
            let node = NativeAccessibilityNode(object: object)
            if node.value("accessibilityIdentifier") as? String == identifier { return node }
            pending.append(contentsOf: node.value("accessibilityChildren") as? [Any] ?? [])
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if let window = object as? NSWindow, let view = window.contentView { pending.append(view) }
        }
        print("Native control not found: \(identifier); inspected \(visited) native nodes")
        return nil
    }

    @MainActor private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }
    @MainActor private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 5000, "Unexpectedly empty native render")
        print("NATIVE_RENDER \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
#endif
