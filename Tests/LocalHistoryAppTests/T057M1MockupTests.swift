#if os(macOS)
import Ambiance
import AppKit
import LocalHistoryCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-057 M1: mockups of « Plan du jour en un clic », « Bilan visible » and the menu bar panel cleanup.
/// Fixture data only. `GOALONG_T057_M1_SNAPSHOTS=<dir>` writes the BEFORE and AFTER PNGs, light and dark.
final class T057M1MockupTests: XCTestCase {
    @MainActor func testJevWatchTextSaysWhatJevDoes() {
        var settings = JevInterventionSettings()
        XCTAssertEqual(MenuBarPanelModel.jevWatchText(settings), "Rappel après 2 min hors travail")
        settings.effectsEnabled = true
        XCTAssertEqual(MenuBarPanelModel.jevWatchText(settings), "Rappel après 2 min hors travail, écran rouge après 5 min")
    }

    func testPlanSummaryProgressIsPlural() {
        XCTAssertEqual(DayPlanSummary(nextTime: nil, nextTitle: nil, done: 0, total: 0).progressText, "Rien de prévu")
        XCTAssertEqual(DayPlanSummary(nextTime: nil, nextTitle: nil, done: 1, total: 4).progressText, "1 fait sur 4")
        XCTAssertEqual(DayPlanSummary(nextTime: nil, nextTitle: nil, done: 2, total: 4).progressText, "2 faits sur 4")
    }

    @MainActor func testRetryKeepsTheDayUnavailableUntilARead() {
        let model = makeModel()
        model.refresh() // settles the displayed day first
        model.dayUnavailable = true
        model.retryDay() // no loader here: nothing read, nothing cleared
        XCTAssertTrue(model.dayUnavailable)
    }

    // MARK: Render

    @MainActor private func makeModel() -> MenuBarPanelModel {
        let suite = "t057m1-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        return MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
    }

    @MainActor func testRenderMockups() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_T057_M1_SNAPSHOTS"] else { throw XCTSkip("Opt-in T-057 M1 mockup render") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }

