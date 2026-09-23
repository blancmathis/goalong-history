#if os(macOS)
import AppKit
import Sparkle

/// Uses public AppKit ownership/child-window APIs only; never Sparkle private ivars or KVC.
/// Armed by an explicit update action, not a passive background check.
@MainActor final class SoftwareUpdateWindowCoordinator {
    @MainActor private final class Entry {
        weak var window: NSWindow?
        weak var attachedParent: NSWindow?
        let level: NSWindow.Level
        let behavior: NSWindow.CollectionBehavior
        let hidesOnDeactivate: Bool
        init(_ window: NSWindow) {
            self.window = window; level = window.level
            behavior = window.collectionBehavior; hidesOnDeactivate = window.hidesOnDeactivate
        }
    }
    private weak var dashboard: NSWindow?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false
    private var focusPending = false
    private(set) var isPresenting = false
    private let recognizes: (NSWindow) -> Bool
    private let ordersWindows: Bool

    init(ordersWindows: Bool = true, recognizes: ((NSWindow) -> Bool)? = nil) {
        self.ordersWindows = ordersWindows; self.recognizes = recognizes ?? { Self.isSparkleWindow($0) }
    }
    static func isSparkleWindow(_ window: NSWindow) -> Bool {
        let framework = Bundle(for: SPUStandardUserDriver.self).bundleURL
        // Window controllers are public AppKit objects. Check their defining bundle, not names/titles.
        if let owner = window.windowController, Bundle(for: type(of: owner)).bundleURL == framework { return true }
        return Bundle(for: type(of: window)).bundleURL == framework
    }
    func registerDashboard(_ window: NSWindow) {
        dashboard = window
        scheduleRefresh()
    }
    func beginExplicitPresentation() {
        isPresenting = true; focusPending = true
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didUpdateNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.scheduleRefresh() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notice in
                guard let window = notice.object as? NSWindow else { return }
                Task { @MainActor in self?.windowClosed(window) }
            })
        }
        scheduleRefresh()
    }
    func dashboardWasShown() {
        guard isPresenting else { return }
        focusPending = true; scheduleRefresh()
    }
    private func scheduleRefresh() {
        guard isPresenting, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.reconcile(NSApplication.shared.windows)
        }
    }
    /// Injectable window list allows native offscreen regression tests without an updater/network.
    func reconcile(_ windows: [NSWindow]) {
        guard isPresenting else { return }
        entries = entries.filter { $0.value.window != nil }
        for window in windows where recognizes(window) && (window.isVisible || (focusPending && window.isMiniaturized)) {
            let id = ObjectIdentifier(window)
            let isNew = entries[id] == nil
            let entry = entries[id] ?? Entry(window)
            entries[id] = entry
            let parent = dashboard.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
            if let old = entry.attachedParent, old !== parent {
                old.removeChildWindow(window); entry.attachedParent = nil
            }
            if let parent, window !== parent, window.parent == nil {
                parent.addChildWindow(window, ordered: .above); entry.attachedParent = parent
            }
            let level = NSWindow.Level(rawValue: max(entry.level.rawValue, NSWindow.Level.floating.rawValue))
            if window.level != level { window.level = level }
            if !window.collectionBehavior.contains(.fullScreenAuxiliary) {
                window.collectionBehavior.insert(.fullScreenAuxiliary)
            }
            if !window.hidesOnDeactivate { window.hidesOnDeactivate = true }
            // Never steal focus on every app update or when the user switches to another app.
            if ordersWindows, (focusPending || isNew), NSApplication.shared.isActive {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            focusPending = false
        }
    }
    private func windowClosed(_ window: NSWindow) {
        if window === dashboard {
            for entry in entries.values {
                if let child = entry.window { entry.attachedParent?.removeChildWindow(child) }
                entry.attachedParent = nil
            }
            dashboard = nil
        }
        if let entry = entries.removeValue(forKey: ObjectIdentifier(window)) { restore(entry) }
    }
    private func restore(_ entry: Entry) {
        guard let window = entry.window else { return }
        entry.attachedParent?.removeChildWindow(window)
        window.level = entry.level
        window.collectionBehavior = entry.behavior
        window.hidesOnDeactivate = entry.hidesOnDeactivate
    }
    func finish() {
        isPresenting = false; focusPending = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for entry in entries.values { restore(entry) }
        entries.removeAll()
    }
}
#endif
