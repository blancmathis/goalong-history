#if os(macOS)
    import AgentActivity
    import AppKit
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
        private var configManager: ConfigManager!
        private var permissions: PermissionManager!
        private var captureHealthStore: CaptureHealthStore!
        private var semanticContextStore: SemanticContextStore!
        private var memoryStore: LocalActivityMemoryStore!
        private var retentionStore: HistoryRetentionStore!
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
        private var readOnlyQueryServer: GoalongReadOnlyQueryServer?
        private var dashboardWindowController: DashboardWindowController!
        private var applicationMenuController: ApplicationMenuController!
        private var menuBarController: MenuBarController!
        private var capabilityConsents: GoalongCapabilityConsentStore!

        private var permissionTimer: Timer?
        private var lastPermissionStatus: PermissionStatus?
        private var lastRecordedHealthState: CaptureHealthState?
        private var workspaceObservers: [NSObjectProtocol] = []
        private var capabilityConsentObserver: NSObjectProtocol?
        private var retentionCleanupGate = DailyMaintenanceGate()
        private var localCaptureRuntimeActive = false

        func applicationDidFinishLaunching(_ notification: Notification) {
            guard !anotherInstanceIsRunning() else {
                NSApplication.shared.terminate(nil)
                return
            }

            NSApplication.shared.setActivationPolicy(.accessory)

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
                    performInitialDiscovery: capabilityConsents.isEnabled(.aiConversations),
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
                    onQuit: {
                        NSApplication.shared.terminate(nil)
                    }
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
                    onOpenShare: { [weak self] in self?.dashboardWindowController.show(section: .share) },
                    onTogglePause: { [weak self] in self?.toggleManualPause() },
                    onRequestPermissions: { [weak self] in self?.requestPermissionsAndExplain() },
                    onReloadConfig: { [weak self] in self?.reloadConfiguration() },
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
            } catch {
                presentFatalError(error)
                return
            }

            applyDailyRetentionCleanupIfNeeded()
            applyCapabilityConsents(recordTransition: false)
            ChatGPTRecapRuntime.shared.configure(deviceID: deviceIdentity.info.deviceID)
            installCapabilityConsentObserver()

            installWorkspaceObservers()
            showDashboardOnFirstConsentLaunch()
        }

        func applicationWillTerminate(_ notification: Notification) {
            permissionTimer?.invalidate()
            if let capabilityConsentObserver {
                NotificationCenter.default.removeObserver(capabilityConsentObserver)
            }
            capabilityConsentObserver = nil
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

            let center = NSWorkspace.shared.notificationCenter
            for observer in workspaceObservers {
                center.removeObserver(observer)
            }
            workspaceObservers.removeAll()
        }

        func applicationShouldHandleReopen(
            _ sender: NSApplication,
            hasVisibleWindows flag: Bool
        ) -> Bool {
            dashboardWindowController?.show(section: dashboardViewModel?.selectedSection ?? .overview)
            return false
        }

        private func toggleManualPause() {
            if !capabilityConsents.isEnabled(.localComputerHistory) {
                do {
                    try dashboardViewModel.configureCaptureForOnboarding(enabled: true)
                } catch {
                    Diagnostics.write(
                        "Computer History stayed off because its local configuration could not be enabled: \(error)"
                    )
                    return
                }
                guard capabilityConsents.set(
                    .localComputerHistory,
                    enabled: true,
                    surface: .menuBar
                ) else { return }
                applyCapabilityConsents(recordTransition: true)
                return
            }
            if captureState.isManuallyPaused {
                captureState.setManualPaused(false)
                captureHealthStore.setPaused(false)
                recorder.record(
                    kind: .recordingResumed, message: "Recording resumed from the Goalong History interface")
                contextMonitor.resetAndSample()
            } else {
                recorder.record(kind: .recordingPaused, message: "Recording paused from the Goalong History interface")
                recorder.flush()
                captureState.setManualPaused(true)
                captureHealthStore.setPaused(true)
                _ = minuteSealer.stopAndSeal()
            }
            menuBarController.updateStatus()
        }

        private func applyConfiguration(_ config: RecorderConfig) throws -> RecorderConfig {
            let applied = try configManager.save(config)
            do {
                try retentionStore.updateDetailedRetention(fromLegacyDays: applied.retentionDays)
                retentionStore.applyCleanup()
            } catch {
                Diagnostics.write("Could not persist detailed retention policy: \(error)")
            }
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
            guard capabilityConsents.isEnabled(.localComputerHistory) else {
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

            if status.canAttemptInputTap, !eventTapMonitor.isRunning {
                _ = eventTapMonitor.start()
            } else if !status.canAttemptInputTap,
                eventTapMonitor.isRunning || eventTapMonitor.hasPendingUnexpectedRestart
            {
                eventTapMonitor.stop()
            }

            let assessment = captureHealthStore.assessment
            if assessment.state != lastRecordedHealthState {
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
            capabilityConsentObserver = NotificationCenter.default.addObserver(
                forName: .goalongCapabilityConsentDidChange,
                object: capabilityConsents,
                queue: .main
            ) { [weak self] _ in
                self?.applyCapabilityConsents(recordTransition: true)
            }
        }

        private func applyCapabilityConsents(recordTransition: Bool) {
            let localCaptureEnabled = capabilityConsents.isEnabled(.localComputerHistory)
            if localCaptureEnabled {
                let wasActive = localCaptureRuntimeActive
                localCaptureRuntimeActive = true
                captureState.setManualPaused(false)
                captureHealthStore.setPaused(false)
                minuteSealer.start()
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
            } else {
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

            if capabilityConsents.isEnabled(.aiConversations) {
                agentActivityRuntime.start()
            } else {
                agentActivityRuntime.stop()
            }

            configureReadOnlyQueryServer()

            let analysisEnabled = GoalongBuildCapabilities.permitsRemoteAnalysis
                && capabilityConsents.isEnabled(.chatGPTAnalysis)
            if analysisEnabled {
                ChatGPTRecapRuntime.shared.start()
            } else {
                ChatGPTRecapRuntime.shared.stop()
            }

            configureUploader(for: configManager.config)
            dashboardViewModel.refreshEverything()
        }

        private func configureReadOnlyQueryServer() {
            guard capabilityConsents.isEnabled(.appleScreenTime) else {
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

            // The broker serves requests on one serial utility queue. Reuse one bounded Apple
            // reader so unchanged source files can reuse decoded segments, but build a new
            // response for every request after rechecking Apple's current file fingerprints.
            let appleSource = AppleSystemScreenTimeSource(
                deviceID: "goalong-cli-current-mac"
            )
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: AppPaths.applicationSupportDirectory,
                screenTimeHandler: { day, macOnly, selectedDeviceIDs in
                    try GoalongQueryCLI.screenTimePayload(
                        day: day,
                        macOnly: macOnly,
                        selectedDeviceIDs: selectedDeviceIDs,
                        collectionProvider: { appleSource.collect(for: $0) },
                        currentMacProvider: { appleSource.currentMacDevice }
                    )
                },
                screenTimeRangeHandler: { days in
                    try GoalongQueryCLI.screenTimeRangePayload(
                        days: days,
                        collectionProvider: { appleSource.collect(for: $0) },
                        currentMacProvider: { appleSource.currentMacDevice }
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

        private func applyDailyRetentionCleanupIfNeeded(now: Date = Date()) {
            guard retentionCleanupGate.admit(now: now) else { return }
            retentionStore.applyCleanup(now: now)
        }

        private func installWorkspaceObservers() {
            let center = NSWorkspace.shared.notificationCenter

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
                }
            )

            workspaceObservers.append(
                center.addObserver(
                    forName: NSWorkspace.screensDidSleepNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    if self.captureState.setSystemAwake(false) {
                        self.recorder.record(kind: .systemSleep, message: "Displays went to sleep")
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
                    if self.captureState.setSystemAwake(true) {
                        self.recorder.record(kind: .systemWake, message: "Displays woke")
                        self.contextMonitor.resetAndSample()
                        self.checkPermissionsAndStartTap()
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
            alert.messageText = "Goalong History could not start"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }
#endif
