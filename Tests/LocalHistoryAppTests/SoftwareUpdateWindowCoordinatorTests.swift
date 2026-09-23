#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

final class SoftwareUpdateWindowCoordinatorTests: XCTestCase {
    @MainActor func testOnlyExplicitUpdateWindowsStayAboveDashboardAndRestoreOnFinish() throws {
        _ = NSApplication.shared
        let main = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 900, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        let update = NSWindow(contentRect: NSRect(x: 21000, y: 20000, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 22000, y: 20000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        for window in [main, update, other] { window.isReleasedWhenClosed = false; window.orderFrontRegardless() }
        defer { for window in [other, update, main] { window.orderOut(nil); window.close() } }
        let level = update.level, behavior = update.collectionBehavior, hides = update.hidesOnDeactivate
        let helper = SoftwareUpdateWindowCoordinator(ordersWindows: false, recognizes: { $0 === update })
        defer { helper.finish() }
        helper.registerDashboard(main)
        helper.reconcile([main, update, other])
        XCTAssertNil(update.parent); XCTAssertEqual(update.level, level, "Passive checks never raise a window")
        helper.beginExplicitPresentation(); helper.reconcile([main, update, other])
        XCTAssertTrue(update.parent === main)
        XCTAssertGreaterThan(update.level.rawValue, main.level.rawValue)
        XCTAssertTrue(update.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertNil(other.parent); XCTAssertEqual(other.level, .normal)
        helper.reconcile([main, update, other])
        XCTAssertEqual(main.childWindows?.filter { $0 === update }.count, 1)
        helper.finish()
        XCTAssertNil(update.parent); XCTAssertEqual(update.level, level)
        XCTAssertEqual(update.collectionBehavior, behavior); XCTAssertEqual(update.hidesOnDeactivate, hides)
        XCTAssertFalse(helper.isPresenting)
    }
    @MainActor func testUnknownAndHiddenWindowsAreNotPresented() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let helper = SoftwareUpdateWindowCoordinator(ordersWindows: false, recognizes: { _ in true })
        defer { helper.finish(); window.close() }
        XCTAssertFalse(SoftwareUpdateWindowCoordinator.isSparkleWindow(window))
        helper.beginExplicitPresentation(); helper.reconcile([window])
        XCTAssertFalse(window.isVisible); XCTAssertEqual(window.level, .normal)
    }
}
#endif
