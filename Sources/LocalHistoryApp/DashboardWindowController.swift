#if os(macOS)
    import AppKit
    import Darwin
    import SwiftUI

    struct DashboardVisibilityState: Equatable {
        var windowIsVisible: Bool
        var windowIsMiniaturized: Bool
        var applicationIsHidden: Bool
        var windowIsOccluded: Bool
        var windowIsKey: Bool

        /// Dashboard readers can touch large or protected local stores. They run only
        /// while Goalong owns the keyboard, never merely because a background window
        /// remains visible beside the application the user is actually using.
        var permitsRefresh: Bool {
            windowIsVisible && !windowIsMiniaturized && !applicationIsHidden
                && windowIsKey
        }

        static let hidden = DashboardVisibilityState(
            windowIsVisible: false,
            windowIsMiniaturized: false,
            applicationIsHidden: false,
            windowIsOccluded: true,
            windowIsKey: false
        )
    }

    final class DashboardVisibilityCoordinator {
        private let visibilityDidChange: (Bool) -> Void
        private(set) var permitsRefresh = false

        init(visibilityDidChange: @escaping (Bool) -> Void) {
            self.visibilityDidChange = visibilityDidChange
        }

        func update(_ state: DashboardVisibilityState) {
            let next = state.permitsRefresh
            guard next != permitsRefresh else { return }
            permitsRefresh = next
            visibilityDidChange(next)
        }
    }

    final class DashboardWindowController: NSWindowController, NSWindowDelegate {
        let viewModel: DashboardViewModel

        private static let frameAutosaveName = "GoalongHistory.MainWindow.v4"
        private static let legacyFrameAutosaveName = "LocalHistory.MainWindow.v3"
        private var applicationVisibilityObservers: [NSObjectProtocol] = []
        private lazy var visibilityCoordinator = DashboardVisibilityCoordinator {
            [weak self] isVisible in
            guard let self else { return }
            if isVisible {
                self.viewModel.dashboardDidBecomeVisible()
            } else {
                self.viewModel.dashboardDidBecomeHidden()
            }
        }

        init(viewModel: DashboardViewModel) {
            self.viewModel = viewModel
            super.init(window: nil)

            for name in [
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification,
                NSApplication.didResignActiveNotification,
            ] {
                applicationVisibilityObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: NSApplication.shared,
                        queue: .main
                    ) { [weak self] _ in
                        self?.updateDashboardVisibility()
                    }
                )
            }

            // A direct Finder/Spotlight/Launchpad launch makes the app active. A login-item
            // launch stays in accessory mode, so it can keep recording without opening UI.
            DispatchQueue.main.async { [weak self] in
                guard let self, NSApplication.shared.isActive, self.window == nil else { return }
                self.show(section: self.viewModel.selectedSection)
            }
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            for observer in applicationVisibilityObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func loadWindow() {
            let rootView = LocalHistoryDashboardView(model: viewModel)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = ProductIdentity.displayName
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 1080, height: 680)
            window.setContentSize(NSSize(width: 1240, height: 790))
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenPrimary, .participatesInCycle]
            window.animationBehavior = .documentWindow
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false

            let restoredCurrentFrame = window.setFrameUsingName(Self.frameAutosaveName)
            let restoredLegacyFrame =
                restoredCurrentFrame
                ? false
                : window.setFrameUsingName(Self.legacyFrameAutosaveName)
            if !restoredCurrentFrame && !restoredLegacyFrame {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)

            self.window = window
            window.delegate = self
        }

        func show(section: DashboardSection = .overview) {
            viewModel.selectSection(section)

            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            if window == nil {
                loadWindow()
            }

            guard let window else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            showWindow(nil)
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            updateDashboardVisibility()
            DispatchQueue.main.async { [weak self] in
                self?.updateDashboardVisibility()
            }
            SoftwareUpdateManager.shared.refreshAvailableUpdate()
        }

        func windowDidBecomeKey(_ notification: Notification) {
            updateDashboardVisibility()
            viewModel.refreshEverything()
            SoftwareUpdateManager.shared.refreshAvailableUpdate()
        }

        func windowDidResignKey(_ notification: Notification) {
            updateDashboardVisibility()
        }

        func windowDidMiniaturize(_ notification: Notification) {
            updateDashboardVisibility()
        }

        func windowDidDeminiaturize(_ notification: Notification) {
            updateDashboardVisibility()
        }

        func windowDidChangeOcclusionState(_ notification: Notification) {
            updateDashboardVisibility()
        }

        func windowWillClose(_ notification: Notification) {
            visibilityCoordinator.update(.hidden)
            let closingWindow = notification.object as? NSWindow
            closingWindow?.contentViewController = nil
            DispatchQueue.main.async { [weak self, weak closingWindow] in
                if let self, let closingWindow, self.window === closingWindow {
                    self.window = nil
                }
                let application = NSApplication.shared
                let hasVisibleApplicationWindow = application.windows.contains {
                    $0.isVisible && $0.canBecomeKey
                }
                if !hasVisibleApplicationWindow {
                    application.setActivationPolicy(.accessory)
                }
                // SwiftUI and the day readers release their large transient graphs on
                // close. Ask malloc to return the now-free pages once those references
                // have drained so the menu-bar recorder does not retain dashboard RSS.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    _ = malloc_zone_pressure_relief(nil, 0)
                }
            }
        }

        private func updateDashboardVisibility() {
            guard let window else {
                visibilityCoordinator.update(.hidden)
                return
            }
            visibilityCoordinator.update(
                DashboardVisibilityState(
                    windowIsVisible: window.isVisible,
                    windowIsMiniaturized: window.isMiniaturized,
                    applicationIsHidden: NSApplication.shared.isHidden,
                    windowIsOccluded: !window.occlusionState.contains(.visible),
                    windowIsKey: window.isKeyWindow
                )
            )
        }
    }
#endif
