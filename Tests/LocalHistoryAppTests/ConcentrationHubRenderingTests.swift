#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// Opt-in renders of the four Concentration tabs, with fixed data only. Run with an isolated HOME:
/// `GOALONG_CONCENTRATION_HUB_SNAPSHOTS=<dir> HOME=<tmp> CFFIXED_USER_HOME=<tmp> swift test --filter ConcentrationHubRenderingTests`
final class ConcentrationHubRenderingTests: XCTestCase {
    private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    @MainActor func testRenderConcentrationTabs() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_CONCENTRATION_HUB_SNAPSHOTS"] else {
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
        let root = URL(fileURLWithPath: "/private/tmp/focus-hub-render-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "hub-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let modules = GoalongModuleStore(defaults: defaults)
        modules.setEnabled(.blocking, true)
        let blockingWasOn = GoalongModuleStore.shared.isEnabled(.blocking)
        GoalongModuleStore.shared.setEnabled(.blocking, true)
        defer { GoalongModuleStore.shared.setEnabled(.blocking, blockingWasOn) }
        try FileManager.default.createDirectory(at: AppPaths.applicationSupportDirectory, withIntermediateDirectories: true)
        BlockingRuntime.shared.start(modules: modules)
        defer { BlockingRuntime.shared.apply(enabled: false) }
        // The shared runtime only shows « Nouvelle liste… »; the data lives in memory, like the other renders.
        let blocking = BlockingController(document: BlockingDocument(), clock: { Date() }, continuous: { Date().timeIntervalSince1970 })
        let lists = BlockingRuntime(controller: blocking)

        func render(_ name: String, width: CGFloat = 900, height: CGFloat, _ view: some View) throws {
            let content = view.frame(width: width, height: height)
                .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                .environment(\.goalongReduceMotion, true).goalongControls()
            let controller = NSHostingController(rootView: content)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: height))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let host = controller.view
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("HUB_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }
        func tab(_ section: DashboardSection, _ content: some View) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ConcentrationHubHeader(tab: .constant(section))
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }

        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15, minute: 10))!
        let clock = Clock(Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: now)!)
        func controller(_ name: String) throws -> ConcentrationController {
            try ConcentrationController(store: FocusStore(directory: root.appendingPathComponent(name)),
                                        clock: { clock.now }, blocking: { blocking })
        }
        var draft = FocusComposerDraft(); draft.free = .minutes(50)

        // No list yet: the composer offers « Nouvelle liste… » right where lists are picked.
        let empty = try controller("empty")
        app.appearance = NSAppearance(named: .darkAqua); window.appearance = app.appearance
        try render("tab-maintenant-no-list-dark", height: 760,
                   tab(.concentration, ConcentrationPageContent(controller: empty, now: now, measures: [], draft: draft)))
        try render("tab-distractions-empty-dark", height: 760, tab(.distractions, DistractionsPage(runtime: lists, now: now)))

        blocking.save(BlockList(name: "Réseaux sociaux", sites: ["instagram.com", "x.com", "tiktok.com"].map { BlockSiteRule(pattern: $0) },
                                apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")]))
        blocking.save(BlockList(name: "Vidéo", sites: ["netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) }))

        // A finished session where monitoring saw three distractions outside every list.
        let ended = try controller("ended")
        var mode = FocusMode(); mode.minutes = 50
        try ended.startSession(intent: "Rédiger le chapitre 2", mode: mode)
        for (target, windows) in [(JevDistractionTarget.site(host: "www.youtube.com")!, 26),
                                  (JevDistractionTarget.site(host: "lemonde.fr")!, 12),
                                  (JevDistractionTarget.app(bundleIdentifier: "com.valvesoftware.steam", name: "Steam")!, 9)] {
            for _ in 0..<windows {
                let start = clock.now
                let w = JevWindow(start: start, end: start.addingTimeInterval(15), samples: [
                    .init(date: start, resource: target.name, title: "", action: "scroll", surface: "other",
                          isActivity: true, distractionTarget: target)])
                clock.now = w.end
                try ended.recordJevDistraction(window: w, verdict: .procrastination, sessionID: ended.currentSession!.id)
            }
        }
        clock.now = clock.now.addingTimeInterval(600)
        try ended.stopSession(); ended.dismissPanel()
        clock.now = now

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.appearance = app.appearance
            let s = dark ? "dark" : "light"
            try render("tab-maintenant-suggestions-\(s)", height: 1_100,
                       tab(.concentration, ConcentrationPageContent(controller: ended, now: now, measures: [], draft: draft)))
            try render("tab-distractions-\(s)", height: 820, tab(.distractions, DistractionsPage(runtime: lists, now: now)))
            try render("tab-programme-\(s)", height: 1_100, tab(.blocking, BlockingPageContent(controller: blocking, now: now)))
            try render("tab-surveillance-\(s)", height: 1_000, tab(.monitoring, JevMonitoringPage(onOpenRecording: {})))
        }
        try render("tab-off-light", height: 300,
                   tab(.concentration, GoalongModuleOffNote(module: .concentration,
                                                            text: "Séances, Pomodoro, plan du jour et bilan. Le module est désactivé.")))
    }
}
#endif
