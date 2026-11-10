#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

/// T-048 D1: the menu bar panel closes on a click outside it and on Esc, though Goalong was not active.
/// Fake monitors only: no window, no real event monitor, no activation.
@MainActor final class MenuBarPanelDismissalTests: XCTestCase {
    private final class Fake {
        var global: [(mask: NSEvent.EventTypeMask, handler: (NSEvent) -> Void)] = []
        var local: [(mask: NSEvent.EventTypeMask, handler: (NSEvent) -> NSEvent?)] = []
        var removed = 0
        var activations = 0
        var closes = 0
        var insidePanel = false
    }

    private func make() -> (MenuBarPanelDismissal, Fake) {
        let fake = Fake()
        let hooks = MenuBarPanelDismissal.Hooks(
            addGlobalMonitor: { fake.global.append(($0, $1)); return fake.global.count },
            addLocalMonitor: { fake.local.append(($0, $1)); return -fake.local.count },
            removeMonitor: { _ in fake.removed += 1 },
            isInsidePanel: { _ in fake.insidePanel },
            activate: { fake.activations += 1 },
            frontmostOther: { nil })
        return (MenuBarPanelDismissal(hooks: hooks) { fake.closes += 1 }, fake)
    }

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: code == 53 ? "\u{1b}" : "a", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "a",
                         isARepeat: false, keyCode: code)!
    }

    private func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testOpeningThePanelWatchesOutsideClicksAndActivatesGoalong() {
        let (dismissal, fake) = make()
        dismissal.begin()
        XCTAssertTrue(dismissal.isArmed)
        XCTAssertEqual(fake.activations, 1, "the panel takes the keyboard")
        XCTAssertEqual(fake.global.count, 1)
        XCTAssertTrue(fake.global[0].mask.contains(.leftMouseDown))
        XCTAssertTrue(fake.global[0].mask.contains(.rightMouseDown))
        fake.global[0].handler(click())
        XCTAssertEqual(fake.closes, 1, "a click in another app, the desktop or another menu bar item closes the panel")
    }

    func testEscClosesThePanelAndOtherKeysReachIt() {
        let (dismissal, fake) = make()
        dismissal.begin()
        XCTAssertEqual(fake.local.count, 1)
        XCTAssertTrue(fake.local[0].mask.contains(.keyDown))
        XCTAssertNotNil(fake.local[0].handler(key(0)), "ordinary keys go to the panel")
        XCTAssertEqual(fake.closes, 0)
        XCTAssertNil(fake.local[0].handler(key(53)), "Esc is used up")
        XCTAssertEqual(fake.closes, 1)
    }

    /// T-051: AppKit must not close the panel by itself; a pointer leaving the icon or the panel keeps it open.
    func testAppKitNeverClosesThePanelAndPointerMovesKeepItOpen() {
        XCTAssertEqual(MenuBarController.panelBehavior, .applicationDefined,
                       "a .transient popover is closed by AppKit on focus or activation changes")
        let (dismissal, fake) = make()
        dismissal.begin()
        XCTAssertFalse(fake.global[0].mask.contains(.mouseMoved), "no pointer-move watch")
        XCTAssertFalse(fake.global[0].mask.contains(.mouseExited))
        XCTAssertFalse(fake.local[0].mask.contains(.mouseMoved))
        XCTAssertFalse(fake.local[0].mask.contains(.mouseExited))
        XCTAssertEqual(fake.closes, 0)
    }

    /// With the panel no longer transient, a click in another Goalong window (or on our own icon) must still close it.
    func testClickInAnotherGoalongWindowClosesAndClickInThePanelKeepsItOpen() {
        let (dismissal, fake) = make()
        dismissal.begin()
        XCTAssertTrue(fake.local[0].mask.contains(.leftMouseDown))
        fake.insidePanel = true
        XCTAssertNotNil(fake.local[0].handler(click()))
        XCTAssertEqual(fake.closes, 0, "a click on the panel keeps it open")
        fake.insidePanel = false
        XCTAssertNotNil(fake.local[0].handler(click()), "the click goes on to its target")
        XCTAssertEqual(fake.closes, 1)
    }

    func testClosingRemovesEveryMonitorOnceAndReopeningDoesNotStack() {
        let (dismissal, fake) = make()
        dismissal.begin()
        dismissal.begin()
        XCTAssertEqual(fake.removed, 2, "a second open replaces the first watch")
        dismissal.end()
        XCTAssertFalse(dismissal.isArmed)
        XCTAssertEqual(fake.removed, 4)
        dismissal.end()
        XCTAssertEqual(fake.removed, 4)
    }

    /// The bug of 0.6.178: the panel opened with no outside-click watch, so only a second click on the icon closed it.
    func testThePanelIsShownOnlyWithTheWatchArmedAndTheWatchEndsWithIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp/MenuBarController.swift"), encoding: .utf8)
        let begin = try XCTUnwrap(source.range(of: "panelDismissal.begin()"), "togglePanel arms the watch")
        let show = try XCTUnwrap(source.range(of: "popover.show(relativeTo:"))
        XCTAssertLessThan(begin.lowerBound, show.lowerBound, "the watch is armed before the panel shows")
        XCTAssertEqual(source.components(separatedBy: "popover.show(").count, 2, "one place shows the panel")
        let didClose = try XCTUnwrap(source.range(of: "func popoverDidClose"))
        let end = try XCTUnwrap(source.range(of: "panelDismissal.end()"), "the watch ends when the panel closes")
        XCTAssertGreaterThan(end.lowerBound, didClose.lowerBound)
    }
}
#endif
