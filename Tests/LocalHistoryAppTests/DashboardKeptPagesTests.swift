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
            .onReceiveWhileShown(timer) { _ in counts.ticks[name, default: 0] += 1 }
            .onAppear { counts.appears[name, default: 0] += 1 }
            .onDisappear { counts.disappears[name, default: 0] += 1 }
            .task { counts.tasks[name, default: 0] += 1 }
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
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { ($0 as String).hasPrefix("a 5 kept 1") })
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
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { $0 == "b 3 kept 0" }, "the page showed stale values")
            XCTAssertGreaterThan(counts.ticks["b"] ?? 0, 0)
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

    private static func keptView(in view: NSView) -> DashboardKeptPagesView? {
        if let kept = view as? DashboardKeptPagesView { return kept }
        for child in view.subviews { if let kept = keptView(in: child) { return kept } }
        return nil
    }
}
#endif
