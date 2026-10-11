#if os(macOS)
import Ambiance
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class BlockingActivationRegressionTests: XCTestCase {
    @MainActor func testNativePanelSwitchStartsAndStopsBlocking() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_BLOCKING_UI_TESTS"] == "1" else {
            throw XCTSkip("Opt-in native blocking activation with an in-memory list")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "blocking-activation-" + UUID().uuidString
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let modules = GoalongModuleStore(defaults: defaults)
        modules.setEnabled(.blocking, true)
        let list = BlockList(name: "Régression", sites: [.init(pattern: "example.invalid")])
        let controller = BlockingController(document: BlockingDocument(lists: [list]),
            backend: StandardBlockingBackend(), runningApps: { [] })
        defer { controller.shutdown() }
        controller.observe(BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: -1,
            windowFrame: CGRect(x: 100, y: 100, width: 300, height: 200), isBrowser: true,
            url: "example.invalid", privateWindow: false, at: Date()))
        let subscription = controller.$activeBlocks.dropFirst().sink { _ in
            XCTAssertTrue(Thread.isMainThread, "Blocking state must publish on the main thread")
        }
        defer { subscription.cancel() }
        let model = MenuBarPanelModel(state: CaptureState(isGloballyPaused: { false }), modules: modules,
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { controller }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        model.refreshRuntimeState()
        let host = NSHostingController(rootView: MenuBarPanelView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(title: "Panneau", target: nil, action: nil)
        window.contentView = anchor
        window.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: 700)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        defer { popover.close(); window.orderOut(nil); window.contentView = nil }
        pump()
        XCTAssertTrue(try press("Bloquer Régression", in: host.view))
        pump()
        XCTAssertEqual(controller.activeBlocks.count, 1)
        XCTAssertEqual(controller.activeBlocks.first?.listIDs, [list.id])
        XCTAssertEqual(controller.activeBlocks.first?.lock, .free)
        XCTAssertTrue(model.blockLists.first?.isActive == true)
        XCTAssertTrue(try press("Bloquer Régression", in: host.view))
        pump()
        XCTAssertTrue(controller.activeBlocks.isEmpty)
        XCTAssertTrue(model.blockLists.first?.isActive == false)

        // The app's composer uses this same controller entry point.
        controller.start(listIDs: [list.id], until: Date().addingTimeInterval(600), lock: .free)
        XCTAssertEqual(controller.activeBlocks.count, 1)
        XCTAssertNil(controller.error)
    }

    @MainActor private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    @MainActor private func press(_ label: String, in view: NSView) throws -> Bool {
        func value(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        var pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let candidate = pending.popLast(), seen.count < 10_000 {
            guard let object = candidate as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if value(object, "accessibilityLabel") as? String == label {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                if object.responds(to: selector), let method = object.method(for: selector) {
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(method, to: Press.self)(object, selector)
                }
            }
            pending.append(contentsOf: value(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        XCTFail("Missing native blocking switch: \(label)")
        throw NSError(domain: "BlockingActivationRegressionTests", code: 1)
    }
}
#endif
