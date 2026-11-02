#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// R282-1 (T-043 R4a): in the version without sign-in, a switch that is ON must stay usable so the member can
/// withdraw consent. The real view is hosted off screen (alpha 0, never ordered front) and its accessibility
/// tree says whether each switch is enabled.
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
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["R282_PNG_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chatgpt-consentement.png"))
        }
        // The switches sit at the trailing edge; a track is a solid run of 25+ pixels, thinner than any glyph there.
        let usable = solidRows(rep, near: (0x0D, 0x10, 0x0E)), locked = solidRows(rep, near: (0x56, 0x62, 0x52))
        XCTAssertGreaterThan(usable, 10, "R282-1: the consent switch is ON; its track must be full ink, usable to withdraw (usable \(usable), locked \(locked))")
        XCTAssertEqual(locked, 0, "R282-1: the ON consent switch is drawn locked (usable \(usable), locked \(locked))")
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

    private func text(_ object: NSObject) -> String {
        guard let raw = value(object, "accessibilityValue") else { return "nil" }
        return "\(raw)"
    }

    private func value(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }

    @MainActor private func find(_ identifier: String, in view: NSView) -> NSObject? {
        var pending: [Any] = [view], seen = Set<ObjectIdentifier>(), visited = 0
        while let item = pending.popLast(), visited < 10_000 {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            visited += 1
            if value(object, "accessibilityIdentifier") as? String == identifier { return object }
            pending.append(contentsOf: value(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return nil
    }
}
#endif
