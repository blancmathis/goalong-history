#if os(macOS)
    import AppKit

    /// Installs the standard macOS menu hierarchy while the dashboard is open.
    /// The app can still launch as an LSUIElement menu-bar recorder; switching to
    /// `.regular` in `DashboardWindowController` then reveals this retained menu.
    final class ApplicationMenuController: NSObject, NSMenuDelegate {
        private let onOpenSettings: () -> Void
        private let onCheckForUpdates: () -> Void
        private let canCheckForUpdates: () -> Bool
        private let onQuit: () -> Void

        private let servicesMenu = NSMenu(title: "Services")
        private let windowMenu = NSMenu(title: "Window")
        private let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )

        private(set) lazy var mainMenu: NSMenu = buildMainMenu()

        init(
            onOpenSettings: @escaping () -> Void,
            onCheckForUpdates: @escaping () -> Void,
            canCheckForUpdates: @escaping () -> Bool,
            onQuit: @escaping () -> Void
        ) {
            self.onOpenSettings = onOpenSettings
            self.onCheckForUpdates = onCheckForUpdates
            self.canCheckForUpdates = canCheckForUpdates
            self.onQuit = onQuit
            super.init()
        }

        func install(in application: NSApplication) {
            application.mainMenu = mainMenu
            application.servicesMenu = servicesMenu
            application.windowsMenu = windowMenu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            checkForUpdatesItem.isEnabled = canCheckForUpdates()
        }

        private func buildMainMenu() -> NSMenu {
            let menu = NSMenu(title: "Main Menu")
            menu.addItem(rootItem(title: ProductIdentity.displayName, submenu: applicationMenu()))
            menu.addItem(rootItem(title: "File", submenu: fileMenu()))
            menu.addItem(rootItem(title: "Edit", submenu: editMenu()))
            menu.addItem(rootItem(title: "View", submenu: viewMenu()))
            menu.addItem(rootItem(title: "Window", submenu: windowMenu))
            return menu
        }

        private func applicationMenu() -> NSMenu {
            let menu = NSMenu(title: ProductIdentity.displayName)
            menu.delegate = self

            menu.addItem(item("About \(ProductIdentity.displayName)", action: #selector(showAbout)))
            checkForUpdatesItem.target = self
            menu.addItem(checkForUpdatesItem)
            menu.addItem(.separator())
            menu.addItem(item("Settings…", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(.separator())

            let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            servicesItem.submenu = servicesMenu
            menu.addItem(servicesItem)
            menu.addItem(.separator())

            menu.addItem(
                responderItem(
                    "Hide \(ProductIdentity.displayName)",
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h"
                ))
            let hideOthers = responderItem(
                "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(hideOthers)
            menu.addItem(
                responderItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
            menu.addItem(.separator())
            menu.addItem(
                item(
                    "Quit \(ProductIdentity.displayName)",
                    action: #selector(quit),
                    keyEquivalent: "q"
                ))
            return menu
        }

        private func fileMenu() -> NSMenu {
            let menu = NSMenu(title: "File")
            menu.addItem(
                responderItem(
                    "Close Window",
                    action: #selector(NSWindow.performClose(_:)),
                    keyEquivalent: "w"
                ))
            return menu
        }

        private func editMenu() -> NSMenu {
            let menu = NSMenu(title: "Edit")
            menu.addItem(responderItem("Undo", action: Selector(("undo:")), keyEquivalent: "z"))
            let redo = responderItem("Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(redo)
            menu.addItem(.separator())
            menu.addItem(responderItem("Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
            menu.addItem(responderItem("Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            menu.addItem(responderItem("Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            menu.addItem(
                responderItem("Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
            return menu
        }

        private func viewMenu() -> NSMenu {
            let menu = NSMenu(title: "View")
            let fullScreen = responderItem(
                "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f"
            )
            fullScreen.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(fullScreen)
            return menu
        }

        private func configureWindowMenu() {
            guard windowMenu.items.isEmpty else { return }
            windowMenu.addItem(
                responderItem(
                    "Minimize",
                    action: #selector(NSWindow.performMiniaturize(_:)),
                    keyEquivalent: "m"
                ))
            windowMenu.addItem(responderItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
            windowMenu.addItem(.separator())
            windowMenu.addItem(
                responderItem(
                    "Bring All to Front",
                    action: #selector(NSApplication.arrangeInFront(_:))
                ))
        }

        private func rootItem(title: String, submenu: NSMenu) -> NSMenuItem {
            if submenu === windowMenu { configureWindowMenu() }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        private func item(
            _ title: String,
            action: Selector,
            keyEquivalent: String = ""
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            return item
        }

        private func responderItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String = ""
        ) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        }

        @objc private func showAbout() {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        @objc private func openSettings() {
            onOpenSettings()
        }

        @objc private func checkForUpdates() {
            onCheckForUpdates()
        }

        @objc private func quit() {
            onQuit()
        }
    }
#endif
