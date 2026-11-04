#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// R13a guards. A view change must not wait: no full scan of a period's segments each time the page reads a total,
/// and no animated transaction that holds back the page's `.task(id:)` reads. Both budgets keep a wide margin, so a
/// slow runner stays green while the former code stays red (see each test).
final class ViewSwitchBudgetTests: XCTestCase {
    /// A busy 28-day period: ~1,500 segments a day, as on a member with a context change every 40 s.
    private static func busyPeriod(days: Int = 28, perDay: Int = 1_500) -> GoalongLocalAnalytics.Period {
        let kinds: [GoalongLocalAnalytics.Kind] = [.work, .other, .unclassified, .work, .idle, .unobserved]
        let origin = Date(timeIntervalSince1970: 1_790_000_000)
        return GoalongLocalAnalytics.Period(days: (0..<days).map { day in
            let start = origin.addingTimeInterval(Double(day) * 86_400)
            let segments = (0..<perDay).map { index in
                var segment = GoalongLocalAnalytics.Segment(
                    start: start.addingTimeInterval(Double(index) * 40), end: start.addingTimeInterval(Double(index + 1) * 40),
                    kind: kinds[index % kinds.count], application: "App \(index % 9)", bundleIdentifier: "fr.exemple.app\(index % 9)",
                    host: index % 3 == 0 ? "site\(index % 5).exemple.fr" : nil)
                segment.task = index % 4 == 0 ? "Tâche \(index % 3)" : nil
                return segment
            }
            return GoalongLocalAnalytics.Day(date: start, end: start.addingTimeInterval(86_400), state: .ready,
                                             segments: segments, eventCount: perDay * 10, classifierVersions: [])
        })
    }

    /// The former code filtered every segment of the period on each read (~170 ms per round here, ~17 s for 100 rounds);
    /// the totals are now computed once with the day. Budget: 100 rounds in 1 s.
    func testPeriodTotalsDoNotRescanSegmentsOnEachRead() {
        let period = Self.busyPeriod()
        let summary = GoalongActivitySummary(period: period, previous: period, now: .distantFuture)
        // Same values as the definitions they replace.
        for day in period.days.prefix(3) {
            for kind in GoalongLocalAnalytics.Kind.allCases {
                XCTAssertEqual(day.seconds(kind), day.segments.filter { $0.kind == kind }.reduce(0) { $0 + $1.seconds })
            }
            XCTAssertEqual(day.observedSeconds, day.segments.filter { $0.kind != .unobserved }.reduce(0) { $0 + $1.seconds })
            XCTAssertEqual(day.contextChanges, zip(day.segments, day.segments.dropFirst()).filter { a, b in
                a.kind.isActive && b.kind.isActive && a.end == b.start && a.context != b.context }.count)
            XCTAssertGreaterThan(day.contextChanges, 0)
            XCTAssertFalse(day.sequences.isEmpty)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var sink = 0.0
        for _ in 0..<100 {
            sink += period.activeSeconds + period.observedSeconds + period.workSeconds
            sink += Double(period.contextChanges + period.sameTaskChanges + period.daysWithObservations)
            sink += summary.averagePerDay(.work) ?? 0
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(elapsed, 1.0, "100 reads of a 28-day period's totals took \(Int(elapsed * 1_000)) ms")
    }

    /// The former segmented control changed its value inside `withAnimation(settle)`: Activité's `.task(id:)` read
    /// started ~300 ms after the click (the real dashboard, gallery data, a window never on screen). Now one turn.
    @MainActor func testActivityPeriodReadStartsRightAfterTheClick() throws {
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            var options = GalleryFixtures.DashboardOptions()
            options.section = .overview
            let model = try GalleryFixtures.dashboardModel(ctx, options)
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790),
                                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            DashboardWindowController.configure(window)
            let host = DashboardWindowContent(rootView: LocalHistoryDashboardView(model: model)
                .defaultAppStorage(ctx.defaults)
                .environment(\.goalongDefaults, ctx.defaults)
                .environment(\.locale, GalleryClock.locale)
                .environment(\.timeZone, GalleryClock.timeZone)
                .environment(\.calendar, GalleryClock.calendar))
            window.contentView = host
            window.setContentSize(NSSize(width: 1180, height: 790))
            defer { window.contentView = nil; window.close() }
            let ready = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - ready < 10,
                  GoalongAnalyticsModel.loadsStarted == 0 || GoalongAnalyticsModel.loadsInFlight > 0 {
                spin(host)
            }
            // R14a: the old control held the read back after the click's layout (~300 ms of animation). The guard times
            // that wait alone: from the layout of the new selection (the click's own CPU work, guarded per view by
            // testEachViewSwitchStaysWithinItsBudget) to the start of the read. One quiet main-loop turn (2 ms wait,
            // layout, display) is timed first, as the runner's speed: budget = 6 turns, at least 60 ms, never above
            // 150 ms (half the old hold-back). R13c budget (whole delay < 200 ms) left 25 % margin in release.yml.
            var turns: [Double] = []
            for _ in 0..<20 {
                let turn = ProcessInfo.processInfo.systemUptime
                spin(host)
                turns.append(ProcessInfo.processInfo.systemUptime - turn)
            }
            let quietTurn = turns.sorted()[turns.count / 2]
            let budget = min(0.15, max(0.06, 6 * quietTurn))
            let button = try XCTUnwrap(ViewSwitchAX.first(in: host) {
                $0.replacingOccurrences(of: "\u{00A0}", with: " ") == "28 jours" })
            let before = GoalongAnalyticsModel.loadsStarted
            let pressed = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(ViewSwitchAX.flag(button, "accessibilityPerformPress"), true)
            // A period seen before commits after its off-main source check (R14a), then lays out once.
            while GoalongAnalyticsModel.selectionsPending > 0, ProcessInfo.processInfo.systemUptime - pressed < 2 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            host.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime - pressed
            while GoalongAnalyticsModel.loadsStarted == before, ProcessInfo.processInfo.systemUptime - pressed < 2 { spin(host) }
            let delay = ProcessInfo.processInfo.systemUptime - pressed
            let wait = max(0, delay - laidOut)
            XCTAssertGreaterThan(GoalongAnalyticsModel.loadsStarted, before, "the 28-day read never started")
            XCTAssertLessThan(wait, budget, "the 28-day read waited \(Int(wait * 1_000)) ms after the click's layout")
            FileHandle.standardError.write(Data(("[switch-budget] 28-day read started \(Int(delay * 1_000)) ms after the click,"
                + " \(Int(wait * 1_000)) ms after its layout (budget \(Int(budget * 1_000)) ms, margin"
                + " \(Int((1 - wait / budget) * 100)) %, quiet turn \(Int(quietTurn * 1_000)) ms)\n").utf8))
        }
    }