        func snapshot(_ name: String, _ view: some View, width: CGFloat, height: CGFloat? = nil) throws {
            let controller = NSHostingController(rootView: view.environment(\.goalongReduceMotion, true))
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: height ?? 1400))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let host = controller.view
            window.setContentSize(NSSize(width: width, height: height ?? host.fittingSize.height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            print("T057M1_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        let model = makeModel()
        func base() {
            model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
            model.workSeconds = 11520; model.otherSeconds = 2880; model.workKnown = true; model.dayUnavailable = false
            model.segments = [.init(id: 0, start: 0.34, end: 0.40, kind: .work), .init(id: 1, start: 0.405, end: 0.425, kind: .other),
                              .init(id: 2, start: 0.43, end: 0.47, kind: .work)]
            model.nowFraction = 0.49
            model.focusAvailable = true; model.concentrationEnabled = true; model.focusKind = .pomodoro; model.focusMinutes = 25
            model.focusRun = nil; model.live = []; model.dayPlanSummary = nil
            model.ambianceEnabled = true; model.ambianceExpanded = false
            model.blockingEnabled = true
        }
        let sources = ["Ambre", "Canopée", "Méridien", "Sillage", "Filigrane", "Orbite", "Lagon", "Pluie douce", "Marée", "Brume", "Aube", "Dune"]
            .map { AmbianceSource(id: $0.lowercased(), title: $0, kind: .focus, isAvailable: true) }
        model.ambianceSources = sources; model.ambianceCurrent = sources[1]

        let slots: [DayPlanSlotPreview] = [
            .init(id: 0, time: "09:00 – 10:30", title: "Rédaction du rapport", state: .done),
            .init(id: 1, time: "10:45 – 11:30", title: "Relire les retours clients", state: .done),
            .init(id: 2, time: "14:30 – 16:00", title: "Préparer la démo", state: .planned),
            .init(id: 3, time: "16:15 – 17:00", title: "Réponses aux e-mails", state: .planned),
            .init(id: 4, time: "17:00 – 17:30", title: "Bilan et lendemain", state: .planned),
        ]
        let moment = Date(timeIntervalSince1970: 1_795_000_000)
        let navigation = GoalongActivityNavigation(day: moment, now: moment)
        func header(plan: Bool, evening: Bool = false) -> some View {
            GoalongActivityHeader(selection: navigation, isPreview: false, isRefreshing: false, onDay: { _ in }, onPeriod: { _ in },
                                  onStep: { _ in }, onToday: {}, onReturn: {}, onShare: {},
                                  onPlan: plan ? {} : nil, onRecap: plan ? {} : nil,
                                  endOfDayHint: evening ? "Journée terminée · 6 h 12 de travail" : nil)
                .frame(width: 900).background(LHTheme.pageBackground).goalongControls()
        }
        func heavy() {
            base()
            model.focusRun = .init(phaseTitle: "Travail", remaining: 1122, elapsed: 378, progress: 0.25, cycle: 2, cycles: 4,
                                   nextBreak: Date(timeIntervalSince1970: 1_791_716_400), isPaused: false)
            model.live = (0..<5).map { .init(id: "r\($0)", title: "Bloque Liste \($0 + 1)", detail: "En cours jusqu’à 1\($0 + 1):30", lock: .free, stop: .now) }
            model.ambianceExpanded = true; model.ambianceSoundsBuilt = true
        }

        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.appearance = app.appearance
            let s = dark ? "dark" : "light"
            // 1. Plan du jour
            base()
            try snapshot("1-plan-popover-before-\(s)", MenuBarPanelView(model: model), width: 340)
            model.dayPlanSummary = .init(nextTime: "14:30", nextTitle: "Préparer la démo", done: 2, total: 5)
            try snapshot("1-plan-popover-after-\(s)", MenuBarPanelView(model: model), width: 340)
            try snapshot("1-plan-activity-before-\(s)", header(plan: false), width: 900)
            try snapshot("1-plan-activity-after-\(s)", header(plan: true), width: 900)
            try snapshot("1-plan-view-\(s)", DayPlanView(dayTitle: "Vendredi 27 novembre", slots: slots).frame(width: 640)
                .background(LHTheme.pageBackground).goalongControls(), width: 640)
            // 4. Bilan visible
            try snapshot("4-bilan-activity-after-\(s)", header(plan: true), width: 900)
            try snapshot("4-bilan-activity-evening-\(s)", header(plan: true, evening: true), width: 900)
            // popover: heavy content, short screen
            heavy()
            let screen: CGFloat = 560
            try snapshot("p3-bounded-before-natural-\(s)", MenuBarPanelView(model: model), width: 340)
            try snapshot("p3-bounded-before-short-screen-\(s)", MenuBarPanelView(model: model).frame(height: screen, alignment: .top).clipped(),
                         width: 340, height: screen)
            try snapshot("p3-bounded-after-short-screen-\(s)", MenuBarPanelView(model: model, maxHeight: screen), width: 340, height: screen)
            // day unavailable
            base(); model.workKnown = false; model.workSeconds = 0; model.segments = []
            try snapshot("p2-day-unavailable-before-\(s)", MenuBarPanelView(model: model), width: 340)
            model.dayUnavailable = true
            try snapshot("p2-day-unavailable-after-\(s)", MenuBarPanelView(model: model), width: 340)
            // Jev watch
            base()
            model.live = [.init(id: "jev", title: "Surveillance", detail: "En cours jusqu’à 17:00", lock: .free, stop: .page)]
            try snapshot("p4-jev-watch-before-\(s)", MenuBarPanelView(model: model), width: 340)
            model.live = [.init(id: "jev", title: "Jev surveille", detail: "En cours jusqu’à 17:00", lock: .free, stop: .page,
                                jevWatch: "Rappel après 2 min hors travail, écran rouge après 5 min")]
            try snapshot("p4-jev-watch-after-\(s)", MenuBarPanelView(model: model), width: 340)
        }
    }
}
#endif
