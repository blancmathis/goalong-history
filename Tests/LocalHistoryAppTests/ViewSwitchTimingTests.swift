#if os(macOS)
import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// R13a: time from a click (accessibility press on the real button) to the first drawn frame and to complete data,
/// for each main view, on a busy synthetic member (35 days), in a window never ordered on screen.
/// Opt-in: `GOALONG_SWITCH_TIMING=<output dir>` [`GOALONG_SWITCH_TIMING_PASSES=11`]. Writes `switch-timing.json`.
final class ViewSwitchTimingTests: XCTestCase {
    struct Sample: Codable { let view: String; let pass: Int; let firstMs: Double; let completeMs: Double; let maxStallMs: Double
        /// R13c: the first frame's layout alone (SwiftUI's own work), without the CPU bitmap draw of `cacheDisplay`.
        var firstLayoutMs: Double? = nil
        /// R14c: the longest main-thread block from the click to « complet » (the bench's CPU bitmap draw excluded).
        /// A cold period click lays its content out when its data come in, after the selection's own layout.
        var longestMs: Double? = nil
        /// R14c: the click showed a stored read of the period (checked off the main thread) rather than its loading state.
        var fromStore: Bool? = nil
        /// R14c: main-thread CPU time from the click to the first layout (draw excluded). Far below `firstLayoutMs`
        /// means the thread waited (preempted on a loaded Mac, or blocked), not that SwiftUI worked.
        var blockCpuMs: Double? = nil
        /// R14c: main-thread CPU inside the one slice timed as the block (wall `firstLayoutMs`).
        var blockSliceCpuMs: Double? = nil }

    @MainActor func testMeasureViewSwitches() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["GOALONG_SWITCH_TIMING"], !output.isEmpty else {
            throw XCTSkip("opt-in: GOALONG_SWITCH_TIMING=<output dir>")
        }
        let passes = Int(environment["GOALONG_SWITCH_TIMING_PASSES"] ?? "") ?? 11
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            let preloadBase = GoalongAnalyticsModel.preloadsStarted
            let (model, window, host, written, summaries) = try Self.memberDashboard(ctx, days: 35)
            log("fixture: \(written.events) events, \(written.bytes / 1_000_000) MB journals, \(summaries) summary files")
            defer { window.contentView = nil; window.close() }
            Self.draw(host)
            XCTAssertNotNil(Self.settle(host, model: model, timeout: 30), "Activité never finished its first read")
            // R14a: the main pages are built at rest after launch. The member's first click comes after that (a member
            // reads Activité first); the time it takes, its longest block and its memory are logged.
            if let pages = Self.keptPages(in: host), pages.preheatPending > 0 {
                let before = Self.footprintMB(), start = ProcessInfo.processInfo.systemUptime
                var longest = 0.0
                let deadline = start + 30
                while pages.preheatPending > 0, ProcessInfo.processInfo.systemUptime < deadline {
                    _ = Self.settle(host, model: model, timeout: 0.05) { longest = max(longest, $0) }
                }
                XCTAssertEqual(pages.preheatPending, 0, "the main pages were never built at rest")
                _ = Self.settle(host, model: model, timeout: 10) { longest = max(longest, $0) }
                log(String(format: "preheat: %d pages in %.0f ms after the first read, longest block %.0f ms, footprint %.0f -> %.0f MB",
                           pages.hosts.count - 1, (ProcessInfo.processInfo.systemUptime - start) * 1_000, longest * 1_000,
                           before, Self.footprintMB()))
            }

