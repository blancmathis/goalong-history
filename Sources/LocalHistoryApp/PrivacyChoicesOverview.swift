#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct PrivacyChoicesOverview: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @State private var analysisSelection = GoalongAnalysisSelection.load()
    @State private var showingSharing = false
    @State private var showingRetention = false
    @State private var retentionSummary = ""
    @State private var retentionEnabled = false
    @State private var pause = GoalongGlobalPause.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Vos choix appliqués", systemImage: "slider.horizontal.3")
                        .font(LHTheme.cardTitleFont)
                    ForEach([GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]) { capability in
                        HStack {
                            Text(capability.title).font(.system(size: 13))
                            Spacer()
                            Text(consents.isEnabled(capability) ? "Source activée" : "Source désactivée")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Divider()
                    Text(model.appliedSettings.recordingSummary).font(.system(size: 13))
                    Text(model.appliedSettings.capturePrivateBrowsing
                         ? "Fenêtres privées détectées : incluses selon votre choix."
                         : "Fenêtres privées détectées : exclues. La détection dépend du navigateur ; la pause reste le plus sûr pour une activité sensible.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    HStack(spacing: 12) {
                        // During the global pause, « Reprendre tout le suivi » is the one lime action of the screen.
                        Button("Modifier l’enregistrement") { model.openRecordingSettings() }
                            .modifier(GoalongMainActionStyle(primary: !pause.blocksActivity))
                        Button("Gérer les exclusions") { model.openApplicationsSettings() }.buttonStyle(LHSecondaryButtonStyle())
                        Button("Gérer les sources") { model.selectSection(.settings) }.buttonStyle(LHSecondaryButtonStyle())
                    }
                    // UI-9 (16): the card shows the choices; the explanations stay one click away.
                    GoalongDisclosureGroup("En savoir plus") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ce résumé montre les réglages enregistrés. Votre accord par source, les accès macOS et la disponibilité réelle des données sont distincts.")
                            Text("Les filtres d’enregistrement s’appliquent à l’historique de ce Mac, pas au Temps d’écran d’Apple ni aux conversations IA d’origine. Chaque source et chaque envoi a ses propres réglages.")
                        }.font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Ce qui peut quitter ce Mac", systemImage: "arrow.up.doc")
                        .font(LHTheme.cardTitleFont)
                    Text(Self.dailySendingText(enabled: sender.enabled, paused: sender.savedConfiguration?.paused == true))
                        .font(.system(size: 13, weight: .semibold))
                    if sender.savedConfiguration != nil {
                        Text(sender.status).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Text(Self.chatGPTAnalysisText(consented: consents.isEnabled(.chatGPTAnalysis),
                                                  selection: analysisSelection, policy: exclusions.policy))
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    HStack(spacing: 12) {
                        Button("Vérifier l’envoi au site…") { showingSharing = true }.buttonStyle(LHSecondaryButtonStyle())
                        if sender.enabled {
                            Button("Mettre en pause l’envoi quotidien") { sender.stop() }.buttonStyle(LHSecondaryButtonStyle())
                        }
                    }
                    GoalongDisclosureGroup("En savoir plus") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Envoyer au site et partager avec d’autres personnes sont deux actions différentes : les règles de destinataires du site s’appliquent après l’envoi. Un export local crée un fichier ; toute personne qui le reçoit peut en garder une copie.")
                            Text("Mettre en pause, déconnecter ou supprimer localement n’efface pas les données déjà reçues ; un transfert en cours peut se terminer. Gérez les destinataires et supprimez les données distantes sur le site ou chez le service. La recherche de mises à jour contacte le serveur des versions sans envoyer votre activité.")
                        }.font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("La conservation est un choix distinct", systemImage: "calendar.badge.clock")
                        .font(LHTheme.cardTitleFont)
                    Text(retentionEnabled ? "Le nettoyage automatique est activé pour les règles ci-dessous." : "Le nettoyage automatique est désactivé : les données locales restent jusqu’à leur suppression.")
                        .font(.system(size: 13, weight: .medium))
                    if retentionEnabled { Text(retentionSummary).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText) }
                    Button("Choisir la conservation par type de données…") { showingRetention = true }.buttonStyle(LHSecondaryButtonStyle())
                    GoalongDisclosureGroup("En savoir plus") {
                        Text("Les fichiers d’activité sont lisibles par votre compte macOS : les permissions de fichiers ne sont pas un chiffrement. La conservation ne couvre pas tout : données Apple, conversations IA d’origine, exports, sauvegardes et copies distantes ont leurs propres réglages. Les bilans ChatGPT s’effacent avec l’historique détaillé des jours concernés.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { refreshRetention(); analysisSelection = .load(); pause = .load() }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
        .onReceive(NotificationCenter.default.publisher(for: .goalongRetentionPolicyDidChange)) { _ in refreshRetention() }
        .sheet(isPresented: $showingSharing) { GoalongWebsiteSharingSheet().goalongControls() }
        .sheet(isPresented: $showingRetention, onDismiss: refreshRetention) {
            HistoryRetentionSettingsSheet(legacyRetentionDays: model.appliedSettings.retentionDays).goalongControls()
        }
    }
    /// UI-54: the real state, never « désactivé ou en pause ».
    nonisolated static func dailySendingText(enabled: Bool, paused: Bool) -> String {
        enabled ? "L’envoi quotidien au site est activé."
            : paused ? "L’envoi quotidien au site est en pause." : "L’envoi quotidien au site est désactivé."
    }
    /// Same state as the « Autoriser les analyses » switch in Réglages › Analyse ChatGPT.
    nonisolated static func chatGPTAnalysisText(consented: Bool, selection: GoalongAnalysisSelection, policy: GoalongPrivacyPolicy) -> String {
        selection.allowsAnalysis(consented: consented, policy: policy)
            ? "L’analyse ChatGPT est activée. Les analyses lancées ou planifiées peuvent envoyer le contexte choisi au service connecté."
            : "L’analyse ChatGPT est désactivée. L’activer est un choix distinct de l’enregistrement local."
    }
    private func refreshRetention() {
        let store = HistoryRetentionStore(legacyRetentionDays: model.appliedSettings.retentionDays)
        retentionEnabled = store.isAutomaticCleanupEnabled
        retentionSummary = store.policy.retentionDescription
    }
}

/// Lime only when the button is the screen's one main action (DESIGN §9).
struct GoalongMainActionStyle: ViewModifier {
    var primary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if primary { content.buttonStyle(LHPrimaryButtonStyle()) } else { content.buttonStyle(LHSecondaryButtonStyle()) }
    }
}
#endif
