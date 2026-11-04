#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// R14a: pages already visited stay alive while hidden, and a hidden page costs nothing.
@MainActor final class DashboardKeptPagesTests: XCTestCase {
    final class Source: ObservableObject { @Published var value = 0 }
    final class Counts {
        var bodies: [String: Int] = [:], ticks: [String: Int] = [:], appears: [String: Int] = [:], disappears: [String: Int] = [:]
        var tasks: [String: Int] = [:], timeline: [String: Int] = [:]
        /// The appear logic under the rule of kept pages (`onAppearWhenShown`, `taskWhenShown`).
        var shownAppears: [String: Int] = [:], shownTasks: [String: Int] = [:]
        /// Each value of `goalongMotionPaused` the page's brand mark was evaluated with.
        var motionPaused: [String: [Bool]] = [:]
    }

    /// Records what the brand mark beside it reads.
    struct MotionPausedProbe: View {
        let name: String
        let counts: Counts
        @Environment(\.goalongMotionPaused) private var paused
        var body: some View {
            let _ = counts.motionPaused[name, default: []].append(paused)
            return Color.clear.frame(width: 1, height: 1)
        }
    }

    struct Probe: View {
        let name: String
        @ObservedObject var source: Source
        let counts: Counts
        @State private var kept = 0
        private let timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
        var body: some View {
            counts.bodies[name, default: 0] += 1
            return VStack {
                Text("\(name) \(source.value) kept \(kept)").accessibilityIdentifier("\(name) \(source.value) kept \(kept)")
                Button("plus") { kept += 1 }.accessibilityIdentifier("\(name)-plus")
                TimelineView(.periodic(from: Date(), by: 0.02)) { context in
                    let _ = counts.timeline[name, default: 0] += 1
                    Text("t \(context.date.timeIntervalSince1970)")
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack { GoalongActivityMark(isActive: true, width: 16); MotionPausedProbe(name: name, counts: counts) }
            }
            .onReceiveWhileShown(timer) { _ in counts.ticks[name, default: 0] += 1 }
            .onAppear { counts.appears[name, default: 0] += 1 }  // own layout: measures the plain modifiers
            .onDisappear { counts.disappears[name, default: 0] += 1 }
            .task { counts.tasks[name, default: 0] += 1 }  // own layout: measures the plain modifiers
            .onAppearWhenShown { counts.shownAppears[name, default: 0] += 1 }
            .taskWhenShown { counts.shownTasks[name, default: 0] += 1 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("probe-\(name)")
        }
    }

    struct Root: View {
        @ObservedObject var source: Source
        let selected: String
        let counts: Counts
        var keep = true
        var body: some View {
            DashboardKeptPages(key: selected, keep: keep) { Probe(name: selected, source: source, counts: counts) }
        }
    }

    private func spin(_ host: NSView, _ seconds: TimeInterval = 0.1) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
    }

    /// Spins until `done` holds, 3 s at most (the caller asserts after it).
    private func spin(_ host: NSView, until done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done() && Date() < end { spin(host, 0.02) }
    }

