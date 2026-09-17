#if os(macOS)
    import AppKit
    import Combine
    import Foundation

    /// Runs inside Goalong. No helper, LaunchAgent, daemon, or relaunch loop.
    @MainActor
    final class BackgroundContinuityController: ObservableObject {
        static let shared = BackgroundContinuityController()
        @Published private(set) var interruptionNotice: String?
        private let preferences = BackgroundContinuityPreferences()
        private let journal = BackgroundSessionJournal()
        private var activity: NSObjectProtocol?
        private var preferenceObserver: NSObjectProtocol?
        private var heartbeatTimer: Timer?
        private var hasEnabledSources = false
        private var started = false

        func start(hasEnabledSources: Bool) {
            guard !started else { update(hasEnabledSources: hasEnabledSources); return }
            started = true
            if journal.begin() {
                interruptionNotice = "The previous session did not shut down cleanly. Check recording status. Activity while Goalong was closed cannot be reconstructed."
                Diagnostics.write("Previous Goalong session ended without a clean shutdown; cause unknown")
            }
            Diagnostics.write("Goalong runtime started")
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateActivity() }
            }
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.journal.heartbeat() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            heartbeatTimer = timer
            update(hasEnabledSources: hasEnabledSources)
        }

        func update(hasEnabledSources: Bool) {
            self.hasEnabledSources = hasEnabledSources
            updateActivity()
        }

        private func updateActivity() {
            let needed = started && hasEnabledSources && preferences.keepRunning
            if needed && activity == nil {
                // These options protect useful background work from automatic/sudden
                // termination. They do NOT prevent sleep, logout, Quit, or Force Quit.
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
                    reason: "Goalong is maintaining the sources enabled by the user"
                )
            } else if !needed, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }

        func stop(reason: String) {
            guard started else { return }
            started = false
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
            preferenceObserver = nil
            updateActivity()
            journal.finish(reason: reason)
            Diagnostics.write("Goalong runtime stopped: \(reason)")
        }

        func dismissInterruptionNotice() { interruptionNotice = nil }
    }
#endif
