#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

@MainActor private final class SwitchFixtureState: ObservableObject {
    @Published var row = false
    @Published var inline = true
    @Published var only = false
}

private struct SwitchAccessibilityFixture: View {
    @ObservedObject var state: SwitchFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Ligne", isOn: $state.row).toggleStyle(.goalongSwitch).accessibilityIdentifier("switch-row")
            Toggle("En ligne", isOn: $state.inline).toggleStyle(.goalongSwitchInline).accessibilityIdentifier("switch-inline")
            Toggle("Seul", isOn: $state.only).labelsHidden().toggleStyle(.goalongSwitchOnly).accessibilityIdentifier("switch-only")
        }
        .padding(20).frame(width: 400, height: 200, alignment: .topLeading)
    }
}

/// DEF-01 (T-046): VoiceOver « Activer » and AXPress must flip a brand switch, like a click.
/// The window is never ordered on screen: the accessibility tree is read from the hosting view.
final class GoalongSwitchAccessibilityTests: XCTestCase {
    @MainActor func testAXPressTogglesEveryGoalongSwitchLayout() throws {
        let app = NSApplication.shared
        // Materialize only this test process's SwiftUI accessibility tree.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = SwitchFixtureState()
        let host = NSHostingView(rootView: SwitchAccessibilityFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        pump()

        for (id, keyPath) in [("switch-row", \SwitchFixtureState.row), ("switch-inline", \.inline), ("switch-only", \.only)] {
            let before = state[keyPath: keyPath]
            let node = try element(id, in: host)
            XCTAssertEqual(node.value("accessibilityRole") as? String, "AXCheckBox", id)
            // AppKit's AXPress return value is not reliable for switches; assert the real state.
            _ = node.accessibilityPerformPress()
            pump()
            XCTAssertEqual(state[keyPath: keyPath], !before, "\(id): AXPress must toggle the switch")
            _ = try element(id, in: host).accessibilityPerformPress()
            pump()
            XCTAssertEqual(state[keyPath: keyPath], before, "\(id): a second AXPress must toggle it back")
        }
    }

    // Selector-based access: SwiftUI accessibility proxies do not always advertise protocol conformance.
    private struct Node {
        let object: NSObject
        func value(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }

    @MainActor private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    @MainActor private func element(_ identifier: String, in view: NSView) throws -> Node {
        var pending: [Any] = [view], seen = Set<ObjectIdentifier>(), visited = 0
        while let value = pending.popLast(), visited < 10_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            visited += 1
            let node = Node(object: object)
            if node.value("accessibilityIdentifier") as? String == identifier { return node }
            pending.append(contentsOf: node.value("accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        XCTFail("Missing accessible element \(identifier); visited \(visited) nodes")
        throw NSError(domain: "GoalongSwitchAccessibilityTests", code: 1)
    }
}
#endif
