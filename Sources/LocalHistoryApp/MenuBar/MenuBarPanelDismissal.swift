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
            /// The app that was frontmost before the panel opened; given back when Esc closes the panel.
            var frontmostOther: () -> NSRunningApplication?

            static let live = Hooks(
                addGlobalMonitor: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
                addLocalMonitor: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
                removeMonitor: { NSEvent.removeMonitor($0) },
                activate: { NSApplication.shared.activate(ignoringOtherApps: true) },
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
            hooks.activate()
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
        }
    }
#endif
