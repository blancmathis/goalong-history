#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Opt-in native renders of the trust surfaces: a recording interruption, the support
/// request window and the update status. Refuses to run outside an isolated home.
final class GoalongTrustRenderingTests: XCTestCase {
    @MainActor func testRenderTrustSurfaces() throws {
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
        let config = ConfigManager()
        let permissions = PermissionManager()
        let health = CaptureHealthStore(permissions: permissions)
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/trust-preview"),
            performInitialDiscovery: false, sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions,
            configManager: config, sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "trust-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        model.showWelcome = false
        XCTAssertTrue(GoalongCapabilityConsentStore.shared.set(.localComputerHistory, enabled: true, surface: .settings))
        health.markStorageInterrupted(.diskFull, at: Date().addingTimeInterval(-600))
        model.dashboardDidBecomeVisible()
        pump()
        XCTAssertEqual(model.runtime.storageFailure, .diskFull)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 790),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, section, pane) in [("activity-storage-interrupted", DashboardSection.overview, SettingsPane.home),
                                          ("settings-home-trust", .settings, .home),
                                          ("settings-storage-trust", .settings, .storage),
                                          ("settings-advanced-trust", .settings, .advanced)] {
                model.selectedSection = section; model.settingsPane = pane
                let controller = NSHostingController(rootView: LocalHistoryDashboardView(model: model))
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 1240, height: 790))
                window.makeKeyAndOrderFront(nil); pump()
                try snapshot(controller.view, to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        let support = SupportRequestController()
        support.phase = .ready(URL(fileURLWithPath: "/tmp/Goalong-diagnostic-preview.json"), SupportFindings.detect(
            live: ["storageInterrupted": .flag(true), "storageFailure": .state(.diskFull)],
            timeline: [SupportRecord(schema: 1, revision: nil, timestamp: Date(), session: UUID(), sequence: 1,
                                     component: .app, event: .appStarted, level: .info, source: nil, line: nil,
                                     values: ["previousExitUnclean": .flag(true)])],
            storage: SupportStorage(freeMB: 740, lowSpace: true, storesMB: [:], eventDayFiles: 3, enumerationTruncated: false),
            crashes: [], diagnosticsEnabled: true), byteCount: 184_000, eventCount: 1_240)
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = NSHostingController(rootView: SupportRequestView(controller: support))
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 580, height: 660)); pump()
            try snapshot(controller.view, to: output.appendingPathComponent("support-request-\(dark ? "dark" : "light").png"))
        }
        support.phase = .preparing
        let preparing = NSHostingController(rootView: SupportRequestView(controller: support))
        window.contentViewController = preparing; pump()
        try snapshot(preparing.view, to: output.appendingPathComponent("support-request-preparing.png"))

        health.markStorageRestored()
        model.dashboardDidBecomeHidden(); model.dashboardDidBecomeVisible(); pump()
        XCTAssertNil(model.runtime.storageFailure)
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
