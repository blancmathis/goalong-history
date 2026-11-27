#if os(macOS)
    import AppKit

    /// T-048 D1: closes the menu bar panel on a click outside it and on Esc.
    ///
    /// T-051: the popover is `.applicationDefined`, so AppKit never closes it by itself (focus or activation
    /// changes, pointer leaving the icon). It closes only here: click elsewhere, Esc, second click on the icon.
    ///
    /// Before T-051, a `.transient` popover closes on outside clicks only while its app is active. Goalong is a menu bar
    /// app: a click on its icon (and, since 0.6.178, a click relayed from the helper's icon) does not
    /// activate it, so the panel stayed open until a second click on the icon.
    /// Fix: activate Goalong when the panel opens (the panel gets the keyboard), and watch mouse downs in
    /// other apps while it is shown, because activation can be refused (cooperative activation, macOS 14+).
    @MainActor final class MenuBarPanelDismissal {
        struct Hooks {
            /// Mouse downs sent to other apps (desktop, other windows, other menu bar items, the helper's icon).
            var addGlobalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
            /// Events sent to Goalong itself; return nil to swallow one.
            var addLocalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
            var removeMonitor: (Any) -> Void
            /// True when a Goalong event lands in the panel's window or one opened from it (a click there keeps the panel open).
            var isInsidePanel: (NSEvent) -> Bool = { _ in false }
            /// Brings Goalong forward so the panel takes the keyboard.
            var activate: () -> Void
            /// True when the app in front shows a full-screen window. Activating Goalong there makes macOS hide
            /// the menu bar of that Space (seen 2026-11-24: `hideBackstopMenuBar` 30-40 ms after Goalong comes forward).
            var frontIsFullScreen: (NSRunningApplication?) -> Bool = { _ in false }
            /// T-057 (bugs-concurrence-05): same question for a real front app, answered off the main actor so the
            /// click never waits for that app's Accessibility. `nil` = ask `frontIsFullScreen` at once (tests).
            var probeFullScreen: ((NSRunningApplication, @escaping @MainActor (Bool) -> Void) -> Void)?
            /// The app that was frontmost before the panel opened; given back when Esc closes the panel.
            var frontmostOther: () -> NSRunningApplication?

            static let live = Hooks(
                addGlobalMonitor: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
                addLocalMonitor: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
                removeMonitor: { NSEvent.removeMonitor($0) },
                activate: { NSApplication.shared.activate(ignoringOtherApps: true) },
                frontIsFullScreen: { app in MainActor.assumeIsolated { MenuBarPanelDismissal.showsFullScreenWindow(app) } },
                probeFullScreen: { app, done in
                    let pid = app.processIdentifier
                    DispatchQueue.global(qos: .userInitiated).async {
                        let answer = MenuBarPanelDismissal.axShowsFullScreenWindow(pid: pid)
                        DispatchQueue.main.async { MainActor.assumeIsolated { done(answer) } }
                    }
                },
                frontmostOther: {
                    let app = NSWorkspace.shared.frontmostApplication
                    return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
                })
        }

        /// True when `window` is the panel's window or hangs from it (child window via `parent`, sheet via
        /// `sheetParent`). Generic over the window type so tests need no real window.
        static func isInside<W: AnyObject>(_ window: W?, panel: W?, parents: (W) -> [W]) -> Bool {
            guard let panel else { return false }
            var seen = Set<ObjectIdentifier>()
            var pending = window.map { [$0] } ?? []
            while let next = pending.popLast() {
                if next === panel { return true }
                guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
                pending += parents(next)
            }
            return false
        }

        static func isInside(_ window: NSWindow?, panel: NSWindow?) -> Bool {
            isInside(window, panel: panel) { [$0.parent, $0.sheetParent].compactMap { $0 } }
        }

        static let outsideClicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        static let escapeKeyCode: UInt16 = 53

        private let hooks: Hooks
        private let close: @MainActor () -> Void
        private var monitors: [Any] = []
        private var previousApp: NSRunningApplication?

        /// `close`: closes the panel (the owner then calls `end()` from its did-close callback).
        init(hooks: Hooks = .live, close: @escaping @MainActor () -> Void) {
            self.hooks = hooks
            self.close = close
        }

        var isArmed: Bool { !monitors.isEmpty }

        /// Call right before the panel shows.
        func begin() {
            end()
            previousApp = hooks.frontmostOther()
            if let global = hooks.addGlobalMonitor(Self.outsideClicks, { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }) { monitors.append(global) }
            if let local = hooks.addLocalMonitor([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], { [weak self] event in
                switch event.type {
                case .keyDown:
                    guard event.keyCode == Self.escapeKeyCode else { return event }
                    MainActor.assumeIsolated { self?.dismissByKeyboard() }
                    return nil
                default:
                    // A click in another Goalong window or on our own icon closes the panel; the click still goes on.
                    // Mouse moves and exits never come here: leaving the icon or the panel keeps it open.
                    MainActor.assumeIsolated {
                        guard let self, !self.hooks.isInsidePanel(event) else { return }
                        self.close()
                    }
                    return event
                }
            }) { monitors.append(local) }
            // In a full-screen Space, stay in the back: the menu bar stays visible. A click in the panel still
            // activates Goalong (normal first click); outside clicks close the panel through the global monitor.
            // T-057: the Accessibility question (21-56 ms on a cold first call, up to 0.2 s for a slow app) is asked
            // off the main actor. Until it answers, Goalong stays in the back (the safe side in a full-screen Space);
            // it activates only if the answer is "not full screen", the panel is still the same one, and the app in
            // front is still the same app.
            probeGeneration &+= 1
            guard let app = previousApp, let probe = hooks.probeFullScreen else {
                if !hooks.frontIsFullScreen(previousApp) { hooks.activate() }
                return
            }
            let generation = probeGeneration
            probe(app) { [weak self] fullScreen in
                guard let self, self.probeGeneration == generation, self.isArmed, !fullScreen,
                      self.hooks.frontmostOther()?.processIdentifier == app.processIdentifier else { return }
                self.hooks.activate()
            }
        }

        private var probeGeneration = 0

        /// Full-screen check of the front app's focused window (Accessibility, `AXFullScreen`); Goalong itself when
        /// `app` is nil. Without Accessibility access the answer is false and Goalong activates as before.
        static func showsFullScreenWindow(_ app: NSRunningApplication?) -> Bool {
            guard let app else {
                return NSApplication.shared.windows.contains { $0.isVisible && $0.isOnActiveSpace && $0.styleMask.contains(.fullScreen) }
            }
            return axShowsFullScreenWindow(pid: app.processIdentifier)
        }

        /// The Accessibility part alone: safe off the main actor.
        nonisolated static func axShowsFullScreenWindow(pid: pid_t) -> Bool {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.1)
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else { return false }
            return (value as? Bool) ?? false
        }

        /// Esc: close and hand the keyboard back to the app the user was in.
        func dismissByKeyboard() {
            let previous = previousApp
            close()
            previous?.activate()
        }

        /// Call once the panel has closed, whatever closed it.
        func end() {
            for monitor in monitors { hooks.removeMonitor(monitor) }
            monitors = []
            previousApp = nil
            probeGeneration &+= 1
        }
    }
#endif
