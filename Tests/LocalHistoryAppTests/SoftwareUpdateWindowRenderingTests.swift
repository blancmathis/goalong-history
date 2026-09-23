#if os(macOS)
import AppKit
import SwiftUI
import Sparkle
import XCTest
@testable import LocalHistoryApp

extension GoalongBrandRenderingTests {
    /// Exercise the real pinned Sparkle user driver's checking and download windows.
    /// No updater, network, executable installation, capture or real home data is involved.
    @MainActor func testIsolatedSparkleWindowsStayAboveDashboard() throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["GOALONG_BRAND_TEST_HOME"], let path = env["GOALONG_BRAND_SNAPSHOTS"] else {
            throw XCTSkip("Isolated native Sparkle UI audit only")
        }
        guard home.hasPrefix("/tmp/goalong-brand-"), FileManager.default.homeDirectoryForCurrentUser.path == home else {
            XCTFail("Refusing native test outside disposable home"); return
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: home).appendingPathComponent("SyntheticUpdate.app")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.goalong.synthetic-update", "CFBundleName": "Goalong — validation isolée", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: fixture))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let main = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 900, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.title = "Goalong — validation isolée"; main.isReleasedWhenClosed = false
        defer { main.orderOut(nil); main.close() }
        main.makeKeyAndOrderFront(nil)
        let helper = SoftwareUpdateWindowCoordinator(ordersWindows: false)
        helper.registerDashboard(main)
        defer { helper.finish() }
        for download in [false, true] {
            let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
            helper.beginExplicitPresentation()
            if download { driver.showDownloadInitiated(cancellation: {}) }
            else { driver.showUserInitiatedUpdateCheck(cancellation: {}) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            helper.reconcile(app.windows)
            let update = try XCTUnwrap(app.windows.first { $0.isVisible && SoftwareUpdateWindowCoordinator.isSparkleWindow($0) })
            XCTAssertTrue(update.parent === main, "Real Sparkle window must attach above Goalong")
            XCTAssertGreaterThan(update.level.rawValue, main.level.rawValue)
            main.makeKeyAndOrderFront(nil)
            helper.reconcile(app.windows)
            XCTAssertTrue(update.parent === main, "Clicking the dashboard cannot bury the update")
            update.setFrameOrigin(NSPoint(x: 20000, y: 20000))
            let view = try XCTUnwrap(update.contentView)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(download ? "update-download-native.png" : "update-check-native.png"))
            driver.dismissUpdateInstallation()
            helper.finish()
            XCTAssertNil(update.parent)
        }
        print("NATIVE_SPARKLE_WINDOW_ORDER real checking/download windows above dashboard; no network or installation")
    }
}
#endif
