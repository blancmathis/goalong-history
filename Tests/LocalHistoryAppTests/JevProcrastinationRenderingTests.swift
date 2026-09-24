#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class JevProcrastinationRenderingTests: XCTestCase {
    @MainActor func testRenderIsolatedCriteriaWithSyntheticData() throws {
        guard let output = ProcessInfo.processInfo.environment["GOALONG_JEV_CONTEXT_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with synthetic criteria only")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jev-context-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        for state in ["empty", "existing-work", "with-examples"] {
            let store = JevWorkContextStore(root: root.appendingPathComponent(state))
            if state != "empty" {
                try store.save("Atlas : concevoir le site de lancement.", applications: "Figma pour le design, GitHub pour les revues.",
                    content: "Documentation et rédaction liées à Atlas.",
                    procrastination: state == "with-examples" ? "Scroller le fil Pour vous de X ; comparer des achats personnels sans lien avec Atlas." : "")
            }
            for dark in [true, false] {
                app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.appearance = app.appearance
                let view = JevWorkContextControls(store: store)
                    .padding(24).frame(width: 700).fixedSize(horizontal: false, vertical: true)
                    .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                let controller = NSHostingController(rootView: view)
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 700, height: 900))
                window.makeKeyAndOrderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let host = controller.view
                let height = max(300, host.fittingSize.height)
                host.frame = NSRect(x: 0, y: 0, width: 700, height: height)
                window.setContentSize(NSSize(width: 700, height: height))
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 5000)
                let name = "criteria-\(state)-\(dark ? "dark" : "light").png"
                try data.write(to: directory.appendingPathComponent(name))
                print("JEV_CONTEXT_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }
    }
}
#endif
