#if os(macOS)
    import AgentActivity
    import AppKit
    import Foundation
    import LocalHistoryCore

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

        func applicationDidFinishLaunching(_ notification: Notification) {
            guard !anotherInstanceIsRunning() else {
                NSApplication.shared.terminate(nil)
                return
            }

            NSApplication.shared.setActivationPolicy(.accessory)

            do {
                try AppPaths.prepare()
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
                let executableURL = Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/Applications/Goalong History.app/Contents/MacOS/Goalong History")
                agentActivityRuntime = try AgentActivityRuntime(
                    rootDirectory: AppPaths.agentActivityDirectory,
                    executableURL: executableURL,
                    onCaptured: { [weak self] captures in
                        self?.recordAgentCaptures(captures)
                    }
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

            retentionStore.applyCleanup()
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
                    "interface_version": (Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String) ?? "0.5.1-dev",
                ]
            )
            agentActivityRuntime.start()
            ChatGPTRecapRuntime.shared.configure(deviceID: deviceIdentity.info.deviceID)
            ChatGPTRecapRuntime.shared.start()

            installWorkspaceObservers()
            contextMonitor.start()
            startPermissionPolling()
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
                recorder.record(kind: .recordingResumed, message: "Recording resumed from the Goalong History interface")
                contextMonitor.resetAndSample()
            } else {
                recorder.record(kind: .recordingPaused, message: "Recording paused from the Goalong History interface")
                recorder.flush()
                captureState.setManualPaused(true)
                captureHealthStore.setPaused(true)
            }
            menuBarController.updateStatus()
        }

        private func recordAgentCaptures(_ captures: [AgentCaptureRecord]) {
            for capture in captures {
                let context = ContextSnapshot(
                    app: AppSnapshot(
                        name: capture.provider.displayName,
                        bundleIdentifier: "ai.goalong.agent.\(capture.provider.rawValue.lowercased())",
                        processIdentifier: ProcessInfo.processInfo.processIdentifier
                    ),
                    window: nil,
                    focusedElement: nil,
                    url: nil,
                    suppressionReason: nil
                )
                var metadata: [String: String] = [
                    "agent_capture_id": capture.id,
                    "agent_provider": capture.provider.rawValue,
                    "agent_source_key": capture.sourceKey,
                    "agent_relative_path_sha256": SHA256Digest.hashHex(capture.relativePath),
                    "agent_content_sha256": capture.sha256,
                    "agent_manifest_hash": capture.manifestHash,
                    "agent_storage_kind": capture.storageKind.rawValue,
                    "agent_version": String(capture.version),
                    "agent_byte_count": String(capture.byteCount),
                    "agent_stored_byte_count": String(capture.storedByteCount),
                    "agent_message_count": String(capture.summary.messageCount),
                    "agent_tool_call_count": String(capture.summary.toolCallCount),
                ]
                if let sessionID = capture.summary.sessionID {
                    metadata["agent_session_sha256"] = SHA256Digest.hashHex(sessionID)
                }
                recorder.record(
                    kind: .agentArtifactCaptured,
                    context: context,
                    message: "Agent activity captured locally",
                    metadata: metadata,
                    timestamp: capture.capturedAt
                )
            }
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
            if let cutoff {
                store.deleteEvents(since: cutoff) { [weak self] rawResult in
                    guard let self else { completion(rawResult); return }
                    switch rawResult {
                    case .failure:
                        completion(rawResult)
                    case .success(let rawCount):
                        self.semanticContextStore.deleteEvents(since: cutoff) { semanticResult in
                            switch semanticResult {
                            case .failure(let error): completion(.failure(error))
                            case .success(let semanticCount):
                                let total = rawCount + semanticCount
                                self.recorder.record(
                                    kind: .historyCleared,
                                    message: "Detailed local activity and semantic snapshots deleted",
                                    metadata: [
                                        "deleted_events": String(rawCount),
                                        "deleted_semantic_snapshots": String(semanticCount),
                                    ]
                                )
                                completion(.success(total))
                            }
                        }
                    }
                }
            } else {
                store.deleteAll { [weak self] rawResult in
                    guard let self else { completion(rawResult); return }
                    switch rawResult {
                    case .failure:
                        completion(rawResult)
                    case .success(let rawCount):
                        self.semanticContextStore.deleteAll { semanticResult in
                            switch semanticResult {
                            case .failure(let error): completion(.failure(error))
                            case .success(let semanticCount):
                                let total = rawCount + semanticCount
                                self.recorder.record(
                                    kind: .historyCleared,
                                    message: "All detailed local activity and semantic snapshots deleted",
                                    metadata: [
                                        "deleted_files": String(rawCount),
                                        "deleted_semantic_files": String(semanticCount),
                                    ]
                                )
                                completion(.success(total))
                            }
                        }
                    }
                }
            }
        }

        private func requestPermissionsAndExplain() {
            permissions.requestAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let status = self.permissions.currentStatus
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

        private func startPermissionPolling() {
            permissionTimer?.invalidate()
            let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.checkPermissionsAndStartTap()
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }

        private func checkPermissionsAndStartTap() {
            let status = permissions.currentStatus
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
            } else if !status.canAttemptInputTap, eventTapMonitor.isRunning {
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
                    self.menuBarController.updateStatus()
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