    func testHiddenPageIsNotEvaluatedTimedOrReachableAndKeepsItsState() throws {
        try GalleryRenderer.withPreparedApplication {
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            // As in the app window: the kept pages sit beside the dashboard's hosting view.
            let host = DashboardWindowContent(rootView: Root(source: source, selected: "a", counts: counts))
            window.contentView = host
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            // « a » gets a state of its own, then « b » is shown.
            let plus = try XCTUnwrap(ViewSwitchAX.first(in: host) { $0 == "a-plus" })
            XCTAssertEqual(ViewSwitchAX.flag(plus, "accessibilityPerformPress"), true)
            spin(host)
            // Its appear logic ran once while shown (a loaded runner starts the task late: wait for it, bounded).
            spin(host, until: { counts.shownAppears["a"] == 1 && counts.shownTasks["a"] == 1 })
            XCTAssertEqual(counts.shownAppears["a"], 1); XCTAssertEqual(counts.shownTasks["a"], 1)
            host.setRootView(Root(source: source, selected: "b", counts: counts))
            // The new page is in the window after one layout pass, with no turn of the main loop: no frame shows the
            // old page under the new selection.
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(pages.shownKey, "b")
            XCTAssertTrue(pages.hosts["b"]?.superview === pages)
            spin(host)
            XCTAssertEqual(pages.hosts.count, 2)
            XCTAssertTrue(pages.superview === host.pageLayer, "the pages are not beside the dashboard's hosting view")
            XCTAssertNil(ViewSwitchAX.first(in: host) { $0 == "probe-a" }, "a hidden page left in the accessibility tree")
            let bodies = counts.bodies["a"] ?? 0, ticks = counts.ticks["a"] ?? 0
            let timeline = counts.timeline["a"] ?? 0
            for _ in 0..<5 { source.value += 1; spin(host, 0.05) }
            spin(host, 0.2)
            XCTAssertEqual(counts.bodies["a"] ?? 0, bodies, "a publication evaluated the hidden page")
            XCTAssertEqual(counts.ticks["a"] ?? 0, ticks, "a timer of the hidden page fired")
            XCTAssertGreaterThan(counts.bodies["b"] ?? 0, 1)
            XCTAssertEqual(counts.timeline["a"] ?? 0, timeline, "a TimelineView of the hidden page ran")
            // Hidden as when the page was left before R14a: its `onDisappear` ran and its `.task` was cancelled.
            XCTAssertEqual(counts.disappears["a"], 1)
            // Back to « a »: its own state, the new value, the same hosting view.
            let before = pages.hosts["a"]
            host.setRootView(Root(source: source, selected: "a", counts: counts))
            spin(host)
            XCTAssertTrue(pages.hosts["a"] === before)
            // Back as when the page was opened before R14a: its `onAppear` and `.task` run again (fresh data).
            XCTAssertEqual(counts.appears["a"], 2)
            XCTAssertEqual(counts.tasks["a"], 2)
            XCTAssertEqual(counts.shownAppears["a"], 2); XCTAssertEqual(counts.shownTasks["a"], 2)
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { ($0 as String).hasPrefix("a 5 kept 1") })
            // The timer fires every 20 ms; a loaded runner can spend a whole spin in layout, so wait (bounded) for it.
            spin(host, until: { (counts.ticks["a"] ?? 0) > ticks })
            XCTAssertGreaterThan(counts.ticks["a"] ?? 0, ticks, "the shown page's timer is idle")
        }
    }

