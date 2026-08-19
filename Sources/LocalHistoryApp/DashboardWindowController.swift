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
            window.title = "LocalHistory"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 1080, height: 680)
            window.setContentSize(NSSize(width: 1240, height: 790))
            window.center()
            window.setFrameAutosaveName("LocalHistory.MainWindow.v3")
            window.isReleasedWhenClosed = false

            // The recorder can stay a lightweight menu-bar accessory while its dashboard is closed,
            // but the dashboard itself must behave like a normal macOS application window. Keeping
            // it at the normal level and making it the primary full-screen window prevents it from
            // joining another application's full-screen Space as an overlay.
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenPrimary]

            super.init(window: window)
            window.delegate = self
        }

        required init?(coder: NSCoder) { nil }

        func show(section: DashboardSection = .overview) {
            viewModel.selectSection(section)

            // LSUIElement keeps the background recorder out of the Dock. Promote the application
            // while the dashboard is in use so macOS gives it normal app, Space and full-screen
            // semantics instead of treating the window as an accessory over the current app.
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            showWindow(nil)
            application.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            viewModel.refreshEverything()
        }
    }
#endif
