#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct PrivacyChoicesOverview: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @State private var showingSharing = false
    @State private var showingRetention = false
    @State private var retentionSummary = ""
    @State private var retentionEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Vos choix appliqués", systemImage: "slider.horizontal.3")
                        .font(LHTheme.cardTitleFont)
                    Text("Ce résumé montre les réglages enregistrés. Votre accord par source, les accès macOS et la disponibilité réelle des données sont distincts.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
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
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Modifier l’enregistrement et les exclusions") { model.openRecordingSettings() }.buttonStyle(LHPrimaryButtonStyle())
                        Button("Gérer les sources") { model.selectSection(.settings) }.buttonStyle(LHSecondaryButtonStyle())
                    }
                    Text("Les filtres d’enregistrement s’appliquent à l’historique de ce Mac, pas au Temps d’écran d’Apple ni aux conversations IA d’origine. Chaque source et chaque envoi a ses propres réglages.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Ce qui peut quitter ce Mac", systemImage: "arrow.up.doc")
                        .font(LHTheme.cardTitleFont)
                    Text(sender.enabled ? "L’envoi quotidien au site est activé." : "L’envoi quotidien au site est désactivé ou en pause.")
                        .font(.system(size: 13, weight: .semibold))
                    if sender.savedConfiguration != nil {
                        Text(sender.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(consents.isEnabled(.chatGPTAnalysis)
                         ? "L’analyse ChatGPT est activée. Les analyses lancées ou planifiées peuvent envoyer le contexte choisi au service connecté."
                         : "L’analyse ChatGPT est désactivée. L’activer est un choix distinct de l’enregistrement local.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Envoyer au site et partager avec d’autres personnes sont deux actions différentes : les règles de destinataires du site s’appliquent après l’envoi. Un export local crée un fichier ; toute personne qui le reçoit peut en garder une copie.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Vérifier l’envoi au site…") { showingSharing = true }.buttonStyle(LHSecondaryButtonStyle())
                        if sender.enabled {
                            Button("Mettre en pause l’envoi quotidien") { sender.stop() }.buttonStyle(LHSecondaryButtonStyle())
                        }
                    }
                    Text("Mettre en pause, déconnecter ou supprimer localement n’efface pas les données déjà reçues ; un transfert en cours peut se terminer. Gérez les destinataires et supprimez les données distantes sur le site ou chez le service. La recherche de mises à jour contacte le serveur des versions sans envoyer votre activité.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("La conservation est un choix distinct", systemImage: "calendar.badge.clock")
                        .font(LHTheme.cardTitleFont)
                    Text(retentionEnabled ? "Le nettoyage automatique est activé pour les règles ci-dessous." : "Le nettoyage automatique est désactivé : les données locales restent jusqu’à leur suppression.")
                        .font(.system(size: 13, weight: .medium))
                    if retentionEnabled { Text(retentionSummary).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Button("Choisir la conservation par type de données…") { showingRetention = true }.buttonStyle(LHSecondaryButtonStyle())
                    Text("Les fichiers d’activité sont lisibles par votre compte macOS : les permissions de fichiers ne sont pas un chiffrement. La conservation ne couvre pas tout : données Apple, conversations IA d’origine, historique des analyses ChatGPT, exports, sauvegardes et copies distantes ont leurs propres réglages.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { refreshRetention() }
        .onReceive(NotificationCenter.default.publisher(for: .goalongRetentionPolicyDidChange)) { _ in refreshRetention() }
        .sheet(isPresented: $showingSharing) { GoalongWebsiteSharingSheet().goalongControls() }
        .sheet(isPresented: $showingRetention, onDismiss: refreshRetention) { HistoryRetentionSettingsSheet().goalongControls() }
    }
    private func refreshRetention() {
        let store = HistoryRetentionStore(legacyRetentionDays: model.appliedSettings.retentionDays)
        retentionEnabled = store.isAutomaticCleanupEnabled
        retentionSummary = store.policy.retentionDescription
    }
}
#endif
