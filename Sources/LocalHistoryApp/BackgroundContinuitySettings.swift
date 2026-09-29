#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    struct BackgroundContinuitySettings: View {
        @AppStorage(BackgroundContinuityPreferences.keepRunningKey) private var keepRunning = true
        @StateObject private var login = LaunchAtLoginManager()
        @ObservedObject private var continuity = BackgroundContinuityController.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Enregistrement en arrière-plan", subtitle: "Goalong reste actif sans garder sa fenêtre ouverte.")
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Garder Goalong actif en arrière-plan", isOn: $keepRunning)
                            .toggleStyle(.switch)
                        Text("Activé par défaut. Fermer la fenêtre laisse vos sources actives ; Quitter demande confirmation avant d’arrêter. Désactivez pour quitter à la fermeture de la dernière fenêtre. Aucun service supplémentaire n’est installé et votre Mac peut toujours se mettre en veille.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Ouvrir Goalong à l’ouverture de session", isOn: Binding(
                            get: { login.isRegistered },
                            set: { _ = login.setUserPreference($0, surface: .settings) }
                        )).toggleStyle(.switch).disabled(login.isChanging)
                        Text(login.statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        if consents.isEnabled(.launchAtLogin) && !login.isEnabled {
                            Text("Le démarrage automatique demande votre attention. Goalong ne modifie jamais un choix fait dans Réglages Système.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if login.requiresApproval || login.state == .unavailable {
                            Button("Ouvrir « Ouverture »") { login.openLoginItemsSettings() }
                                .buttonStyle(.bordered)
                        }
                        if let message = login.message {
                            Text(message).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if let notice = continuity.interruptionNotice {
                            Divider()
                            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                            Button("Masquer") { continuity.dismissInterruptionNotice() }
                                .buttonStyle(.bordered)
                        }
                        Text("Ces options n’activent aucune source supplémentaire et ne reprennent pas une pause. Après un plantage ou une fermeture forcée, il faut rouvrir Goalong.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { login.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login.refresh()
            }
        }
    }
#endif