    func testASecondaryPageIsReleasedOnceLeft() throws {
        try GalleryRenderer.withPreparedApplication {
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: Root(source: source, selected: "a", counts: counts))
            window.contentView = host
            spin(host)
            host.setRootView(Root(source: source, selected: "x", counts: counts, keep: false))
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            XCTAssertEqual(Set(pages.hosts.keys), ["a", "x"])
            host.setRootView(Root(source: source, selected: "a", counts: counts))
            spin(host)
            XCTAssertEqual(Set(pages.hosts.keys), ["a"], "a secondary page stayed alive once left")
            XCTAssertEqual(pages.shownKey, "a")
        }
    }

    struct PreheatRoot: View {
        @ObservedObject var source: Source
        let selected: String
        let counts: Counts
        var body: some View {
            DashboardKeptPages(key: selected, preheat: ["a", "b"].filter { $0 != selected }.map { name in
                DashboardKeptPageSeed(key: name, inputs: 0) { AnyView(Probe(name: name, source: source, counts: counts)) }
            }) { Probe(name: selected, source: source, counts: counts) }
        }
    }

    func testThePagesNotVisitedYetAreBuiltAtRestAndStayInertUntilTheirFirstVisit() throws {
        try GalleryRenderer.withPreparedApplication {
            let delay = DashboardKeptPagesView.preheatDelay
            DashboardKeptPagesView.preheatDelay = 0.3
            defer { DashboardKeptPagesView.preheatDelay = delay }
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: PreheatRoot(source: source, selected: "a", counts: counts))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let pages = try XCTUnwrap(Self.keptView(in: host))
            let shown = Date()
            // Not in the click: only once the window has been quiet for the delay (no fixed sleep: a loaded machine
            // stretches every turn of the run loop).
            XCTAssertNil(pages.hosts["b"])
            while pages.hosts["b"] == nil && Date().timeIntervalSince(shown) < 10 { spin(host, 0.02) }
            let built = try XCTUnwrap(pages.hosts["b"], "the page was not built at rest")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shown), 0.3, "the page was built before the window was quiet")
            XCTAssertEqual(pages.preheatPending, 0)
            XCTAssertNil(built.superview, "a page built at rest went into the window")
            XCTAssertNil(ViewSwitchAX.first(in: host) { $0 == "probe-b" })
            // Built as a page visited then left at once: its `onAppear` and `.task` ran once, then it left (its task is
            // cancelled). Inert until shown: no timer, no evaluation by a publication.
            XCTAssertEqual(counts.appears["b"], 1); XCTAssertEqual(counts.disappears["b"], 1)
            // R14a correction: its appear logic did not run (the rule of kept pages, `KeptPageGate`).
            XCTAssertNil(counts.shownAppears["b"], "a page built at rest ran its appear logic")
            XCTAssertNil(counts.shownTasks["b"], "a page built at rest ran its task")
            // Its active brand mark was paused from its first evaluation (no motion while built at rest).
            XCTAssertFalse(counts.motionPaused["b", default: []].isEmpty)
            XCTAssertFalse(counts.motionPaused["b", default: []].contains(false), "a page built at rest animated its mark")
            let bodies = counts.bodies["b"] ?? 0
            XCTAssertGreaterThan(bodies, 0)
            for _ in 0..<3 { source.value += 1; spin(host, 0.05) }
            XCTAssertEqual(counts.bodies["b"] ?? 0, bodies, "a publication evaluated a page built at rest")
            XCTAssertNil(counts.ticks["b"], "a timer of a page built at rest fired")
            // The first visit is a return: the same hosting view, its reads start, its values are today's.
            host.setRootView(PreheatRoot(source: source, selected: "b", counts: counts))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(pages.hosts["b"] === built)
            XCTAssertTrue(built.superview === pages)
            spin(host)
            XCTAssertEqual(counts.appears["b"], 2); XCTAssertEqual(counts.tasks["b"], 2)
            // Its first real showing runs its appear logic, as a visit did before pages were kept.
            XCTAssertEqual(counts.shownAppears["b"], 1); XCTAssertEqual(counts.shownTasks["b"], 1)
            XCTAssertEqual(counts.motionPaused["b"]?.last, false, "the mark stayed paused once its page was shown")
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { $0 == "b 3 kept 0" }, "the page showed stale values")
            spin(host, until: { (counts.ticks["b"] ?? 0) > 0 })
            XCTAssertGreaterThan(counts.ticks["b"] ?? 0, 0, "the page's timer never started on its first visit")
        }
    }

    struct Labeled: View {
        let label: String
        @ObservedObject var source: Source
        var body: some View { Text("\(label) \(source.value)").accessibilityIdentifier("\(label) \(source.value)") }
    }

    struct InputsRoot: View {
        @ObservedObject var source: Source
        let label: String
        var body: some View {
            // `label` reaches the page by value: it is declared as an input.
            DashboardKeptPages(key: "a", inputs: label) { Labeled(label: label, source: source) }
        }
    }

    func testTheShownPageGetsANewRootOnlyWhenWhatItTakesByValueChanges() throws {
        try GalleryRenderer.withPreparedApplication {
            let source = Source()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: InputsRoot(source: source, label: "x"))
            window.contentView = host
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            let roots = pages.rootCount
            // A publication of an object the page observes: the page updates itself, no new root.
            for _ in 0..<3 { source.value += 1; spin(host, 0.05) }
            XCTAssertEqual(pages.rootCount, roots, "a publication gave the shown page a new root")
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { $0 == "x 3" })
            // A value passed by value changes: a new root, in the same layout pass.
            host.setRootView(InputsRoot(source: source, label: "y"))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(pages.rootCount, roots + 1)
            spin(host)
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { $0 == "y 3" }, "the page kept a stale input")
        }
    }

    /// What a page reads from its environment, compared between the dashboard's hosting view and a kept page.
    struct Snapshot: Equatable {
        let scheme: ColorScheme, contrast: ColorSchemeContrast, reduceMotion: Bool, systemReduceMotion: Bool
        let locale: String, timeZone: String, calendar: Calendar.Identifier, direction: LayoutDirection
        let active: ControlActiveState, defaults: ObjectIdentifier, enabled: Bool, scale: CGFloat
        init(_ env: EnvironmentValues) {
            scheme = env.colorScheme; contrast = env.colorSchemeContrast; reduceMotion = env.goalongReduceMotion
            systemReduceMotion = env.accessibilityReduceMotion; locale = env.locale.identifier
            timeZone = env.timeZone.identifier; calendar = env.calendar.identifier; direction = env.layoutDirection
            active = env.controlActiveState; defaults = ObjectIdentifier(env.goalongDefaults); enabled = env.isEnabled
            scale = env.displayScale
        }
    }

    final class Snapshots { var values: [String: Snapshot] = [:] }

    struct EnvironmentProbe: View {
        @Environment(\.self) private var environment
        let name: String
        let snapshots: Snapshots
        var body: some View {
            snapshots.values[name] = Snapshot(environment)
            return Text(name)
        }
    }

    struct EnvironmentRoot: View {
        let selected: String
        let snapshots: Snapshots
        let defaults: UserDefaults
        var body: some View {
            VStack {
                EnvironmentProbe(name: "root", snapshots: snapshots)
                DashboardKeptPages(key: selected) { EnvironmentProbe(name: selected, snapshots: snapshots) }
            }
            // Values set above the pages, as the gallery and the app do: each one must reach the page.
            .environment(\._colorSchemeContrast, .increased)
            .environment(\.goalongReduceMotion, true)
            .environment(\.goalongDefaults, defaults)
            .environment(\.controlActiveState, .key)
            .environment(\.locale, Locale(identifier: "fr_FR"))
            .environment(\.timeZone, TimeZone(identifier: "Pacific/Auckland")!)
            .environment(\.calendar, Calendar(identifier: .buddhist))
        }
    }

    func testAKeptPageHasTheDashboardsEnvironmentAndFollowsAnAppearanceChangeEvenHidden() throws {
        try GalleryRenderer.withPreparedApplication {
            let snapshots = Snapshots(), defaults = UserDefaults(suiteName: "kept-pages-\(UUID().uuidString)")!
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            defer { window.contentView = nil; window.close() }
            func root(_ selected: String) -> EnvironmentRoot { EnvironmentRoot(selected: selected, snapshots: snapshots, defaults: defaults) }
            let host = DashboardWindowContent(rootView: root("a"))
            window.contentView = host
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            XCTAssertTrue(pages.superview === host.pageLayer, "the page is not in the layer of kept pages")
            let first = try XCTUnwrap(snapshots.values["root"])
            XCTAssertEqual(first.contrast, .increased); XCTAssertEqual(first.calendar, .buddhist)
            XCTAssertEqual(first.scheme, .light); XCTAssertEqual(first.active, .key)
            XCTAssertEqual(snapshots.values["a"], first)
            // The shown page follows a change of appearance.
            window.appearance = NSAppearance(named: .darkAqua)
            spin(host)
            XCTAssertEqual(snapshots.values["root"]?.scheme, .dark)
            XCTAssertEqual(snapshots.values["a"], snapshots.values["root"])
            // A hidden page follows it too: on its return, in the very layout that shows it again.
            host.setRootView(root("b"))
            spin(host)
            XCTAssertEqual(snapshots.values["b"], snapshots.values["root"])
            window.appearance = NSAppearance(named: .aqua)
            spin(host)
            XCTAssertEqual(snapshots.values["a"]?.scheme, .dark, "the hidden page was updated")
            host.setRootView(root("a"))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(pages.shownKey, "a")
            XCTAssertEqual(snapshots.values["root"]?.scheme, .light)
            XCTAssertEqual(snapshots.values["a"], snapshots.values["root"], "the page came back with the old appearance")
        }
    }

    // MARK: R14a correction (review of 2026-11-04)

    /// B1 + N1: the real dashboard, reopened on Réglages with a past day J chosen in Activité. The main pages are built
    /// at rest: the day stays J, the chosen session stays, no permission guide is announced. Activité's first real
    /// showing then runs its appear logic (it follows today, as a visit did before pages were kept).
    func testPagesBuiltAtRestActOnNothingOutsideThemselves() throws {
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            let delay = DashboardKeptPagesView.preheatDelay
            // Nothing is built at rest before the day J and its session are chosen (checked below).
            DashboardKeptPagesView.preheatDelay = 6
            defer { DashboardKeptPagesView.preheatDelay = delay }
            let (model, window, host, _, _) = try ViewSwitchTimingTests.memberDashboard(ctx, days: 8, section: .settings)
            defer { window.contentView = nil; window.close() }
            var guides = 0
            let observer = NotificationCenter.default.addObserver(forName: .goalongPermissionGuideDidOpen, object: nil,
                                                                  queue: nil) { _ in guides += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            let calendar = Calendar.current
            let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: model.now())))
            // The window reopened on Réglages: Activité has not been shown since, and its day starts on today.
            model.selectDay(pastDay)
            ViewSwitchTimingTests.draw(host)
            let pages = try XCTUnwrap(ViewSwitchTimingTests.keptPages(in: host))
            spin(host, until: { model.filteredSessions.count > 1 })
            // A session of J other than the first: the model would fall back to the first one, or to none.
            let session = try XCTUnwrap(model.filteredSessions.last?.id, "no session on the day J")
            model.selectSession(session)
            spin(host, 0.2)
            XCTAssertEqual(model.selectedSessionID, session)
            XCTAssertEqual(Array(pages.hosts.keys.map { String($0.prefix(while: { $0 != "|" })) }), ["settings"], "a page was built at rest before the day J and its session were chosen")
            let settingsGuides = guides
            let started = Date()
            while pages.preheatPending > 0, Date().timeIntervalSince(started) < 60 { spin(host, 0.05) }
            XCTAssertEqual(pages.preheatPending, 0, "the main pages were not built at rest")
            XCTAssertNotNil(pages.hosts.keys.first { $0.hasPrefix("activity|") }, "Activité was not built at rest")
            spin(host, 0.3)
            XCTAssertEqual(model.selectedDay, pastDay, "a page built at rest changed the day")
            XCTAssertEqual(model.selectedSessionID, session, "a page built at rest changed the chosen session")
            XCTAssertEqual(guides, settingsGuides, "a page built at rest announced the permission guide")
            // First real showing of Activité: its appear logic runs now.
            model.selectSection(.overview)
            spin(host, 0.3)
            XCTAssertTrue(calendar.isDate(model.selectedDay, inSameDayAs: model.now()),
                          "Activité's appear logic did not run on its first showing")
        }
    }

    /// N1, every page: no appear logic of the app runs outside the gate of its page (`KeptPageGate`). A plain
    /// `onAppear` or `.task` is allowed only on a view that writes its own state from its own layout (`// own layout`) or on the brand mark,
    /// compiled alone, that drives only its own motion (`// own state`).
    func testEveryAppearLogicGoesThroughTheGateOfItsPage() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DashboardKeptPages.swift" }
        XCTAssertGreaterThan(files.count, 50)
        let plain = try NSRegularExpression(pattern: #"\.onAppear\s*[({]|(^\s*(\}\s*)?|\))\.task\s*[({]"#)
        var offending: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.contains("// own layout")
                && !(line.contains("// own state") && file.lastPathComponent == "GoalongMotionView.swift") {
                if plain.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offending.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offending, [], "appear logic outside the gate of its page (use onAppearWhenShown / taskWhenShown)")
    }

    struct CloseRoot: View {
        @ObservedObject var source: Source
        let selected: String
        let counts: Counts
        var body: some View {
            // « c » is never built in this test (long delay): the timer stays set.
            DashboardKeptPages(key: selected, preheat: [DashboardKeptPageSeed(key: "c", inputs: 0) {
                AnyView(Probe(name: "c", source: source, counts: counts))
            }]) { Probe(name: selected, source: source, counts: counts) }
        }
    }

    /// N3: the window closes (its content leaves it, as `windowWillClose` does) with no `dismantleNSView`: every kept
    /// page is freed and the timer of the pages built at rest stops. Back in a window, the page asked for last returns.
    func testClosingTheWindowFreesEveryPageAndStopsTheTimer() throws {
        try GalleryRenderer.withPreparedApplication {
            let delay = DashboardKeptPagesView.preheatDelay
            DashboardKeptPagesView.preheatDelay = 60
            defer { DashboardKeptPagesView.preheatDelay = delay }
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: CloseRoot(source: source, selected: "a", counts: counts))
            window.contentView = host
            spin(host)
            host.setRootView(CloseRoot(source: source, selected: "b", counts: counts))
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            XCTAssertEqual(Set(pages.hosts.keys), ["a", "b"])
            XCTAssertTrue(pages.preheatScheduled)
            weak var former = pages.hosts["a"]
            window.contentView = nil
            XCTAssertTrue(pages.hosts.isEmpty, "a kept page outlived its window")
            XCTAssertFalse(pages.preheatScheduled, "the timer of the pages built at rest outlived the window")
            // Freed once SwiftUI ends its pending work (a loaded runner takes longer: wait for it, bounded).
            spin(host, until: { former == nil })
            XCTAssertNil(former, "a kept page is still in memory once its window closed")
            window.contentView = host
            spin(host)
            XCTAssertEqual(pages.shownKey, "b")
            XCTAssertTrue(pages.hosts["b"]?.superview === pages, "the page asked for last did not come back")
        }
    }

    struct ScopeRoot: View {
        @ObservedObject var source: Source
        let selected: String
        let device: String
        let counts: Counts
        var body: some View {
            DashboardKeptPages(key: "\(selected)|\(device)", scope: device) {
                Probe(name: "\(selected)|\(device)", source: source, counts: counts)
            }
        }
    }

    /// N3: another device frees the pages of the former one.
    func testAnotherDeviceFreesThePagesOfTheFormerOne() throws {
        try GalleryRenderer.withPreparedApplication {
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: ScopeRoot(source: source, selected: "a", device: "1", counts: counts))
            window.contentView = host
            spin(host)
            host.setRootView(ScopeRoot(source: source, selected: "b", device: "1", counts: counts))
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            XCTAssertEqual(Set(pages.hosts.keys), ["a|1", "b|1"])
            host.setRootView(ScopeRoot(source: source, selected: "b", device: "2", counts: counts))
            spin(host)
            XCTAssertEqual(Set(pages.hosts.keys), ["b|2"], "the pages of the former device stayed in memory")
            XCTAssertEqual(pages.shownKey, "b|2")
            XCTAssertTrue(pages.hosts["b|2"]?.superview === pages)
        }
    }

    /// N4: Tab never enters a hidden page. The window recalculates its key-view loop (as the app window does,
    /// `autorecalculatesKeyViewLoop`); walking the whole loop meets the shown page and never a hidden one. Limit: the
    /// focus moves inside a SwiftUI page are not NSViews and need a key window on screen, which tests never show.
    func testTheKeyViewLoopNeverEntersAHiddenPage() throws {
        try GalleryRenderer.withPreparedApplication {
            let source = Source(), counts = Counts()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.autorecalculatesKeyViewLoop = true
            defer { window.contentView = nil; window.close() }
            let host = DashboardWindowContent(rootView: Root(source: source, selected: "a", counts: counts))
            window.contentView = host
            spin(host)
            host.setRootView(Root(source: source, selected: "b", counts: counts))
            spin(host)
            let pages = try XCTUnwrap(Self.keptView(in: host))
            let hidden = try XCTUnwrap(pages.hosts["a"]), shown = try XCTUnwrap(pages.hosts["b"])
            window.recalculateKeyViewLoop()
            var loop: [NSView] = [], view: NSView? = host
            while let current = view, loop.count < 500, !loop.contains(where: { $0 === current }) {
                loop.append(current); view = current.nextKeyView
            }
            XCTAssertTrue(loop.contains { $0 === shown || $0.isDescendant(of: shown) }, "the shown page is out of the key-view loop")
            XCTAssertFalse(loop.contains { $0 === hidden || $0.isDescendant(of: hidden) }, "Tab can enter a hidden page")
            XCTAssertNil(hidden.window)
        }
    }

    /// N2: two quick « jour suivant » while the first is checked give J+2, not J+1.
    func testTwoQuickClicksBothCount() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let day = calendar.date(byAdding: .day, value: -5, to: now)!
        let shown = GoalongActivityNavigation(day: day, period: 1, now: now, calendar: calendar)
        let chain = GoalongSelectionChain()
        var first = chain.base(shown); first.step(1, earliest: nil, now: now, calendar: calendar)
        chain.ask(first, token: 1)
        // The second click comes before the first is committed: the page still shows J.
        var second = chain.base(shown); second.step(1, earliest: nil, now: now, calendar: calendar)
        chain.ask(second, token: 2)
        XCTAssertEqual(second.day, calendar.date(byAdding: .day, value: 2, to: day))
        // The first click's check ends late: it lost, nothing is cleared.
        chain.committed(token: 1)
        XCTAssertEqual(chain.asked, second)
        chain.committed(token: 2)
        XCTAssertNil(chain.asked)
        XCTAssertEqual(chain.base(second), second)
    }

    private static func keptView(in view: NSView) -> DashboardKeptPagesView? {
        if let kept = view as? DashboardKeptPagesView { return kept }
        for child in view.subviews { if let kept = keptView(in: child) { return kept } }
        return nil
    }
}
#endif
