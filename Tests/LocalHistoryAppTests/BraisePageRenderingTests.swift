#if os(macOS)
import AppKit
import BraiseCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Opt-in production-view renders with synthetic settings and a gamma driver that never touches displays.
final class BraisePageRenderingTests: XCTestCase {
    @MainActor func testRenderPanelAndEditor() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_BRAISE_SNAPSHOTS"] else { throw XCTSkip("Opt-in Braise render") }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/private/tmp/goalong-braise-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BraiseStore(directory: root, legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false,
                                             clock: { Date(timeIntervalSince1970: 1_790_000_000) })
        defer { controller.shutdown() }
        controller.setMode(.on)
        try controller.saveRule(ScheduleRule(weekdays: Set(2...6), startMinute: 21 * 60, endMinute: 7 * 60))
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        func render(_ name: String, _ view: some View, width: CGFloat, height: CGFloat) throws {
            let host = NSHostingController(rootView: view.frame(width: width, height: height).goalongControls()
                .environment(\.goalongReduceMotion, true))
            window.contentViewController = host; window.setContentSize(NSSize(width: width, height: height))
            window.makeKeyAndOrderFront(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
            let image = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: image)
            let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(bytes.count, 4000); try bytes.write(to: output.appendingPathComponent(name + ".png"))
        }
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            try render("braise-page-" + suffix, BraisePageContent(controller: controller), width: 900, height: 1050)
            try render("braise-panel-" + suffix, BraisePageContent(controller: controller, compact: true), width: 480, height: 680)
            try render("braise-rule-" + suffix, BraiseRuleEditor(controller: controller, initial: controller.preferences.rules[0]), width: 650, height: 400)
        }
    }
}
#endif
