#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    struct BackgroundContinuitySettings: View {
        static let loginTitle = "Ouvrir Goalong à l’ouverture de session"
        static let unknownStateTitle = "État inconnu"
        @AppStorage(BackgroundContinuityPreferences.keepRunningKey) private var keepRunning = true
        @StateObject private var login = LaunchAtLoginManager()
        @ObservedObject private var continuity = BackgroundContinuityController.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @ObservedObject private var blocking = BlockingRuntime.shared

        private var blockingHoldsLogin: Bool { login.isRegistered && blocking.controller?.hasLocks == true }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                // Goalong stays active even while recording is off: the title names the app, not the recording (UI-43).
                SectionTitle(title: "Goalong en arrière-plan", subtitle: "Goalong reste actif sans garder sa fenêtre ouverte.")
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Garder Goalong actif en arrière-plan", isOn: $keepRunning)
                            .toggleStyle(.goalongSwitch)
                        Text("Recommandé : fermer la fenêtre n’arrête pas l’enregistrement, et Quitter demande confirmation. Aucun service supplémentaire n’est installé ; votre Mac peut toujours se mettre en veille.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        Divider()
                        if login.switchValue != nil {
                            Toggle(Self.loginTitle, isOn: Binding(
                                get: { login.isRegistered },
                                set: { _ = login.setUserPreference($0, surface: .settings) }
                            )).toggleStyle(.goalongSwitch).disabled(login.isChanging || blockingHoldsLogin)
                            Text(blockingHoldsLogin
                                 ? LaunchAtLoginManager.heldMessage
                                 : login.statusDetail)
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        } else {
                            // macOS gave no state: say so on the row instead of an "off" switch (UI-43).
                            HStack(alignment: .center, spacing: 16) {
                                Text(Self.loginTitle).frame(maxWidth: .infinity, alignment: .leading)
                                // UI-9 (59): the glyph carries the colour, the word stays in ink (DESIGN §9).
                                Label {
                                    Text(Self.unknownStateTitle).foregroundStyle(LHTheme.text)
                                } icon: {
                                    Image(systemName: "questionmark.circle").foregroundStyle(LHTheme.warning)
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("settings-login-unknown")
                            GoalongNote(login.statusDetail)
                        }
                        if consents.isEnabled(.launchAtLogin) && !login.isEnabled {
                            Text("Le démarrage automatique demande votre attention. Goalong ne modifie jamais un choix fait dans Réglages Système.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if login.requiresApproval || login.state == .unavailable {
                            Button("Ouvrir Réglages Système…") { login.openLoginItemsSettings() }
                                .buttonStyle(LHSecondaryButtonStyle())
                        }
                        if let message = login.message {
                            Text(message).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if let notice = continuity.interruptionNotice {
                            Divider()
                            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                            Button("Masquer") { continuity.dismissInterruptionNotice() }
                                .buttonStyle(LHSecondaryButtonStyle())
                        }
                        Text("Ces options n’activent aucune source et ne reprennent pas une pause.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
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