    /// R14a: the main-thread block of each click (press + layout, the bench's « blocage »), per view, on the busy
    /// member of the bench (35 days). Never opt-in, never skipped: it runs on every `swift test`, PR CI included
    /// (and release.yml, which runs the same tests through build_app.sh).
    ///
    /// Budget = ratio × reference. The reference is timed in the same run, on the same runner, before the first pass of
    /// clicks and after each (median of the 6): each time the median of 7 rebuilds of a fixed lazy page (scroll view, lazy stack, rows of text
    /// and plain buttons), the same kind of work as a page switch. Chosen out of four candidates measured on this Mac and
    /// on PR CI (35251da): its ratios move least between the two (CI/Mac 0.5-0.76 per view); an eager 240-row stack
    /// moved ×0.35, a kept page swapped by state ×0.7 (same as lazy), a plain CPU sort ×1.4-1.7.
    /// Warm = median of passes 1-4, against the median reference. Cold = pass 0, the first click of each view on a new
    /// dashboard once the other periods are stored (R14c); for Activité and the overview, from the click to « complet »
    /// (longest block), for the other pages the block at the click; against the
    /// reference timed just before and after that pass.
    /// Warm ratios (R14a) = highest seen / 0.7 over 5 Mac runs, 1 `make check` and PR CI 35251da. Highest warm seen
    /// again at R14c (4 Mac runs, debug, test alone): 1 j 2.37 · 7 j 2.16 · 28 j 4.57 · overview 1.25 · settings 1.10 ·
    /// history 1.39 · work 0.71 · concentration 0.39.
    /// Cold ratios (R14c) = highest seen / 0.7 over those 4 runs and 2 more (load 17-22): 1 j 2.53 · 7 j 3.30 ·
    /// 28 j 7.43 · overview 1.19. The sidebar pages other than the overview are not Activité's: their cold stays the
    /// block at the click (R14a; their own later reads are two-moded, history 20 or 37 ms), highest seen settings 0.89 ·
    /// history 0.60 · work 0.91 · concentration 0.55 (work and concentration widened to keep 30 %). Before R14c the first Activité click waited on
    /// EventKit's permission answer (×2-3 in cold): its budgets were 9.7-20 × ref and let that wait through.
    static let switchBudgetRatios: [String: (warm: Double, cold: Double)] = [
        "activite-1j": (warm: 3.6, cold: 3.6), "activite-7j": (warm: 3.3, cold: 4.7), "activite-28j": (warm: 6.8, cold: 10.6),
        "overview": (warm: 1.9, cold: 1.7), "settings": (warm: 1.7, cold: 1.5), "history": (warm: 2.1, cold: 0.9),
        "work": (warm: 1.15, cold: 1.3), "concentration": (warm: 0.75, cold: 0.8),
    ]

