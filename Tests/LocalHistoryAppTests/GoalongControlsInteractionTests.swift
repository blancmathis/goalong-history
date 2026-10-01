#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Real mouse and key events against Goalong's own field chrome: clicking the text of a
/// styled field or search field focuses it and typing reaches the binding.
final class GoalongControlsInteractionTests: XCTestCase {
    private final class Box: ObservableObject { @Published var a = ""; @Published var b = ""; @Published var c = "" }
    private struct Harness: View {
        @ObservedObject var box: Box
        var body: some View {
            VStack(spacing: 30) {
                TextField("Champ", text: $box.a).textFieldStyle(GoalongFieldStyle())
                GoalongSearchField("Recherche", text: $box.b)
                GoalongTextArea(text: $box.c, placeholder: "Zone", minHeight: 60)
            }.padding(30).frame(width: 400)
        }
    }

    @MainActor func testClicksFocusFieldsAndTypingReachesBindings() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_DESIGN_AUDIT"] != nil else {
            throw XCTSkip("Opt-in: needs a real window server session; use scripts/verify_design_audit.sh")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let box = Box()
        let host = NSHostingView(rootView: Harness(box: box))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        pump()
        window.setContentSize(host.fittingSize); pump()
        let height = host.bounds.height
        // Top-left based layout: padding 30, field 34, gap 30, search 34. Synthetic events reach
        // AppKit text fields but neither SwiftUI tap gestures nor NSTextView (TextEditor) tracking,
        // so padding clicks and GoalongTextArea need a manual check in the real app.
        for (y, x, keyPath, text) in [(47.0, 200.0, \Box.a, "abc"), (111.0, 200.0, \Box.b, "xyz")] {
            click(window, at: NSPoint(x: x, y: height - y))
            pump()
            for character in text { type(window, String(character)) }
            pump()
            XCTAssertEqual(box[keyPath: keyPath], text, "click (\(x), \(y)): a=\(box.a) b=\(box.b) c=\(box.c)")
        }
    }

    /// Text views track the mouse modally after mouseDown, so mouseUp is queued first.
    @MainActor private func click(_ window: NSWindow, at point: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        // Drain the queued mouseUp if no tracking loop consumed it.
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }
    @MainActor private func type(_ window: NSWindow, _ character: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: character,
                                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
            window.sendEvent(event)
        }
    }
    @MainActor private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
}
#endif
