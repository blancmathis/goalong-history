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

            super.init(window: window)
            window.delegate = self
        }

        required init?(coder: NSCoder) { nil }

        func show(section: DashboardSection = .overview) {
            viewModel.selectSection(section)
            NSApplication.shared.activate(ignoringOtherApps: true)
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            viewModel.refreshEverything()
        }
    }
#endif
