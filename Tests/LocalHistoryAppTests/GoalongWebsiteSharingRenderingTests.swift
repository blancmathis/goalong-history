#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// Real native views, entirely synthetic data and an isolated preferences home.
final class GoalongWebsiteSharingRenderingTests: XCTestCase {
    @MainActor func testRenderSharingWindow() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["GOALONG_SHARING_SNAPSHOTS"], let home = env["GOALONG_SHARING_TEST_HOME"] else {
            throw XCTSkip("Opt-in synthetic UI rendering")
        }
        guard home.hasPrefix("/tmp/goalong-sharing-home-"), FileManager.default.homeDirectoryForCurrentUser.path == home else {
            XCTFail("Refusing to render with real user preferences"); return
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: home)
        let token = root.appendingPathComponent("synthetic.token")
        try Data("synthetic-preview-only-access".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        UserDefaults.standard.set("https://goalong.example", forKey: "goalong.website.origin")
        UserDefaults.standard.set(token.path, forKey: "goalong.website.tokenFilePath")
        let catalog = Data(#"{"days":[{"telemetry":{"timezone":"Europe/Paris","devices":[{"id":"mac","name":"MacBook Pro · Démonstration","kind":"computer","screenSeconds":21600,"apps":[{"id":"vscode","name":"Visual Studio Code","seconds":7200},{"id":"figma","name":"Figma","seconds":3600},{"id":"safari","name":"Safari","seconds":2400},{"id":"notes","name":"Notes","seconds":1200},{"id":"mail","name":"Mail","seconds":900},{"id":"private","name":"Application privée","seconds":600}]},{"id":"phone","name":"iPhone · Démonstration","kind":"phone","screenSeconds":5400,"apps":[]}],"websites":{"rows":[{"domain":"github.com","seconds":900},{"domain":"developer.apple.com","seconds":600}]}}}]}"#.utf8)
        let payload = Data(#"{"version":2,"source":"goalong-history","days":[{"date":"2026-09-13","title":"Journée de démonstration","summary":"","outcomes":[],"activities":[],"telemetry":{"devices":[{"id":"device-demo","name":"Ordinateur","screenSeconds":null,"hourly":null,"apps":[{"id":"vscode","name":"Visual Studio Code","seconds":7200},{"id":"figma","name":"Figma","seconds":3600}]}],"websites":null,"agent":null}}]}"#.utf8)
        let scheduler = GoalongWebsiteAutoSender(defaults: .standard, root: root, sourceConsent: { _ in true })
        let model = GoalongWebsiteSharingModel(autoSender: scheduler, root: root,
            catalogLoader: { _, _, _ in try GoalongSiteSelectionCatalog(payload: catalog) },
            exporter: { _, _, _ in payload }, sender: { _, _, _, _ in XCTFail("Rendering must never send"); return Data() }, sourceConsent: { _ in true })
        await model.loadCatalog()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "GoLong · Sélection de démonstration"
        defer { window.orderOut(nil); window.contentViewController = nil; scheduler.forget() }
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            for narrow in [false, true] {
                let width: CGFloat = narrow ? 680 : 740, height: CGFloat = narrow ? 560 : 720
                let host = NSHostingController(rootView: GoalongWebsiteSharingSheet(model: model))
                window.contentViewController = host
                window.setContentSize(NSSize(width: width, height: height))
                window.makeKeyAndOrderFront(nil)
                pump()
                try snapshot(host.view, to: out.appendingPathComponent("sharing-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
        model.draft.deviceIDs = ["mac"]
        model.draft.includeApplications = true
        model.draft.applicationIDs = ["vscode", "figma"]
        model.draft.delivery = .daily; model.draft.timezone = "Europe/Paris"
        model.draft.hour = 9; model.draft.minute = 30
        app.appearance = NSAppearance(named: .darkAqua); window.appearance = app.appearance
        let host = NSHostingController(rootView: GoalongWebsiteSharingSheet(model: model))
        window.contentViewController = host
        window.setContentSize(NSSize(width: 740, height: 720)); pump()
        // Replacing the previous host correctly cancels its preview on disappearance.
        // Prepare only after mounting this host so the image proves the live consent UI.
        await model.prepare(origin: "https://goalong.example", tokenPath: token.path)
        pump()
        XCTAssertNotNil(model.preview)
        XCTAssertFalse(model.reviewed)
        try snapshot(host.view, to: out.appendingPathComponent("sharing-daily-dark.png"))
        // Programmatic native scrolling, not a claim of physical input validation.
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host.view).first)
        let document = try XCTUnwrap(scroll.documentView)
        document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView); pump()
        XCTAssertNotNil(model.preview, "The rendered preview must not have been cancelled by host replacement")
        try snapshot(host.view, to: out.appendingPathComponent("sharing-preview-dark.png"))
        model.reviewed = true
        pump()
        XCTAssertNotNil(model.preview)
        XCTAssertTrue(model.reviewed)
        XCTAssertFalse(scheduler.enabled, "A checked review alone must not activate the plan")
        try snapshot(host.view, to: out.appendingPathComponent("sharing-approved-dark.png"))
    }
    @MainActor private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
    @MainActor private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
