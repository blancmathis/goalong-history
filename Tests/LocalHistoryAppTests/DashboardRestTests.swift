#if os(macOS)
import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// R14b § 5: at rest the dashboard republishes nothing. The model's two wakeups (status every 5 s, today's data every
/// 60 s) run one minute on a virtual clock, on the busy member's real window content (never on screen): no store
/// publishes, and neither the page shown nor the pages kept hidden evaluate their body. One real data change then
/// publishes exactly once and leaves the hidden pages still. Pages: Activité, Concentration, Blocage, Réglages.
final class DashboardRestTests: XCTestCase {
    /// The two wakeups of `DashboardRefreshScheduler`, fired by hand.
    private final class Wakeups {
        final class Task: DashboardScheduledTask {
            let interval: TimeInterval, action: () -> Void
            var cancelled = false
            init(_ interval: TimeInterval, _ action: @escaping () -> Void) { self.interval = interval; self.action = action }
            func cancel() { cancelled = true }
        }
        var tasks: [Task] = []
        lazy var schedule: DashboardRefreshScheduler.Schedule = { [unowned self] interval, action in
            let task = Task(interval, action)
            tasks.append(task)
            return task
        }

        /// One minute: 12 status wakeups and 1 data wakeup, in time order; `after` runs after each one.
        func minute(after: () -> Void) -> (status: Int, data: Int) {
            var fired = (status: 0, data: 0)
            for second in 1...60 {
                for task in tasks where !task.cancelled && second % Int(task.interval) == 0 {
                    task.action()
                    after()
                    if task.interval == DashboardRefreshScheduler.runtimeInterval { fired.status += 1 } else { fired.data += 1 }
                }
            }
            return fired
        }
    }

    @MainActor func testRestPublishesNothingAndHiddenPagesStayStill() throws {
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            let wakeups = Wakeups()
            let (model, window, host, _, _) = try ViewSwitchTimingTests.memberDashboard(ctx, days: 7,
                scheduler: DashboardRefreshScheduler(schedule: wakeups.schedule))
            defer { window.contentView = nil; window.close(); DashboardBodyProbe.counting = false }
            ViewSwitchTimingTests.draw(host)
            XCTAssertNotNil(ViewSwitchTimingTests.settle(host, model: model, timeout: 30), "Activité never finished its first read")
            if let pages = ViewSwitchTimingTests.keptPages(in: host) {
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while pages.preheatPending > 0, ProcessInfo.processInfo.systemUptime < deadline {
                    _ = ViewSwitchTimingTests.settle(host, model: model, timeout: 0.05)
                }
            }
            @MainActor func pump() {
                model.waitForPendingWorkForTesting()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            @MainActor func show(_ section: DashboardSection) {
                if let button = ViewSwitchTimingTests.node("sidebar-\(section.rawValue)", in: host) {
                    XCTAssertEqual(ViewSwitchAX.flag(button, "accessibilityPerformPress"), true, "press \(section)")
                } else {
                    model.selectSection(section)  // Blocage: the hub's tab does this
                }
                XCTAssertNotNil(ViewSwitchTimingTests.settle(host, model: model, timeout: 20), "\(section) never completed")
                pump()
            }
            // Every variant visited once, so the others are kept hidden while one is shown.
            let variants: [(DashboardSection, Set<String>)] = [
                (.overview, ["activite"]), (.concentration, ["concentration", "concentration-maintenant"]),
                (.blocking, ["concentration", "blocage"]), (.settings, ["reglages"]),
            ]
            for (section, _) in variants { show(section) }

            var publications: [String: Int] = [:]
            let stores: [(String, ObservableObjectPublisher)] = [
                ("device", model.deviceStore.objectWillChange), ("alert", model.alertStore.objectWillChange),
                ("navigation", model.navigationStore.objectWillChange), ("settings", model.settingsStore.objectWillChange),
                ("runtime", model.runtimeStore.objectWillChange), ("snapshot", model.snapshotStore.objectWillChange),
            ]
            let watches = stores.map { name, publisher in publisher.sink { publications[name, default: 0] += 1 } }
            defer { watches.forEach { $0.cancel() } }

            for (section, shown) in variants {
                show(section)
                publications = [:]
                DashboardBodyProbe.reset()
                DashboardBodyProbe.counting = true
                let fired = wakeups.minute(after: pump)
                for _ in 0..<5 { pump() }
                DashboardBodyProbe.counting = false
                XCTAssertEqual(fired.status, 12, "\(section): the status wakeup did not run every 5 s")
                XCTAssertEqual(fired.data, 1, "\(section): the data wakeup did not run once")
                XCTAssertEqual(publications, [:], "\(section): a store published at rest")
                XCTAssertEqual(DashboardBodyProbe.counts, [:], "\(section): a body was evaluated at rest")
                log("\(section.rawValue) rest: publications \(publications) bodies \(DashboardBodyProbe.counts)")

                // Control: one changed read publishes once; the shown page updates at most once, hidden pages not at all.
                let now = model.snapshotStore.snapshot
                DashboardBodyProbe.reset()
                DashboardBodyProbe.counting = true
                XCTAssertTrue(model.publishSnapshot(Self.changed(now)), "\(section): a changed read was dropped")
                for _ in 0..<5 { pump() }
                DashboardBodyProbe.counting = false
                XCTAssertEqual(publications, ["snapshot": 1], "\(section): one data change must publish exactly once")
                let hidden = DashboardBodyProbe.counts.filter { !shown.contains($0.key) && $0.key != "root" && $0.key != "sidebar" }
                XCTAssertEqual(hidden, [:], "\(section): a hidden page was evaluated")
                XCTAssertTrue(DashboardBodyProbe.counts.values.allSatisfy { $0 <= 1 }, "\(section): \(DashboardBodyProbe.counts)")
                log("\(section.rawValue) control: publications \(publications) bodies \(DashboardBodyProbe.counts)")
                // Back to the real read before the next page (not counted).
                XCTAssertTrue(model.publishSnapshot(now))
                pump()
            }
        }
    }

    /// The same day with one more event: a real change of the data the 60 s pass reads.
    static func changed(_ s: DashboardDaySnapshot) -> DashboardDaySnapshot {
        DashboardDaySnapshot(day: s.day, eventCount: s.eventCount + 1, activeMinutes: s.activeMinutes,
            workMinutes: s.workMinutes, sealedMinutes: s.sealedMinutes, liveAnchoredMinutes: s.liveAnchoredMinutes,
            privateMinutes: s.privateMinutes, softwareAttributedEvents: s.softwareAttributedEvents, sessions: s.sessions,
            appUsage: s.appUsage, trackedUsage: s.trackedUsage, timeline: s.timeline, storageBytes: s.storageBytes,
            availableDays: s.availableDays)
    }

    private func log(_ text: String) { FileHandle.standardError.write(Data("[rest] \(text)\n".utf8)) }
}
#endif
