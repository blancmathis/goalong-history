#if os(macOS)
    import AgentActivity
    import AppKit
    import Foundation
    import LocalHistoryCore

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
        private var commitmentUploader: CommitmentUploader?
        private var recorder: EventRecorder!
        private var contextProvider: ContextProvider!
        private var contextMonitor: ContextMonitor!
        private var eventTapMonitor: EventTapMonitor!
        private var dashboardViewModel: DashboardViewModel!
        private var sharingRulesStore: SharingRulesStore!
        private var agentActivityRuntime: AgentActivityRuntime!
        private var dashboardWindowController: DashboardWindowController!
        private var menuBarController: MenuBarController!

        private var permissionTimer: Timer?
        private var lastPermissionStatus: PermissionStatus?
        private var lastRecordedHealthState: CaptureHealthState?
        private var workspaceObservers: [NSObjectProtocol] = []
        private var retentionCleanupGate = DailyMaintenanceGate()

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
                commitmentUploader = CommitmentUploader(config: configManager.config, identity: deviceIdentity)
                minuteSealer.setUploader(commitmentUploader)
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
                    }
                )
                dashboardWindowController = DashboardWindowController(viewModel: dashboardViewModel)

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
            minuteSealer.start()
            commitmentUploader?.replayPending()

            recorder.record(
                kind: .recorderStarted,
                message: "Goalong History started",
                metadata: [
                    "storage": AppPaths.eventsDirectory.path,
                    "network_upload": configManager.config.verificationEnabled == true
                        ? "opaque_commitments_only" : "disabled",
                    "verification_server": configManager.config.verificationServerURL ?? "none",
                    "device_trust_tier": deviceIdentity.info.trustTier,
                    "raw_text_capture": "disabled",
                    "interface_version":
                        (Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String) ?? "0.5.1-dev",
                ]
            )
            agentActivityRuntime.start()
            ChatGPTRecapRuntime.shared.configure(deviceID: deviceIdentity.info.deviceID)
            ChatGPTRecapRuntime.shared.start()

            installWorkspaceObservers()
            contextMonitor.start()
            checkPermissionsAndStartTap()
            showDashboardOnFirstV3Launch()
        }

        func applicationWillTerminate(_ notification: Notification) {
            permissionTimer?.invalidate()
            agentActivityRuntime?.stop()
            ChatGPTRecapRuntime.shared.stop()
            contextMonitor?.stop()
            eventTapMonitor?.stop()
            recorder?.record(kind: .recorderStopped, message: "Goalong History stopped")
            recorder?.flush()
            captureHealthStore?.flush()
            minuteSealer?.stopAndSeal()
            recorder?.close()

            let center = NSWorkspace.shared.notificationCenter
            for observer in workspaceObservers {
                center.removeObserver(observer)
            }
            workspaceObservers.removeAll()
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            dashboardWindowController?.show(section: dashboardViewModel?.selectedSection ?? .overview)
            return true
        }

        private func toggleManualPause() {
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
            commitmentUploader = CommitmentUploader(config: config, identity: deviceIdentity)
            minuteSealer.setUploader(commitmentUploader)
            commitmentUploader?.replayPending()
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

        private func showDashboardOnFirstV3Launch() {
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