            Self.waitForPreloads(host, model: model, since: preloadBase)
            // R14c: a trace of the clicks alone (GOALONG_SWITCH_GATE=<dir>): « ready » written here, clicks once « go » exists.
            if let gate = environment["GOALONG_SWITCH_GATE"], !gate.isEmpty {
                FileManager.default.createFile(atPath: gate + "/ready", contents: nil)
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                while !FileManager.default.fileExists(atPath: gate + "/go"), ProcessInfo.processInfo.systemUptime < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            var samples: [Sample] = []
            // Sidebar destinations present for this member, then the periods of Activité.
            let sections: [DashboardSection] = [.settings, .history, .concentration, .blocking, .ambiance, .overview]
            for pass in 0..<passes {
                for period in ["7", "28", "1"] {
                    guard let button = Self.periodButton(period, in: host) else {
                        XCTFail("no period \(period)"); return
                    }
                    samples.append(Self.measure("activite-\(period)j", pass: pass, press: button, host: host, model: model))
                    // R14c: a first click is measured on the stored read; a click without one measures something else.
                    if pass == 0, samples.last?.fromStore != true { XCTFail("activite-\(period)j: first click without a stored read") }
                }
                for section in sections {
                    guard let button = Self.node("sidebar-\(section.rawValue)", in: host) else { continue }
                    samples.append(Self.measure(section.rawValue, pass: pass, press: button, host: host, model: model))
                }
            }
            // R14a: one model publication (`objectWillChange`) on each view, every page already visited: the cost a
            // periodic republication adds to the shown page (pages kept alive must not add theirs).
            var republish: [String: Double] = [:]
            // A profile of the clicks alone (R14c) leaves the republications out: GOALONG_SWITCH_SKIP_REPUBLISH=1.
            let republished = environment["GOALONG_SWITCH_SKIP_REPUBLISH"] == nil
            for target in ["activite-28j", "activite-7j", "activite-1j"] + sections.map(\.rawValue) where republished {
                let period = target.hasPrefix("activite-") ? String(target.dropFirst(9).dropLast()) : nil
                if period != nil, model.navigationStore.selectedSection != .overview, let back = Self.node("sidebar-overview", in: host) {
                    _ = Self.measure("overview", pass: -1, press: back, host: host, model: model)
                }
                guard let button = period.map({ Self.periodButton($0, in: host) }) ?? Self.node("sidebar-\(target)", in: host) else { continue }
                _ = Self.measure(target, pass: -1, press: button, host: host, model: model)
                republish[target] = Self.republish(host, model: model)
            }
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: directory.appendingPathComponent("switch-timing.json"))
            try encoder.encode(republish).write(to: directory.appendingPathComponent("switch-republish.json"))
            // R14a: the columns of the T-043 report. Block = click + layout on the main thread (no draw);
            // first = first drawn frame (CPU bitmap draw included); complete = data read + frame; republish = one publication.
            if let pages = Self.keptPages(in: host) {
                log(String(format: "kept pages: %d, footprint at the end %.0f MB", pages.hosts.count, Self.footprintMB()))
            }
            // R14c: longest = the longest main-thread block from the click to complete (cold included).
            log("view             block  first  complete longest republish | cold block first complete longest")
            for view in Set(samples.map(\.view)).sorted() {
                let rows = samples.filter { $0.view == view }
                let warm = rows.filter { $0.pass > 0 }
                log(String(format: "%-16@ %6.1f %6.1f %8.1f %7.1f %9.1f | %6.1f %6.1f %8.1f %7.1f",
                           view as NSString, Self.median(warm.compactMap(\.firstLayoutMs)), Self.median(warm.map(\.firstMs)),
                           Self.median(warm.map(\.completeMs)), Self.median(warm.compactMap(\.longestMs)), republish[view] ?? -1,
                           rows.first?.firstLayoutMs ?? 0, rows.first?.firstMs ?? 0, rows.first?.completeMs ?? 0,
                           rows.first?.longestMs ?? 0))
            }
        }
    }

    // MARK: Measure
    /// The busy member's dashboard (R13a): `days` days of journals and their summaries, the real window content,
    /// a window never ordered on screen. Shared by the timing (opt-in) and its CI guard (ViewSwitchBudgetTests).
    @MainActor static func memberDashboard(_ ctx: GalleryContext, days: Int, section: DashboardSection = .overview,
                                          scheduler: DashboardRefreshScheduler? = nil) throws
        -> (DashboardViewModel, GalleryWindow, NSView, (events: Int, bytes: Int), Int) {
        try AppPaths.prepareApplicationStorage(applicationSupportDirectory: AppPaths.applicationSupportDirectory)
        GalleryFixtureHome.enableRecording()
        let written = try BusyMemberFixture.install(days: days)
        // The app's own backfill writes the finished days' summaries 3 minutes after launch: a member who used
        // Goalong for weeks has them. A separate reader, so the window's own day cache starts cold.
        BusyMemberFixture.writeSummaries(days: days)
        let summaries = (try? FileManager.default.contentsOfDirectory(atPath:
            AppPaths.applicationSupportDirectory.appendingPathComponent("activity-days").path)) ?? []

        ctx.environment.usedBytes = Int64(written.bytes)
        var options = GalleryFixtures.DashboardOptions()
        options.section = section
        options.refreshScheduler = scheduler
        let model = try GalleryFixtures.dashboardModel(ctx, options)
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        DashboardWindowController.configure(window)
        let root = LocalHistoryDashboardView(model: model)
            .defaultAppStorage(ctx.defaults)
            .environment(\.goalongDefaults, ctx.defaults)
            .environment(\.locale, GalleryClock.locale)
            .environment(\.timeZone, GalleryClock.timeZone)
            .environment(\.calendar, GalleryClock.calendar)
        let host = DashboardWindowContent(rootView: root)
        window.contentView = host
        window.setContentSize(NSSize(width: 1180, height: 790))
        return (model, window, host, written, summaries.count)
    }

    @MainActor static func keptPages(in view: NSView) -> DashboardKeptPagesView? {
        if let pages = view as? DashboardKeptPagesView { return pages }
        for child in view.subviews { if let pages = keptPages(in: child) { return pages } }
        return nil
    }

    /// The process's memory as Activity Monitor counts it (phys_footprint).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }


    /// R14c: the other periods are read in the background after the first display. The first clicks wait for that, as a
    /// member's would after a moment on the page; otherwise a click races the preload and measures a loading state
    /// (the 2 ms 28-day cold seen on CI at dc8d178).
    /// `baseline` is `GoalongAnalyticsModel.preloadsStarted` read before this run built its dashboard (R14c-N3).
    @MainActor static func waitForPreloads(_ host: NSView, model: DashboardViewModel, since baseline: Int) {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !GoalongAnalyticsModel.preloadsSettled(since: baseline), ProcessInfo.processInfo.systemUptime < deadline {
            _ = settle(host, model: model, timeout: 0.05) { _ in }
        }
        XCTAssertTrue(GoalongAnalyticsModel.preloadsSettled(since: baseline), "the other periods were never read in the background")
        _ = settle(host, model: model, timeout: 10) { _ in }
    }

    /// R14c, proof of the guard (GOALONG_SWITCH_FAULT_MS=n): every other first 1-day click blocks n ms more, an
    /// intermittent regression. Never set in CI.
    @MainActor private static var faultCalls = 0

    @MainActor static func measure(_ view: String, pass: Int, press: NSObject, host: NSView, model: DashboardViewModel) -> Sample {
        // R14c: a period click must build that period's content inside the measured window (see below).
        let period = view.hasPrefix("activite-") ? Int(view.dropFirst(9).dropLast()) : nil
        let builtBefore = period.map { GoalongAnalyticsContent.builtPeriods[$0, default: 0] } ?? 0
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(ViewSwitchAX.flag(press, "accessibilityPerformPress") == true, "press \(view)")
        if view == "activite-1j", pass == 0, let fault = Double(ProcessInfo.processInfo.environment["GOALONG_SWITCH_FAULT_MS"] ?? "") {
            faultCalls += 1
            let until = ProcessInfo.processInfo.systemUptime + (faultCalls % 2 == 1 ? fault / 1_000 : 0)
            while ProcessInfo.processInfo.systemUptime < until {}
        }
        let layout: Double
        var blockCpuSlice = 0.0
        let fromStore = GoalongAnalyticsModel.selectionsPending > 0
        if fromStore {
            // R14a: a period seen before waits for its off-main source check, then goes on screen in one layout.
            // Blocage = the longest main-thread block from the press to that layout; 1re image counts the whole wait.
            var block = ProcessInfo.processInfo.systemUptime - started
            blockCpuSlice = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
            let deadline = started + 5
            while GoalongAnalyticsModel.selectionsPending > 0, ProcessInfo.processInfo.systemUptime < deadline {
                let slice = ProcessInfo.processInfo.systemUptime, sliceCpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                let wall = ProcessInfo.processInfo.systemUptime - slice - 0.001
                if wall > block { block = wall; blockCpuSlice = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - sliceCpu) / 1e9 }
            }
            XCTAssertEqual(GoalongAnalyticsModel.selectionsPending, 0, "\(view): the selection never committed")
            let commit = ProcessInfo.processInfo.systemUptime, commitCpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            host.layoutSubtreeIfNeeded()
            let after = ProcessInfo.processInfo.systemUptime - commit
            if after > block { blockCpuSlice = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - commitCpu) / 1e9 }
            layout = max(block, after)
        } else {
            host.layoutSubtreeIfNeeded()
            layout = ProcessInfo.processInfo.systemUptime - started
            blockCpuSlice = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
        }
        let blockCpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
        draw(host)
        let first = ProcessInfo.processInfo.systemUptime - started
        var stall = 0.0
        let idleAt = settle(host, model: model, timeout: 20) { stall = max(stall, $0) }
        XCTAssertNotNil(idleAt, "\(view) never completed")
        // The accessibility lookup that confirms the end is not timed: complete = every read over, then one drawn frame.
        let frame = ProcessInfo.processInfo.systemUptime
        draw(host)
        let total = (idleAt ?? frame) - started + (ProcessInfo.processInfo.systemUptime - frame)
        // R14c: the longest block runs from the click to « complet ». A period without a stored read shows its loading
        // state at the click and lays its content out when the data come in: that layout is in `stall`, not in `layout`.
        // No silent pass: the content of the period clicked must have been built in this window.
        if let period {
            XCTAssertGreaterThan(GoalongAnalyticsContent.builtPeriods[period, default: 0], builtBefore,
                                 "\(view): its \(period)-day content was not built between the click and complete; nothing measured")
        }
        return Sample(view: view, pass: pass, firstMs: first * 1_000, completeMs: total * 1_000, maxStallMs: max(stall, first) * 1_000,
                      firstLayoutMs: layout * 1_000, longestMs: max(layout, stall) * 1_000, fromStore: fromStore, blockCpuMs: blockCpu * 1_000, blockSliceCpuMs: blockCpuSlice * 1_000)
    }

    /// One publication of the model with the page laid out and displayed: median of 3, minus nothing (an idle turn
    /// is logged beside it, ~1 ms). Same method as the T-043 report. R14b: the model publishes through its six stores, so
    /// all six send at once, in the same turn: still everything the model can publish at once, as the model's own
    /// publication was before. A view that now observes no store (it only calls the model) is no longer reached: that is
    /// the gain of R14b, not a change of method.
    @MainActor static func republish(_ host: NSView, model: DashboardViewModel) -> Double {
        let stores: [ObservableObjectPublisher] = [model.deviceStore.objectWillChange, model.alertStore.objectWillChange,
            model.navigationStore.objectWillChange, model.settingsStore.objectWillChange,
            model.runtimeStore.objectWillChange, model.snapshotStore.objectWillChange]
        func once(_ send: Bool) -> Double {
            let started = ProcessInfo.processInfo.systemUptime
            if send { stores.forEach { $0.send() } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            return (ProcessInfo.processInfo.systemUptime - started) * 1_000
        }
        _ = once(false)
        return (0..<3).map { _ in once(true) }.sorted()[1]
    }

    /// Runs the main loop in 2 ms slices until every read is over and no loading view is left for five slices.
    /// Returns when the quiet streak began (the last read over, its frame laid out), or nil on timeout.
    @MainActor static func settle(_ host: NSView, model: DashboardViewModel, timeout: TimeInterval,
                                   stall: (Double) -> Void = { _ in }) -> TimeInterval? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var quiet = 0, quietSince = 0.0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let slice = ProcessInfo.processInfo.systemUptime
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let end = ProcessInfo.processInfo.systemUptime
            stall(max(0, end - slice - 0.002))
            let idle = GoalongAnalyticsModel.loadsInFlight == 0 && !model.snapshotStore.isRefreshing
                && ComputerHistoryPageModel.refreshesInFlight == 0 && GoalongWorkReviewModel.loadsInFlight == 0
            if idle && quiet == 0 { quietSince = end }
            quiet = idle ? quiet + 1 : 0
            if quiet >= 5 {
                if node("analytics-primary-loading-motion", in: host) == nil { return quietSince }
                quiet = 0
            }
        }
        return nil
    }

    /// One whole drawn frame: layout, then every layer drawn into a bitmap.
    @MainActor static func draw(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private func log(_ text: String) { FileHandle.standardError.write(Data("[switch-timing] \(text)\n".utf8)) }

    // MARK: Accessibility tree

    @MainActor static func periodButton(_ days: String, in view: NSView) -> NSObject? {
        let label = days == "1" ? "Jour" : days + " jours"
        return ViewSwitchAX.first(in: view) { text in
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") == label
        }
    }

    @MainActor static func node(_ identifier: String, in view: NSView) -> NSObject? { ViewSwitchAX.first(in: view) { $0 == identifier } }
}

