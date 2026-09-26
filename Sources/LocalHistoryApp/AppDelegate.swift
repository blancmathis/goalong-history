#if os(macOS)
    import AgentActivity
    import AppKit
    import Carbon
    import AppleSystemScreenTime
    import Foundation
    import LocalHistoryCore
    import LocalHistoryQueryCLI

    struct DailyMaintenanceGate {
        private let calendar: Calendar
        private var lastRunDay: Date?

        init(calendar: Calendar = .current) {
            self.calendar = calendar
        }

        mutating func admit(now: Date = Date()) -> Bool {
            let day = calendar.startOfDay(for: now)
            guard lastRunDay != day else { return false }
            lastRunDay = day
            return true
        }
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        @MainActor private lazy var websitePairing = GoalongWebsitePairingCoordinator()
        @MainActor private var pendingWebsiteURL: URL?
        @MainActor private var activeWebsiteURL: URL?
        @MainActor private var websitePairingTask: Task<Void, Never>?

        func application(_ application: NSApplication, open urls: [URL]) {
            guard urls.count == 1, let url = urls.first, url.scheme == "goalong-history" else { return }
            Task { @MainActor in
                // Reopening the same link brings its existing confirmation forward.
                // A newer link replaces an unanswered prompt, never an in-flight send.
                if activeWebsiteURL != url { pendingWebsiteURL = url }
                presentWebsitePairingIfReady()
            }
        }

        @MainActor private func presentWebsitePairingIfReady() {
            guard pendingWebsiteURL != nil || activeWebsiteURL != nil,
                  let controller = dashboardWindowController else { return }
            controller.showForWebsitePairing()
            guard websitePairingTask == nil else {
                if pendingWebsiteURL != nil { websitePairing.cancelPendingPrompt() }
                return
            }
            websitePairingTask = Task { @MainActor in
                defer { activeWebsiteURL = nil; websitePairingTask = nil }
                while let url = pendingWebsiteURL {
                    pendingWebsiteURL = nil
                    activeWebsiteURL = url
                    guard let window = controller.window else { return }
                    let connected = await websitePairing.connect(url: url, window: window)
                    if connected && pendingWebsiteURL == nil {
                        UserDefaults.standard.set(true, forKey: "goalong.website.openAfterPairing")
                        controller.show(section: .settings)
                        self.dashboardViewModel.settingsPane = .website
                        NotificationCenter.default.post(name: .goalongWebsiteConnected, object: nil)
                    }
                }
            }
        }
        private var configManager: ConfigManager!
        private var permissions: PermissionManager!
        private var captureHealthStore: CaptureHealthStore!
        private var semanticContextStore: SemanticContextStore!
        private var memoryStore: LocalActivityMemoryStore!
        private var retentionStore: HistoryRetentionStore!
        private var retentionPolicyObserver: NSObjectProtocol?
        private var captureState: CaptureState!
        private var store: JSONLStore!
        private var integrityStateStore: IntegrityStateStore!
        private var deviceIdentity: DeviceIdentity!
        private var integrityJournal: IntegrityJournal!
        private var minuteSealer: MinuteSealer!
        private var recorder: EventRecorder!
        private var contextProvider: ContextProvider!
        private var contextMonitor: ContextMonitor!
        private var eventTapMonitor: EventTapMonitor!
        private var dashboardViewModel: DashboardViewModel!
        private var sharingRulesStore: SharingRulesStore!
        private var agentActivityRuntime: AgentActivityRuntime!
        private var screenTimeRepository: AppleSystemScreenTimeRepository?
        private var screenTimeArchiveTimer: Timer?
        private var screenTimeArchiveRefreshInFlight = false
        private var readOnlyQueryServer: GoalongReadOnlyQueryServer?
        private var dashboardWindowController: DashboardWindowController!
        private var applicationMenuController: ApplicationMenuController!
        private var menuBarController: MenuBarController!
        private var capabilityConsents: GoalongCapabilityConsentStore!

        private var permissionTimer: Timer?
        private var lastPermissionStatus: PermissionStatus?
        private var lastRecordedHealthState: CaptureHealthState?
        private var workspaceObservers: [NSObjectProtocol] = []
        private var screenLockObservers: [NSObjectProtocol] = []
        private var capabilityConsentObserver: NSObjectProtocol?
        private var globalPauseObserver: NSObjectProtocol?
        private var resumingGlobalPause = false
        private var retentionCleanupGate = DailyMaintenanceGate()
        private var localCaptureRuntimeActive = false

        private var runtimeStarted = false
        private var userQuitConfirmed = false
        private var quitAlertIsVisible = false
        private let continuityPreferences = BackgroundContinuityPreferences()

        private var hasEnabledBackgroundSources: Bool {
            guard let capabilityConsents else { return false }
            return [GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations].contains {
                capabilityConsents.isEnabled($0)
            }
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            PermissionRecovery.launchWhenParentHasExited { [weak self] in self?.startApplication() }
        }

        @MainActor private func startApplication() {
            guard !anotherInstanceIsRunning() else {
                NSApplication.shared.terminate(nil)
                return
            }

            runtimeStarted = true
            SupportDiagnostics.shared.start()
            LegacyInstallationMigrator.run()
            NSApplication.shared.setActivationPolicy(.accessory)
            GoalongWebsiteAutoSender.shared.start()
            SoftwareUpdateManager.shared.start()

            do {
                try AppPaths.prepare()
                let retentionDirectories = ComputerHistoryStore.retentionDirectories(
                    rootDirectory: AppPaths.applicationSupportDirectory
                )
                let scavengingReport = AbandonedTemporaryScavenger(
                    rootDirectory: AppPaths.applicationSupportDirectory,
                    codexMemoryDirectory: retentionDirectories.last
                ).scavenge()
                if scavengingReport.deletedFiles > 0 {
                    Diagnostics.write(
                        "Recovered abandoned temporary files: "
                            + "count=\(scavengingReport.deletedFiles) "
                            + "bytes=\(scavengingReport.deletedBytes)"
                    )
                }
                for diagnostic in scavengingReport.diagnostics {
                    Diagnostics.write(diagnostic)
                }
                configManager = ConfigManager()
                capabilityConsents = GoalongCapabilityConsentStore.shared
                permissions = PermissionManager()
                captureHealthStore = CaptureHealthStore(permissions: permissions)
                semanticContextStore = SemanticContextStore()
                memoryStore = LocalActivityMemoryStore()
                retentionStore = HistoryRetentionStore(
                    legacyRetentionDays: configManager.config.retentionDays
                )
                captureState = CaptureState()
                store = try JSONLStore(retentionDays: configManager.config.retentionDays)
                integrityStateStore = IntegrityStateStore()
                deviceIdentity = try DeviceIdentity()
                screenTimeRepository = try GoalongScreenTimeRepositoryProvider.repository(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: deviceIdentity.info.deviceID
                )
                integrityJournal = IntegrityJournal(stateStore: integrityStateStore)
                minuteSealer = MinuteSealer(stateStore: integrityStateStore, identity: deviceIdentity)
                minuteSealer.setUploader(nil)
                recorder = EventRecorder(
                    store: store,
                    integrityJournal: integrityJournal,
                    minuteSealer: minuteSealer,
                    captureHealth: captureHealthStore
                )
                contextProvider = ContextProvider(configManager: configManager, permissions: permissions)
                contextMonitor = ContextMonitor(
                    provider: contextProvider,
                    recorder: recorder,
                    state: captureState,
                    configManager: configManager,
                    permissions: permissions,
                    captureHealth: captureHealthStore,
                    semanticContextStore: semanticContextStore,
                    memoryStore: memoryStore
                )
                eventTapMonitor = EventTapMonitor(
                    recorder: recorder,
                    contextMonitor: contextMonitor,
                    contextProvider: contextProvider,
                    state: captureState,
                    configManager: configManager,
                    captureHealth: captureHealthStore
                )
                sharingRulesStore = SharingRulesStore()
                let executableURL =
                    Bundle.main.executableURL
                    ?? URL(
                        fileURLWithPath: CommandLine.arguments.first
                            ?? "/Applications/Goalong History.app/Contents/MacOS/Goalong History")
                agentActivityRuntime = try AgentActivityRuntime(
                    rootDirectory: AppPaths.agentActivityDirectory,
                    executableURL: executableURL,
                    performInitialDiscovery: capabilityConsents.isEnabled(.aiConversations) && !GoalongGlobalPause.isPaused(),
                    onCaptured: { _ in }
                )

                dashboardViewModel = DashboardViewModel(
                    state: captureState,
                    permissions: permissions,
                    configManager: configManager,
                    sharingRulesStore: sharingRulesStore,
                    agentActivityRuntime: agentActivityRuntime,
                    deviceInfo: deviceIdentity.info,
                    eventTapStatus: { [weak self] in self?.eventTapMonitor.isRunning ?? false },
                    currentSuppression: { [weak self] in self?.contextMonitor.latestSnapshot?.suppressionReason },
                    captureHealthSnapshot: { [unowned self] in self.captureHealthStore.snapshot },
                    onBeginCaptureValidation: { [weak self] in
                        self?.captureHealthStore.beginControlledInputValidation()
                    },
                    onTogglePause: { [weak self] in self?.toggleManualPause() },
                    onRequestPermissions: { [weak self] in self?.requestPermissionsAndExplain() },
                    onSaveConfiguration: { [weak self] config in
                        guard let self else { return config }
                        return try self.applyConfiguration(config)
                    },
                    onDeleteDetails: { [weak self] cutoff, completion in
                        self?.deleteDetails(since: cutoff, completion: completion)
                    },
                    onDeleteTargetedDetails: { [weak self] request, completion in
                        self?.deleteTargetedDetails(request, completion: completion)
                    }
                )
                dashboardWindowController = DashboardWindowController(viewModel: dashboardViewModel)

                applicationMenuController = ApplicationMenuController(
                    onOpenSettings: { [weak self] in
                        self?.dashboardWindowController.show(section: .settings)
                    },
                    onCheckForUpdates: {
                        SoftwareUpdateManager.shared.checkForUpdates()
                    },
                    canCheckForUpdates: {
                        SoftwareUpdateManager.shared.canCheckForUpdates
                    },
                    onQuit: { [weak self] in self?.requestUserQuit() }
                )
                applicationMenuController.install(in: NSApplication.shared)

                menuBarController = MenuBarController(
                    state: captureState,
                    permissions: permissions,
                    store: store,
                    recorder: recorder,
                    configManager: configManager,
                    eventTapStatus: { [weak self] in self?.eventTapMonitor.isRunning ?? false },
                    currentSuppression: { [weak self] in self?.contextMonitor.latestSnapshot?.suppressionReason },
                    captureHealth: { [unowned self] in self.captureHealthStore.assessment },
                    onDeleteDetails: { [weak self] cutoff, completion in
                        self?.deleteDetails(since: cutoff, completion: completion)
                    },
                    onOpenDashboard: { [weak self] in self?.dashboardWindowController.show(section: .overview) },
                    onOpenMonitoring: { [weak self] in self?.dashboardWindowController.show(section: .monitoring) },
                    onOpenShare: { [weak self] in self?.dashboardWindowController.show(section: .share) },
                    onTogglePause: { [weak self] in self?.toggleManualPause() },
                    onRequestPermissions: { [weak self] in self?.requestPermissionsAndExplain() },
                    onReloadConfig: { [weak self] in self?.reloadConfiguration() },
                    onQuit: { [weak self] in self?.requestUserQuit() }
                )
            } catch {
                SupportDiagnostics.shared.failure(error, component: .app)
                presentFatalError(error)
                return
            }

            SupportDiagnosticsRuntime.shared.start { [weak self] in self?.supportSnapshot() ?? [:] }
            applyDailyRetentionCleanupIfNeeded()
            applyCapabilityConsents(recordTransition: false)
            BackgroundContinuityController.shared.start(hasEnabledSources: hasEnabledBackgroundSources)
            ChatGPTRecapRuntime.shared.configure(deviceID: deviceIdentity.info.deviceID)
            installCapabilityConsentObserver()
            retentionPolicyObserver = NotificationCenter.default.addObserver(
                forName: .goalongRetentionPolicyDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.retentionStore = HistoryRetentionStore(legacyRetentionDays: self.configManager.config.retentionDays)
                self.retentionStore.applyCleanupAfterDrainingDerivedWriters { [weak self] in
                    self?.dashboardViewModel.refreshEverything()
                }
            }

            installWorkspaceObservers()
            showDashboardOnFirstConsentLaunch()
            if PermissionRecovery.consumeSetupReturn() || CommandLine.arguments.contains(PermissionRecovery.parentArgument) {
                dashboardWindowController?.show(section: .settings)
            } else if CommandLine.arguments.contains(PermissionRecovery.completedArgument) || UserDefaults.standard.double(forKey: "goalong.restoreVisibleUntil") > Date().timeIntervalSince1970 {
                UserDefaults.standard.removeObject(forKey: "goalong.restoreVisibleUntil")
                let previousSection = UserDefaults.standard.string(forKey: "goalong.restoreVisibleSection")
                    .flatMap(DashboardSection.init(rawValue:)) ?? dashboardViewModel.selectedSection
                dashboardWindowController?.show(section: previousSection)
            }
            // A URL can arrive before the dashboard exists on a cold launch.
            Task { @MainActor in presentWebsitePairingIfReady() }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            !continuityPreferences.keepRunning
        }

        private func requestUserQuit() {
            guard confirmUserQuitIfNeeded() else { return }
            userQuitConfirmed = true
            NSApplication.shared.terminate(nil)
        }

        private func confirmUserQuitIfNeeded() -> Bool {
            guard !userQuitConfirmed,
                  BackgroundContinuityPreferences.shouldConfirmQuit(
                    keepRunning: continuityPreferences.keepRunning,
                    hasEnabledSources: hasEnabledBackgroundSources
                  ) else { return true }
            guard !quitAlertIsVisible else { return false }
            quitAlertIsVisible = true
            defer { quitAlertIsVisible = false }
            let alert = NSAlert()
            alert.messageText = "Quit Goalong and stop recording?"
            alert.informativeText = "Your enabled sources will stop until you reopen Goalong or its next enabled login. Close the window instead to keep recording in the background. Activity while Goalong is closed cannot be recovered."
            alert.addButton(withTitle: "Keep running")
            alert.addButton(withTitle: "Quit and stop recording")
            NSApplication.shared.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertSecondButtonReturn
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let senderPID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            let senderID = senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            // Our menu and Command-Q use requestUserQuit(). Cover a direct Dock Quit
            // as well, but never intercept logout/shutdown, installers, or a restart.
            if senderID == "com.apple.dock", !PermissionRecovery.isRestarting,
               !SoftwareUpdateManager.shared.isRelaunchingForUpdate {
                guard confirmUserQuitIfNeeded() else { return .terminateCancel }
                userQuitConfirmed = true
            }
            guard event?.eventClass == AEEventClass(kCoreEventClass), event?.eventID == AEEventID(kAEQuitApplication),
                  PermissionRecovery.shouldAssistSettingsQuit(senderBundleID: senderID,
                    pendingSetup: PermissionRecovery.pendingSetup() != nil, alreadyRestarting: PermissionRecovery.isRestarting) else {
                return .terminateNow
            }
            // Assist only a fresh permission-session quit sent by Apple's System Settings.
            // Ordinary Quit, shutdown, logout and updater quits never arm this path.
            PermissionRecovery.prepareRelaunch { error in
                if let error { Diagnostics.write("Permission relaunch preparation failed: \(error)") }
                sender.reply(toApplicationShouldTerminate: error == nil)
            }
            return .terminateLater
        }

        func applicationWillTerminate(_ notification: Notification) {
            guard runtimeStarted else { return }
            if dashboardWindowController?.window?.isVisible == true {
                UserDefaults.standard.set(Date().addingTimeInterval(90).timeIntervalSince1970, forKey: "goalong.restoreVisibleUntil")
                UserDefaults.standard.set(dashboardViewModel.selectedSection.rawValue, forKey: "goalong.restoreVisibleSection")
            }
            SoftwareUpdateManager.shared.stop()
            permissionTimer?.invalidate()
            screenTimeArchiveTimer?.invalidate()
            screenTimeArchiveTimer = nil
            if let capabilityConsentObserver {
                NotificationCenter.default.removeObserver(capabilityConsentObserver)
            }
            capabilityConsentObserver = nil
            if let globalPauseObserver { NotificationCenter.default.removeObserver(globalPauseObserver) }
            globalPauseObserver = nil
            if let retentionPolicyObserver { NotificationCenter.default.removeObserver(retentionPolicyObserver) }
            retentionPolicyObserver = nil
            readOnlyQueryServer?.stop()
            readOnlyQueryServer = nil
            agentActivityRuntime?.stop()
            if GoalongBuildCapabilities.permitsRemoteAnalysis {
                ChatGPTRecapRuntime.shared.stop()
            }
            contextMonitor?.stop()
            eventTapMonitor?.stop()
            if capabilityConsents?.isEnabled(.localComputerHistory) == true {
                recorder?.record(kind: .recorderStopped, message: "Goalong History stopped")
            }
            recorder?.flush()
            captureHealthStore?.flush()
            if capabilityConsents?.isEnabled(.localComputerHistory) == true {
                minuteSealer?.stopAndSeal()
            }
            recorder?.close()
            let reason = SoftwareUpdateManager.shared.isRelaunchingForUpdate ? "update"
                : PermissionRecovery.isRestarting ? "permission_restart"
                : userQuitConfirmed ? "user_quit" : "system_or_application_exit"
            BackgroundContinuityController.shared.stop(reason: reason)

            let center = NSWorkspace.shared.notificationCenter
            for observer in workspaceObservers {
                center.removeObserver(observer)
            }
            workspaceObservers.removeAll()
            for observer in screenLockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
            screenLockObservers.removeAll()
            SupportDiagnosticsRuntime.shared.stop()
        }

        func applicationShouldHandleReopen(
            _ sender: NSApplication,
            hasVisibleWindows flag: Bool
        ) -> Bool {
            dashboardWindowController?.show(section: dashboardViewModel?.selectedSection ?? .overview)
            return false
        }

        private func toggleManualPause() {
            guard !GoalongGlobalPause.isPaused() else { dashboardWindowController.show(section: .settings); return }
            if !capabilityConsents.isEnabled(.localComputerHistory) {
                // A menu action must not broaden capture or bypass the guided source choice.
                dashboardWindowController.show(section: .settings)
                return
            }
            if captureState.isManuallyPaused {
                continuityPreferences.manuallyPaused = false
                captureState.setManualPaused(false)
                captureHealthStore.setPaused(false)
                minuteSealer.start()
                recorder.record(
                    kind: .recordingResumed, message: "Recording resumed from the Goalong History interface")
                contextMonitor.resetAndSample()
            } else {
                recorder.record(kind: .recordingPaused, message: "Recording paused from the Goalong History interface")
                recorder.flush()
                continuityPreferences.manuallyPaused = true
                captureState.setManualPaused(true)
                captureHealthStore.setPaused(true)
                _ = minuteSealer.stopAndSeal()
            }
            menuBarController.updateStatus()
        }

        private func applyConfiguration(_ config: RecorderConfig) throws -> RecorderConfig {
            let applied = try configManager.save(config)
            // Retention is an independent, explicitly confirmed policy. Saving a
            // recording switch must never authorize deletion of existing history.
            contextMonitor.resetAndSample()
            configureUploader(for: applied)
            menuBarController.updateStatus()
            return applied
        }

        private func reloadConfiguration() {
            configManager.reload()
            contextMonitor.resetAndSample()
            configureUploader(for: configManager.config)
        }

        private func configureUploader(for config: RecorderConfig) {
            _ = config
            minuteSealer.setUploader(nil)
        }

        private func deleteDetails(
            since cutoff: Date?,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            let barrier = DerivedHistoryWriteBarrier.shared
            let suspension = barrier.suspend()
            ActivityAnalysisRuntime.shared.prepareForHistoryClear()
            ChatGPTRecapRuntime.shared.prepareForHistoryClear()
            barrier.notifyWhenDrained(suspension) { [self] in
                deleteDetailsAfterDerivedWritersDrain(
                    since: cutoff,
                    suspension: suspension,
                    completion: completion
                )
            }
        }

        private func deleteTargetedDetails(
            _ request: TargetedHistoryDeletionRequest,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            let barrier = DerivedHistoryWriteBarrier.shared
            let suspension = barrier.suspend()
            ActivityAnalysisRuntime.shared.prepareForHistoryClear()
            ChatGPTRecapRuntime.shared.prepareForHistoryClear()
            barrier.notifyWhenDrained(suspension) { [self] in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let selection = try TargetedHistoryDeletionResolver().resolve(request)
                        try semanticContextStore.preflightSnapshotDeletion(
                            withIDs: selection.semanticSnapshotIDs,
                            on: selection.semanticDays
                        )
                        let derivedPlan = try DerivedHistoryCleaner().prepareDeletion(
                            days: selection.affectedDays
                        )
                        deleteTargetedDetailsAfterPreflight(
                            selection: selection,
                            derivedPlan: derivedPlan,
                            suspension: suspension,
                            completion: completion
                        )
                    } catch {
                        DispatchQueue.main.async { [self] in
                            completeHistoryClear(
                                .failure(error),
                                suspension: suspension,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }

        private func deleteTargetedDetailsAfterPreflight(
            selection: TargetedHistoryDeletionSelection,
            derivedPlan: DerivedHistoryDeletionPlan,
            suspension: DerivedHistoryWriteBarrier.Suspension,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            store.deleteEvents(
                withIDs: selection.eventIDs,
                from: selection.start,
                through: selection.end
            ) { [self] rawResult in
                switch rawResult {
                case .failure(let error):
                    completeHistoryClear(
                        .failure(error),
                        suspension: suspension,
                        completion: completion
                    )
                case .success(let raw):
                    guard raw.eventCount >= selection.eventIDs.count else {
                        completeHistoryClear(
                            .failure(TargetedHistoryDeletionError.sourceChangedDuringCommit),
                            suspension: suspension,
                            completion: completion
                        )
                        return
                    }
                    let semanticIDs = selection.semanticSnapshotIDs.union(
                        raw.semanticSnapshotIDs
                    )
                    semanticContextStore.deleteSnapshots(
                        withIDs: semanticIDs,
                        on: selection.semanticDays
                    ) { [self] semanticResult in
                        switch semanticResult {
                        case .failure(let error):
                            completeHistoryClear(
                                .failure(error),
                                suspension: suspension,
                                completion: completion
                            )
                        case .success(let semanticCount):
                            finishTargetedHistoryDeletion(
                                rawCount: raw.eventCount,
                                semanticCount: semanticCount,
                                derivedPlan: derivedPlan,
                                suspension: suspension,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }

        private func finishTargetedHistoryDeletion(
            rawCount: Int,
            semanticCount: Int,
            derivedPlan: DerivedHistoryDeletionPlan,
            suspension: DerivedHistoryWriteBarrier.Suspension,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            do {
                let derived = try derivedPlan.execute()
                recorder.record(
                    kind: .historyCleared,
                    message:
                        "Selected local activity, semantic snapshots, and derived memories deleted",
                    metadata: [
                        "scope": "targeted_item",
                        "deleted_events": String(rawCount),
                        "deleted_semantic_snapshots": String(semanticCount),
                        "deleted_activity_analysis_files": String(derived.activityAnalysisFiles),
                        "deleted_activity_memory_files": String(derived.activityMemoryFiles),
                        "deleted_computer_history_files": String(derived.computerHistoryFiles),
                    ]
                )
                completeHistoryClear(
                    .success(rawCount + semanticCount + derived.total),
                    suspension: suspension,
                    completion: completion
                )
            } catch {
                completeHistoryClear(
                    .failure(error),
                    suspension: suspension,
                    completion: completion
                )
            }
        }

        private func deleteDetailsAfterDerivedWritersDrain(
            since cutoff: Date?,
            suspension: DerivedHistoryWriteBarrier.Suspension,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            let derivedPlan: DerivedHistoryDeletionPlan
            do {
                // Preflight every derived target before the irreversible raw and
                // semantic deletions begin. The write barrier remains suspended while
                // the resulting plan is held and later executed.
                derivedPlan = try DerivedHistoryCleaner().prepareDeletion(since: cutoff)
            } catch {
                // No source or derived file has been modified yet. Resume without
                // invalidating caches or starting a forced rewrite against the unsafe
                // target that caused preflight to fail.
                DerivedHistoryWriteBarrier.shared.resume(suspension)
                completion(.failure(error))
                return
            }

            if let cutoff {
                store.deleteEvents(since: cutoff) { [self] rawResult in
                    switch rawResult {
                    case .failure(let error):
                        completeHistoryClear(
                            .failure(error),
                            suspension: suspension,
                            completion: completion
                        )
                    case .success(let rawCount):
                        semanticContextStore.deleteEvents(since: cutoff) { [self] semanticResult in
                            switch semanticResult {
                            case .failure(let error):
                                completeHistoryClear(
                                    .failure(error),
                                    suspension: suspension,
                                    completion: completion
                                )
                            case .success(let semanticCount):
                                finishHistoryDeletion(
                                    rawCount: rawCount,
                                    semanticCount: semanticCount,
                                    since: cutoff,
                                    derivedPlan: derivedPlan,
                                    suspension: suspension,
                                    completion: completion
                                )
                            }
                        }
                    }
                }
            } else {
                store.deleteAll { [self] rawResult in
                    switch rawResult {
                    case .failure(let error):
                        completeHistoryClear(
                            .failure(error),
                            suspension: suspension,
                            completion: completion
                        )
                    case .success(let rawCount):
                        semanticContextStore.deleteAll { [self] semanticResult in
                            switch semanticResult {
                            case .failure(let error):
                                completeHistoryClear(
                                    .failure(error),
                                    suspension: suspension,
                                    completion: completion
                                )
                            case .success(let semanticCount):
                                finishHistoryDeletion(
                                    rawCount: rawCount,
                                    semanticCount: semanticCount,
                                    since: nil,
                                    derivedPlan: derivedPlan,
                                    suspension: suspension,
                                    completion: completion
                                )
                            }
                        }
                    }
                }
            }
        }

        private func finishHistoryDeletion(
            rawCount: Int,
            semanticCount: Int,
            since cutoff: Date?,
            derivedPlan: DerivedHistoryDeletionPlan,
            suspension: DerivedHistoryWriteBarrier.Suspension,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            do {
                let derived = try derivedPlan.execute()
                recorder.record(
                    kind: .historyCleared,
                    message: cutoff == nil
                        ? "All detailed local activity, semantic snapshots, and derived memories deleted"
                        : "Detailed local activity, semantic snapshots, and derived memories deleted",
                    metadata: [
                        "deleted_events": String(rawCount),
                        "deleted_semantic_snapshots": String(semanticCount),
                        "deleted_activity_analysis_files": String(derived.activityAnalysisFiles),
                        "deleted_activity_memory_files": String(derived.activityMemoryFiles),
                        "deleted_computer_history_files": String(derived.computerHistoryFiles),
                    ]
                )
                completeHistoryClear(
                    .success(rawCount + semanticCount + derived.total),
                    suspension: suspension,
                    completion: completion
                )
            } catch {
                completeHistoryClear(
                    .failure(error),
                    suspension: suspension,
                    completion: completion
                )
            }
        }

        private func completeHistoryClear(
            _ result: Result<Int, Error>,
            suspension: DerivedHistoryWriteBarrier.Suspension,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            var completedResult = result
            do {
                try ActivityAnalysisRuntime.shared.invalidateRevisionCacheForHistoryClear()
            } catch {
                switch result {
                case .success:
                    completedResult = .failure(error)
                case .failure:
                    Diagnostics.write(
                        "Could not invalidate activity-analysis revisions after a failed history clear: \(error)"
                    )
                }
            }

            DerivedHistoryWriteBarrier.shared.resume(suspension)
            ActivityAnalysisRuntime.shared.refreshAfterHistoryClear()
            completion(completedResult)
        }

        private func requestPermissionsAndExplain() {
            permissions.requestAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.checkPermissionsAndStartTap(forceRefresh: true)
                let status = self.permissions.snapshot
                if !status.accessibility {
                    self.permissions.openAccessibilitySettings()
                } else if !status.inputMonitoring {
                    self.permissions.openInputMonitoringSettings()
                }
            }
        }

        private func showDashboardOnFirstConsentLaunch() {
            guard dashboardViewModel.showWelcome else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                self?.dashboardWindowController.show(section: .overview)
            }
        }

        private func supportSnapshot() -> [SupportKey: SupportValue] {
            guard let permissions, let health = captureHealthStore?.snapshot else { return [:] }
            let status = permissions.snapshot
            var values: [SupportKey: SupportValue] = [
                .accessibilityPreflight: .flag(status.accessibilityPreflight),
                .accessibilityFunctional: .flag(status.accessibilityFunctionalProbe),
                .accessibilityCrossProcess: .flag(status.accessibilityCrossProcessProbe),
                .inputPreflight: .flag(status.inputMonitoringDirectlyGranted),
                .tapRunning: .flag(eventTapMonitor?.isRunning ?? false),
                .callbackObserved: .flag(health.inputCallbackObservedThisLaunch == true),
                .permissionIdentityChanged: .flag(health.lastKnownWorkingBuild.map { !$0.hasSamePermissionIdentity(as: health.build) } ?? false),
                .state: .state(SupportState(rawValue: CaptureHealthEvaluator.assess(health).state.rawValue) ?? .unknown),
                .paused: .flag(health.isManuallyPaused),
                .globalPause: .flag(GoalongGlobalPause.isPaused()),
                .localSource: .flag(capabilityConsents?.isEnabled(.localComputerHistory) ?? false),
                .appleSource: .flag(capabilityConsents?.isEnabled(.appleScreenTime) ?? false),
                .conversationSource: .flag(capabilityConsents?.isEnabled(.aiConversations) ?? false)
            ]
            if let error = status.accessibilityProbeError { values[.axError] = .count(Int(error)) }
            if let metrics = eventTapMonitor?.ingressMetrics {
                values[.pendingEvents] = .count(metrics.currentDepth)
                values[.droppedEvents] = .count(metrics.droppedCount)
            }
            if !GoalongGlobalPause.isPaused() {
                values[.inputCount] = .count(health.recentCounters.inputEventCount)
                if let date = health.lastAXContextSuccessAt { values[.axSuccessAgeSeconds] = .number(max(0, Date().timeIntervalSince(date))) }
                if let date = health.lastInputEventAt { values[.callbackAgeSeconds] = .number(max(0, Date().timeIntervalSince(date))) }
            }
            return values
        }

        private func schedulePermissionWatchdog() {
            permissionTimer?.invalidate()
            let interval = PermissionWatchdogPolicy.interval(
                status: permissions.snapshot,
                eventTapRunning: eventTapMonitor.isRunning
            )
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                self?.checkPermissionsAndStartTap(forceRefresh: true)
            }
            timer.tolerance = interval >= PermissionWatchdogPolicy.healthyInterval ? 6 : 0.3
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }

        private func checkPermissionsAndStartTap(forceRefresh: Bool = false) {
            guard capabilityConsents.isEnabled(.localComputerHistory), !GoalongGlobalPause.isPaused() else {
                permissionTimer?.invalidate()
                permissionTimer = nil
                eventTapMonitor.stop()
                contextMonitor.stop()
                captureState.setManualPaused(true)
                captureHealthStore.setPaused(true)
                menuBarController.updateStatus()
                return
            }
            applyDailyRetentionCleanupIfNeeded()
            let status =
                forceRefresh
                ? permissions.refresh(force: true)
                : permissions.snapshot
            captureHealthStore.updatePermissions(status)

            if status != lastPermissionStatus {
                recorder.record(
                    kind: .permissionStatus,
                    message: "macOS permission status changed",
                    metadata: [
                        "accessibility": String(status.accessibility),
                        "input_monitoring": String(status.inputMonitoring),
                        "accessibility_preflight": String(status.accessibilityPreflight),
                        "accessibility_functional": String(status.accessibilityFunctionalProbe),
                        "input_monitoring_preflight": String(status.inputMonitoringDirectlyGranted),
                    ]
                )
                if status.accessibility {
                    contextMonitor.resetAndSample()
                }
                lastPermissionStatus = status
            }

            if continuityPreferences.keepRunning && captureState.isCapturing {
                contextMonitor.ensureRunning()
            }
            if status.canAttemptInputTap, !eventTapMonitor.isRunning, captureState.isCapturing {
                _ = eventTapMonitor.start()
            } else if !status.canAttemptInputTap,
                eventTapMonitor.isRunning || eventTapMonitor.hasPendingUnexpectedRestart
            {
                eventTapMonitor.stop()
            }

            let assessment = captureHealthStore.assessment
            if assessment.state != lastRecordedHealthState {
                SupportDiagnostics.shared.record(.captureHealthChanged, component: .capture,
                    values: [.state: .state(SupportState(rawValue: assessment.state.rawValue) ?? .unknown),
                             .captureProven: .flag(assessment.captureProven)])
                recorder.record(
                    kind: .recorderHealth,
                    message: assessment.detail,
                    metadata: [
                        "state": assessment.state.rawValue,
                        "capture_proven": String(assessment.captureProven),
                    ]
                )
                lastRecordedHealthState = assessment.state
            }
            menuBarController.updateStatus()
            schedulePermissionWatchdog()
        }

        private func installCapabilityConsentObserver() {
            globalPauseObserver = NotificationCenter.default.addObserver(forName: .goalongGlobalPauseDidChange,
                object: nil, queue: .main) { [weak self] notice in
                guard let self, notice.object as? String == AppPaths.applicationSupportDirectory.standardizedFileURL.path else { return }
                self.resumingGlobalPause = !GoalongGlobalPause.isPaused()
                self.applyCapabilityConsents(recordTransition: true)
                if GoalongGlobalPause.isPaused() { self.screenTimeRepository?.waitForPendingCollection() }
                self.resumingGlobalPause = false
                self.menuBarController.updateStatus()
            }
            capabilityConsentObserver = NotificationCenter.default.addObserver(
                forName: .goalongCapabilityConsentDidChange,
                object: capabilityConsents,
                queue: .main
            ) { [weak self] _ in
                self?.applyCapabilityConsents(recordTransition: true)
            }
        }

        private func applyCapabilityConsents(recordTransition: Bool) {
            let localCaptureEnabled = capabilityConsents.isEnabled(.localComputerHistory) && !GoalongGlobalPause.isPaused()
            if localCaptureEnabled && !localCaptureRuntimeActive {
                let wasActive = localCaptureRuntimeActive
                localCaptureRuntimeActive = true
                // Preserve a manual pause across both global-pause recovery and updates.
                let retainManualPause = resumingGlobalPause && GoalongGlobalPause.load().recordingWasPaused
                if resumingGlobalPause {
                    continuityPreferences.manuallyPaused = retainManualPause
                } else if recordTransition {
                    continuityPreferences.manuallyPaused = false
                }
                let paused = continuityPreferences.manuallyPaused
                captureState.setManualPaused(paused)
                captureHealthStore.setPaused(paused)
                if !paused { minuteSealer.start() }
                contextMonitor.start()
                checkPermissionsAndStartTap(forceRefresh: true)
                if recordTransition && !wasActive {
                    recorder.record(
                        kind: .recordingResumed,
                        message: "Computer History enabled by explicit consent"
                    )
                } else {
                    recorder.record(
                        kind: .recorderStarted,
                        message: "Goalong History started",
                        metadata: [
                            "storage": AppPaths.eventsDirectory.path,
                            "build_edition": GoalongBuildCapabilities.edition.rawValue,
                            "network_upload": GoalongBuildCapabilities.permitsRemoteVerification
                                && capabilityConsents.isEnabled(.remoteVerification)
                                && configManager.config.verificationEnabled == true
                                ? "opaque_commitments_only" : "disabled",
                            "verification_server": GoalongBuildCapabilities.permitsRemoteVerification
                                && capabilityConsents.isEnabled(.remoteVerification)
                                ? (configManager.config.verificationServerURL ?? "none")
                                : "disabled",
                            "device_trust_tier": deviceIdentity.info.trustTier,
                            "raw_text_capture": "disabled",
                            "interface_version":
                                (Bundle.main.object(
                                    forInfoDictionaryKey: "CFBundleShortVersionString"
                                ) as? String) ?? "0.6.0-dev",
                        ]
                    )
                }
            } else if !localCaptureEnabled {
                let wasActive = localCaptureRuntimeActive
                localCaptureRuntimeActive = false
                permissionTimer?.invalidate()
                permissionTimer = nil
                eventTapMonitor.stop()
                contextMonitor.stop()
                captureState.setManualPaused(true)
                captureHealthStore.setPaused(true)
                if wasActive {
                    _ = minuteSealer.stopAndSeal()
                }
                if recordTransition && wasActive {
                    recorder.record(
                        kind: .recordingPaused,
                        message: "Computer History disabled by explicit consent"
                    )
                    recorder.flush()
                }
            }

            if capabilityConsents.isEnabled(.aiConversations) && !GoalongGlobalPause.isPaused() {
                agentActivityRuntime.start()
            } else {
                agentActivityRuntime.stop()
            }

            configureScreenTimeDailyArchive()
            configureReadOnlyQueryServer()

            let analysisEnabled = GoalongBuildCapabilities.permitsRemoteAnalysis
                && capabilityConsents.isEnabled(.chatGPTAnalysis) && !GoalongGlobalPause.isPaused()
            if analysisEnabled {
                ChatGPTRecapRuntime.shared.start()
            } else {
                ChatGPTRecapRuntime.shared.stop()
            }

            configureUploader(for: configManager.config)
            let backgroundSourcesEnabled = hasEnabledBackgroundSources
            DispatchQueue.main.async {
                BackgroundContinuityController.shared.update(hasEnabledSources: backgroundSourcesEnabled)
            }
            dashboardViewModel.refreshEverything()
        }

        private func configureReadOnlyQueryServer() {
            guard capabilityConsents.isEnabled(.appleScreenTime), !GoalongGlobalPause.isPaused() else {
                readOnlyQueryServer?.stop()
                readOnlyQueryServer = nil
                do {
                    try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(
                        rootDirectory: AppPaths.applicationSupportDirectory
                    )
                } catch {
                    Diagnostics.write(
                        "Screen Time CLI broker stayed off but an unexpected socket path was preserved: \(error)"
                    )
                }
                return
            }
            guard readOnlyQueryServer == nil else { return }

            guard let screenTimeRepository else {
                Diagnostics.write("Screen Time CLI broker stayed off because daily storage is unavailable.")
                return
            }
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: AppPaths.applicationSupportDirectory,
                screenTimeHandler: { day, macOnly, selectedDeviceIDs in
                    try GoalongQueryCLI.screenTimePayload(
                        day: day,
                        macOnly: macOnly,
                        selectedDeviceIDs: selectedDeviceIDs,
                        collectionProvider: { screenTimeRepository.collect(for: $0) },
                        currentMacProvider: { screenTimeRepository.currentMacDevice }
                    )
                },
                screenTimeRangeHandler: { days in
                    try GoalongQueryCLI.screenTimeRangePayload(
                        days: days,
                        dailyCollectionProvider: { screenTimeRepository.collect(for: $0) },
                        currentMacProvider: { screenTimeRepository.currentMacDevice }
                    )
                }
            )
            do {
                try server.start()
                readOnlyQueryServer = server
            } catch {
                server.stop()
                Diagnostics.write(
                    "Screen Time CLI broker stayed off because it could not start safely: \(error)"
                )
            }
        }

        /// Uses the existing Goalong process to maintain one local file for the active day.
        /// Historical Apple stores are never opened by this timer or by subsequent readers.
        private func configureScreenTimeDailyArchive() {
            screenTimeArchiveTimer?.invalidate()
            screenTimeArchiveTimer = nil
            guard capabilityConsents.isEnabled(.appleScreenTime), !GoalongGlobalPause.isPaused(), screenTimeRepository != nil else {
                return
            }

            refreshCurrentScreenTimeDay()
            let interval: TimeInterval = 10 * 60
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshCurrentScreenTimeDay()
            }
            timer.tolerance = 60
            RunLoop.main.add(timer, forMode: .common)
            screenTimeArchiveTimer = timer
        }

        private func refreshCurrentScreenTimeDay() {
            guard capabilityConsents.isEnabled(.appleScreenTime), !GoalongGlobalPause.isPaused(),
                  let screenTimeRepository,
                  !screenTimeArchiveRefreshInFlight
            else { return }
            screenTimeArchiveRefreshInFlight = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = screenTimeRepository.collect(for: Date())
                DispatchQueue.main.async {
                    self?.screenTimeArchiveRefreshInFlight = false
                }
            }
        }

        private func applyDailyRetentionCleanupIfNeeded(now: Date = Date()) {
            guard retentionCleanupGate.admit(now: now) else { return }
            retentionStore.applyCleanupAfterDrainingDerivedWriters(now: now)
        }

        private func installWorkspaceObservers() {
            let center = NSWorkspace.shared.notificationCenter
            // Session switching is not screen locking. Keep an independent gate
            // and still re-check WindowServer before each foreground observation.
            let distributed = DistributedNotificationCenter.default()
            for (name, unlocked) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
                screenLockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    if self.captureState.setScreenUnlocked(unlocked) {
                        self.recorder.record(kind: unlocked ? .sessionUnlocked : .sessionLocked,
                            message: unlocked ? "Screen unlocked" : "Screen locked")
                        self.contextMonitor.invalidatePresence()
                        self.recorder.flush()
                        if unlocked {
                            self.contextMonitor.resetAndSample()
                            self.checkPermissionsAndStartTap(forceRefresh: true)
                        }
                    }
                })
            }

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.contextMonitor.sampleNow()
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.recorder.record(kind: .sessionLocked, message: "macOS user session became inactive")
                    self.captureState.setUserSessionActive(false)
                    self.contextMonitor.invalidatePresence()
                    self.recorder.flush()
                    self.menuBarController.updateStatus()
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.captureState.setUserSessionActive(true)
                    self.recorder.record(kind: .sessionUnlocked, message: "macOS user session became active")
                    self.contextMonitor.resetAndSample()
                    self.checkPermissionsAndStartTap(forceRefresh: true)
                    self.refreshCurrentScreenTimeDay()
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.willSleepNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.recorder.record(kind: .systemSleep, message: "Mac is going to sleep")
                    self.captureState.setSystemAwake(false)
                    self.contextMonitor.invalidatePresence()
                    self.recorder.flush()
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.didWakeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.captureState.setSystemAwake(true)
                    self.recorder.record(kind: .systemWake, message: "Mac woke from sleep")
                    self.contextMonitor.resetAndSample()
                    self.checkPermissionsAndStartTap(forceRefresh: true)
                    self.refreshCurrentScreenTimeDay()
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.screensDidSleepNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    if self.captureState.setDisplaysAwake(false) {
                        self.recorder.record(kind: .systemSleep, message: "Displays went to sleep")
                        self.contextMonitor.invalidatePresence()
                        self.recorder.flush()
                    }
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.screensDidWakeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    if self.captureState.setDisplaysAwake(true) {
                        self.recorder.record(kind: .systemWake, message: "Displays woke")
                        self.contextMonitor.resetAndSample()
                        self.checkPermissionsAndStartTap(forceRefresh: true)
                    }
                }
            )
        }

        private func anotherInstanceIsRunning() -> Bool {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            return
                NSRunningApplication
                .runningApplications(withBundleIdentifier: "ai.goalong.localhistory")
                .contains { $0.processIdentifier != currentPID && !$0.isTerminated }
        }

        private func presentFatalError(_ error: Error) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Goalong History n’a pas pu démarrer"
            alert.addButton(withTitle: "Exporter un diagnostic…")
            alert.addButton(withTitle: "Quitter")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { @MainActor in
                    SupportExportController.shared.export { NSApplication.shared.terminate(nil) }
                }
            } else { NSApplication.shared.terminate(nil) }
        }
    }
#endif
