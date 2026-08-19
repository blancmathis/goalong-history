#if os(macOS)
    import AppKit
    import SwiftUI

    final class DashboardWindowController: NSWindowController, NSWindowDelegate {
        let viewModel: DashboardViewModel

        init(viewModel: DashboardViewModel) {
            self.viewModel = viewModel

            let rootView = LocalHistoryDashboardView(model: viewModel)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = ProductIdentity.displayName
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 1080, height: 680)
            window.setContentSize(NSSize(width: 1240, height: 790))
            window.center()
            // Keep the historical autosave key so existing users retain their preferred window size.
            window.setFrameAutosaveName("LocalHistory.MainWindow.v3")
            window.isReleasedWhenClosed = false

            // The recorder stays a lightweight menu-bar accessory while its dashboard is closed,
            // but the dashboard itself must behave like a normal macOS application window.
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenPrimary]

            super.init(window: window)
            window.delegate = self
        }

        required init?(coder: NSCoder) { nil }

        func show(section: DashboardSection = .overview) {
            viewModel.selectSection(section)

            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            showWindow(nil)
            application.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
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