/// Accessibility lookups shared by the switch timing and its CI guard.
@MainActor enum ViewSwitchAX {
    static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// The accessibility tree is built only while it is asked for; it is switched off again before any timing, so the
    /// measure is the one of a member without VoiceOver.
    static func first(in view: NSView, where match: (String) -> Bool) -> NSObject? {
        let before = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        defer { NSApplication.shared.accessibilitySetValue(before ?? false, forAttribute: Self.enhancedUI) }
        var pending: [Any] = [view], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 20_000 {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle"] {
                if let text = Self.read(object, name) as? String, match(text) { return object }
            }
            pending.append(contentsOf: Self.read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return nil
    }

    nonisolated static func flag(_ object: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Getter.self)(object, selector)
    }

    nonisolated static func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}

/// A busy member: 15 hours a day, a context change about every 40 s among 48 apps and sites and a few hundred window
/// titles, typing bursts and 3 s heartbeats. Invented apps, sites and titles only.
@MainActor enum BusyMemberFixture {
    private static let apps: [(String, String, String?)] = (0..<48).map { index in
        let browser = index % 3 == 0
        return (browser ? "Safari" : "App \(index)", browser ? "com.apple.Safari" : "fr.exemple.app\(index)",
                browser ? "site\(index).exemple.fr" : nil)
    }

