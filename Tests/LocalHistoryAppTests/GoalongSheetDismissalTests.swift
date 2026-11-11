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
#endif
