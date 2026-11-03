#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// R282-1 (T-043 R4a): in the version without sign-in, a switch that is ON must stay usable so the member can
/// withdraw consent. The real view is hosted off screen (alpha 0, never ordered front) and its pixels say
/// whether the ON switch is drawn usable (full ink) or locked (secondary ink): the accessibility tree does not
/// tell a greyed switch apart.
final class GoalongChatGPTSettingsRenderTests: XCTestCase {
    @MainActor private func model() throws -> DashboardViewModel {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("Dashboard tests require an isolated test HOME")
        }
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/r282-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "r282-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
    }

    @MainActor func testLockedVersionKeepsTheActiveConsentSwitchUsableInTheRenderedView() throws {
        let model = try model()
        // A reviewed selection and a stored consent: the « Autoriser » switch reads ON.
        var selection = GoalongAnalysisSelection(); selection.version = 1; selection.reviewed = true; selection.computer = true
        selection.privacyRevision = GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision
        // The secure writer refuses the symlinked /tmp ancestor of the test HOME: write the file plainly.
        let support = AppPaths.applicationSupportDirectory
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: support.appendingPathComponent("chatgpt-analysis-selection.json"))
        defer { try? FileManager.default.removeItem(at: support.appendingPathComponent("chatgpt-analysis-selection.json")) }
        GoalongCapabilityConsentStore.shared.set(.chatGPTAnalysis, enabled: true, surface: .settings)
        ChatGPTRecapRuntime.shared.setConnectionStateForTesting(.codexUnavailable)
        let wasAutomatic = ChatGPTRecapRuntime.shared.automaticRecapsEnabled
        ChatGPTRecapRuntime.shared.automaticRecapsEnabled = false
        defer {
            ChatGPTRecapRuntime.shared.automaticRecapsEnabled = wasAutomatic
            GoalongCapabilityConsentStore.shared.set(.chatGPTAnalysis, enabled: false, surface: .settings)
            ChatGPTRecapRuntime.shared.setConnectionStateForTesting(.checking)
        }
        let host = NSHostingView(rootView: GoalongChatGPTSettings(model: model).frame(width: 760, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // Appearing refreshes the account; pin the version without sign-in once the view is up.
        ChatGPTRecapRuntime.shared.setConnectionStateForTesting(.codexUnavailable)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // Pixels, not a flag: the ON track is full ink (LHTheme.text) when usable and secondary ink when locked
        // (GoalongSwitchButtonStyle). Light appearance: text 0D100E, secondary 566252.
        host.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        // A fixed 2x sRGB bitmap, not the screen's: a CI Mac without Retina gives a 1x window, where the ink
        // left of the knob is ~17 px, under the 25 px run, so neither track counted (release 41553934058).
        let rep = try render(host, scale: 2)
        if let dir = ProcessInfo.processInfo.environment["R282_PNG_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chatgpt-consentement.png"))
        }
        // The switches sit at the trailing edge; a track is a solid run of 25+ pixels, thinner than any glyph there.
        let usable = solidRows(rep, near: (0x0D, 0x10, 0x0E)), locked = solidRows(rep, near: (0x56, 0x62, 0x52))
        XCTAssertGreaterThan(usable, 10, "R282-1: the consent switch is ON; its track must be full ink, usable to withdraw (usable \(usable), locked \(locked))")
        XCTAssertEqual(locked, 0, "R282-1: the ON consent switch is drawn locked (usable \(usable), locked \(locked))")
    }

    @MainActor private func render(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        let plain = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rep = try XCTUnwrap(plain.retagging(with: .sRGB))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func solidRows(_ rep: NSBitmapImageRep, near rgb: (Int, Int, Int)) -> Int {
        var rows = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0, best = 0
            for x in max(0, rep.pixelsWide - 220)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { run = 0; continue }
                let d = abs(Int(c.redComponent * 255) - rgb.0) + abs(Int(c.greenComponent * 255) - rgb.1) + abs(Int(c.blueComponent * 255) - rgb.2)
                run = d < 24 ? run + 1 : 0
                best = max(best, run)
            }
            if best >= 25 { rows += 1 }
        }
        return rows
    }
}
#endif
