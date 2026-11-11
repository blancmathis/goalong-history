#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-052 lot 1: the click-outside mechanism, proved with real AppKit sheets on windows the headless support keeps at alpha 0
/// (no window on screen, no focus). Clicks are synthesized events sent through `NSApp.sendEvent`.
@MainActor final class GoalongSheetDismissalTests: XCTestCase {
    private struct Rig {
        let parent: NSWindow
        let sheet: NSWindow
        var cancelled: () -> Int
        var asked: () -> Int
    }
    private final class Counter { var cancelled = 0; var asked = 0 }

    private func rig(dirty: Bool) -> Rig {
        let parent = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let counter = Counter()
        let root = Text("Feuille").frame(width: 300, height: 200)
            .goalongDismissOnOutsideClick(isDirty: { dirty }, onCancel: { counter.cancelled += 1 })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: root))
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet)
        spin { sheet.sheetParent === parent && !sheet.contentView!.subviews.isEmpty }
        return Rig(parent: parent, sheet: sheet, cancelled: { counter.cancelled }, asked: { counter.asked })
    }

    private func spin(_ condition: () -> Bool = { false }, for seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func click(in window: NSWindow, at point: NSPoint = NSPoint(x: 50, y: 50)) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }

    private func close(_ rig: Rig) {
        rig.parent.endSheet(rig.sheet); rig.sheet.close(); rig.parent.close()
    }

    func testTheMonitorReceivesAClickThatTheModalSheetIgnores() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        XCTAssertTrue(rig.parent.attachedSheet === rig.sheet, "the sheet is attached")
        click(in: rig.parent)
        XCTAssertEqual(rig.cancelled(), 1, "a click in the parent window acts like « Annuler »")
    }

    func testAClickInsideTheSheetDoesNothing() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        click(in: rig.sheet)
        XCTAssertEqual(rig.cancelled(), 0)
    }

    func testCommandWOnTheSheetActsLikeCancelAndOtherKeysDoNot() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: rig.sheet.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: 13)!
            NSApp.sendEvent(event)
        }
        key("w", [])
        key("q", .command)
        XCTAssertEqual(rig.cancelled(), 0)
        key("w", .command)
        XCTAssertEqual(rig.cancelled(), 1)
    }

    func testEscapeOnTheSheetActsLikeCancelAndAnotherKeyDoesNot() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        func key(_ chars: String, code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: rig.sheet.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        key("a", code: 0)
        XCTAssertEqual(rig.cancelled(), 0)
        key("\u{1B}", code: 53)
        XCTAssertEqual(rig.cancelled(), 1)
    }

    func testTheFirstTextFieldOfTheSheetTakesTheInitialFocus() {
        let parent = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        struct Form: View {
            @State var first = ""; @State var second = ""
            var body: some View {
                VStack { TextField("Premier", text: $first); TextField("Second", text: $second) }.frame(width: 300, height: 200)
                    .goalongDismissOnOutsideClick()
            }
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: Form()))
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet)
        spin({ (sheet.firstResponder as? NSTextView)?.isFieldEditor == true }, for: 1.0)
        let editor = sheet.firstResponder as? NSTextView
        XCTAssertEqual(editor?.isFieldEditor, true)
        let field = editor?.delegate as? NSTextField
        XCTAssertEqual(field?.placeholderString ?? field?.accessibilityLabel(), field?.placeholderString ?? field?.accessibilityLabel())
        // The first field in reading order, not the second.
        let fields = sheet.contentView!.allDescendants.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let top = fields.max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }
        XCTAssertTrue(field === top)
        parent.endSheet(sheet); sheet.close(); parent.close()
    }

    func testDecisionKeepsEveryExclusion() {
        typealias D = GoalongSheetDismissal
        XCTAssertEqual(D.decision(isEnabled: true, isDirty: false, otherLayerAbove: false), .cancel)
        XCTAssertEqual(D.decision(isEnabled: true, isDirty: true, otherLayerAbove: false), .askToDiscard)
        XCTAssertEqual(D.decision(isEnabled: true, isDirty: false, otherLayerAbove: true), .ignore, "alert, panel, popover")
        XCTAssertEqual(D.decision(isEnabled: true, isDirty: true, otherLayerAbove: true), .ignore)
        XCTAssertEqual(D.decision(isEnabled: false, isDirty: false, otherLayerAbove: false), .ignore)
    }

    func testADirtySheetNeverClosesWithoutAsking() {
        let rig = rig(dirty: true)
        defer { close(rig) }
        click(in: rig.parent)
        XCTAssertEqual(rig.cancelled(), 0, "the input is kept until the member confirms")
        XCTAssertNotNil(rig.parent.attachedSheet, "the sheet stays")
    }

    func testAClickOnAnotherWindowDoesNothing() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        let other = NSWindow(contentRect: NSRect(x: 21000, y: 20000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.orderFrontRegardless()
        defer { other.close() }
        click(in: other)
        XCTAssertEqual(rig.cancelled(), 0)
    }

    func testNoClickOutsideWhileAnAlertIsAboveTheSheet() {
        let rig = rig(dirty: false)
        defer { close(rig) }
        let alertWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        alertWindow.isReleasedWhenClosed = false
        rig.sheet.beginSheet(alertWindow)
        spin(for: 0.3)
        click(in: rig.parent)
        XCTAssertEqual(rig.cancelled(), 0, "a nested alert or file panel blocks the outside click")
        rig.sheet.endSheet(alertWindow); alertWindow.close()
    }
}

private extension NSView {
    var allDescendants: [NSView] { subviews + subviews.flatMap { $0.allDescendants } }
}
#endif
