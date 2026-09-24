#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

@MainActor private final class DisclosureFixtureState: ObservableObject {
    @Published var first = false
    @Published var second = false
    @Published var revision = 0
    @Published var contentClicks = 0
}

private struct DisclosureInteractionFixture: View {
    @ObservedObject var state: DisclosureFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GoalongDisclosureGroup("Heures et valeurs", isExpanded: $state.first) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("09:00–10:00 · 45 min actives · 30 min de focus")
                    Button("Action dans le contenu") { state.contentClicks += 1 }
                    GoalongDisclosureGroup("Section imbriquée") { Text("Contenu imbriqué") }
                }.padding(.vertical, 10)
            }
            GoalongDisclosureGroup("Comparaison avec la période précédente", isExpanded: $state.second) {
                Text("Période précédente : 4 h").padding(.vertical, 10)
            }
            Text("Actualisation \(state.revision)")
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 600, height: 500, alignment: .topLeading)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
        .environment(\.accessibilityReduceMotion, true)
    }
}

final class GoalongDisclosureInteractionTests: XCTestCase {
    @MainActor func testWholeRowTitleAccessibilityNestedControlsAndRefresh() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_FOCUS_UI_TESTS"] == "1" else {
            throw XCTSkip("Opt-in native interaction test; synthetic window only")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let state = DisclosureFixtureState()
        let controller = NSHostingController(rootView: DisclosureInteractionFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        pump()

        let first = try button("Heures et valeurs", in: controller.view)
        XCTAssertGreaterThan(first.accessibilityFrame().width, 500, "The click target must include empty header space")
        XCTAssertFalse(state.first)
        try click(first.accessibilityFrame(), fraction: 0.95, in: window)
        XCTAssertTrue(state.first, "Clicking the empty right side must expand the section")
        XCTAssertFalse(state.second)

        let refreshedFirst = try button("Heures et valeurs", in: controller.view)
        try click(refreshedFirst.accessibilityFrame(), fraction: 0.18, in: window)
        XCTAssertFalse(state.first, "Clicking the title, not just the chevron, must collapse it")

        XCTAssertTrue(try button("Heures et valeurs", in: controller.view).accessibilityPerformPress())
        pump()
        XCTAssertTrue(state.first, "VoiceOver/AXPress must use the same toggle action")
        XCTAssertTrue(try button("Action dans le contenu", in: controller.view).accessibilityPerformPress())
        pump()
        XCTAssertEqual(state.contentClicks, 1)
        XCTAssertTrue(state.first, "Content actions must not toggle their containing section")

        XCTAssertTrue(try button("Section imbriquée", in: controller.view).accessibilityPerformPress())
        pump()
        XCTAssertTrue(state.first)
        XCTAssertTrue(try button("Comparaison avec la période précédente", in: controller.view).accessibilityPerformPress())
        pump()
        XCTAssertTrue(state.second)
        state.revision += 1
        pump()
        XCTAssertTrue(state.first, "A data refresh must preserve expansion")
        XCTAssertTrue(state.second)

        if let path = ProcessInfo.processInfo.environment["GOALONG_FOCUS_UI_SNAPSHOT"] {
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor private func elements(_ object: Any) -> [NSAccessibility] {
        guard let element = object as? NSAccessibility else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { elements($0) }
    }

    @MainActor private func button(_ label: String, in view: NSView) throws -> NSAccessibility {
        try XCTUnwrap(elements(view).first {
            $0.accessibilityRole() == .button && $0.accessibilityLabel() == label
        }, "Missing accessible button: \(label)")
    }

    @MainActor private func click(_ frame: NSRect, fraction: CGFloat, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Only the fixture's own window receives these events; no system pointer movement.
        NSApplication.shared.postEvent(up, atStart: false)
        window.sendEvent(down)
        pump()
    }
}
#endif
