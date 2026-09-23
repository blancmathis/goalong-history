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
            if GoalongGlobalPause.isPaused() {
                display = ("Arrêt de confidentialité", "pause.circle.fill", "Sources et envois suspendus")
            } else if health.state == .permissionRequired
                || health.state == .permissionAppearsEnabledButStaleForBuild
                || health.state == .accessibilityContextUnavailable
            {
                display = (
                    health.state.title, "exclamationmark.triangle.fill", health.detail
                )
            } else if !recording {
                display = ("Recording paused", "pause.circle.fill", "\(ProductIdentity.displayName) is paused")
            } else if let suppression, suppression == .accessibilityUnavailable {
                display = (
                    "Browser context unavailable", "exclamationmark.shield.fill",
                    "This browser context cannot be inspected safely"
                )
            } else if let suppression, suppression == .sessionUnavailable {
                display = (
                    "Mac session unavailable", "lock.fill",
                    "The Mac is locked, asleep or otherwise unavailable"
                )
            } else if health.state == .inputTapUnavailable || health.state == .awaitingInputEvidence {
                display = (health.state.title, "waveform.path.ecg", health.detail)
            } else {
                display = (
                    "Recording locally",
                    "record.circle.fill",
                    "Goalong is running. Monitoring and privacy rules are applied in the background."
                )
            }

            statusMenuItem.title = display.title
            statusMenuItem.image = NSImage(
                systemSymbolName: display.symbol,
                accessibilityDescription: display.description
            )
            statusMenuItem.toolTip = display.description
            permissionMenuItem.title =
                "Accessibility: \(permissionStatus.accessibility ? "on" : "off")  •  Direct input: \(permissionStatus.inputMonitoringStatusLabel)  •  Tap object: \(eventTapStatus() ? "on" : "off")  •  Evidence: \(health.captureProven ? "yes" : "no")"
            globalPauseItem.title = GoalongGlobalPause.isPaused() ? "Reprendre tout le suivi" : "Tout suspendre pour confidentialité…"
            pauseMenuItem.title = !GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory)
                ? "Set up Computer History…"
                : (state.isManuallyPaused ? "Reprendre l’enregistrement local" : "Arrêter l’enregistrement local…")

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
            let openItem = makeItem("Open \(ProductIdentity.displayName)", action: #selector(openDashboard), keyEquivalent: "o")
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
            menu.addItem(makeItem("Share signed day…", action: #selector(openShare)))
            menu.addItem(.separator())

            menu.addItem(makeItem("Open today's JSONL", action: #selector(openTodayFile)))
            menu.addItem(makeItem("Open data folder", action: #selector(openDataFolder)))
            menu.addItem(makeItem("Open configuration", action: #selector(openConfiguration)))

            let permissionsMenu = NSMenu(title: "Permissions")
            permissionsMenu.addItem(makeItem("Request required access", action: #selector(requestPermissions)))
            permissionsMenu.addItem(
                makeItem("Guided Accessibility setup", action: #selector(openAccessibilitySettings)))
            permissionsMenu.addItem(
                makeItem("Guided Input Monitoring setup", action: #selector(openInputMonitoringSettings)))
            let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
            permissionsItem.submenu = permissionsMenu
            menu.addItem(permissionsItem)

            let clearMenu = NSMenu(title: "Clear history")
            clearMenu.addItem(makeItem("Last 10 minutes…", action: #selector(clearLastTenMinutes)))
            clearMenu.addItem(makeItem("Last hour…", action: #selector(clearLastHour)))
            clearMenu.addItem(makeItem("Last day…", action: #selector(clearLastDay)))
            clearMenu.addItem(makeItem("All detailed history…", action: #selector(clearAllHistory)))
            let clearItem = NSMenuItem(title: "Clear detailed history", action: nil, keyEquivalent: "")
            clearItem.submenu = clearMenu
            menu.addItem(clearItem)

            menu.addItem(makeItem("Reload configuration", action: #selector(reloadConfiguration)))
            menu.addItem(makeItem("Open diagnostics", action: #selector(openDiagnostics)))
            menu.addItem(.separator())
            menu.addItem(makeItem("Quit \(ProductIdentity.displayName)", action: #selector(quit), keyEquivalent: "q"))
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
            alert.informativeText = "Votre historique ne sera plus enregistré jusqu’à la reprise. Pour une pause détente, utilisez Pause Jev : l’historique continue."
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
            if !FileManager.default.fileExists(atPath: AppPaths.diagnosticsFile.path) {
                FileManager.default.createFile(
                    atPath: AppPaths.diagnosticsFile.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            }
            GoalongWorkspaceOpenPolicy.open(AppPaths.diagnosticsFile, purpose: .localFile)
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
                title: "Configuration reloaded",
                message: "\(ProductIdentity.displayName) reloaded config.json and refreshed verification settings."
            )
        }

        @objc private func clearLastTenMinutes() {
            clearHistory(since: Date().addingTimeInterval(-10 * 60), label: "last 10 minutes")
        }

        @objc private func clearLastHour() {
            clearHistory(since: Date().addingTimeInterval(-60 * 60), label: "last hour")
        }

        @objc private func clearLastDay() {
            clearHistory(since: Date().addingTimeInterval(-24 * 60 * 60), label: "last day")
        }

        @objc private func clearAllHistory() {
            guard
                confirmDestructiveAction(
                    title: "Delete all detailed \(ProductIdentity.displayName) events?",
                    message:
                        "This removes detailed local JSONL events. Cryptographic minute seals and server receipts are kept, so anchored periods remain visible but can only be shared as private when their details are gone."
                )
            else { return }

            onDeleteDetails(nil) { [weak self] result in
                switch result {
                case .success(let itemCount):
                    self?.showInformation(
                        title: "Detailed history deleted",
                        message: "Deleted \(itemCount) detailed event or semantic item(s). Existing seals and receipts remain."
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
                    title: "Delete the \(label)?",
                    message:
                        "Matching detailed events will be removed locally. Existing cryptographic seals are kept; deleted intervals cannot later be revealed and will fall back to private."
                )
            else { return }

            onDeleteDetails(cutoff) { [weak self] result in
                switch result {
                case .success(let count):
                    self?.showInformation(
                        title: "Detailed history deleted",
                        message: "Deleted \(count) detailed event or semantic item(s) from the \(label). Existing seals remain."
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
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
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
