#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore

    final class MenuBarController: NSObject, NSMenuDelegate {
        private let statusItem: NSStatusItem
        private let menu = NSMenu()

        private let state: CaptureState
        private let permissions: PermissionManager
        private let store: JSONLStore
        private let recorder: EventRecorder
        private let configManager: ConfigManager
        private let eventTapStatus: () -> Bool
        private let currentSuppression: () -> SuppressionReason?
        private let captureHealth: () -> CaptureHealthAssessment
        private let onDeleteDetails: (Date?, @escaping (Result<Int, Error>) -> Void) -> Void
        private let onOpenDashboard: () -> Void
        private let onOpenMonitoring: () -> Void
        private let onOpenShare: () -> Void
        private let onTogglePause: () -> Void
        private let onRequestPermissions: () -> Void
        private let onReloadConfig: () -> Void
        private let onQuit: () -> Void

        private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let permissionMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let globalPauseItem = NSMenuItem(title: "Arrêt de confidentialité", action: #selector(toggleGlobalPause), keyEquivalent: "")
        private let pauseMenuItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")
        private let technicalStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let updateMenuItem = NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(checkForUpdates), keyEquivalent: "")

        init(
            state: CaptureState,
            permissions: PermissionManager,
            store: JSONLStore,
            recorder: EventRecorder,
            configManager: ConfigManager,
            eventTapStatus: @escaping () -> Bool,
            currentSuppression: @escaping () -> SuppressionReason?,
            captureHealth: @escaping () -> CaptureHealthAssessment,
            onDeleteDetails: @escaping (Date?, @escaping (Result<Int, Error>) -> Void) -> Void,
            onOpenDashboard: @escaping () -> Void,
            onOpenMonitoring: @escaping () -> Void,
            onOpenShare: @escaping () -> Void,
            onTogglePause: @escaping () -> Void,
            onRequestPermissions: @escaping () -> Void,
            onReloadConfig: @escaping () -> Void,
            onQuit: @escaping () -> Void
        ) {
            self.state = state
            self.permissions = permissions
            self.store = store
            self.recorder = recorder
            self.configManager = configManager
            self.eventTapStatus = eventTapStatus
            self.currentSuppression = currentSuppression
            self.captureHealth = captureHealth
            self.onDeleteDetails = onDeleteDetails
            self.onOpenDashboard = onOpenDashboard
            self.onOpenMonitoring = onOpenMonitoring
            self.onOpenShare = onOpenShare
            self.onTogglePause = onTogglePause
            self.onRequestPermissions = onRequestPermissions
            self.onReloadConfig = onReloadConfig
            self.onQuit = onQuit

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            super.init()

            configureStatusItem()
            buildMenu()
            updateStatus()
        }

        func menuWillOpen(_ menu: NSMenu) {
            updateStatus()
        }

        func updateStatus() {
            let permissionStatus = permissions.snapshot
            let recording = state.isCapturing
            let suppression = recording ? currentSuppression() : nil
            let health = captureHealth()

            let display: (title: String, symbol: String, description: String)
            let localEnabled = GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory)
            if GoalongGlobalPause.isPaused() {
                display = ("Arrêt de confidentialité", "pause.circle.fill", "Sources et envois suspendus")
            } else if !localEnabled {
                display = ("Enregistrement désactivé", "circle.dashed", "Activez l’enregistrement dans Réglages pour remplir votre historique")
            } else if health.state == .storageUnavailable {
                display = ("Enregistrement interrompu", "externaldrive.badge.exclamationmark",
                           "L’historique ne peut pas être écrit (disque plein ?). Reprise automatique dès que possible")
            } else if health.state == .permissionRequired
                || health.state == .permissionAppearsEnabledButStaleForBuild
                || health.state == .accessibilityContextUnavailable
            {
                display = ("Autorisation macOS à vérifier", "exclamationmark.triangle.fill",
                           "Ouvrez Goalong pour rétablir l’accès : rien n’est enregistré en attendant")
            } else if !recording {
                display = ("Enregistrement en pause", "pause.circle.fill", "\(ProductIdentity.displayName) est en pause")
            } else if let suppression, suppression == .accessibilityUnavailable {
                display = ("Navigateur non accessible", "exclamationmark.shield.fill",
                           "Cette fenêtre ne peut pas être lue en toute sécurité : aucun détail enregistré")
            } else if let suppression, suppression == .sessionUnavailable {
                display = ("Session Mac inactive", "lock.fill", "Le Mac est verrouillé, en veille ou indisponible")
            } else if health.state == .inputTapUnavailable || health.state == .awaitingInputEvidence {
                display = ("Interactions en attente", "waveform.path.ecg",
                           "Les clics et la frappe seront comptés dès le premier événement reçu")
            } else {
                display = ("Enregistrement local actif", "record.circle.fill",
                           "Votre activité reste sur ce Mac")
            }

            statusMenuItem.title = display.title
            statusMenuItem.image = NSImage(
                systemSymbolName: display.symbol,
                accessibilityDescription: display.description
            )
            statusMenuItem.toolTip = display.description
            permissionMenuItem.title = display.description
            technicalStatusItem.title =
                "Accessibilité : \(permissionStatus.accessibility ? "oui" : "non") · Surveillance de l’entrée : \(permissionStatus.inputMonitoringStatusLabel) · Interactions : \(eventTapStatus() ? "actives" : "inactives") · Preuve : \(health.captureProven ? "oui" : "non")"
            globalPauseItem.title = GoalongGlobalPause.isPaused() ? "Reprendre tout le suivi" : "Tout suspendre pour confidentialité…"
            pauseMenuItem.title = !localEnabled
                ? "Configurer l’enregistrement…"
                : (state.isManuallyPaused ? "Reprendre l’enregistrement local" : "Arrêter l’enregistrement local…")
            Task { @MainActor in
                let updates = SoftwareUpdateManager.shared
                self.updateMenuItem.title = updates.availableVersion.map { "Installer la version \($0)…" }
                    ?? "Rechercher les mises à jour…"
            }

            if let button = statusItem.button {
                button.image = GoalongBrandAssets.menuBarImage
                button.toolTip = "\(ProductIdentity.displayName) — \(display.title)"
                button.setAccessibilityLabel(ProductIdentity.displayName)
                button.setAccessibilityHelp(display.description)
            }
        }

        private func configureStatusItem() {
            if let button = statusItem.button {
                button.image = GoalongBrandAssets.menuBarImage
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = ProductIdentity.displayName
                button.setAccessibilityLabel(ProductIdentity.displayName)
            }
            statusItem.menu = menu
            menu.delegate = self
        }

        private func buildMenu() {
            let openItem = makeItem("Ouvrir \(ProductIdentity.displayName)", action: #selector(openDashboard), keyEquivalent: "o")
            openItem.image = GoalongBrandAssets.menuBarImage
            menu.addItem(openItem)
            menu.addItem(.separator())

            statusMenuItem.isEnabled = false
            permissionMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)
            menu.addItem(permissionMenuItem)
            menu.addItem(.separator())

            globalPauseItem.target = self
            pauseMenuItem.target = self
            let privacyMenu = NSMenu(title: "Confidentialité · arrêter le suivi")
            privacyMenu.addItem(globalPauseItem)
            privacyMenu.addItem(pauseMenuItem)
            let privacyItem = NSMenuItem(title: "Confidentialité · arrêter le suivi", action: nil, keyEquivalent: "")
            privacyItem.submenu = privacyMenu
            menu.addItem(privacyItem)
            Task { @MainActor in JevMenuController.shared.install(in: self.menu, onOpenMonitoring: self.onOpenMonitoring) }
            menu.addItem(.separator())
            updateMenuItem.target = self
            menu.addItem(updateMenuItem)
            menu.addItem(makeItem("Signaler un problème…", action: #selector(openDiagnostics)))

            // Tools for inspection and recovery stay available without cluttering the
            // everyday menu.
            let advanced = NSMenu(title: "Avancé")
            technicalStatusItem.isEnabled = false
            advanced.addItem(technicalStatusItem)
            advanced.addItem(.separator())
            advanced.addItem(makeItem("Partager une journée signée…", action: #selector(openShare)))
            advanced.addItem(makeItem("Ouvrir le fichier du jour (JSONL)", action: #selector(openTodayFile)))
            advanced.addItem(makeItem("Ouvrir le dossier des données", action: #selector(openDataFolder)))
            advanced.addItem(makeItem("Ouvrir la configuration", action: #selector(openConfiguration)))
            advanced.addItem(makeItem("Recharger la configuration", action: #selector(reloadConfiguration)))
            advanced.addItem(.separator())

            let permissionsMenu = NSMenu(title: "Autorisations")
            permissionsMenu.addItem(makeItem("Demander les accès nécessaires", action: #selector(requestPermissions)))
            permissionsMenu.addItem(makeItem("Réglage Accessibilité…", action: #selector(openAccessibilitySettings)))
            permissionsMenu.addItem(makeItem("Réglage Surveillance de l’entrée…", action: #selector(openInputMonitoringSettings)))
            let permissionsItem = NSMenuItem(title: "Autorisations", action: nil, keyEquivalent: "")
            permissionsItem.submenu = permissionsMenu
            advanced.addItem(permissionsItem)

            let clearMenu = NSMenu(title: "Effacer l’historique détaillé")
            clearMenu.addItem(makeItem("10 dernières minutes…", action: #selector(clearLastTenMinutes)))
            clearMenu.addItem(makeItem("Dernière heure…", action: #selector(clearLastHour)))
            clearMenu.addItem(makeItem("Dernières 24 heures…", action: #selector(clearLastDay)))
            clearMenu.addItem(makeItem("Tout l’historique détaillé…", action: #selector(clearAllHistory)))
            let clearItem = NSMenuItem(title: "Effacer l’historique détaillé", action: nil, keyEquivalent: "")
            clearItem.submenu = clearMenu
            advanced.addItem(clearItem)
            let advancedItem = NSMenuItem(title: "Avancé", action: nil, keyEquivalent: "")
            advancedItem.submenu = advanced
            menu.addItem(advancedItem)
            menu.addItem(.separator())
            menu.addItem(makeItem("Quitter \(ProductIdentity.displayName)", action: #selector(quit), keyEquivalent: "q"))
        }

        @objc private func checkForUpdates() {
            Task { @MainActor in
                let updates = SoftwareUpdateManager.shared
                if updates.availableVersion != nil { updates.showAvailableUpdate() } else { updates.checkForUpdates() }
            }
        }

        private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            return item
        }

        @objc private func openDashboard() {
            onOpenDashboard()
        }

        @objc private func openShare() {
            onOpenShare()
        }

        @objc private func toggleGlobalPause() {
            if !GoalongGlobalPause.isPaused(), !confirmRecordingStop(allSources: true) { return }
            do {
                try GoalongGlobalPause.setPaused(!GoalongGlobalPause.isPaused(), recordingWasPaused: state.isManuallyPaused)
                updateStatus()
            } catch {
                let alert = NSAlert(); alert.messageText = "Pause non modifiée"; alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }

        private func confirmRecordingStop(allSources: Bool) -> Bool {
            let alert = NSAlert()
            alert.messageText = allSources ? "Suspendre tout le suivi ?" : "Arrêter l’enregistrement local ?"
            alert.informativeText = "Votre historique ne sera plus enregistré jusqu’à la reprise. Pour suspendre seulement les rappels de surveillance, utilisez plutôt « Faire une pause » : l’historique continue."
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Suspendre le suivi")
            return alert.runModal() == .alertSecondButtonReturn
        }
        @objc private func togglePause() {
            if state.isCapturing, !confirmRecordingStop(allSources: false) { return }
            onTogglePause()
            updateStatus()
        }

        @objc private func openTodayFile() {
            let file = AppPaths.eventFileURL()
            if FileManager.default.fileExists(atPath: file.path) {
                GoalongWorkspaceOpenPolicy.open(file, purpose: .localFile)
            } else {
                GoalongWorkspaceOpenPolicy.open(AppPaths.eventsDirectory, purpose: .localFile)
            }
        }

        @objc private func openDataFolder() {
            GoalongWorkspaceOpenPolicy.open(
                AppPaths.applicationSupportDirectory,
                purpose: .localFile
            )
        }

        @objc private func openConfiguration() {
            GoalongWorkspaceOpenPolicy.open(AppPaths.configFile, purpose: .localFile)
        }

        @objc private func openDiagnostics() {
            Task { @MainActor in SupportRequestController.shared.present() }
        }

        @objc private func requestPermissions() {
            onRequestPermissions()
        }

        @objc private func openAccessibilitySettings() {
            permissions.openAccessibilitySettings()
        }

        @objc private func openInputMonitoringSettings() {
            permissions.openInputMonitoringSettings()
        }

        @objc private func reloadConfiguration() {
            onReloadConfig()
            showInformation(
                title: "Configuration rechargée",
                message: "\(ProductIdentity.displayName) a relu config.json et actualisé ses réglages."
            )
        }

        @objc private func clearLastTenMinutes() {
            clearHistory(since: Date().addingTimeInterval(-10 * 60), label: "des 10 dernières minutes")
        }

        @objc private func clearLastHour() {
            clearHistory(since: Date().addingTimeInterval(-60 * 60), label: "de la dernière heure")
        }

        @objc private func clearLastDay() {
            clearHistory(since: Date().addingTimeInterval(-24 * 60 * 60), label: "des dernières 24 heures")
        }

        @objc private func clearAllHistory() {
            guard
                confirmDestructiveAction(
                    title: "Effacer tout l’historique détaillé ?",
                    message:
                        "Les événements détaillés enregistrés sur ce Mac seront supprimés. Les sceaux cryptographiques sont conservés : les périodes concernées restent visibles, mais ne pourront plus être partagées qu’en mode privé."
                )
            else { return }

            onDeleteDetails(nil) { [weak self] result in
                switch result {
                case .success(let itemCount):
                    self?.showInformation(
                        title: "Historique détaillé effacé",
                        message: "\(itemCount) élément(s) détaillé(s) supprimé(s). Les sceaux existants sont conservés."
                    )
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }

        @objc private func quit() {
            onQuit()
        }

        private func clearHistory(since cutoff: Date, label: String) {
            guard
                confirmDestructiveAction(
                    title: "Effacer l’historique \(label) ?",
                    message:
                        "Les événements détaillés correspondants seront supprimés de ce Mac. Les sceaux cryptographiques sont conservés ; les périodes effacées apparaîtront comme privées."
                )
            else { return }

            onDeleteDetails(cutoff) { [weak self] result in
                switch result {
                case .success(let count):
                    self?.showInformation(
                        title: "Historique détaillé effacé",
                        message: "\(count) élément(s) détaillé(s) supprimé(s). Les sceaux existants sont conservés."
                    )
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }

        private func confirmDestructiveAction(title: String, message: String) -> Bool {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Effacer")
            alert.addButton(withTitle: "Annuler")
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func showInformation(title: String, message: String) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }

        private func showError(_ error: Error) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }
#endif
