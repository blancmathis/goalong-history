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
            .environment(\.goalongReduceMotion, fixture.reduced)
        }
    }
    @MainActor func testLiveActivityReleaseAndReducedMotion() async throws {
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
        // Yield the main actor so SwiftUI .task and the display timeline can run.
        func wait(_ seconds: Double) async throws {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
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
        try await wait(0.7)
        print("MOTION_WINDOW visible=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) minimized=\(window.isMiniaturized)")
        let activeA = try pixels("native-active-a")
        try await wait(0.4)
        let activeB = try pixels("native-active-b")
        XCTAssertFalse(activeA == activeB, "A visible native activity must actually move")
        fixture.active = false
        try await wait(0.5)
        let restA = try pixels("native-rest-dark")
        try await wait(0.4)
        XCTAssertTrue(restA == (try pixels("native-rest-dark-stable")), "Idle frames must remain identical")
        fixture.reduced = true; fixture.active = true
        try await wait(0.4)
        let reduced = try pixels("native-reduced-dark")
        try await wait(0.4)
        XCTAssertTrue(reduced == (try pixels("native-reduced-dark-stable")), "Reduced frames must remain identical")
        XCTAssertTrue(restA == reduced, "Reduced motion displays the exact resting geometry")
        window.appearance = NSAppearance(named: .aqua)
        try await wait(0.3)
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
        .environment(\.goalongReduceMotion, true)
        let progressHost = NSHostingController(rootView: progress)
        window.contentViewController = progressHost
        window.setContentSize(NSSize(width: 520, height: 240))
        try await wait(0.3)
        let view = progressHost.view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("native-progress-semantics.png"))
    }
}
#endif
