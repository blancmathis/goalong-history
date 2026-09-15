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
        model.saveSettings(); pump()
        XCTAssertFalse(model.settingsHaveChanges)
        XCTAssertEqual(config.config.captureClicks, !originalClicks)
        model.settingsDraft.captureClicks = originalClicks
        model.saveSettings(); pump()
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
