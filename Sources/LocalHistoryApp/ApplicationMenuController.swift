#if os(macOS)
    import AppKit

    /// Installs the standard macOS menu hierarchy while the dashboard is open.
    /// The app can still launch as an LSUIElement menu-bar recorder; switching to
    /// `.regular` in `DashboardWindowController` then reveals this retained menu.
    final class ApplicationMenuController: NSObject, NSMenuDelegate {
        private let onOpenSettings: () -> Void
        private let onNavigate: (DashboardSection) -> Void
        private let onCheckForUpdates: () -> Void
        private let canCheckForUpdates: () -> Bool
        private let onQuit: () -> Void

        private let servicesMenu = NSMenu(title: "Services")
        private let windowMenu = NSMenu(title: "Fenêtre")
        private let checkForUpdatesItem = NSMenuItem(
            title: "Rechercher les mises à jour…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )

        private(set) lazy var mainMenu: NSMenu = buildMainMenu()

        init(
            onOpenSettings: @escaping () -> Void,
            onNavigate: @escaping (DashboardSection) -> Void = { _ in },
            onCheckForUpdates: @escaping () -> Void,
            canCheckForUpdates: @escaping () -> Bool,
            onQuit: @escaping () -> Void
        ) {
            self.onOpenSettings = onOpenSettings
            self.onNavigate = onNavigate
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
            menu.addItem(rootItem(title: "Fichier", submenu: fileMenu()))
            menu.addItem(rootItem(title: "Édition", submenu: editMenu()))
            menu.addItem(rootItem(title: "Présentation", submenu: viewMenu()))
            menu.addItem(rootItem(title: "Fenêtre", submenu: windowMenu))
            let help = helpMenu()
            menu.addItem(rootItem(title: "Aide", submenu: help))
            NSApplication.shared.helpMenu = help
            return menu
        }

        private func applicationMenu() -> NSMenu {
            let menu = NSMenu(title: ProductIdentity.displayName)
            menu.delegate = self

            menu.addItem(item("À propos de \(ProductIdentity.displayName)", action: #selector(showAbout)))
            checkForUpdatesItem.target = self
            menu.addItem(checkForUpdatesItem)
            menu.addItem(.separator())
            menu.addItem(item("Réglages…", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(.separator())

            let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            servicesItem.submenu = servicesMenu
            menu.addItem(servicesItem)
            menu.addItem(.separator())

            menu.addItem(
                responderItem(
                    "Masquer \(ProductIdentity.displayName)",
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h"
                ))
            let hideOthers = responderItem(
                "Masquer les autres",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(hideOthers)
            menu.addItem(
                responderItem("Tout afficher", action: #selector(NSApplication.unhideAllApplications(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Quitter et rouvrir \(ProductIdentity.displayName)", action: #selector(restart)))
            menu.addItem(
                item(
                    "Quitter \(ProductIdentity.displayName)",
                    action: #selector(quit),
                    keyEquivalent: "q"
                ))
            return menu
        }

        private func fileMenu() -> NSMenu {
            let menu = NSMenu(title: "Fichier")
            menu.addItem(
                responderItem(
                    "Fermer la fenêtre",
                    action: #selector(NSWindow.performClose(_:)),
                    keyEquivalent: "w"
                ))
            return menu
        }

        private func editMenu() -> NSMenu {
            let menu = NSMenu(title: "Édition")
            menu.addItem(responderItem("Annuler", action: Selector(("undo:")), keyEquivalent: "z"))
            let redo = responderItem("Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(redo)
            menu.addItem(.separator())
            menu.addItem(responderItem("Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
            menu.addItem(responderItem("Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            menu.addItem(responderItem("Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            menu.addItem(
                responderItem("Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
            return menu
        }

        private func viewMenu() -> NSMenu {
            let menu = NSMenu(title: "Présentation")
            for (index, section) in DashboardSection.primarySections.filter({ $0 != .settings }).enumerated() {
                let entry = item(section.simpleTitle, action: #selector(navigate(_:)), keyEquivalent: "\(index + 1)")
                entry.representedObject = section.rawValue
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let fullScreen = responderItem(
                "Passer en plein écran",
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
                    "Placer dans le Dock",
                    action: #selector(NSWindow.performMiniaturize(_:)),
                    keyEquivalent: "m"
                ))
            windowMenu.addItem(responderItem("Réduire/agrandir", action: #selector(NSWindow.performZoom(_:))))
            windowMenu.addItem(.separator())
            windowMenu.addItem(
                responderItem(
                    "Tout ramener au premier plan",
                    action: #selector(NSApplication.arrangeInFront(_:))
                ))
        }

        private func helpMenu() -> NSMenu {
            let menu = NSMenu(title: "Aide")
            menu.addItem(item("Signaler un problème…", action: #selector(reportProblem)))
            menu.addItem(.separator())
            menu.addItem(item("Guide d’utilisation", action: #selector(openGuide)))
            menu.addItem(item("Notes de version", action: #selector(openReleaseNotes)))
            return menu
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

        @objc private func navigate(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let section = DashboardSection(rawValue: raw) else { return }
            onNavigate(section)
        }

        @objc private func checkForUpdates() {
            onCheckForUpdates()
        }

        @objc private func restart() {
            Task { @MainActor in
                PermissionRecovery.restart { error in
                    guard let error else { return }
                    let alert = NSAlert()
                    alert.messageText = "Goalong est resté ouvert"
                    alert.informativeText = error
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        @objc private func reportProblem() {
            Task { @MainActor in SupportRequestController.shared.present() }
        }

        @objc private func openGuide() {
            GoalongWorkspaceOpenPolicy.open(ProductIdentity.guideURL, purpose: .documentation)
        }

        @objc private func openReleaseNotes() {
            GoalongWorkspaceOpenPolicy.open(ProductIdentity.rollingReleasePageURL, purpose: .updatePage)
        }

        @objc private func quit() {
            onQuit()
        }
    }
#endif
