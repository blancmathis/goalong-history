#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI

    /// R14a: the pages already visited stay alive, like tabs. Each one has its own hosting view; only the page shown is
    /// in the window. A hidden page keeps its state (day chosen, scroll position) but is not updated, laid out or drawn:
    /// a model publication does not evaluate it, its timers stop (`keptPageShown`), and it is out of the accessibility
    /// tree and the key-view loop. Coming back puts the same hosting view in the window again: one update with what
    /// changed while it was away, no new page.
    ///
    /// Where the pages live (measured, DashboardKeptPagesTests): a hosting view placed under the dashboard's own hosting
    /// view stays linked to it after it leaves the window, and every update of the dashboard re-evaluates it. So in the
    /// app window (`DashboardWindowContent`) the pages sit in a layer beside the dashboard's hosting view, over the place
    /// SwiftUI gives this view. Anywhere else (gallery renders) they sit inside this view.
    struct DashboardKeptPages<Page: View>: NSViewRepresentable {
        /// One kept page per key (section and device).
        let key: String
        /// False: the page is released once left (secondary pages, rarely opened). Bounds the memory kept.
        var keep = true
        /// After a different page is put in the window (the former `onAppear` of each new page).
        var onShown: () -> Void = {}
        @ViewBuilder let page: () -> Page

        func makeNSView(context: Context) -> DashboardKeptPagesSlot { DashboardKeptPagesSlot() }

        func updateNSView(_ slot: DashboardKeptPagesSlot, context: Context) {
            // Not run here: a hosting view created or updated inside the dashboard's update stays linked to it, and every
            // later update of the dashboard re-evaluated the hidden page (measured, DashboardKeptPagesTests). The pages
            // view runs it in its own layout, in the same frame.
            slot.pages.request(key: key, keep: keep, page: AnyView(page()),
                               environment: DashboardCarriedEnvironment(context.environment), onShown: onShown)
        }

        static func dismantleNSView(_ slot: DashboardKeptPagesSlot, coordinator: ()) { slot.release() }
    }

    extension EnvironmentValues {
        /// False while a kept page is out of the window: its timers, `TimelineView`s and rereads stop.
        var keptPageShown: Bool {
            get { self[KeptPageShownKey.self] }
            set { self[KeptPageShownKey.self] = newValue }
        }

        /// True inside `DashboardWindowContent`, which shows the toasts above the kept pages.
        var dashboardToastsAbovePages: Bool {
            get { self[DashboardToastsAbovePagesKey.self] }
            set { self[DashboardToastsAbovePagesKey.self] = newValue }
        }
    }

    private struct KeptPageShownKey: EnvironmentKey { static let defaultValue = true }

    extension View {
        /// `onReceive` for a timer of a page: it stops while the page is kept out of the window (DashboardKeptPages).
        /// A hidden page's `onAppear`, `.task` and `TimelineView` already wait for its return (measured); its timers do not.
        func onReceiveWhileShown<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View
        where P.Failure == Never {
            modifier(KeptPageReceive(publisher: publisher, action: action))
        }
    }

    private struct KeptPageReceive<P: Publisher>: ViewModifier where P.Failure == Never {
        @Environment(\.keptPageShown) private var shown
        let publisher: P
        let action: (P.Output) -> Void
        func body(content: Content) -> some View {
            content.onReceive(shown ? publisher.eraseToAnyPublisher() : Empty().eraseToAnyPublisher(), perform: action)
        }
    }
    private struct DashboardToastsAbovePagesKey: EnvironmentKey { static let defaultValue = false }

    /// What a kept page takes from the environment above it. Not the whole environment (`\.self`): it would override the
    /// page's own `keptPageShown`. System values (appearance, contrast, Reduce Motion, control size) come from the page's
    /// own window; styles are applied again by the caller.
    struct DashboardCarriedEnvironment {
        let locale: Locale, timeZone: TimeZone, calendar: Calendar, colorScheme: ColorScheme
        let reduceMotion: Bool, defaults: UserDefaults, recording: DashboardViewModel?
        let accessCheck: SourceAccessService.Check

        init(_ environment: EnvironmentValues) {
            locale = environment.locale; timeZone = environment.timeZone; calendar = environment.calendar
            colorScheme = environment.colorScheme; reduceMotion = environment.goalongReduceMotion
            defaults = environment.goalongDefaults; recording = environment.goalongRecordingModel
            accessCheck = environment.sourceAccessCheck
        }

        func apply(to page: AnyView, shown: Bool) -> AnyView {
            AnyView(page
                .defaultAppStorage(defaults).environment(\.goalongDefaults, defaults)
                .environment(\.locale, locale).environment(\.timeZone, timeZone).environment(\.calendar, calendar)
                .environment(\.colorScheme, colorScheme).environment(\.goalongReduceMotion, reduceMotion)
                .environment(\.goalongRecordingModel, recording).environment(\.sourceAccessCheck, accessCheck)
                .environment(\.keptPageShown, shown))
        }
    }

    /// The app window's content: the dashboard's hosting view, the layer of kept pages above it, then the toasts.
    final class DashboardWindowContent: NSView {
        let root: NSHostingView<AnyView>
        let pageLayer = DashboardPassThroughView()
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
        private weak var content: DashboardWindowContent?
        private var inside = false
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
            resolve(final: window != nil)
            guard let content else { return }
            if window == nil {
                // Out of the window (window closed, onboarding shown in its place): the pages leave with this view.
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
        override func layout() { if !frozen { super.layout() } }
    }

    final class DashboardKeptPagesView: NSView {
        private(set) var hosts: [String: DashboardKeptHost] = [:]
        private(set) var shownKey: String?
        private var pages: [String: (AnyView, DashboardCarriedEnvironment)] = [:]
        weak var slot: DashboardKeptPagesSlot?
        private var requested: (key: String, keep: Bool, page: AnyView, environment: DashboardCarriedEnvironment,
                                onShown: () -> Void)?
        /// Keys of pages released once left.
        private var released: Set<String> = []

        override var isFlipped: Bool { true }

        /// Asks for `show` at the next layout of this view.
        func request(key: String, keep: Bool = true, page: AnyView, environment: DashboardCarriedEnvironment,
                     onShown: @escaping () -> Void) {
            requested = (key, keep, page, environment, onShown)
            needsLayout = true
        }

        func applyRequest() {
            guard slot?.placed == true, let request = requested else { return }
            requested = nil
            if show(key: request.key, keep: request.keep, page: request.page, environment: request.environment) {
                DispatchQueue.main.async(execute: request.onShown)
            }
        }

        /// Only the shown page is given a new root: the hidden ones keep the one they had when they left.
        /// Returns true when another page went into the window.
        @discardableResult
        func show(key: String, keep: Bool = true, page: AnyView, environment: DashboardCarriedEnvironment) -> Bool {
            pages[key] = (page, environment)
            if keep { released.remove(key) } else { released.insert(key) }
            let host: DashboardKeptHost
            if let kept = hosts[key] {
                host = kept
                host.frozen = false
                host.rootView = environment.apply(to: page, shown: true)
            } else {
                host = DashboardKeptHost(rootView: environment.apply(to: page, shown: true))
                // The page fills the space SwiftUI gives the slot; it never sizes the window.
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                hosts[key] = host
            }
            guard shownKey != key else { return false }
            if let oldKey = shownKey, let old = hosts[oldKey], let (oldPage, oldEnvironment) = pages[oldKey] {
                // One last update tells the page it is hidden (timers off), then it is frozen out of the window.
                old.rootView = oldEnvironment.apply(to: oldPage, shown: false)
                old.layoutSubtreeIfNeeded()
                old.frozen = true
                old.removeFromSuperview()
                if released.contains(oldKey) { hosts[oldKey] = nil; pages[oldKey] = nil; released.remove(oldKey) }
            }
            shownKey = key
            mountShown()
            return true
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
            for host in hosts.values { host.removeFromSuperview() }
            hosts.removeAll(); pages.removeAll(); shownKey = nil; requested = nil; released.removeAll()
        }
    }
#endif
