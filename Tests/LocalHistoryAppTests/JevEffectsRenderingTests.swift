#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class JevEffectsRenderingTests: XCTestCase {
    @MainActor func testDurationBoundaryAndStrongPresetInAnIsolatedNativeWindow() throws {
        guard let output = ProcessInfo.processInfo.environment["GOALONG_JEV_EFFECTS_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in synthetic window; no production settings or screen effects")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "JevEffectsRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = JevInterventionPreferences(defaults: defaults)
        let app = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let originalAppearance = app.appearance
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 156),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Goalong · test des rappels"
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentViewController = nil
            app.appearance = originalAppearance
            app.setActivationPolicy(originalPolicy)
            previousApplication?.activate(options: [.activateIgnoringOtherApps])
        }
        let content = JevWarningContent()
        var closeCount = 0
        let warning = NSHostingController(rootView: JevWarningView(content: content, onClose: { closeCount += 1 })
            .frame(width: 400, height: 156))
        window.contentViewController = warning
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            var closeFrame: NSRect?
            for seconds in [15, 599, 600, 615] {
                content.seconds = seconds
                pump()
                let nodes = accessibilityNodes(in: warning.view)
                let close = try XCTUnwrap(nodes.first { $0.string("accessibilityIdentifier") == "jev-warning-close" })
                let duration = nodes.first { $0.string("accessibilityIdentifier") == "jev-warning-duration" }
                XCTAssertEqual(duration != nil, seconds >= 600)
                if let closeFrame {
                    XCTAssertEqual(close.frame().minY, closeFrame.minY, accuracy: 1)
                    XCTAssertEqual(close.frame().minX, closeFrame.minX, accuracy: 1)
                } else { closeFrame = close.frame() }
                if seconds == 15 || seconds == 600 {
                    try snapshot(warning.view, to: directory.appendingPathComponent("reminder-\(seconds)-\(dark ? "dark" : "light").png"))
                }
                if seconds == 615 { XCTAssertTrue(close.press()) }
            }
        }
        XCTAssertEqual(closeCount, 2)
        let controls = NSHostingController(rootView: JevInterventionControls(preferences: preferences)
            .padding(24).frame(width: 760).fixedSize(horizontal: false, vertical: true)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent))
        window.contentViewController = controls
        window.setContentSize(NSSize(width: 760, height: 1000))
        pump()
        let preset = try XCTUnwrap(accessibilityNodes(in: controls.view).first {
            $0.string("accessibilityIdentifier") == "jev-strength-veryStrong"
        })
        XCTAssertTrue(preset.press())
        pump()
        XCTAssertEqual(preferences.settings.stages.map(\.intensity), [65, 85])
        XCTAssertFalse(preferences.settings.effectsEnabled, "Choosing a stronger preset must not turn on effects")
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            pump()
            window.setContentSize(NSSize(width: 760, height: max(700, controls.view.fittingSize.height)))
            pump()
            try snapshot(controls.view, to: directory.appendingPathComponent("effects-\(dark ? "dark" : "light").png"))
        }
    }
    @MainActor private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
    @MainActor private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: url)
    }
    private struct Node {
        let object: NSObject
        func value(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        func string(_ name: String) -> String? { value(name) as? String }
        func frame() -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return .zero }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
            return unsafeBitCast(method, to: Getter.self)(object, selector)
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    @MainActor private func accessibilityNodes(in view: NSView) -> [Node] {
        var pending: [Any] = [view], seen = Set<ObjectIdentifier>(), nodes: [Node] = []
        while let item = pending.popLast(), nodes.count < 3000 {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = Node(object: object)
            nodes.append(node)
            pending.append(contentsOf: node.value("accessibilityChildren") as? [Any] ?? [])
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return nodes
    }
}
#endif
