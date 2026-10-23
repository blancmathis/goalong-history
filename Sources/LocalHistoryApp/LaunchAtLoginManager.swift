#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import ServiceManagement

    @MainActor
    final class LaunchAtLoginManager: ObservableObject {
        enum State: Equatable {
            case enabled
            case disabled
            case requiresApproval
            case unavailable
        }

        @Published private(set) var state: State = .disabled
        @Published private(set) var isChanging = false
        @Published private(set) var message: String?

        private var reading = false
        private var generation = 0

        init() {
            state = Self.state(for: SMAppService.mainApp.status)
        }

        var isEnabled: Bool {
            state == .enabled
        }

        var isRegistered: Bool {
            state == .enabled || state == .requiresApproval
        }

        var requiresApproval: Bool {
            state == .requiresApproval
        }

        var statusTitle: String {
            switch state {
            case .enabled:
                return "Démarre automatiquement"
            case .requiresApproval:
                return "Autorisation requise"
            case .disabled:
                return "Démarre seulement à l’ouverture"
            case .unavailable:
                return "État indisponible"
            }
        }

        var statusDetail: String {
            switch state {
            case .enabled:
                return "\(ProductIdentity.displayName) sera prêt après chaque ouverture de session."
            case .requiresApproval:
                return "Autorisez \(ProductIdentity.displayName) dans Réglages Système → Général → Ouverture."
            case .disabled:
                return "Vous pouvez toujours ouvrir \(ProductIdentity.displayName) vous-même à tout moment."
            case .unavailable:
                return "macOS n’a pas pu lire l’état d’ouverture à la connexion."
            }
        }

        nonisolated static func state(for status: SMAppService.Status) -> State {
            switch status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered: return .disabled
            case .notFound: return .unavailable
            @unknown default: return .unavailable
            }
        }

        /// `SMAppService.status` is a synchronous XPC round trip: read it off the main thread,
        /// one read at a time, and drop a result older than a change made meanwhile.
        func refresh() {
            guard !reading else { return }
            reading = true
            let started = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let next = Self.state(for: SMAppService.mainApp.status)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reading = false
                    if self.generation == started { self.state = next }
                }
            }
        }

        /// A user action needs the result now (the caller reads `requiresApproval` right after).
        private func readNow() {
            generation += 1
            state = Self.state(for: SMAppService.mainApp.status)
        }

        /// Same rule as Settings: a locked block keeps Goalong at login until it ends.
        var heldByBlocking: Bool {
            isRegistered && BlockingRuntime.shared.controller?.hasLocks == true
        }

        @discardableResult
        func setEnabled(_ enabled: Bool) -> Bool {
            guard GoalongLoginItemGate.isAllowed else {
                message = "Goalong Dev ne gère pas l’ouverture à la connexion : c’est le rôle de Goalong installé."
                return false
            }
            isChanging = true
            message = nil
            defer {
                isChanging = false
                readNow()
            }

            do {
                let service = SMAppService.mainApp
                if enabled {
                    switch service.status {
                    case .enabled, .requiresApproval:
                        break
                    case .notRegistered, .notFound:
                        try service.register()
                    @unknown default:
                        try service.register()
                    }
                } else {
                    switch service.status {
                    case .notRegistered, .notFound:
                        break
                    case .enabled, .requiresApproval:
                        try service.unregister()
                    @unknown default:
                        try service.unregister()
                    }
                }
                return true
            } catch {
                message = (error as NSError).localizedDescription
                return false
            }
        }

        func suggestedOnboardingPreference(defaults: UserDefaults = .standard) -> Bool {
            let consent = GoalongCapabilityConsentStore.shared.document.consent(for: .launchAtLogin)
            return BackgroundContinuityPreferences.suggestedLoginPreference(
                storedPreference: defaults.object(forKey: "launchAtLoginPreference") as? Bool,
                consentEnabled: consent.enabled,
                consentWasRecorded: consent.changedAt != nil,
                systemEnabled: isRegistered
            )
        }

        @discardableResult
        func setUserPreference(_ enabled: Bool, surface: GoalongConsentSurface) -> Bool {
            guard GoalongCapabilityConsentStore.shared.set(.launchAtLogin, enabled: enabled, surface: surface) else {
                message = "Votre préférence de démarrage n’a pas pu être enregistrée. Réessayez."
                return false
            }
            // Save explicit opt-outs even when the previous consent was already off.
            // Never re-register in refresh(), after a wake, or merely after an update.
            UserDefaults.standard.set(enabled, forKey: "launchAtLoginPreference")
            let preferences = BackgroundContinuityPreferences()
            if BackgroundContinuityPreferences.keepsLoginItem(enabled: enabled, registered: isRegistered,
                                                              lockActive: BlockingRuntime.shared.controller?.hasLocks == true) {
                // Never escape a lock by a reboot. Blocage removes the item when the lock ends.
                preferences.blockingForcedLogin = true
                message = Self.heldMessage
                return true
            }
            // An explicit choice belongs to the member: Blocage must not undo it later.
            preferences.blockingForcedLogin = false
            return setEnabled(enabled)
        }

        static let heldMessage = "Un blocage verrouillé est en cours : Goalong reste ouvert à la connexion jusqu’à la fin."


        func openLoginItemsSettings() {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
#endif
