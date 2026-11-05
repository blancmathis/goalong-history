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
/// publishes, and neither the page shown nor the pages kept hidden evaluate their body. Then, per page, one real change
/// of a store the page shown observes publishes exactly once, updates that page exactly once and leaves the hidden pages
/// still. Pages shown: Activité, Concentration, Blocage, Réglages; Historique and Travail are kept hidden (preheated).
/// Every one has its own probe.
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
            // The first build of every page is counted, so a probe that never runs cannot pass for a still page.
            DashboardBodyProbe.reset()
            DashboardBodyProbe.counting = true
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
            // Every variant visited once, so the others are kept hidden while one is shown. Per variant: the page shown
            // (its probe must count exactly 1 for the control), the page inside it (at most 1), and the store of the
            // control, one the page shown observes.
            let variants: [(section: DashboardSection, page: String, inner: Set<String>, store: String)] = [
                (.overview, "activite", [], "snapshot"),
                (.concentration, "concentration", ["concentration-maintenant"], "navigation"),
                (.blocking, "safeguards", ["blocage"], "navigation"),
                (.settings, "reglages", [], "settings"),
            ]
            for variant in variants { show(variant.section) }
            DashboardBodyProbe.counting = false
            XCTAssertNotNil(ViewSwitchTimingTests.keptPages(in: host), "the pages are not kept")
            for probe in ["activite", "concentration", "concentration-maintenant", "safeguards", "blocage", "reglages", "historique", "travail"] {
                XCTAssertGreaterThan(DashboardBodyProbe.counts[probe] ?? 0, 0, "the page \(probe) was never built")
            }

            /// One real change of the store `name`, read by the page shown; returns its way back.
            @MainActor func change(_ name: String) -> () -> Void {
                switch name {
                case "snapshot":  // the 60 s pass finds one more event
                    let now = model.snapshotStore.snapshot
                    XCTAssertTrue(model.publishSnapshot(Self.changed(now)), "a changed read was dropped")
                    return { XCTAssertTrue(model.publishSnapshot(now)) }
                case "navigation":  // another Réglages pane: the hub observes the navigation, and stays shown
                    let pane = model.navigationStore.settingsPane
                    model.navigationStore.settingsPane = pane == .modules ? .home : .modules
                    return { model.navigationStore.settingsPane = pane }
                default:  // a configuration notice, which Réglages shows
                    let settings = model.settingsStore
                    let (notice, locked, backup) = (settings.configNotice, settings.configLocked, settings.configBackupName)
                    settings.setConfigStatus(notice: "R14b : témoin du test de repos.", locked: locked, backupName: backup)
                    return { settings.setConfigStatus(notice: notice, locked: locked, backupName: backup) }
                }
            }

            var publications: [String: Int] = [:]
            let stores: [(String, ObservableObjectPublisher)] = [
                ("device", model.deviceStore.objectWillChange), ("alert", model.alertStore.objectWillChange),
                ("navigation", model.navigationStore.objectWillChange), ("settings", model.settingsStore.objectWillChange),
                ("runtime", model.runtimeStore.objectWillChange), ("snapshot", model.snapshotStore.objectWillChange),
            ]
            let watches = stores.map { name, publisher in publisher.sink { publications[name, default: 0] += 1 } }
            defer { watches.forEach { $0.cancel() } }

            for (section, page, inner, store) in variants {
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

                // Control: one real change publishes once and updates the page shown exactly once (a page that stayed
                // still would fail); the pages kept hidden are not evaluated at all.
                DashboardBodyProbe.reset()
                DashboardBodyProbe.counting = true
                let undo = change(store)
                for _ in 0..<5 { pump() }
                DashboardBodyProbe.counting = false
                XCTAssertEqual(publications, [store: 1], "\(section): one change must publish exactly once")
                XCTAssertEqual(DashboardBodyProbe.counts[page], 1, "\(section): the page shown did not update exactly once")
                let hidden = DashboardBodyProbe.counts.filter {
                    $0.key != page && !inner.contains($0.key) && $0.key != "root" && $0.key != "sidebar"
                }
                XCTAssertEqual(hidden, [:], "\(section): a hidden page was evaluated")
                XCTAssertTrue(DashboardBodyProbe.counts.values.allSatisfy { $0 <= 1 }, "\(section): \(DashboardBodyProbe.counts)")
                log("\(section.rawValue) control: publications \(publications) bodies \(DashboardBodyProbe.counts)")
                // Back to the state before the next page (not counted).
                undo()
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
