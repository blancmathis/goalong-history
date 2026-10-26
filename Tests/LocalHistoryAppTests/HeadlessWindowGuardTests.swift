#if os(macOS)
import AppKit
import GoalongHeadlessTestSupport
import XCTest

/// In `make test`: no test window ever reaches the screen of the person working on this Mac, and the
/// test process never takes the focus. The window server is asked, not AppKit. Shows nothing.
final class HeadlessWindowGuardTests: XCTestCase {
    private func visibleWindowsOfThisProcess() -> [[String: Any]] {
        let displays = GoalongHeadlessDisplayBounds()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { GoalongHeadlessWindowInfoIsVisible($0, getpid(), displays) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testVisibilityRuleMatchesOnlyWindowsSomeoneCouldSee() {
        let display = [NSValue(rect: NSRect(x: 0, y: 0, width: 1440, height: 900))]
        func info(pid: pid_t = 42, alpha: Double = 1, x: Double = 100, width: Double = 400) -> [AnyHashable: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: ["X": x, "Y": 100, "Width": width, "Height": 300]]
        }
        XCTAssertTrue(GoalongHeadlessWindowInfoIsVisible(info(), 42, display))
        XCTAssertFalse(GoalongHeadlessWindowInfoIsVisible(info(alpha: 0), 42, display), "alpha 0")
        XCTAssertFalse(GoalongHeadlessWindowInfoIsVisible(info(pid: 7), 42, display), "another process")
        XCTAssertFalse(GoalongHeadlessWindowInfoIsVisible(info(x: 5000), 42, display), "off every display")
        XCTAssertFalse(GoalongHeadlessWindowInfoIsVisible(info(width: 1), 42, display), "1 point wide")
    }

    @MainActor
    func testWindowsPanelsAndStatusItemsNeverReachTheScreenNorTakeTheFocus() throws {
        guard GoalongHeadlessActive() else { throw XCTSkip("GOALONG_TESTS_VISIBLE=1: windows are meant to be seen") }
        let center = NSScreen.main.map { NSRect(x: $0.frame.midX - 200, y: $0.frame.midY - 150, width: 400, height: 300) }
            ?? NSRect(x: 200, y: 200, width: 400, height: 300)
        let window = NSWindow(contentRect: center, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Goalong headless guard"
        window.animationBehavior = .documentWindow
        let panel = NSPanel(contentRect: center.offsetBy(dx: 40, dy: 40), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let alert = NSAlert()
        alert.messageText = "Goalong headless guard"
        let previousPolicy = NSApp.activationPolicy()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer {
            NSStatusBar.system.removeStatusItem(item)
            window.orderOut(nil); window.close()
            panel.orderOut(nil); panel.close()
            alert.window.orderOut(nil)
            NSApp.setActivationPolicy(previousPolicy)
        }

        NSApp.setActivationPolicy(.regular)
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        alert.window.orderFront(nil)
        window.animator().alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        spin(0.5)

        XCTAssertEqual(visibleWindowsOfThisProcess().count, 0, "\(visibleWindowsOfThisProcess())")
        XCTAssertEqual(window.alphaValue, 1, "the code under test must still read the alpha it set")
        XCTAssertEqual(NSApp.activationPolicy(), .regular, "the code under test must still read the policy it set")
        XCTAssertTrue(item.isVisible, "the code under test must still read its status item as visible")
        XCTAssertEqual(NSRunningApplication.current.activationPolicy, .prohibited, "the real process must stay .prohibited")
        XCTAssertFalse(NSApp.isActive)
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, getpid())
        XCTAssertEqual(GoalongHeadlessVisibleWindowCount(), 0, "a window was visible earlier in this run")
    }
}
#endif
