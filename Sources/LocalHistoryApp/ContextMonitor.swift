#if os(macOS)
    import CoreGraphics
    import Foundation
    import LocalHistoryCore

    final class ContextMonitor {
        private let provider: ContextProvider
        private let recorder: EventRecorder
        private let state: CaptureState
        private let configManager: ConfigManager

        private var timer: Timer?
        private var previous: ContextSnapshot?
        private var lastHeartbeat = Date.distantPast

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
            configManager: ConfigManager
        ) {
            self.provider = provider
            self.recorder = recorder
            self.state = state
            self.configManager = configManager
        }

        func start() {
            stop()
            let interval = max(0.25, Double(configManager.config.pollIntervalMilliseconds) / 1_000.0)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.sampleNow()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            sampleNow()
            ActivityAnalysisRuntime.shared.start(
                recorder: recorder,
                state: state,
                configManager: configManager,
                currentContext: { [weak self] in self?.latestSnapshot }
            )
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            ActivityAnalysisRuntime.shared.stop()
        }

        func resetAndSample() {
            previous = nil
            sampleNow()
        }

        func sampleNow() {
            guard state.isCapturing else { return }
            guard let current = provider.capture() else { return }
            setLatest(current)

            if let reason = current.suppressionReason {
                if previous?.suppressionReason != reason || previous?.app != current.app {
                    recorder.record(
                        kind: .captureSuppressed,
                        context: current,
                        suppressionReason: reason,
                        message: suppressionMessage(for: reason)
                    )
                }
                previous = current
                return
            }

            if let previousReason = previous?.suppressionReason {
                recorder.record(
                    kind: .captureResumed,
                    context: current,
                    message: "Capture resumed after \(previousReason.rawValue)"
                )
            }

            if previous?.app != current.app {
                recorder.record(kind: .applicationActivated, context: current)
            }

            if previous?.window != current.window {
                recorder.record(kind: .windowChanged, context: current)
            }

            if previous?.url != current.url, current.url != nil {
                recorder.record(kind: .urlChanged, context: current)
            }

            if previous?.focusedElement != current.focusedElement {
                recorder.record(kind: .focusChanged, context: current)
            }

            let heartbeatInterval = TimeInterval(max(10, configManager.config.heartbeatSeconds))
            if Date().timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
                recorder.record(
                    kind: .heartbeat,
                    context: current,
                    metadata: ["idle_seconds": String(format: "%.1f", idleSeconds())]
                )
                lastHeartbeat = Date()
            }

            previous = current
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
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        }
    }
#endif
