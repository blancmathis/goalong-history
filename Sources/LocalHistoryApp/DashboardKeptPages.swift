#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI

    /// R14a: the pages already visited stay alive, like tabs. Each one has its own hosting view; only the page shown is
    /// in the window. A hidden page keeps its state (day chosen, scroll position) but is not updated, laid out or drawn:
    /// a model publication does not evaluate it, its timers stop (`KeptPageGate`), and it is out of the accessibility
    /// tree and the key-view loop. Coming back puts the same hosting view in the window again: one update with what
    /// changed while it was away, no new page.
    ///
    /// Where the pages live (measured, DashboardKeptPagesTests): a hosting view placed under the dashboard's own hosting
    /// view stays linked to it after it leaves the window, and every update of the dashboard re-evaluates it. So in the
    /// app window (`DashboardWindowContent`) the pages sit in a layer beside the dashboard's hosting view, over the place
    /// SwiftUI gives this view. Anywhere else (gallery renders) they sit inside this view.
    struct DashboardKeptPages<Page: View>: View {
        /// One kept page per key (section and device).
        let key: String
        /// What the keys belong to (the device): when it changes, the pages of the former one are freed (N3).
        var scope = ""
        /// False: the page is released once left (secondary pages, rarely opened). Bounds the memory kept.
        var keep = true
        /// Every value the page takes by value from the caller (not through an object it observes). The shown page
        /// gets a new root only when these, its key or its environment change: a publication of a model the page
        /// observes updates it once, by its own observation (measured: re-rooting it on every publication doubled the
        /// cost, Activité 28 j 17 → 38 ms).
        var inputs: any Equatable = 0
        /// Pages to build at rest, out of the window, before their first visit (`DashboardKeptPagesView.preheat`).
        var preheat: [DashboardKeptPageSeed] = []
        /// After a different page is put in the window (the former `onAppear` of each new page).
        var onShown: () -> Void = {}
        @ViewBuilder let page: () -> Page
        // Each value a page takes from above, read here one by one: SwiftUI does not update a representable for an
        // environment value its parent never reads (measured: the page kept the old appearance), and reading the whole
        // environment would also update the page on every focus change.
        @Environment(\.locale) private var locale
        @Environment(\.timeZone) private var timeZone
        @Environment(\.calendar) private var calendar
        @Environment(\.layoutDirection) private var layoutDirection
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.controlActiveState) private var controlActiveState
        @Environment(\.goalongReduceMotion) private var reduceMotion
        @Environment(\.goalongDefaults) private var defaults
        @Environment(\.goalongRecordingModel) private var recording
        @Environment(\.sourceAccessCheck) private var accessCheck

        var body: some View {
            DashboardKeptPagesRepresentable(key: key, scope: scope, keep: keep, inputs: inputs, preheat: preheat, onShown: onShown, page: page, environment: .init(
                locale: locale, timeZone: timeZone, calendar: calendar, layoutDirection: layoutDirection,
                colorScheme: colorScheme, contrast: contrast, controlActiveState: controlActiveState,
                reduceMotion: reduceMotion, defaults: defaults, recording: recording, accessCheck: accessCheck))
        }
    }

    private struct DashboardKeptPagesRepresentable<Page: View>: NSViewRepresentable {
        let key: String
        let scope: String
        let keep: Bool
        let inputs: any Equatable
        let preheat: [DashboardKeptPageSeed]
        let onShown: () -> Void
        let page: () -> Page
        let environment: DashboardCarriedEnvironment

        func makeNSView(context: Context) -> DashboardKeptPagesSlot { DashboardKeptPagesSlot() }

        func updateNSView(_ slot: DashboardKeptPagesSlot, context: Context) {
            // Not run here: a hosting view created or updated inside the dashboard's update stays linked to it, and every
            // later update of the dashboard re-evaluated the hidden page (measured, DashboardKeptPagesTests). The pages
            // view runs it in its own layout, in the same frame.
            slot.pages.request(key: key, scope: scope, keep: keep, inputs: inputs, page: AnyView(page()), environment: environment,
                               onShown: onShown)
            slot.pages.seeds = preheat
        }

        static func dismantleNSView(_ slot: DashboardKeptPagesSlot, coordinator: ()) { slot.release() }
    }

    /// A kept page that can be built before its first visit. `page` is only called at rest, out of any SwiftUI update.
    struct DashboardKeptPageSeed {
        let key: String
        let inputs: any Equatable
        let page: () -> AnyView
    }

    extension EnvironmentValues {
        /// The gate of the kept page this view is in: closed while the page is out of the window (its timers stop).
        var keptPageGate: KeptPageGate {
            get { self[KeptPageGateKey.self] }
            set { self[KeptPageGateKey.self] = newValue }
        }

        /// True inside `DashboardWindowContent`, which shows the toasts above the kept pages.
        var dashboardToastsAbovePages: Bool {
            get { self[DashboardToastsAbovePagesKey.self] }
            set { self[DashboardToastsAbovePagesKey.self] = newValue }
        }
    }

    /// Open while its page is in the window. A reference, set once per page: closing it stops the page's timers at
    /// once, with no SwiftUI update of the page (measured: the update that told the old page it was hidden ran in the
    /// click, 5 ms for Réglages, 48 ms the first time for Activité).
    ///
    /// The rule of every kept page (R14a correction): a page built at rest and never shown acts on nothing outside
    /// itself. It writes nothing in a model (day, chosen session), opens no Codex session, starts no sync or scan,
    /// consumes no request and posts no notification. So the appear logic of every view of a page goes through its gate:
    /// `onAppearWhenShown` and `taskWhenShown` instead of `onAppear` and `.task`. Closed at rest, they do nothing; the
    /// page's first real showing runs them, as a visit did before pages were kept, and so does each return (a return
    /// re-runs `onAppear` and `.task`, measured). Outside a kept page the gate is always open: no change. Only a view
    /// that writes its own state from its own layout keeps a plain `onAppear` (marked `// own layout`), and so does the
    /// brand mark, compiled alone by scripts/test_brand_motion.sh, which drives only its own motion (`// own state`); a
    /// test scans the sources for any other (DashboardKeptPagesTests).
    final class KeptPageGate: @unchecked Sendable {
        static let alwaysOpen = KeptPageGate()
        let open = CurrentValueSubject<Bool, Never>(true)
        /// Main thread only, like the page.
        var isOpen: Bool { open.value }
    }

    private struct KeptPageGateKey: EnvironmentKey { static let defaultValue = KeptPageGate.alwaysOpen }

    extension View {
        /// `onReceive` for a timer of a page: it stops while the page is kept out of the window (DashboardKeptPages).
        /// A hidden page's `onAppear`, `.task` and `TimelineView` already wait for its return (measured); its timers do not.
        func onReceiveWhileShown<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View
        where P.Failure == Never {
            modifier(KeptPageReceive(publisher: publisher, action: action))
        }
    }

    extension View {
        /// `onAppear` under the rule of kept pages (`KeptPageGate`): skipped while the page is built at rest, run at its
        /// first real showing and at each return.
        func onAppearWhenShown(perform action: @escaping () -> Void) -> some View {
            modifier(KeptPageAppear(action: action))
        }

        /// `.task` under the rule of kept pages (`KeptPageGate`).
        func taskWhenShown(priority: TaskPriority = .userInitiated,
                           _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
            modifier(KeptPageTask(id: 0, priority: priority, action: action))
        }

        /// `.task(id:)` under the rule of kept pages (`KeptPageGate`).
        func taskWhenShown<ID: Equatable>(id: ID, priority: TaskPriority = .userInitiated,
                                          _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
            modifier(KeptPageTask(id: id, priority: priority, action: action))
        }
    }

    private struct KeptPageAppear: ViewModifier {
        @Environment(\.keptPageGate) private var gate
        let action: () -> Void
        func body(content: Content) -> some View {
            let gate = self.gate
            return content.onAppear { if gate.isOpen { action() } }
        }
    }

    private struct KeptPageTask<ID: Equatable>: ViewModifier {
        @Environment(\.keptPageGate) private var gate
        let id: ID
        let priority: TaskPriority
        let action: @MainActor @Sendable () async -> Void
        func body(content: Content) -> some View {
            let gate = self.gate, action = self.action
            return content.task(id: id, priority: priority) { @MainActor in
                guard gate.isOpen else { return }
                await action()
            }
        }
    }

    private struct KeptPageReceive<P: Publisher>: ViewModifier where P.Failure == Never {
        @Environment(\.keptPageGate) private var gate
        let publisher: P
        let action: (P.Output) -> Void
        func body(content: Content) -> some View {
            // Closing the gate cancels the subscription to the timer (an autoconnected timer then stops); opening it
            // subscribes again.
            let publisher = self.publisher
            return content.onReceive(gate.open.removeDuplicates().map { open in
                open ? publisher.eraseToAnyPublisher() : Empty(completeImmediately: false).eraseToAnyPublisher()
            }.switchToLatest(), perform: action)
        }
    }
    private struct DashboardToastsAbovePagesKey: EnvironmentKey { static let defaultValue = false }

    /// What a kept page takes from the environment above it (DashboardKeptPagesTests compares each one with the
    /// dashboard's). Not the whole environment (`\.self`): it also holds the dashboard hosting view's own plumbing
    /// (focus bridge, accessibility focus requests, its window, undo manager), and carried over it hid the page from
    /// accessibility (measured). Appearance-derived values are carried too, so that a value set above (the gallery's
    /// contrast and key state) reaches the page as it reached it inside one hosting view; styles are applied again by
    /// the caller.
    struct DashboardCarriedEnvironment {
        let locale: Locale, timeZone: TimeZone, calendar: Calendar, layoutDirection: LayoutDirection
        let colorScheme: ColorScheme, contrast: ColorSchemeContrast, controlActiveState: ControlActiveState
        let reduceMotion: Bool, defaults: UserDefaults, recording: DashboardViewModel?
        let accessCheck: SourceAccessService.Check

        /// Same values (objects by identity). The access check is a function, set once above the dashboard: not compared.
        func same(as other: DashboardCarriedEnvironment) -> Bool {
            locale == other.locale && timeZone == other.timeZone && calendar == other.calendar
                && layoutDirection == other.layoutDirection && colorScheme == other.colorScheme && contrast == other.contrast
                && controlActiveState == other.controlActiveState && reduceMotion == other.reduceMotion
                && defaults === other.defaults && recording === other.recording
        }

        func apply(to page: AnyView, gate: KeptPageGate) -> AnyView {
            AnyView(page
                .defaultAppStorage(defaults).environment(\.goalongDefaults, defaults)
                .environment(\.locale, locale).environment(\.timeZone, timeZone).environment(\.calendar, calendar)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.colorScheme, colorScheme).environment(\._colorSchemeContrast, contrast)
                .environment(\.controlActiveState, controlActiveState).environment(\.goalongReduceMotion, reduceMotion)
                .environment(\.goalongRecordingModel, recording).environment(\.sourceAccessCheck, accessCheck)
                .environment(\.keptPageGate, gate))
        }
    }

    /// The app window's content: the dashboard's hosting view, the layer of kept pages above it, then the toasts.
    final class DashboardWindowContent: NSView {
        let root: NSHostingView<AnyView>
        let pageLayer = DashboardPassThroughView()
        /// Gallery renders: the pages run with animations off, as the dashboard does under the renderer's `.transaction`
        /// (a transaction does not cross into another hosting view). The app leaves it false.
        var pagesWithoutAnimation = false
        private let toasts: DashboardToastLayer

        init<Root: View>(rootView: Root, sizing: NSHostingSizingOptions = DashboardWindowController.hostingSizing) {
            root = NSHostingView(rootView: AnyView(rootView.environment(\.dashboardToastsAbovePages, true)))
            root.sizingOptions = sizing
            toasts = DashboardToastLayer(rootView: AnyView(GoalongToastHost().environment(\.locale, GoalongUIFormat.locale)))
            toasts.sizingOptions = []
            super.init(frame: NSRect(origin: .zero, size: DashboardWindowController.defaultContentSize))
            for layer in [root, pageLayer, toasts] as [NSView] {
                layer.frame = bounds
                layer.autoresizingMask = [.width, .height]
                addSubview(layer)
            }
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        func setRootView<Root: View>(_ rootView: Root) {
            root.rootView = AnyView(rootView.environment(\.dashboardToastsAbovePages, true))
        }

        override func layout() {
            super.layout()
            for case let pages as DashboardKeptPagesView in pageLayer.subviews { pages.slot?.place() }
        }
    }

    /// Takes the clicks that land on one of its subviews, never the ones on its empty space.
    final class DashboardPassThroughView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let view = super.hitTest(point)
            return view === self ? nil : view
        }
    }

    /// The toasts never take a click (`GoalongToastHost` is `allowsHitTesting(false)`).
    private final class DashboardToastLayer: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The place SwiftUI gives the pages. In `DashboardWindowContent` the pages go to its page layer, over this place;
    /// elsewhere they go inside it. No page is put anywhere before that choice: a hosting view put under the dashboard's
    /// hosting view once stays linked to it after it moves (measured, DashboardKeptPagesTests).
    final class DashboardKeptPagesSlot: NSView {
        let pages = DashboardKeptPagesView()
        private(set) weak var content: DashboardWindowContent?
        private var inside = false
        private var wasInWindow = false
        private var watched: [NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            pages.slot = self
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolve(final: false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, wasInWindow {
                // Out of the window (window closed, onboarding shown in its place): every kept page is freed now and the
                // timer of the pages built at rest stops, even if SwiftUI never dismantles this view (N3). Back in a
                // window, the page last asked for is built again.
                pages.releaseKeepingRequest()
            }
            wasInWindow = window != nil
            resolve(final: window != nil)
            guard let content else { return }
            if window == nil {
                pages.removeFromSuperview()
            } else if pages.superview !== content.pageLayer {
                content.pageLayer.addSubview(pages)
                place()
            }
        }

        override func layout() {
            super.layout()
            // A render with no window (gallery) lays this view out without moving it to a window.
            resolve(final: true)
            place()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            place()
        }

        /// Finds where the pages go, once: beside the dashboard's hosting view in the app window, inside this view
        /// elsewhere (`final` once the hierarchy can no longer change).
        private func resolve(final: Bool) {
            guard content == nil, !inside else { return }
            var ancestor = superview
            while let view = ancestor, !(view is DashboardWindowContent) { ancestor = view.superview }
            if let found = ancestor as? DashboardWindowContent {
                content = found
                pages.autoresizingMask = []
                found.pageLayer.addSubview(pages)
                // SwiftUI moves this view's ancestors as well as this view: follow every frame up to the window's content.
                var view: NSView? = self
                while let current = view, current !== found {
                    current.postsFrameChangedNotifications = true
                    watched.append(NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: current, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
                    view = current.superview
                }
            } else if final {
                inside = true
                pages.autoresizingMask = [.width, .height]
                addSubview(pages)
            } else {
                return
            }
            place()
            pages.applyRequest()
            pages.mountShown()
        }

        /// Puts the pages over this view.
        func place() {
            let frame = content.map { convert(bounds, to: $0.pageLayer) } ?? bounds
            if (content != nil || inside), pages.frame != frame { pages.frame = frame }
        }

        var placed: Bool { content != nil || inside }

        func release() {
            for token in watched { NotificationCenter.default.removeObserver(token) }
            watched.removeAll()
            pages.releaseAll()
            pages.removeFromSuperview()
        }
    }

    /// A page's hosting view. Out of the window it is frozen: no update is run even if SwiftUI asks for one.
    final class DashboardKeptHost: NSHostingView<AnyView> {
        var frozen = false
        let gate = KeptPageGate()
        /// What its root was built from: a new root is given only when one of them changes.
        var inputs: any Equatable = 0
        var environment: DashboardCarriedEnvironment?
        override func layout() { if !frozen { super.layout() } }
    }

    final class DashboardKeptPagesView: NSView {
        private(set) var hosts: [String: DashboardKeptHost] = [:]
        private(set) var shownKey: String?
        weak var slot: DashboardKeptPagesSlot?
        private typealias Request = (key: String, scope: String, keep: Bool, inputs: any Equatable, page: AnyView,
                                     environment: DashboardCarriedEnvironment, onShown: () -> Void)
        private var requested: Request?
        /// The latest request, kept to build the page again if this view comes back to a window after leaving it.
        private var lastRequest: Request?
        /// The scope of the pages kept (`DashboardKeptPages.scope`).
        private var scope: String?
        /// Keys of pages released once left.
        private var released: Set<String> = []
        /// Pages released by the last click, freed after its frame (freeing a page tree is not free).
        private var leaving: [DashboardKeptHost] = []
        /// Number of roots given to a page (DashboardKeptPagesTests).
        private(set) var rootCount = 0
        /// The latest pages to build at rest (`preheat`).
        var seeds: [DashboardKeptPageSeed] = [] { didSet { if seeds.contains(where: { hosts[$0.key] == nil }) { schedulePreheat() } } }
        /// Pause before a page is built at rest: after launch or a click, the window is left to settle first.
        static var preheatDelay: TimeInterval = 1.5
        private var preheatTimer: Timer?
        private var lastShow = ProcessInfo.processInfo.systemUptime
        /// Seeds not built yet; zero once every main page is ready (bench and tests).
        var preheatPending: Int { slot?.placed == true ? seeds.filter { hosts[$0.key] == nil }.count : seeds.count }

        override var isFlipped: Bool { true }

        /// Asks for `show` at the next layout of this view.
        func request(key: String, scope: String = "", keep: Bool = true, inputs: any Equatable = 0, page: AnyView,
                     environment: DashboardCarriedEnvironment, onShown: @escaping () -> Void) {
            requested = (key, scope, keep, inputs, page, environment, onShown)
            lastRequest = requested
            needsLayout = true
        }

        func applyRequest() {
            guard slot?.placed == true, let request = requested else { return }
            requested = nil
            if show(key: request.key, scope: request.scope, keep: request.keep, inputs: request.inputs,
                    page: request.page, environment: request.environment) {
                DispatchQueue.main.async(execute: request.onShown)
            }
        }

        /// Only the shown page is given a new root, and only when what it is built from changed: the hidden ones keep
        /// the one they had when they left. Returns true when another page went into the window.
        @discardableResult
        func show(key: String, scope: String = "", keep: Bool = true, inputs: any Equatable = 0, page: AnyView,
                  environment: DashboardCarriedEnvironment) -> Bool {
            if let former = self.scope, former != scope {
                // Another device: the pages of the former one are freed after this frame (N3).
                for (oldKey, old) in hosts where oldKey != key {
                    old.gate.open.send(false); old.frozen = true; old.removeFromSuperview()
                    hosts[oldKey] = nil; leaving.append(old)
                }
                if let shown = shownKey, hosts[shown] == nil { shownKey = nil }
                released.removeAll()
                afterThisFrame { [weak self] in self?.leaving.removeAll() }
            }
            self.scope = scope
            if keep { released.remove(key) } else { released.insert(key) }
            let host: DashboardKeptHost
            if let kept = hosts[key] {
                host = kept
                if !Self.equal(host.inputs, inputs) || host.environment.map({ !$0.same(as: environment) }) ?? true {
                    give(host, page, inputs, environment)
                }
            } else {
                host = DashboardKeptHost(rootView: AnyView(EmptyView()))
                give(host, page, inputs, environment)
                // The page fills the space SwiftUI gives the slot; it never sizes the window.
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                hosts[key] = host
            }
            guard shownKey != key else { return false }
            if let oldKey = shownKey, let old = hosts[oldKey] {
                // Out of the window with no update of its own: its gate stops its timers, and freezing it stops any
                // update a publication would ask for. Its `onDisappear` runs, its `.task` is cancelled and its
                // `TimelineView`s wait (measured).
                old.gate.open.send(false)
                old.frozen = true
                old.removeFromSuperview()
                if released.contains(oldKey) {
                    hosts[oldKey] = nil; released.remove(oldKey)
                    leaving.append(old)
                    afterThisFrame { [weak self] in self?.leaving.removeAll() }
                }
            }
            shownKey = key
            lastShow = ProcessInfo.processInfo.systemUptime
            host.frozen = false
            host.gate.open.send(true)
            mountShown()
            return true
        }

        /// Builds one page not visited yet, then waits again: one page per quiet moment, never in a click. The page is
        /// laid out hidden in this view, then taken out in the same turn (no frame shows it): it is then a page visited
        /// and left, frozen with its gate closed until shown. Its gate stays closed throughout, so its appear logic
        /// (`onAppearWhenShown`, `taskWhenShown`) waits for its first visit (`KeptPageGate`). Laid out with no window
        /// instead, it stayed linked to every publication (measured, DashboardKeptPagesTests).
        private func schedulePreheat() {
            guard preheatTimer == nil else { return }
            let timer = Timer(timeInterval: Self.preheatDelay / 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.preheatOne() }
            }
            RunLoop.main.add(timer, forMode: .default)
            preheatTimer = timer
        }

        private func preheatOne() {
            guard ProcessInfo.processInfo.systemUptime - lastShow >= Self.preheatDelay, slot?.placed == true,
                  window != nil, let environment = hosts[shownKey ?? ""]?.environment else { return }
            // At rest only: no event waiting, no mouse button down.
            if NSEvent.pressedMouseButtons != 0 { return }
            guard let seed = seeds.first(where: { hosts[$0.key] == nil }) else {
                preheatTimer?.invalidate(); preheatTimer = nil; return
            }
            let host = DashboardKeptHost(rootView: AnyView(EmptyView()))
            host.gate.open.send(false)
            give(host, seed.page(), seed.inputs, environment)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = bounds
            host.isHidden = true
            addSubview(host, positioned: .below, relativeTo: nil)
            host.layoutSubtreeIfNeeded()
            host.frozen = true
            host.removeFromSuperview()
            host.isHidden = false
            hosts[seed.key] = host
        }

        private func give(_ host: DashboardKeptHost, _ page: AnyView, _ inputs: any Equatable,
                          _ environment: DashboardCarriedEnvironment) {
            host.inputs = inputs
            host.environment = environment
            rootCount += 1
            let view = environment.apply(to: page, gate: host.gate)
            host.rootView = slot?.content?.pagesWithoutAnimation == true
                ? AnyView(view.transaction { $0.disablesAnimations = true; $0.animation = nil }) : view
        }

        private static func equal(_ a: any Equatable, _ b: any Equatable) -> Bool { a.isEqual(to: b) }

        /// Runs `work` at the next turn of the main loop, once this one has drawn its frame (a main-queue block would
        /// run before the frame is committed).
        private func afterThisFrame(_ work: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0, repeats: false) { _ in MainActor.assumeIsolated(work) }
            RunLoop.main.add(timer, forMode: .common)
        }

        /// Puts the shown page in this view, once the slot has placed it.
        func mountShown() {
            guard slot?.placed == true, let host = shownKey.flatMap({ hosts[$0] }), host.superview !== self else { return }
            host.frame = bounds
            addSubview(host)
        }

        override func layout() {
            super.layout()
            applyRequest()
            if let host = shownKey.flatMap({ hosts[$0] }), host.frame != bounds { host.frame = bounds }
        }

        func releaseAll() {
            preheatTimer?.invalidate(); preheatTimer = nil
            for host in hosts.values { host.gate.open.send(false); host.removeFromSuperview() }
            hosts.removeAll(); shownKey = nil; requested = nil; lastRequest = nil; released.removeAll(); leaving.removeAll()
            scope = nil
        }

        /// Frees every page and stops the timer, but keeps what was asked last: back in a window, it is built again.
        func releaseKeepingRequest() {
            let last = lastRequest
            releaseAll()
            requested = last; lastRequest = last
            if last != nil { needsLayout = true }
        }

        /// True while the timer that builds pages at rest is set (DashboardKeptPagesTests).
        var preheatScheduled: Bool { preheatTimer != nil }
    }

    private extension Equatable {
        func isEqual(to other: any Equatable) -> Bool { (other as? Self) == self }
    }
#endif
