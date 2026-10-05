#if os(macOS)
    import AppKit
    import ApplicationServices
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

        var concentrationSink: ((FocusObservation) -> Void)?
        var blockingSink: ((BlockingObservation) -> Void)?
        private(set) var blockingObservationEnabled = false
        private var historyRequested = false
        func setBlockingObservationEnabled(_ enabled: Bool) {
            guard enabled != blockingObservationEnabled else { return }
            provider.invalidateBlocking()
            provider.invalidateHistory()
            sampleGeneration = UUID(); sampleJobs.removeAll()
            blockingRequestID = nil
            blockingObservationEnabled = enabled
            accessibilityEventMonitor?.observesApplicationLaunches = enabled
            if enabled {
                pollingIsActive = true
                accessibilityEventMonitor?.start()
                sampleNow()
            } else if !historyRequested {
                pollingIsActive = false; timer?.invalidate(); timer = nil
                accessibilityEventMonitor?.stop()
            } else { accessibilityEventMonitor?.start(); scheduleNextPoll() }
        }
        static func usesBlockingOnlyLane(capturing: Bool, blockingEnabled: Bool) -> Bool { blockingEnabled && !capturing }
        private var timer: Timer?
        private var accessibilityEventMonitor: AccessibilityEventMonitor?
        private var previous: ContextSnapshot?
        private var lastHeartbeat = Date.distantPast
        private var sampleGeneration = UUID()
        private var sampleJobs = Set<UUID>()
        private let jevVisibleContext = JevVisibleContextSampler()
        private var lastForegroundEvidence: ForegroundActivityEvidence?
        private var lastPresenceActive: Bool?
        private var lastIdleLimit: Int?
        private var observationUnavailable = false
        private var pollingIsActive = false
        private var scheduledPollInProgress = false
        private var blockingRequestID: UUID?
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
                isAccessibilityAvailable: { [weak self, weak permissions] in
                    permissions?.currentStatus.accessibilityUsable == true || (self?.blockingObservationEnabled == true && AXIsProcessTrusted())
                },
                onChange: { [weak self] trigger in
                    self?.sampleNow { snapshot in
                        guard let snapshot else { return }
                        ActivityAnalysisRuntime.shared.captureObservedContext(trigger: trigger, context: snapshot)
                    }
                }
            )
            accessibilityEventMonitor?.onApplication = { [weak self] app in
                guard let self, self.blockingObservationEnabled else { return }
                // Launches may be background launches: enforce app rules immediately, without reading a URL.
                self.blockingSink?(BlockingObservation(bundleIdentifier: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                    windowFrame: nil, isBrowser: BlockingRules.isKnownBrowser(app.bundleIdentifier, configured: self.configManager.config.browserBundleIdentifiers), url: nil, privateWindow: false, at: Date(),
                    regular: app.activationPolicy == .regular, sessionAvailable: ForegroundSessionAvailability.isAvailable(), idleSeconds: 121,
                    isForeground: app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier, isActivation: true))
            }
        }

        func start() {
            stop()
            historyRequested = true
            pollingIsActive = true
            sampleNow()
            ActivityAnalysisRuntime.shared.start(
                recorder: recorder,
                state: state,
                configManager: configManager,
                currentContext: { [weak self] completion in
                    guard let self else { completion(nil); return }
                    // Semantic text capture is privacy-sensitive. A failed fresh probe
                    // must not fall back to a previously safe window or URL.
                    self.requestEvidence(completion: completion)
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
            historyRequested = false
            pollingIsActive = blockingObservationEnabled
            invalidatePresence()
            if !blockingObservationEnabled { accessibilityEventMonitor?.stop() }
            timer?.invalidate()
            timer = nil
            ActivityAnalysisRuntime.shared.stop()
            if blockingObservationEnabled { scheduleNextPoll() }
        }

        func invalidatePresence() {
            sampleGeneration = UUID()
            sampleJobs.removeAll()
            provider.invalidateHistory()
            concentrationSink?(FocusObservation(at: Date(), observing: false))
            previous = nil
            setLatest(nil)
            jevVisibleContext.invalidate()
            lastForegroundEvidence = nil
            lastPresenceActive = nil
            lastIdleLimit = nil
            lastHeartbeat = .distantPast
            JevIngress.shared.boundary()
        }

        func resetAndSample() {
            invalidatePresence()
            sampleNow()
        }

        private func markObservationUnavailable() {
            invalidatePresence()
            if !observationUnavailable {
                recorder.record(kind: .recorderHealth, metadata: ["observation_gap": "true"])
            }
            observationUnavailable = true
        }

        private func scheduleNextPoll() {
            // Preserve the one-shot cadence: a slow blocking read cannot build
            // an unbounded queue of missed polls behind the reserved reader.
            guard blockingRequestID == nil, sampleJobs.isEmpty else { return }
            timer?.invalidate()
            let configuredInterval = Double(configManager.config.pollIntervalMilliseconds) / 1_000.0
            guard pollingIsActive,
                  let interval = blockingObservationEnabled ? 0.75 : Self.nextPollInterval(
                configuredInterval: configuredInterval,
                idleSeconds: idleSeconds(),
                isCapturing: historyRequested && state.isCapturing,
                suppressionReason: latestSnapshot?.suppressionReason,
                eventDrivenCoverageAvailable: accessibilityEventMonitor?.hasReliableEventCoverage == true
                    && consecutiveCaptureFailures == 0
            ) else {
                timer = nil
                return
            }
            let boundedInterval = min(ForegroundUsageObservation.heartbeatInterval,
                (JevIngress.shared.isEnabled || lastForegroundEvidence != nil)
                    ? min(interval, JevIngress.shared.isEnabled ? JevIngress.foregroundSampleInterval : ForegroundActivityProbe.interval) : interval)
            let timer = Timer(timeInterval: boundedInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                self.scheduledPollInProgress = true
                self.sampleNow { _ in
                    self.scheduledPollInProgress = false
                    self.scheduleNextPoll()
                }
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

        func sampleNow(completion: @escaping (ContextSnapshot?) -> Void = { _ in }) {
            let generation = sampleGeneration, jobID = UUID()
            sampleJobs.insert(jobID)
            var completed = false
            let finish: (ContextSnapshot?) -> Void = { snapshot in
                guard !completed else { return }; completed = true
                self.sampleJobs.remove(jobID)
                completion(snapshot)
                if self.pollingIsActive, !self.scheduledPollInProgress { self.scheduleNextPoll() }
            }
            var focusSample = FocusObservation(at: Date(), observing: false)
            if blockingObservationEnabled && (!historyRequested || !state.isCapturing || provider.historyPrivacyStopped || !ForegroundSessionAvailability.isAvailable() || IsSecureEventInputEnabled()) {
                guard blockingRequestID == nil else { finish(nil); return }
                let requestID = UUID()
                blockingRequestID = requestID
                provider.requestBlocking { [weak self] observation in
                    guard let self, self.blockingRequestID == requestID else { finish(nil); return }
                    self.blockingRequestID = nil
                    if self.blockingObservationEnabled, let observation { self.blockingSink?(observation) }
                    finish(nil)
                }
                // Blocking-only retains no history snapshot and never calls a history consumer.
                concentrationSink?(focusSample)
                return
            }
            var publishesFocusSynchronously = true
            defer { if publishesFocusSynchronously { concentrationSink?(focusSample) } }
            guard historyRequested, state.isCapturing else {
                invalidatePresence(); finish(nil); return
            }
            guard ForegroundSessionAvailability.isAvailable() else {
                focusSample.observing = true; focusSample.available = false
                markObservationUnavailable(); finish(nil); return
            }
            if IsSecureEventInputEnabled() {
                sampleGeneration = UUID(); sampleJobs.removeAll()
                provider.invalidateHistory(); lastForegroundEvidence = nil
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
                if previous?.suppressionReason != .secureInput {
                    recorder.record(kind: .captureSuppressed, context: safeContext, suppressionReason: .secureInput)
                }
                setLatest(safeContext)
                lastPresenceActive = nil
                JevIngress.shared.boundary()
                previous = safeContext
                consecutiveCaptureFailures = 0
                captureHealth.setSuppression(.secureInput)
                finish(safeContext); return
            }
            publishesFocusSynchronously = false
            provider.requestCapture(blockingSink: blockingObservationEnabled ? blockingSink : nil, includePresence: true) { [weak self] captured in
                guard let self, self.sampleGeneration == generation else { finish(nil); return }
                guard let captured else {
                    self.markObservationUnavailable()
                    self.consecutiveCaptureFailures = min(self.consecutiveCaptureFailures + 1, 1_000)
                    self.captureHealth.markAXFailure()
                    JevIngress.shared.boundary()
                    finish(nil); return
                }
                finish(self.publish(captured))
            }
        }

        private func publish(_ captured: ContextSnapshot) -> ContextSnapshot? {
            var focusSample = FocusObservation(at: Date(), observing: false)
            defer { concentrationSink?(focusSample) }
            consecutiveCaptureFailures = 0
            observationUnavailable = false
            guard let presence = captured.foregroundUsage else { return nil }
            let observedAt = presence.observedAt
            let observedIdleSeconds = presence.idleSeconds
            guard state.isCapturing, ForegroundSessionAvailability.isAvailable(),
                  !IsSecureEventInputEnabled() else {
                markObservationUnavailable(); return nil
            }
            let current = captured.withForegroundUsage(presence)
            setLatest(current)
            let evidence = presence.evidence
            JevIngress.shared.observeContext(current, foregroundEvidence: evidence, presence: presence)
            jevVisibleContext.observe(current, presence: presence) { [weak self] completion in
                guard let self else { completion(nil); return }
                self.requestEvidence(completion: completion)
            }
            captureHealth.setSuppression(current.suppressionReason)
            if current.suppressionReason == .accessibilityUnavailable {
                captureHealth.markAXFailure()
            } else if current.suppressionReason == nil, provider.lastCaptureProvedExternalAX {
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

            if concentrationSink != nil {
                let label = GoalongWorkContext.Label(application: current.app.name, bundleIdentifier: current.app.bundleIdentifier,
                    host: current.url?.host, title: GoalongWorkContext.displayTitle(current.window?.title))
                let assignment = MainActor.assumeIsolated { GoalongWorkStore.shared.verdicts.assignment(for: label.key) }
                focusSample = FocusObservation(at: observedAt, observing: true, available: true, idleSeconds: observedIdleSeconds, context: label.key, verdict: assignment?.verdict, task: assignment?.task)
            }
            let activityMetadata = presence.metadata(at: observedAt)
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

            // A configurable diagnostic heartbeat must never create holes in time
            // accounting. One fresh sample every <=30s also covers quiet reading.
            let heartbeatInterval = Self.heartbeatInterval(configuredSeconds: configManager.config.heartbeatSeconds)
            if evidence != lastForegroundEvidence || presence.isActive != lastPresenceActive
                || presence.idleLimitSeconds != lastIdleLimit
                || observedAt.timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
                recorder.record(
                    kind: .heartbeat,
                    context: current,
                    metadata: activityMetadata,
                    timestamp: observedAt
                )
                lastHeartbeat = observedAt
            }
            lastForegroundEvidence = evidence
            lastPresenceActive = presence.isActive
            lastIdleLimit = presence.idleLimitSeconds

            previous = current
            return current
        }

        static func heartbeatInterval(configuredSeconds: Int) -> TimeInterval {
            min(ForegroundUsageObservation.heartbeatInterval, TimeInterval(max(10, configuredSeconds)))
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

        private func requestEvidence(completion: @escaping (AXContextEvidence?) -> Void) {
            sampleNow { [weak self] snapshot in
                completion(snapshot.map { AXContextEvidence(snapshot: $0, boundary: self?.provider.lastCaptureBoundary) })
            }
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

        func recordFocusLimit(_ mark: FocusLimitMark) {
            guard historyRequested, state.isCapturing, !provider.historyPrivacyStopped else { return }
            recorder.record(kind: .diagnostic, metadata: ["goalong.focus.limit": mark.kind, "goalong.focus.period": mark.period], timestamp: mark.at)
        }
        private func idleSeconds() -> Double {
            UserInputActivityClock.secondsSinceLastInput()
        }
    }
#endif

#if os(macOS) && DEBUG
// Test fixture: configure observation without installing app/AX observers.
extension ContextMonitor {
    func configureForAdversarialReview(blocking: Bool, polling: Bool) {
        historyRequested = true
        blockingObservationEnabled = blocking
        pollingIsActive = polling
        if !polling { timer?.invalidate(); timer = nil }
    }
    var hasPollForAdversarialReview: Bool { timer != nil }
}
#endif
