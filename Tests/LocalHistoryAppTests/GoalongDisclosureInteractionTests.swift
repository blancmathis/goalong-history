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
    }
}

final class GoalongDisclosureInteractionTests: XCTestCase {
    @MainActor func testWholeRowTitleAccessibilityNestedControlsAndRefresh() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_FOCUS_UI_TESTS"] == "1" else {
            throw XCTSkip("Opt-in native interaction test; synthetic window only")
        }
        let app = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        // Materialize only this test process’s SwiftUI accessibility tree.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = DisclosureFixtureState()
        let controller = NSHostingController(rootView: DisclosureInteractionFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        app.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentViewController = nil
            previousApplication?.activate(options: [.activateIgnoringOtherApps])
        }
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

    // Same selector-based access as the existing native journey tests: SwiftUI
    // accessibility proxy objects do not always advertise protocol conformance.
    private struct NativeAccessibilityNode {
        let object: NSObject
        func value(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        func accessibilityFrame() -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return .zero }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
            return unsafeBitCast(method, to: Getter.self)(object, selector)
        }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }

    @MainActor private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    @MainActor private func button(_ label: String, in view: NSView) throws -> NativeAccessibilityNode {
        var pending: [Any] = [view], seen = Set<ObjectIdentifier>(), visited = 0
        while let value = pending.popLast(), visited < 10_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            visited += 1
            let node = NativeAccessibilityNode(object: object)
            if ["AXButton", "AXDisclosureTriangle"].contains(node.value("accessibilityRole") as? String ?? ""),
               (node.value("accessibilityLabel") as? String == label
                || node.value("accessibilityTitle") as? String == label) { return node }
            pending.append(contentsOf: node.value("accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        XCTFail("Missing accessible button: \(label); visited \(visited) native nodes")
        throw NSError(domain: "GoalongDisclosureInteractionTests", code: 1)
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
        let app = NSApplication.shared
        app.postEvent(down, atStart: false)
        app.postEvent(up, atStart: false)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        pump()
    }
}
#endif
