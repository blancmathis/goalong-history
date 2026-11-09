#if os(macOS)
    import AppKit

    /// T-048 D1: closes the menu bar panel on a click outside it and on Esc.
    ///
    /// A `.transient` popover closes on outside clicks only while its app is active. Goalong is a menu bar
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
            if let local = hooks.addLocalMonitor(.keyDown, { [weak self] event in
                guard event.keyCode == Self.escapeKeyCode else { return event }
                MainActor.assumeIsolated { self?.dismissByKeyboard() }
                return nil
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
