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
                        Text("Recommandé : fermer la fenêtre n’arrête pas l’enregistrement, et Quitter demande confirmation. Aucun service supplémentaire n’est installé ; votre Mac peut toujours se mettre en veille.")
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
                            Button("Ouvrir les éléments de connexion…") { login.openLoginItemsSettings() }
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
                        Text("Ces options n’activent aucune source et ne reprennent pas une pause.")
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
