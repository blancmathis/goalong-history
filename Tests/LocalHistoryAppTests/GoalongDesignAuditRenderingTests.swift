#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Opt-in full-page design audit: renders every destination and Settings pane in a tall
/// window so the whole scroll content is visible. Isolated home only; never starts capture.
/// `scripts/verify_design_audit.sh [output]`
final class GoalongDesignAuditRenderingTests: XCTestCase {
    @MainActor func testRenderEveryPage() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["GOALONG_DESIGN_AUDIT"],
              let home = environment["GOALONG_BRAND_TEST_HOME"] else {
            throw XCTSkip("Opt-in design audit; use scripts/verify_design_audit.sh")
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
        let config = ConfigManager()
        let permissions = PermissionManager()
        let health = CaptureHealthStore(permissions: permissions)
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/design-audit"),
            performInitialDiscovery: false, sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions,
            configManager: config, sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "design-audit", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        model.showWelcome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 1500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let only = environment["GOALONG_DESIGN_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        func render(_ name: String, _ view: some View, size: NSSize = NSSize(width: 1240, height: 1500)) throws {
            if let only, !only.contains(where: { name.hasPrefix($0) }) { return }
            let host = NSHostingController(rootView: view)
            window.contentViewController = host
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            pump(); pump()
            try snapshot(host.view, to: output.appendingPathComponent("\(name).png"))
        }
        func dashboard() -> some View { LocalHistoryDashboardView(model: model) }
        func sheet(_ content: some View) -> some View {
            content.background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
                .tint(LHTheme.accent).accentColor(LHTheme.accent).goalongControls()
        }

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            let sections: [DashboardSection] = [.overview, .work, .history, .monitoring, .activity, .screenTime,
                                                .agentActivity, .chatGPTRecap, .share, .privacy, .cli]
            for section in sections {
                model.selectedSection = section
                try render("page-\(section.rawValue)-\(suffix)", dashboard())
            }
            model.selectedSection = .settings
            for pane in [SettingsPane.home] + SettingsPane.primary + [.advanced, .tools, .connections] {
                model.settingsPane = pane
                try render("settings-\(pane)-\(suffix)", dashboard())
            }
            model.settingsPane = .home
            // Saved definition state of Mon travail.
            try JevWorkContextStore.shared.save("Goalong : app macOS et site. Atlas : préparer le lancement.",
                applications: "Xcode et GitHub pour Goalong. T3 Code pour coder avec les agents.",
                content: "Documentation Swift, e-mails clients, rédaction de posts Goalong.",
                procrastination: "rekordbox, x.com, youtube.com")
            model.selectedSection = .work
            try render("page-work-saved-\(suffix)", dashboard())
            try JevWorkContextStore.shared.save("")
            try render("sheet-jev-connection-\(suffix)", sheet(JevConnectionSheet()), size: NSSize(width: 560, height: 420))
            try render("sheet-retention-\(suffix)", sheet(HistoryRetentionSettingsSheet()), size: NSSize(width: 700, height: 670))
            try render("sheet-sharing-\(suffix)", sheet(GoalongWebsiteSharingSheet()), size: NSSize(width: 740, height: 900))
            for tab in 0...2 {
                try render("sheet-analysis-\(tab)-\(suffix)", sheet(GoalongAnalysisSelectionSheet(
                    model: model, selection: GoalongAnalysisSelection.load(), initialTab: tab) { _ in }),
                    size: NSSize(width: 940, height: 900))
            }
        }
        // A sheet presented by the real dashboard must inherit Goalong control chrome.
        if only == nil || only!.contains("presented") {
            app.appearance = NSAppearance(named: .darkAqua); window.appearance = app.appearance
            model.selectedSection = .overview
            let host = NSHostingController(rootView: dashboard())
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1240, height: 900)); pump()
            model.showingWebsiteShare = true; pump(); pump()
            if let sheet = window.attachedSheet, let view = sheet.contentView {
                try snapshot(view, to: output.appendingPathComponent("presented-sharing-dark.png"))
            } else { XCTFail("Sharing sheet was not presented") }
            model.showingWebsiteShare = false; pump()
        }
        print("DESIGN_AUDIT rendered into \(output.path)")
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
        print("NATIVE_RENDER \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
#endif
