#if os(macOS)
import Ambiance
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class AmbianceModuleNavigationTests: XCTestCase {
    func testDisabledModuleHasNoSidebarEntry() {
        XCTAssertFalse(DashboardSection.sidebarSections(modules: []).contains(.ambiance))
        let sections = DashboardSection.sidebarSections(modules: [.ambiance])
        XCTAssertEqual(sections.last, .settings)
        XCTAssertEqual(sections[sections.count - 2], .ambiance)
    }

    func testModuleIsOffByDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ambiance-module-\(UUID().uuidString)"))
        XCTAssertFalse(GoalongModuleStore(defaults: defaults).isEnabled(.ambiance))
        XCTAssertEqual(GoalongModule.ambiance.defaultsKey, AmbianceSettings.enabledKey)
    }
}

/// Opt-in renders of the Ambiance page with fixed data only.
/// `GOALONG_AMBIANCE_SNAPSHOTS=<dir> swift test --filter AmbiancePageRenderingTests`
final class AmbiancePageRenderingTests: XCTestCase {
    private static let focus = [("ambre", "Ambre"), ("canopee", "Canopée"), ("meridien", "Méridien"), ("sillage", "Sillage"),
                                ("filigrane", "Filigrane"), ("confluence", "Confluence"), ("sanctuaire", "Sanctuaire"), ("gravite", "Gravité")]
    private static let relax = [("lagoon", "Lagon"), ("stillwater", "Eau calme"), ("hearth", "Foyer"), ("reverie", "Rêverie"), ("driftwood", "Bois flotté")]
    private static let textures = [("rain", "Pluie douce"), ("ocean", "Marée"), ("brown", "Velours brun"), ("pink", "Air rose"), ("aube", "Aube")]

    private func sources(orchestra: Bool, textures: Bool, files: Bool) -> [AmbianceSource] {
        var result = Self.focus.map { AmbianceSource(id: $0.0, title: $0.1, kind: .focus, isAvailable: orchestra) }
            + Self.relax.map { AmbianceSource(id: $0.0, title: $0.1, kind: .relax, isAvailable: orchestra) }
        if textures { result += Self.textures.map { AmbianceSource(id: $0.0, title: $0.1, kind: .texture, isAvailable: true) } }
        if files {
            result += [
                AmbianceSource(id: "file:/Users/m/Music/Nils Frahm - Says.m4a", title: "Nils Frahm - Says.m4a", kind: .ownFile,
                               isAvailable: true, path: "/Users/m/Music/Nils Frahm - Says.m4a"),
                AmbianceSource(id: "file:/Volumes/Disque/Pluie de Kyoto.wav", title: "Pluie de Kyoto.wav", kind: .ownFile,
                               isAvailable: false, path: "/Volumes/Disque/Pluie de Kyoto.wav"),
            ]
        }
        return result
    }

    private func packs(_ orchestra: AmbiancePackState.Status, _ textures: AmbiancePackState.Status) -> [AmbiancePackState] {
        [AmbiancePackState(id: "orchestra", title: "Orchestre acoustique", bytes: 77_158_400, status: orchestra),
         AmbiancePackState(id: "textures", title: "Textures et Aube", bytes: 83_363_840, status: textures)]
    }

    @MainActor func testRenderAmbiancePage() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with fixed data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let actions = AmbianceActions(play: { _ in }, stop: {}, download: { _ in }, cancel: { _ in }, remove: { _ in },
                                      addFiles: { _ in }, removeFile: { _ in })

        func render(_ name: String, width: CGFloat, height: CGFloat, _ view: some View) throws {
            let root = view.frame(width: width, height: height)
                .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                .environment(\.goalongReduceMotion, true).goalongControls()
            let controller = NSHostingController(rootView: root)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: height))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let host = controller.view
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 4_000)
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("AMBIANCE_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        var volume = 0.6
        let binding = Binding(get: { volume }, set: { volume = $0 })
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            let playing = sources(orchestra: true, textures: true, files: true)
            try render("setup-\(suffix)", width: 900, height: 1_250, AmbiancePageContent(
                sources: sources(orchestra: false, textures: false, files: false), packs: packs(.notInstalled, .notInstalled),
                state: .idle, volume: binding, actions: actions))
            try render("downloading-\(suffix)", width: 900, height: 560, AmbiancePageContent(
                sources: sources(orchestra: false, textures: false, files: false), packs: packs(.downloading(0.42), .notInstalled),
                state: .idle, volume: binding, actions: actions))
            try render("idle-\(suffix)", width: 900, height: 1_300, AmbiancePageContent(
                sources: sources(orchestra: true, textures: false, files: false), packs: packs(.installed, .downloading(0.67)),
                state: .idle, lastSource: "confluence", volume: binding, actions: actions))
            try render("playing-\(suffix)", width: 900, height: 1_500, AmbiancePageContent(
                sources: playing, packs: packs(.installed, .installed),
                state: .playing(playing[0]), volume: binding, actions: actions))
            try render("narrow-\(suffix)", width: 640, height: 900, AmbiancePageContent(
                sources: playing, packs: packs(.installed, .installed),
                state: .playing(playing[0]), volume: binding, actions: actions))
        }
    }
}
#endif
