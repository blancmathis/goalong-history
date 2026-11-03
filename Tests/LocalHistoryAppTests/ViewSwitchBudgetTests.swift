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
    /// started ~300 ms after the click (the real dashboard, gallery data, a window never on screen). Now ~50 ms.
    /// Budget: the read starts within 200 ms of the accessibility press on « 28 jours ».
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
            let host = NSHostingView(rootView: LocalHistoryDashboardView(model: model)
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
            for _ in 0..<20 { spin(host) }
            let button = try XCTUnwrap(ViewSwitchAX.first(in: host) {
                $0.replacingOccurrences(of: "\u{00A0}", with: " ") == "28 jours" })
            let before = GoalongAnalyticsModel.loadsStarted
            let pressed = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(ViewSwitchAX.flag(button, "accessibilityPerformPress"), true)
            while GoalongAnalyticsModel.loadsStarted == before, ProcessInfo.processInfo.systemUptime - pressed < 2 { spin(host) }
            let delay = ProcessInfo.processInfo.systemUptime - pressed
            XCTAssertGreaterThan(GoalongAnalyticsModel.loadsStarted, before, "the 28-day read never started")
            XCTAssertLessThan(delay, 0.2, "the 28-day read started \(Int(delay * 1_000)) ms after the click")
            FileHandle.standardError.write(Data("[switch-budget] 28-day read started \(Int(delay * 1_000)) ms after the click\n".utf8))
        }
    }

    @MainActor private func spin(_ host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
#endif