    /// R14c: the reference is timed 6 times in a run (before the first pass, then after each). When the slowest of the
    /// 6 is more than `steadyReferenceSpread` × the fastest, the runner's load changed during the run.
    static let steadyReferenceSpread = 1.6

    @MainActor func testEachViewSwitchStaysWithinItsBudget() throws {
        // A busy runner (or Mac) is slow now and then, and its reference moves with it: a run over budget whose
        // reference moved is measured again, from a new dashboard, up to 3 runs in all. A run over budget on a steady
        // reference fails at once: an intermittent regression (one slow click in two) is not hidden by a retry (R14c).
        // Each run is logged: a retry is never silent.
        var over: [String] = []
        for attempt in 1...3 {
            let run = try Self.measureSwitchBudgets(attempt: attempt)
            over = run.over
            if over.isEmpty { break }
            Self.budgetLog("run \(attempt) over budget (reference \(run.moved ? "moved: measured again" : "steady: no retry")): "
                + over.joined(separator: "; "))
            if !run.moved { break }
        }
        for failure in over { XCTFail(failure) }
    }

    /// One run: a new member dashboard, 5 passes over the views, the reference timed after each pass (same load as the
    /// clicks around it; its median is used). Returns the views over budget.
    @MainActor private static func measureSwitchBudgets(attempt: Int) throws -> (over: [String], moved: Bool) {
        var over: [String] = [], moved = false
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            let preloadBase = GoalongAnalyticsModel.preloadsStarted
            let (model, window, host, _, _) = try ViewSwitchTimingTests.memberDashboard(ctx, days: 35)
            defer { window.contentView = nil; window.close() }
            ViewSwitchTimingTests.draw(host)
            XCTAssertNotNil(ViewSwitchTimingTests.settle(host, model: model, timeout: 60), "Activité never finished its first read")
            let pages = try XCTUnwrap(ViewSwitchTimingTests.keptPages(in: host), "no kept-pages layer")
            let preheat = ProcessInfo.processInfo.systemUptime
            while pages.preheatPending > 0, ProcessInfo.processInfo.systemUptime - preheat < 60 {
                _ = ViewSwitchTimingTests.settle(host, model: model, timeout: 0.05)
            }
            XCTAssertEqual(pages.preheatPending, 0, "the main pages were never built at rest")
            _ = ViewSwitchTimingTests.settle(host, model: model, timeout: 20)
            ViewSwitchTimingTests.waitForPreloads(host, model: model, since: preloadBase)

            var samples: [ViewSwitchTimingTests.Sample] = []
            var references: [Double] = [Self.referenceMs()]
            let sections: [DashboardSection] = [.settings, .history, .work, .concentration, .overview]
            for pass in 0..<5 {
                for period in ["7", "28", "1"] {
                    let button = try XCTUnwrap(ViewSwitchTimingTests.periodButton(period, in: host), "no period \(period)")
                    samples.append(ViewSwitchTimingTests.measure("activite-\(period)j", pass: pass, press: button, host: host, model: model))
                }
                for section in sections {
                    let button = try XCTUnwrap(ViewSwitchTimingTests.node("sidebar-\(section.rawValue)", in: host),
                                               "no sidebar entry \(section.rawValue)")
                    samples.append(ViewSwitchTimingTests.measure(section.rawValue, pass: pass, press: button, host: host, model: model))
                }
                references.append(Self.referenceMs())
            }
            let reference = ViewSwitchTimingTests.median(references)
            // The first clicks are one sample each: their reference is the one timed just before and just after them.
            let coldReference = (references[0] + references[1]) / 2
            XCTAssertTrue(reference.isFinite && reference > 0 && coldReference > 0, "the reference page was not timed")
            let spread = (references.max() ?? 0) / max(references.min() ?? 1, 0.001)
            moved = spread > Self.steadyReferenceSpread
            Self.budgetLog(String(format: "run %d reference %.2f ms, first clicks %.2f ms, spread ×%.2f (%@; before and after each pass: %@)",
                                  attempt, reference, coldReference, spread, moved ? "moved" : "steady",
                                  references.map { String(format: "%.1f", $0) }.joined(separator: " ")))
            for (view, ratio) in Self.switchBudgetRatios.sorted(by: { $0.key < $1.key }) {
                let rows = samples.filter { $0.view == view }
                XCTAssertEqual(rows.count, 5, "\(view) was not measured")
                let warm = ViewSwitchTimingTests.median(rows.filter { $0.pass > 0 }.compactMap(\.firstLayoutMs))
                // R14c: the first click is guarded from the click to « complet » (its longest main-thread block). A cold
                // period lays its content out when its data come in, after the selection's own layout: the former
                // window (press + that layout) saw 2 ms for a 28-day first click on CI (dc8d178).
                let first = rows.first { $0.pass == 0 }
                let cold = (view.hasPrefix("activite-") || view == "overview" ? first?.longestMs : first?.firstLayoutMs) ?? .infinity
                if view.hasPrefix("activite-"), rows.first(where: { $0.pass == 0 })?.fromStore != true {
                    over.append("\(view): the first click had no stored read; its cold was not measured")
                }
                let warmBudget = ratio.warm * reference, coldBudget = ratio.cold * coldReference
                Self.budgetLog(String(format: "run %d %@ warm %.1f ms / budget %.1f ms (%.2f × ref, margin %.0f %%), cold %.1f ms / budget %.1f ms (%.2f × ref, margin %.0f %%, block at the click %.1f ms%@)",
                    attempt, view, warm, warmBudget, warm / reference, (1 - warm / warmBudget) * 100,
                    cold, coldBudget, cold / coldReference, (1 - cold / coldBudget) * 100,
                    rows.first { $0.pass == 0 }?.firstLayoutMs ?? -1,
                    rows.first { $0.pass == 0 }?.fromStore == true ? ", stored read" : ""))
                if !(warm < warmBudget) { over.append("\(view): a warm click blocks \(Int(warm)) ms, budget \(Int(warmBudget)) ms") }
                if !(cold < coldBudget) { over.append("\(view): the first click blocks \(Int(cold)) ms, budget \(Int(coldBudget)) ms") }
            }
        }
        return (over, moved)
    }

    /// The calibration page: 240 rows of icon, text and a plain button in a lazy stack under a scroll view (only the
    /// rows in the window are built), rebuilt under a new identity each time as a page switch builds its page, laid
    /// out in a window never on screen. Median of 7 after 2 untimed builds.
    private struct ReferencePage: View {
        let seed: Int
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<240, id: \.self) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row % 2 == 0 ? "clock" : "folder").frame(width: 14)
                            Text("Contexte \(row + seed) · application \(row % 9)").lineLimit(1)
                            Spacer(minLength: 8)
                            Button("\(row * 7 + seed) min") {}.buttonStyle(.plain).monospacedDigit()
                        }
                    }
                }
                .padding(20)
            }
            .id(seed)
        }
    }

    @MainActor private static func referenceMs() -> Double {
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReferencePage(seed: 0))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var times: [Double] = []
        for seed in 1...9 {
            let start = ProcessInfo.processInfo.systemUptime
            host.rootView = ReferencePage(seed: seed)
            host.layoutSubtreeIfNeeded()
            if seed > 2 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
        }
        return ViewSwitchTimingTests.median(times)
    }

    private static func budgetLog(_ text: String) { FileHandle.standardError.write(Data("[switch-budget] \(text)\n".utf8)) }

    /// R13c: with SwiftUI's default sizing (min, ideal and max size), the dashboard's hosting view measured the whole
    /// page at every animation frame (~40 ms on Activité): the period read then started 140-380 ms after the click.
    func testDashboardHostingViewDoesNotSizeTheWindowFromSwiftUI() {
        XCTAssertEqual(DashboardWindowController.hostingSizing, [])
    }

    /// Without SwiftUI sizing, the window alone keeps the root's smallest size (`.frame(minWidth: 900, minHeight: 620)`
    /// in DashboardRootView). `minSize` counts the title bar: 620 there left 592 pt and cut the page at the smallest window.
    @MainActor func testDashboardWindowKeepsTheRootSmallestContentSize() {
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        defer { window.close() }
        DashboardWindowController.configure(window)
        XCTAssertEqual(window.contentMinSize, DashboardWindowController.minimumContentSize)
    }

    @MainActor private func spin(_ host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
#endif
