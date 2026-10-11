#if os(macOS)
import Ambiance
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Opt-in renders of the menu bar panel with fixed data only.
/// `GOALONG_MENUBAR_SNAPSHOTS=<dir> swift test --filter MenuBarPanelRenderingTests`
final class MenuBarPanelRenderingTests: XCTestCase {
    @MainActor func testRenderPanelStates() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_MENUBAR_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with fixed data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }

        let suite = "menubar-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})

        func source(_ id: String, _ title: String, _ kind: AmbianceSource.Kind, _ available: Bool = true) -> AmbianceSource {
            AmbianceSource(id: id, title: title, kind: kind, isAvailable: available)
        }
        let sources = [
            source("ambre", "Ambre", .focus), source("canopee", "Canopée", .focus), source("meridien", "Méridien", .focus),
            source("sillage", "Sillage", .focus), source("filigrane", "Filigrane", .focus), source("orbit", "Orbit", .focus, false),
            source("lagoon", "Lagon", .relax), source("rain", "Pluie douce", .texture), source("ocean", "Marée", .texture),
        ]
        func base() {
            model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
            model.workSeconds = TimeInterval(11520); model.otherSeconds = TimeInterval(2880)
            model.segments = [
                .init(id: 0, start: 0.34, end: 0.40, kind: .work), .init(id: 1, start: 0.405, end: 0.425, kind: .other),
                .init(id: 2, start: 0.43, end: 0.47, kind: .work), .init(id: 3, start: 0.475, end: 0.487, kind: .unclassified),
            ]
            model.nowFraction = 0.49
            model.focusAvailable = true; model.focusUnavailableReason = nil; model.focusKind = .pomodoro; model.focusMinutes = 25
            model.focusRun = nil
            model.ambianceEnabled = true; model.ambianceSources = sources; model.ambianceCurrent = sources[1]
            model.ambiancePlaying = false; model.ambianceLoading = false; model.ambianceError = nil
            model.blockingEnabled = true
            model.blockLists = [
                .init(id: "social", title: "Réseaux sociaux", detail: "6 sites, 2 apps", isActive: false, isLocked: false),
                .init(id: "news", title: "Actualités", detail: "9 sites", isActive: false, isLocked: false),
            ]
        }

        func render(_ name: String) throws {
            let root = MenuBarPanelView(model: model).fixedSize(horizontal: false, vertical: true)
                .environment(\.goalongReduceMotion, true)
            let controller = NSHostingController(rootView: root)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: MenuBarPanelView.width, height: 900))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let host = controller.view
            window.setContentSize(NSSize(width: MenuBarPanelView.width, height: host.fittingSize.height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("MENUBAR_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            base()
            try render("idle-\(suffix)")

            base()
            model.focusRun = .init(phaseTitle: "Travail", remaining: TimeInterval(1122), elapsed: TimeInterval(378), progress: 0.25,
                                   cycle: 2, cycles: 4, nextBreak: Date(timeIntervalSince1970: 1_791_716_400), isPaused: false)
            model.ambiancePlaying = true
            model.blockLists[0] = .init(id: "social", title: "Réseaux sociaux",
                                        detail: "Actif jusqu’à la fin de la séance, 3 tentatives", isActive: true, isLocked: true)
            model.blockLists[1].isActive = true
            try render("session-\(suffix)")

            base()
            model.tracking = .paused(since: nil); model.trackingDetail = "Suivi en pause depuis 10:02"
            model.focusAvailable = false; model.focusKind = .free
            model.focusUnavailableReason = "Reprenez le suivi pour lancer une séance."
            model.ambianceEnabled = false; model.blockingEnabled = false
            try render("paused-\(suffix)")
        }
    }
}
#endif
