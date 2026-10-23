#if os(macOS)
    import AppKit
    import Combine
    import Foundation

    /// Runs inside Goalong. No helper, LaunchAgent, daemon, or relaunch loop.
    @MainActor
    final class BackgroundContinuityController: ObservableObject {
        static let shared = BackgroundContinuityController()
        static let interruptionNoticeText = "La session précédente ne s’est pas fermée correctement. Vérifiez l’état de l’enregistrement. L’activité pendant la fermeture de Goalong ne peut pas être reconstituée."
        @Published private(set) var interruptionNotice: String?
        private let preferences = BackgroundContinuityPreferences()
        private let journal = BackgroundSessionJournal()
        private var activity: NSObjectProtocol?
        private var preferenceObserver: NSObjectProtocol?
        private var heartbeatTimer: Timer?
        private var hasEnabledSources = false
        private var started = false

        /// The banner after an unclean end; none when the blocking guard reopened Goalong.
        static func interruptionNotice(quietRelaunch: Bool) -> String? { quietRelaunch ? nil : interruptionNoticeText }

        /// `quietRelaunch`: the blocking guard reopened Goalong after a kill; the member chose the block,
        /// so no "previous session" banner, only a diagnostics line (spec K §6).
        func start(hasEnabledSources: Bool, quietRelaunch: Bool = GoalongGuardFiles.isGuardRelaunch) {
            guard !started else { update(hasEnabledSources: hasEnabledSources); return }
            started = true
            if journal.begin() {
                interruptionNotice = Self.interruptionNotice(quietRelaunch: quietRelaunch)
                Diagnostics.write(quietRelaunch ? "Previous Goalong session was killed during a severe block; reopened by the guard"
                                                : "Previous Goalong session ended without a clean shutdown; cause unknown")
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