    static func install(days: Int) throws -> (events: Int, bytes: Int) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let directory = AppPaths.eventsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var total = 0, bytes = 0
        let calendar = GalleryClock.calendar
        for offset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -offset, to: GalleryClock.today)!
            var data = Data(), seed = UInt64(offset * 7_919 + 17)
            func next(_ bound: Int) -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int((seed >> 33) % UInt64(bound)) }
            var second = 7 * 3_600 + 30 * 60
            let end = offset == 0 ? Int(GalleryClock.now.timeIntervalSince(day)) : 22 * 3_600 + 30 * 60
            var index = 0
            while second < end {
                let (name, bundle, host) = apps[next(apps.count)]
                let title = "Document \(next(400)) — \(name)"
                let app = AppSnapshot(name: name, bundleIdentifier: bundle, processIdentifier: 400)
                let url = host.map { URLSnapshot(value: "https://\($0)/page/\(next(50))", host: $0, redactionApplied: false) }
                let window = WindowSnapshot(title: title, role: "AXWindow", subrole: "AXStandardWindow")
                let stay = 15 + next(50)
                for step in stride(from: 0, to: stay, by: 3) where second + step < end {
                    let at = day.addingTimeInterval(Double(second + step))
                    var metadata = ForegroundUsageObservation(observedAt: at, idleSeconds: 3, isForegroundVisible: true).metadata(at: at)
                    let kind: EventKind = step == 0 ? .applicationActivated : (step % 12 == 0 ? .typingBurst : .heartbeat)
                    if kind == .typingBurst { metadata["keystroke_count"] = "18"; metadata["content_recorded"] = "false" }
                    let event = HistoryEvent(id: "busy-\(offset)-\(index)", sessionID: "busy", timestamp: at, kind: kind,
                                             app: app, window: window, url: url, metadata: metadata)
                    data.append(try encoder.encode(event)); data.append(0x0A)
                    index += 1
                }
                second += stay
                if next(40) == 0 { second += 20 * 60 }  // a break now and then
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let url = directory.appendingPathComponent(String(format: "%04d-%02d-%02d.jsonl", parts.year!, parts.month!, parts.day!))
            try data.write(to: url, options: .atomic)
            total += index; bytes += data.count
        }
        return (total, bytes)
    }

    static func writeSummaries(days: Int) {
        let calendar = GalleryClock.calendar
        for offset in 1..<days {
            let day = calendar.date(byAdding: .day, value: -offset, to: GalleryClock.today)!
            autoreleasepool {
                _ = GoalongActivityDayReader.load(root: AppPaths.applicationSupportDirectory, day: day, now: GalleryClock.now,
                                                  calendar: calendar, shouldContinue: { true })
            }
        }
    }
}
#endif
