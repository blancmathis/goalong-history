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
    /// member of the bench (35 days). Never opt-in, never skipped: it runs on every `swift test`, PR CI included.
    ///
    /// Budget = ratio × reference. The reference is timed in the same run, on the same runner: the median of 7 builds
    /// of a fixed SwiftUI page of text rows (the same kind of work as a page switch). The ratios are written below
    /// with what they were set from; each one keeps ≥ 30 % margin over the slowest median seen on this Mac (debug
    /// build) and on PR CI. Warm = median of the passes after the first; cold = the first click of each view.
    static let switchBudgetRatios: [String: (warm: Double, cold: Double)] = [
        "activite-1j": (warm: 6, cold: 12), "activite-7j": (warm: 6, cold: 12), "activite-28j": (warm: 8, cold: 16),
        "overview": (warm: 6, cold: 12), "settings": (warm: 6, cold: 12), "history": (warm: 6, cold: 12),
        "work": (warm: 6, cold: 12), "concentration": (warm: 6, cold: 12),
    ]

    @MainActor func testEachViewSwitchStaysWithinItsBudget() throws {
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
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
            let reference = Self.referenceMs()

            var samples: [ViewSwitchTimingTests.Sample] = []
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
            }
            Self.budgetLog(String(format: "reference %.1f ms (median of 7 builds of the reference page)", reference))
            // R14a calibration probe (temporary): candidate references, to keep the one whose ratios hold across machines.
            let candidates = [("lazy", Self.lazyReferenceMs()), ("state", Self.stateReferenceMs()), ("cpu", Self.cpuReferenceMs())]
            for (name, ms) in candidates {
                let ratios = Self.switchBudgetRatios.keys.sorted().map { view -> String in
                    let rows = samples.filter { $0.view == view }
                    let warm = ViewSwitchTimingTests.median(rows.filter { $0.pass > 0 }.compactMap(\.firstLayoutMs))
                    let cold = rows.first { $0.pass == 0 }?.firstLayoutMs ?? .infinity
                    return String(format: "%@ %.2f/%.2f", view, warm / ms, cold / ms)
                }
                Self.budgetLog(String(format: "candidate %@ %.2f ms: ", name, ms) + ratios.joined(separator: ", "))
            }
            for (view, ratio) in Self.switchBudgetRatios.sorted(by: { $0.key < $1.key }) {
                let rows = samples.filter { $0.view == view }
                XCTAssertEqual(rows.count, 5, "\(view) was not measured")
                let warm = ViewSwitchTimingTests.median(rows.filter { $0.pass > 0 }.compactMap(\.firstLayoutMs))
                let cold = rows.first { $0.pass == 0 }?.firstLayoutMs ?? .infinity
                let warmBudget = ratio.warm * reference, coldBudget = ratio.cold * reference
                Self.budgetLog(String(format: "%@ warm %.1f ms / budget %.0f ms (%.1f × ref, margin %.0f %%), cold %.1f ms / budget %.0f ms (%.1f × ref, margin %.0f %%)",
                    view, warm, warmBudget, warm / reference, (1 - warm / warmBudget) * 100,
                    cold, coldBudget, cold / reference, (1 - cold / coldBudget) * 100))
                XCTAssertLessThan(warm, warmBudget, "\(view): a warm click blocks \(Int(warm)) ms, budget \(Int(warmBudget)) ms")
                XCTAssertLessThan(cold, coldBudget, "\(view): the first click blocks \(Int(cold)) ms, budget \(Int(coldBudget)) ms")
            }
        }
    }

    /// The calibration page: 240 rows of icon and texts, rebuilt under a new identity each time (as a page switch builds
    /// its page), laid out in a window never on screen. Median of 7 after 2 untimed builds.
    private struct ReferencePage: View {
        let seed: Int
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<240, id: \.self) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row % 2 == 0 ? "clock" : "folder").frame(width: 14)
                        Text("Contexte \(row + seed) · application \(row % 9)").lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(row * 7 + seed) min").monospacedDigit()
                    }
                }
            }
            .padding(20)
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

    /// Candidate: the same rows in a lazy stack under a scroll view (only the rows in the window are built).
    private struct LazyReferencePage: View {
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

    @MainActor private static func lazyReferenceMs() -> Double {
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LazyReferencePage(seed: 0))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var times: [Double] = []
        for seed in 1...9 {
            let start = ProcessInfo.processInfo.systemUptime
            host.rootView = LazyReferencePage(seed: seed)
            host.layoutSubtreeIfNeeded()
            if seed > 2 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
        }
        return ViewSwitchTimingTests.median(times)
    }

    /// Candidate: one page kept, its content swapped by a published value (as a period change), laid out.
    private final class ReferenceState: ObservableObject { @Published var period = 0 }
    private struct StateReferencePage: View {
        @ObservedObject var state: ReferenceState
        var body: some View {
            let count = [7, 28, 1][state.period % 3]
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<count, id: \.self) { row in
                    HStack(spacing: 8) {
                        Text("Jour \(row + 1)").frame(width: 64, alignment: .leading)
                        ForEach(0..<6, id: \.self) { band in
                            Button {} label: { Color.gray.frame(width: Self.width(row, band, state.period), height: 10) }
                                .buttonStyle(.plain).help("Bande \(band)")
                        }
                        Spacer(minLength: 8)
                        Text("\(row * 7 + state.period) min").monospacedDigit()
                    }
                }
            }
            .padding(20)
        }
        static func width(_ row: Int, _ band: Int, _ period: Int) -> CGFloat { CGFloat(10 + (row * 7 + band * 3 + period) % 40) }
    }

    @MainActor private static func stateReferenceMs() -> Double {
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let state = ReferenceState()
        let host = NSHostingView(rootView: StateReferencePage(state: state))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var times: [Double] = []
        for step in 1...11 {
            let start = ProcessInfo.processInfo.systemUptime
            state.period = step
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded()
            if step > 2 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
        }
        return ViewSwitchTimingTests.median(times)
    }

    /// Candidate: plain CPU work, no UI (sort of a fixed pseudo-random array), median of 7.
    private static func cpuReferenceMs() -> Double {
        var times: [Double] = []
        for run in 0..<9 {
            var x: UInt64 = 0x9E3779B97F4A7C15
            var values: [UInt64] = []
            values.reserveCapacity(200_000)
            for _ in 0..<200_000 {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                values.append(x)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let sorted = values.sorted()
            if run > 1 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
            XCTAssertEqual(sorted.count, values.count)
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
