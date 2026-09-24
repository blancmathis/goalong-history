#if os(macOS)
    import Carbon
    import CoreGraphics
    import Foundation
    import LocalHistoryCore

    final class ContextMonitor {
        struct ContextTransition {
            let kind: LocalHistoryCore.EventKind
            let changedFields: [String]
        }

        private let provider: ContextProvider
        private let recorder: EventRecorder
        private let state: CaptureState
        private let configManager: ConfigManager
        private let captureHealth: CaptureHealthStore
        private let semanticContextStore: SemanticContextStore
        private let memoryStore: LocalActivityMemoryStore

        private var timer: Timer?
        private var accessibilityEventMonitor: AccessibilityEventMonitor?
        private var previous: ContextSnapshot?
        private var lastHeartbeat = Date.distantPast
        private let foregroundActivityProbe = ForegroundActivityProbe()
        private var lastForegroundEvidence: ForegroundActivityEvidence?
        private var pollingIsActive = false
        private var scheduledPollInProgress = false
        private var consecutiveCaptureFailures = 0

        private let snapshotLock = NSLock()
        private var _latestSnapshot: ContextSnapshot?

        var latestSnapshot: ContextSnapshot? {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return _latestSnapshot
        }

        init(
            provider: ContextProvider,
            recorder: EventRecorder,
            state: CaptureState,
            configManager: ConfigManager,
            permissions: PermissionManager,
            captureHealth: CaptureHealthStore,
            semanticContextStore: SemanticContextStore,
            memoryStore: LocalActivityMemoryStore
        ) {
            self.provider = provider
            self.recorder = recorder
            self.state = state
            self.configManager = configManager
            self.captureHealth = captureHealth
            self.semanticContextStore = semanticContextStore
            self.memoryStore = memoryStore
            accessibilityEventMonitor = AccessibilityEventMonitor(
                isAccessibilityAvailable: { [weak permissions] in
                    permissions?.currentStatus.accessibilityUsable == true
                },
                onChange: { [weak self] trigger in
                    guard let self,
                        let snapshot = self.sampleNow()
                    else { return }
                    ActivityAnalysisRuntime.shared.captureObservedContext(
                        trigger: trigger,
                        context: snapshot
                    )
                }
            )
        }

        func start() {
            stop()
            pollingIsActive = true
            sampleNow()
            ActivityAnalysisRuntime.shared.start(
                recorder: recorder,
                state: state,
                configManager: configManager,
                currentContext: { [weak self] in
                    guard let self else { return nil }
                    // Semantic text capture is privacy-sensitive. A failed fresh probe
                    // must not fall back to a previously safe window or URL.
                    return self.sampleNow()
                },
                semanticContextStore: semanticContextStore,
                memoryStore: memoryStore
            )
            accessibilityEventMonitor?.start()
        }

        /// Recover only the existing in-process monitor. The caller must check
        /// source consent, pause, and session state before requesting recovery.
        func ensureRunning() {
            if !pollingIsActive {
                Diagnostics.write("Recovering the in-process context monitor")
                start()
            } else if timer?.isValid != true && !scheduledPollInProgress {
                scheduleNextPoll()
            }
        }

        func stop() {
            pollingIsActive = false
            foregroundActivityProbe.reset()
            lastForegroundEvidence = nil
            accessibilityEventMonitor?.stop()
            timer?.invalidate()
            timer = nil
            ActivityAnalysisRuntime.shared.stop()
        }

        func resetAndSample() {
            previous = nil
            foregroundActivityProbe.reset()
            lastForegroundEvidence = nil
            sampleNow()
        }

        private func scheduleNextPoll() {
            timer?.invalidate()
            let configuredInterval = Double(configManager.config.pollIntervalMilliseconds) / 1_000.0
            guard pollingIsActive,
                  let interval = Self.nextPollInterval(
                configuredInterval: configuredInterval,
                idleSeconds: idleSeconds(),
                isCapturing: state.isCapturing,
                suppressionReason: latestSnapshot?.suppressionReason,
                eventDrivenCoverageAvailable: accessibilityEventMonitor?.hasReliableEventCoverage == true
                    && consecutiveCaptureFailures == 0
            ) else {
                timer = nil
                return
            }
            let boundedInterval = (JevIngress.shared.isEnabled || lastForegroundEvidence != nil)
                ? min(interval, ForegroundActivityProbe.interval) : interval
            let timer = Timer(timeInterval: boundedInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                self.scheduledPollInProgress = true
                self.sampleNow()
                self.scheduledPollInProgress = false
                self.scheduleNextPoll()
            }
            // Give macOS a small coalescing window while keeping the fallback refresh
            // comfortably below one minute even after timer tolerance.
            timer.tolerance = min(1.0, interval * 0.1)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// The event tap, workspace notifications and AX observers remain immediate.
        /// This timer is only their fallback, so it can back off when the user is idle
        /// while retaining the configured high-frequency sampling during active input.
        static func nextPollInterval(
            configuredInterval: TimeInterval,
            idleSeconds: TimeInterval,
            isCapturing: Bool,
            suppressionReason: SuppressionReason?,
            eventDrivenCoverageAvailable: Bool
        ) -> TimeInterval? {
            let base = min(45.0, max(0.25, configuredInterval))
            guard isCapturing else { return nil }

            switch suppressionReason {
            case .accessibilityUnavailable, .sessionUnavailable:
                // The permission watchdog already performs a cached-status recovery
                // check every three seconds. Sampling foreground context faster cannot
                // succeed while AX/session access is absent and only creates wakeups.
                return min(5.0, max(base, 3.0))
            case .secureInput:
                return min(5.0, max(base, 1.0))
            default:
                break
            }
            guard eventDrivenCoverageAvailable else { return base }

            let idle = max(0, idleSeconds)
            if idle < 3 { return base }
            if idle < 15 { return min(45.0, max(base, 2.0)) }
            if idle < 60 { return min(45.0, max(base, 5.0)) }
            if idle < 300 { return min(45.0, max(base, 15.0)) }
            return min(45.0, max(base, 30.0))
        }

        @discardableResult
        func sampleNow() -> ContextSnapshot? {
            defer {
                if pollingIsActive, !scheduledPollInProgress {
                    scheduleNextPoll()
                }
            }
            guard state.isCapturing else {
                foregroundActivityProbe.reset(); lastForegroundEvidence = nil
                JevIngress.shared.boundary(); return nil
            }
            if IsSecureEventInputEnabled() {
                foregroundActivityProbe.reset(); lastForegroundEvidence = nil
                let safeContext = latestSnapshot.map { current in
                    ContextSnapshot(
                        app: current.app,
                        window: nil,
                        focusedElement: nil,
                        url: nil,
                        suppressionReason: .secureInput,
                        privacyRevision: current.privacyRevision, globalPauseRevision: current.globalPauseRevision
                    )
                }
                setLatest(safeContext)
                JevIngress.shared.boundary()
                previous = safeContext
                consecutiveCaptureFailures = 0
                captureHealth.setSuppression(.secureInput)
                return safeContext
            }
            guard let current = provider.capture() else {
                foregroundActivityProbe.reset(); lastForegroundEvidence = nil
                consecutiveCaptureFailures = min(consecutiveCaptureFailures + 1, 1_000)
                captureHealth.markAXFailure()
                JevIngress.shared.boundary()
                return nil
            }
            consecutiveCaptureFailures = 0
            setLatest(current)
            let evidence = foregroundActivityProbe.sample(current,
                labelsEnabled: configManager.config.captureElementLabels)
            JevIngress.shared.observeContext(current, foregroundEvidence: evidence)
            captureHealth.setSuppression(current.suppressionReason)
            if current.suppressionReason == .accessibilityUnavailable {
                captureHealth.markAXFailure()
            } else if current.suppressionReason == nil {
                captureHealth.markAXSuccess(urlAvailable: current.url != nil)
            }

            if let reason = current.suppressionReason {
                lastForegroundEvidence = nil
                if previous?.suppressionReason != reason || previous?.app != current.app {
                    recorder.record(
                        kind: .captureSuppressed,
                        context: current,
                        suppressionReason: reason,
                        message: suppressionMessage(for: reason)
                    )
                }
                previous = current
                return current
            }

            if let previousReason = previous?.suppressionReason {
                recorder.record(
                    kind: .captureResumed,
                    context: current,
                    message: "Capture resumed after \(previousReason.rawValue)"
                )
            }

            let observedAt = Date()
            var activityMetadata = ["idle_seconds": String(format: "%.1f", idleSeconds())]
            if let evidence { activityMetadata[ForegroundActivityEvidence.metadataKey] = evidence.rawValue }
            if let transition = Self.contextTransition(from: previous, to: current) {
                recorder.record(
                    kind: transition.kind,
                    context: current,
                    metadata: activityMetadata.merging([
                        "computer_history.context_changes": transition.changedFields.joined(separator: ","),
                    ]) { _, new in new },
                    timestamp: observedAt
                )
            }

            let heartbeatInterval = TimeInterval(
                evidence == nil ? max(10, configManager.config.heartbeatSeconds)
                    : min(30, max(10, configManager.config.heartbeatSeconds))
            )
            if evidence != lastForegroundEvidence || observedAt.timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
                recorder.record(
                    kind: .heartbeat,
                    context: current,
                    metadata: activityMetadata,
                    timestamp: observedAt
                )
                lastHeartbeat = observedAt
            }
            lastForegroundEvidence = evidence

            previous = current
            return current
        }

        /// One context sample can change application, window, URL and focused element
        /// simultaneously. The selected event already carries the complete resulting
        /// context, so persisting four near-identical rows adds write volume without
        /// adding evidence. Keep the most informative transition kind and record every
        /// changed dimension as compact metadata.
        static func contextTransition(
            from previous: ContextSnapshot?,
            to current: ContextSnapshot
        ) -> ContextTransition? {
            var changedFields: [String] = []
            if previous?.app != current.app {
                changedFields.append("application")
            }
            if previous?.window != current.window {
                changedFields.append("window")
            }
            if previous?.url != current.url, current.url != nil {
                changedFields.append("url")
            }
            if previous?.focusedElement != current.focusedElement {
                changedFields.append("focus")
            }

            let kind: LocalHistoryCore.EventKind?
            if changedFields.contains("application") {
                kind = .applicationActivated
            } else if changedFields.contains("window") {
                kind = .windowChanged
            } else if changedFields.contains("url") {
                kind = .urlChanged
            } else if changedFields.contains("focus") {
                kind = .focusChanged
            } else {
                kind = nil
            }

            return kind.map { ContextTransition(kind: $0, changedFields: changedFields) }
        }

        private func setLatest(_ snapshot: ContextSnapshot?) {
            snapshotLock.lock()
            _latestSnapshot = snapshot
            snapshotLock.unlock()
        }

        private func suppressionMessage(for reason: SuppressionReason) -> String {
            switch reason {
            case .privateBrowserWindow:
                return "Browser activity suppressed because a private-mode marker was detected"
            case .excludedApplication:
                return "Application excluded by configuration"
            case .excludedDomain:
                return "Website excluded by configuration"
            case .secureInput:
                return "Secure input active"
            case .sessionUnavailable:
                return "User session unavailable"
            case .manualPause:
                return "Capture manually paused"
            case .accessibilityUnavailable:
                return "Accessibility permission unavailable"
            }
        }

        private func idleSeconds() -> Double {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .null
            )
        }
    }
#endif
