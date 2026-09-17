#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class GoalongMotionRenderingTests: XCTestCase {
    @MainActor final class Fixture: ObservableObject {
        @Published var active = true
        @Published var reduced = false
    }
    private struct LiveMarks: View {
        @ObservedObject var fixture: Fixture
        var body: some View {
            HStack(spacing: 40) {
                ForEach([24.0, 32.0, 48.0], id: \.self) { size in
                    GoalongActivityMark(isActive: fixture.active, width: size)
                }
            }
            .frame(width: 380, height: 180)
            .background(LHTheme.cardBackground)
            .environment(\.accessibilityReduceMotion, fixture.reduced)
        }
    }
    @MainActor func testLiveActivityReleaseAndReducedMotion() throws {
        guard let output = ProcessInfo.processInfo.environment["GOALONG_MOTION_SNAPSHOTS"] else {
            throw XCTSkip("Set GOALONG_MOTION_SNAPSHOTS for an isolated native window")
        }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 380, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let fixture = Fixture()
        let host = NSHostingController(rootView: LiveMarks(fixture: fixture))
        window.contentViewController = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func pixels(_ name: String) throws -> Data {
            let view = host.view
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(name + ".png"))
            let pointer = try XCTUnwrap(bitmap.bitmapData)
            return Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        wait(0.7)
        let activeA = try pixels("native-active-a")
        wait(0.4)
        let activeB = try pixels("native-active-b")
        XCTAssertNotEqual(activeA, activeB, "A visible native activity must actually move")
        fixture.active = false
        wait(0.5)
        let restA = try pixels("native-rest-dark")
        wait(0.4)
        XCTAssertEqual(restA, try pixels("native-rest-dark-stable"))
        fixture.reduced = true; fixture.active = true
        wait(0.4)
        let reduced = try pixels("native-reduced-dark")
        wait(0.4)
        XCTAssertEqual(reduced, try pixels("native-reduced-dark-stable"))
        XCTAssertEqual(restA, reduced, "Reduced motion displays the exact resting geometry")
        window.appearance = NSAppearance(named: .aqua)
        wait(0.3)
        _ = try pixels("native-reduced-light")

        // A real SwiftUI ProgressView with a measured fraction must retain a bar.
        let progress = VStack(alignment: .leading, spacing: 24) {
            ProgressView("Lecture des analyses…")
            ProgressView(value: 0.4, total: 1) { Text("Import mesuré") } currentValueLabel: { Text("40 %") }
            Text("Aucun pourcentage n’est déduit de la phase du logo.").font(.caption)
        }
        .padding(28).frame(width: 520, height: 240)
        .foregroundStyle(LHTheme.text).background(LHTheme.pageBackground)
        .progressViewStyle(GoalongProgressViewStyle())
        .environment(\.accessibilityReduceMotion, true)
        let progressHost = NSHostingController(rootView: progress)
        window.contentViewController = progressHost
        window.setContentSize(NSSize(width: 520, height: 240))
        wait(0.3)
        let view = progressHost.view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("native-progress-semantics.png"))
    }
}
#endif
