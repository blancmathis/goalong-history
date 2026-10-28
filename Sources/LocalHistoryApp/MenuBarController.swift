#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore
    import SwiftUI

    final class MenuBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
        private let statusItem: NSStatusItem
        private let menu = NSMenu()
        private let popover = NSPopover()
        private var panelModel: MenuBarPanelModel?
        private var panelTimer: Timer?

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
        private let onReloadConfig: () -> Bool
        private let onRetryKeychain: () -> Void
        private let onQuit: () -> Void

        private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let permissionMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let globalPauseItem = NSMenuItem(title: "Confidentialité · tout suspendre…", action: #selector(toggleGlobalPause), keyEquivalent: "")
        private let pauseMenuItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")
        private let sealingSuspendedItem = NSMenuItem(title: "", action: #selector(retryKeychain), keyEquivalent: "")
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
            onReloadConfig: @escaping () -> Bool,
            onRetryKeychain: @escaping () -> Void,
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
            self.onRetryKeychain = onRetryKeychain
            self.onQuit = onQuit

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // Control Centre keeps a stale "blocked" record for the default key Item-0 that the
            // Menu Bar setting no longer reaches (2026-10-15): a fixed name gives the item a fresh key.
            statusItem.autosaveName = GoalongDevChannelMarks.autosaveName("goalong-menu")
            super.init()

            configureStatusItem()
            buildMenu()
            updateStatus()
            NotificationCenter.default.addObserver(
                forName: DeviceTrustState.didChange, object: nil, queue: .main
            ) { [weak self] _ in self?.updateStatus() }
        }

        func menuWillOpen(_ menu: NSMenu) {
            updateStatus()
        }

        @MainActor func configurePanel(model: MenuBarPanelModel) {
            closePanel()
            panelModel = model
            popover.behavior = .transient
            popover.delegate = self
            popover.animates = true
            let host = NSHostingController(rootView: MenuBarPanelView(model: model) { [weak self] height in
                self?.resizePanel(to: height)
            })
            // The panel drives the popover size itself (see resizePanel), so AppKit animates the
            // window frame instead of snapping it while SwiftUI animates the content.
            host.sizingOptions = []
            popover.contentViewController = host
        }

        @MainActor private func resizePanel(to height: CGFloat) {
            guard height > 0 else { return }
            let size = NSSize(width: MenuBarPanelView.width, height: ceil(height))
            guard popover.contentSize != size else { return }
            popover.contentSize = size
        }

        @MainActor func closePanel() {
            panelTimer?.invalidate(); panelTimer = nil
            panelModel?.stopRefreshing()
            popover.performClose(nil)
        }

        func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                panelTimer?.invalidate(); panelTimer = nil
                panelModel?.stopRefreshing()
            }
        }

        @MainActor func showClassicMenu() {
            closePanel()
            // Attach only during native menu tracking, leaving left clicks to the popover.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }

        @MainActor func togglePauseFromPanel() {
            closePanel()
            togglePause()
        }

        @objc private func statusItemClicked() {
            MainActor.assumeIsolated {
                let event = NSApplication.shared.currentEvent
                if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
                    showClassicMenu()
                    return
                }
                guard let model = panelModel, let button = statusItem.button else {
                    showClassicMenu()
                    return
                }
                if popover.isShown { closePanel(); return }
                model.refresh()
                if let host = popover.contentViewController as? NSHostingController<MenuBarPanelView> {
                    // With no sizing options, fittingSize is wrong; ask SwiftUI for the natural height.
                    // A zero proposal returns the fixed-size content height (the outer frame never shrinks it).
                    let ideal = host.sizeThatFits(in: NSSize(width: MenuBarPanelView.width, height: 0))
                    if ideal.height > 0 {
                        popover.contentSize = NSSize(width: MenuBarPanelView.width, height: ceil(ideal.height))
                    }
                }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.popover.isShown else { return }
                        self.panelModel?.refresh()
                    }
                }
                panelTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        static func statusDisplay(
            health: CaptureHealthState, localEnabled: Bool, globalPaused: Bool, recording: Bool, suppression: SuppressionReason?,
            configUnreadable: Bool = false
        ) -> (title: String, symbol: String, description: String) {
            let display: (title: String, symbol: String, description: String)
            if globalPaused {
                display = ("Arrêt de confidentialité", "pause.circle.fill", "Sources et envois suspendus")
            } else if configUnreadable {
                display = ("Réglages illisibles", "exclamationmark.triangle.fill", ConfigManager.failClosedNotice)
            } else if !localEnabled {
                display = ("Enregistrement désactivé", "circle.dashed", "Activez l’enregistrement dans Réglages pour remplir votre historique")
            } else if health == .storageUnavailable {
                display = ("Enregistrement interrompu", "externaldrive.badge.exclamationmark",
                           "L’historique ne peut pas être écrit (disque plein ?). Libérez de l’espace sur le Mac : la reprise est automatique.")
            } else if health == .permissionRequired
                || health == .permissionAppearsEnabledButStaleForBuild
                || health == .accessibilityContextUnavailable
            {
                display = ("Autorisation macOS à vérifier", "exclamationmark.triangle.fill",
                           "Ouvrez Goalong pour rétablir l’accès. Rien n’est enregistré en attendant.")
            } else if !recording {
                display = ("Enregistrement en pause", "pause.circle.fill", "\(ProductIdentity.displayName) est en pause")
            } else if let suppression, suppression == .accessibilityUnavailable {
                display = ("Navigateur non accessible", "exclamationmark.shield.fill",
                           "Cette fenêtre ne peut pas être lue en toute sécurité : aucun détail enregistré")
            } else if let suppression, suppression == .sessionUnavailable {
                display = ("Session Mac inactive", "lock.fill", "Le Mac est verrouillé, en veille ou indisponible")
            } else if health == .inputTapUnavailable {
                // A failed tap never recovers by waiting: say what to check, like the panel.
                display = (health.frenchTitle, "exclamationmark.triangle.fill", health.frenchDetail)
            } else if health == .awaitingInputEvidence {
                display = ("Interactions en attente", "waveform.path.ecg",
                           "Les clics et la frappe seront comptés dès le premier événement reçu.")
            } else {
                display = ("Enregistrement local actif", "record.circle.fill",
                           "Votre activité reste sur ce Mac")
            }
            return display
        }

        func updateStatus() {
            let permissionStatus = permissions.snapshot
            let recording = state.isCapturing
            let suppression = recording ? currentSuppression() : nil
            let health = captureHealth()

            let localEnabled = GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory)
            let display = Self.statusDisplay(
                health: health.state, localEnabled: localEnabled,
                globalPaused: GoalongGlobalPause.isPaused(), recording: recording, suppression: suppression,
                configUnreadable: configManager.isFailClosed)

            statusMenuItem.title = display.title
            statusMenuItem.image = NSImage(
                systemSymbolName: display.symbol,
                accessibilityDescription: display.description
            )
            statusMenuItem.toolTip = display.description
            permissionMenuItem.title = display.description
            technicalStatusItem.title =
                "Accessibilité : \(permissionStatus.accessibility ? "oui" : "non") · Surveillance de l’entrée : \(permissionStatus.inputMonitoringStatusLabel) · Interactions : \(eventTapStatus() ? "actives" : "inactives") · Preuve : \(health.captureProven ? "oui" : "non")"
            if let notice = DeviceTrustState.shared.sealingSuspendedNotice {
                sealingSuspendedItem.title = "\(notice) · Réessayer…"
                sealingSuspendedItem.toolTip = DeviceTrustState.shared.retryFeedback
                sealingSuspendedItem.isEnabled = !DeviceTrustState.shared.isRetryInFlight
                sealingSuspendedItem.isHidden = false
            } else {
                sealingSuspendedItem.isHidden = true
            }
            if let rotation = DeviceIdentityRotation.load() {
                technicalStatusItem.title += " · Identité changée le \(GoalongUIFormat.dayAbbreviated(rotation.at))"
            }
            globalPauseItem.title = GoalongGlobalPause.isPaused() ? GoalongGlobalPauseText.resume : "Confidentialité · tout suspendre…"
            pauseMenuItem.title = !localEnabled
                ? "Configurer l’enregistrement…"
                : (state.isManuallyPaused ? "Reprendre l’enregistrement local" : "Mettre l’enregistrement en pause…")
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

        /// A running Concentration session shows its phase and minutes next to the mark.
        func setFocusTitle(_ text: String?) {
            guard let button = statusItem.button else { return }
            if let text {
                statusItem.length = NSStatusItem.variableLength
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
                button.setAccessibilityValue("Concentration : \(text)")
            } else {
                statusItem.length = NSStatusItem.squareLength
                button.imagePosition = .imageOnly
                button.title = ""
                button.setAccessibilityValue(nil)
            }
        }

        private func configureStatusItem() {
            if let button = statusItem.button {
                button.image = GoalongBrandAssets.menuBarImage
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = ProductIdentity.displayName
                button.setAccessibilityLabel(ProductIdentity.displayName)
                button.target = self
                button.action = #selector(statusItemClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            MainActor.assumeIsolated { GoalongDevChannelMarks.badge(statusItem.button) }
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
            sealingSuspendedItem.target = self
            sealingSuspendedItem.isHidden = true
            menu.addItem(sealingSuspendedItem)
            menu.addItem(.separator())

            globalPauseItem.target = self
            pauseMenuItem.target = self
            let privacyMenu = NSMenu(title: "Confidentialité")
            privacyMenu.addItem(globalPauseItem)
            privacyMenu.addItem(pauseMenuItem)
            let privacyItem = NSMenuItem(title: "Confidentialité", action: nil, keyEquivalent: "")
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
            advanced.addItem(makeItem("Exporter un fichier signé…", action: #selector(openShare)))
            advanced.addItem(makeItem("Ouvrir le fichier d’activité du jour", action: #selector(openTodayFile)))
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
                NSApplication.shared.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = GoalongGlobalPauseText.failureTitle; alert.informativeText = GoalongUserFacingError.message(error)
                alert.runModal()
            }
        }

        private func confirmRecordingStop(allSources: Bool) -> Bool {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = allSources ? "Suspendre tout le suivi ?" : "Mettre l’enregistrement en pause ?"
            alert.informativeText = "Votre historique ne sera plus enregistré jusqu’à la reprise. Pour suspendre seulement les rappels de surveillance, utilisez plutôt « Faire une pause » : l’historique continue."
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: allSources ? "Suspendre le suivi" : "Mettre en pause")
            return alert.runModal() == .alertSecondButtonReturn
        }
        @objc private func retryKeychain() { onRetryKeychain() }

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
            guard onReloadConfig() else {
                showInformation(
                    title: "Configuration non rechargée",
                    message: configManager.statusNotice ?? ConfigManager.reloadFailedNotice
                )
                return
            }
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
                        "Les événements détaillés enregistrés sur ce Mac seront supprimés, ainsi que leurs analyses et mémoires, les appels, l’activité de développement, les notes du jour et les verdicts et corrections de « Mon travail ». Les sceaux cryptographiques sont conservés : les périodes concernées restent visibles, mais ne pourront plus être partagées qu’en mode privé."
                        + Self.commitmentWarning(since: nil)
                )
            else { return }

            onDeleteDetails(nil) { [weak self] result in
                switch result {
                case .success(let itemCount):
                    self?.showInformation(
                        title: "Historique détaillé effacé",
                        message: "\(Self.deletedItemsMessage(itemCount)) Les sceaux existants sont conservés."
                    )
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }

        static func deletedItemsMessage(_ count: Int) -> String {
            count > 1 ? "\(count) éléments détaillés supprimés." : "\(count) élément détaillé supprimé."
        }

        @objc private func quit() {
            onQuit()
        }

        private func clearHistory(since cutoff: Date, label: String) {
            guard
                confirmDestructiveAction(
                    title: "Effacer l’historique \(label) ?",
                    message:
                        "Les événements détaillés correspondants seront supprimés de ce Mac, ainsi que leurs analyses et mémoires, et les appels et l’activité de développement des jours concernés (journée entière). Les notes du jour sont conservées. Les sceaux cryptographiques sont conservés ; les périodes effacées apparaîtront comme privées."
                        + Self.commitmentWarning(since: cutoff)
                )
            else { return }

            onDeleteDetails(cutoff) { [weak self] result in
                switch result {
                case .success(let count):
                    self?.showInformation(
                        title: "Historique détaillé effacé",
                        message: "\(Self.deletedItemsMessage(count)) Les sceaux existants sont conservés."
                    )
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }

        /// An open Concentration commitment measured from this history: the clear can make it fail.
        /// Read from disk when Concentration is off (T-045 D-FR1).
        private static func commitmentWarning(since cutoff: Date?) -> String {
            MainActor.assumeIsolated {
                FocusCommitmentRules.historyClearWarning(GoalongWorkStore.openCommitments(controller: ConcentrationRuntime.shared.controller, store: .standard),
                                                         since: cutoff, at: Date()).map { "\n\n" + $0 } ?? ""
            }
        }

        static func destructiveConfirmationAlert(title: String, message: String) -> NSAlert {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            // « Annuler » comes first so Return can never erase. In the French app AppKit gives it Escape;
            // no button answers Return.
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Effacer").hasDestructiveAction = true
            return alert
        }

        private func confirmDestructiveAction(title: String, message: String) -> Bool {
            NSApplication.shared.activate(ignoringOtherApps: true)
            return Self.destructiveConfirmationAlert(title: title, message: message).runModal() == .alertSecondButtonReturn
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
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Échec de la suppression"
            alert.informativeText = GoalongUserFacingError.message(error)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
#endif
