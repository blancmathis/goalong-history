#if os(macOS)
    import AppKit
    import SwiftUI

    final class DashboardWindowController: NSWindowController, NSWindowDelegate {
        let viewModel: DashboardViewModel

        private static let frameAutosaveName = "GoalongHistory.MainWindow.v4"
        private static let legacyFrameAutosaveName = "LocalHistory.MainWindow.v3"
        private var activationObserver: NSObjectProtocol?

        init(viewModel: DashboardViewModel) {
            self.viewModel = viewModel
            super.init(window: nil)

            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApplication.shared,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isWindowLoaded else { return }
                self.show(section: self.viewModel.selectedSection)
            }

            // A direct Finder/Spotlight/Launchpad launch makes the app active. A login-item
            // launch stays in accessory mode, so it can keep recording without opening UI.
            DispatchQueue.main.async { [weak self] in
                guard let self, NSApplication.shared.isActive, !self.isWindowLoaded else { return }
                self.show(section: self.viewModel.selectedSection)
            }
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
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
            let restoredLegacyFrame = restoredCurrentFrame
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
            if !isWindowLoaded {
                loadWindow()
            }

            guard let window else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            showWindow(nil)
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            SoftwareUpdateManager.shared.refreshAvailableUpdate()
        }

        func windowDidBecomeKey(_ notification: Notification) {
            viewModel.refreshEverything()
            SoftwareUpdateManager.shared.refreshAvailableUpdate()
        }

        func windowWillClose(_ notification: Notification) {
            DispatchQueue.main.async {
                let application = NSApplication.shared
                let hasVisibleApplicationWindow = application.windows.contains {
                    $0.isVisible && $0.canBecomeKey
                }
                if !hasVisibleApplicationWindow {
                    application.setActivationPolicy(.accessory)
                }
            }
        }
    }
#endif
