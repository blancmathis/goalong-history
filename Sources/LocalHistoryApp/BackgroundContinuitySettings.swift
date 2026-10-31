#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    struct BackgroundContinuitySettings: View {
        static let loginTitle = "Ouvrir Goalong à l’ouverture de session"
        static let unknownStateTitle = "État inconnu"
        static let needsAttentionText = "Le démarrage automatique demande votre attention. Goalong ne modifie jamais un choix fait dans Réglages Système."
        /// UI-15A (59): the row already says « État inconnu »; the note says what to check, not the same fact again.
        static var unknownStateText: String { "Vérifiez Goalong dans \(LoginItemsPanel.path)." }

        /// The one orange line under the login row (UI-43): a failed change first, then an unread state,
        /// then a consent macOS does not honour yet. Never two warnings together.
        enum LoginWarning: Equatable {
            case failure(String)
            case unknownState
            case needsAttention
        }

        nonisolated static func loginWarning(message: String?, state: LaunchAtLoginManager.State,
                                             consentEnabled: Bool) -> LoginWarning? {
            if let message { return .failure(message) }
            if LaunchAtLoginManager.switchValue(for: state) == nil { return .unknownState }
            if consentEnabled && state != .enabled { return .needsAttention }
            return nil
        }

        private var loginWarning: LoginWarning? {
            Self.loginWarning(message: login.message, state: login.state, consentEnabled: consents.isEnabled(.launchAtLogin))
        }
        @AppStorage(BackgroundContinuityPreferences.keepRunningKey) private var keepRunning = true
        @StateObject private var login = LaunchAtLoginManager()
        @ObservedObject private var continuity = BackgroundContinuityController.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @ObservedObject private var blocking = BlockingRuntime.shared

        private var blockingHoldsLogin: Bool { login.isRegistered && blocking.controller?.hasLocks == true }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                // Goalong stays active even while recording is off: the title names the app, not the recording (UI-43).
                SectionTitle(title: "Goalong en arrière-plan", subtitle: "Ce qui se passe quand la fenêtre se ferme et quand le Mac démarre.")
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Garder Goalong actif en arrière-plan", isOn: $keepRunning)
                            .toggleStyle(.goalongSwitch)
                        // UI-12B (43): one sentence, without « Recommandé ».
                        GoalongHelpText(lead: "Fermer la fenêtre n’arrête pas l’enregistrement, et Quitter demande confirmation.",
                                        more: "Aucun service supplémentaire n’est installé. Votre Mac peut toujours se mettre en veille.")
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
                        }
                        // UI-12B (43): under the switch it concerns, in plain words.
                        Text("L’ouverture à la session n’allume aucune source et ne reprend pas une pause.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        switch loginWarning {
                        case .failure(let message): WarningNote(text: message)
                        case .unknownState: WarningNote(text: Self.unknownStateText)
                        case .needsAttention: WarningNote(text: Self.needsAttentionText)
                        case nil: EmptyView()
                        }
                        if login.requiresApproval || login.state == .unavailable {
                            Button("Ouvrir Réglages Système…") { login.openLoginItemsSettings() }
                                .buttonStyle(LHSecondaryButtonStyle())
                        }
                        if let notice = continuity.interruptionNotice {
                            Divider()
                            WarningNote(text: notice)
                            Button("Masquer") { continuity.dismissInterruptionNotice() }
                                .buttonStyle(LHSecondaryButtonStyle())
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { login.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login.refresh()
            }
        }
    }

    /// UI-15A (20, 43, 59): the glyph carries the amber, the sentence stays in ink and readable (DESIGN §9).
    private struct WarningNote: View {
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.warning)
                    .frame(width: 14).accessibilityHidden(true)
                Text(text).font(.system(size: 12)).foregroundStyle(LHTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LHTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
        }
    }
#endif
