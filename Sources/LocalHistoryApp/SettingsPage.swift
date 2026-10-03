#if os(macOS)
import SwiftUI
import AppKit

@MainActor struct SettingsPage: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    @State private var search = ""
    @State private var showingRetention = false
    @State private var showingDeveloperProjects = false
    @State private var pendingPrivate = false
    @State private var pendingUnredacted = false
    private var pane: SettingsPane {
        get { model.settingsPane }
        nonmutating set { model.settingsPane = newValue }
    }
    private var recording: Binding<DashboardSettingsDraft> {
        Binding(get: { model.appliedSettings }, set: { _ = model.applyRecordingChoice($0) })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(pane.title).goalongPageTitle()
                content
            }
            .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(pane)
        .safeAreaInset(edge: .top, spacing: 0) {
            if pane != .home {
                SettingsBackBar(title: pane.parent == .home ? "Retour aux réglages" : "Retour à « \(pane.parent.title) »") {
                    pane = pane.parent
                }
            }
        }
        .background(LHTheme.pageBackground)
        .sheet(isPresented: $showingRetention) { HistoryRetentionSettingsSheet().goalongControls() }
        .sheet(isPresented: $showingDeveloperProjects) { GoalongDeveloperProjectsSheet().goalongControls() }
        .alert("Inclure la navigation privée ?", isPresented: $pendingPrivate) {
            Button("Annuler", role: .cancel) {}
            Button("Inclure") { var next = model.appliedSettings; next.capturePrivateBrowsing = true; _ = model.applyRecordingChoice(next) }
        } message: { Text("Les fenêtres privées détectées pourront être enregistrées sur ce Mac. Aucun envoi n’est autorisé par ce choix.") }
        .alert("Conserver les paramètres des adresses ?", isPresented: $pendingUnredacted) {
            Button("Annuler", role: .cancel) {}
            Button("Conserver les valeurs") { var next = model.appliedSettings; next.redactAllURLQueryValues = false; _ = model.applyRecordingChoice(next) }
        } message: { Text("Les paramètres peuvent contenir des recherches ou des informations personnelles. Ils seront conservés sur ce Mac lorsque l’enregistrement des adresses est activé.") }
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .home:
            GoalongSearchField("Rechercher un réglage…", text: $search, accessibilityLabel: "Rechercher un réglage")
            // While searching, results come first; the three main cards return afterwards.
            if search.isEmpty { GoalongDataStatus(model: model) }
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(visiblePanes, id: \.self) { item in
                        GoalongSettingsLink(title: item.title, value: summary(item), symbol: item.symbol) { pane = item }
                            .accessibilityIdentifier("settings-\(item.identifier)")
                        if item != visiblePanes.last { GoalongRowDivider() }
                    }
                    if visiblePanes.isEmpty && !SettingsPane.matchesStartup(search) {
                        Text("Aucun réglage ne correspond à cette recherche.").font(.system(size: 13))
                            .foregroundStyle(LHTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(LHTheme.cardInset)
                    }
                }
            }
            if search.isEmpty || SettingsPane.matchesStartup(search) { BackgroundContinuitySettings() }
            if search.isEmpty {
                GoalongDisclosureGroup("Confidentialité · tout suspendre") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("À réserver aux activités sensibles. Cet arrêt suspend l’historique, les analyses et les envois. Pour une simple pause des rappels, utilisez « Faire une pause » dans Surveillance temps réel : l’historique continue.")
                            .font(.callout).foregroundStyle(.secondary)
                        GoalongGlobalPauseControl(model: model)
                    }.padding(.top, 12)
                }.accessibilityIdentifier("settings-privacy-stop")
                VStack(alignment: .leading, spacing: 16) {
                    GoalongUpdateStatusRow()
                    Button("Signaler un problème…") { SupportRequestController.shared.present() }
                        .buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("settings-report-problem")
                }.font(.system(size: 13))
            }
        case .recording:
            GoalongRecordingCoverageNotice(model: model)
            GoalongSettingsGroup(title: "Sur ce Mac") {
                SourceActivationToggle(capability: .localComputerHistory) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enregistrer mon activité").font(.system(size: 14, weight: .medium))
                        Text("Reste sur ce Mac : enregistrer n’autorise aucun envoi. Le démarrage à l’ouverture de session se règle sur l’accueil des Réglages.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GoalongSettingsGroup(title: "Suivi du temps d’écran") {
                Text("Lire, réfléchir ou regarder sans cliquer compte aussi. Seule la fenêtre au premier plan est suivie.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Sans interaction, continuer à compter", selection: recording.foregroundIdleSeconds) {
                    Text("2 minutes").tag(120)
                    Text("5 minutes · recommandé").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1_800)
                    Text("Tant que l’écran reste allumé").tag(0)
                    if ![0, 120, 300, 600, 900, 1_800].contains(model.appliedSettings.foregroundIdleSeconds) {
                        Text("\(model.appliedSettings.foregroundIdleSeconds) secondes · personnalisé")
                            .tag(model.appliedSettings.foregroundIdleSeconds)
                    }
                }.accessibilityIdentifier("settings-foreground-idle-limit")
                Text("Le délai repart à chaque interaction ; augmentez-le pour de longues lectures. Appels et vidéos au premier plan continuent au-delà. Verrouillage, veille et arrêt de confidentialité interrompent toujours le suivi.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.appliedSettings.foregroundIdleSeconds == 0 {
                    Label("Ce mode peut compter votre absence si vous laissez une fenêtre visible et le Mac déverrouillé.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(LHTheme.warning)
                }
            }
            GoalongSettingsGroup(title: "Données enregistrées") { RecordingChoicesView(draft: recording) }
            VisibleContextControl()
            GoalongDisclosureGroup("Confidentialité avancée") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Inclure les fenêtres privées détectées", isOn: Binding(
                        get: { model.appliedSettings.capturePrivateBrowsing },
                        set: { value in
                            if value { pendingPrivate = true }
                            else { var next = model.appliedSettings; next.capturePrivateBrowsing = false; _ = model.applyRecordingChoice(next) }
                        })).toggleStyle(.goalongSwitch)
                    Toggle("Masquer les valeurs des paramètres d’URL", isOn: Binding(
                        get: { model.appliedSettings.redactAllURLQueryValues },
                        set: { value in
                            if !value { pendingUnredacted = true }
                            else { var next = model.appliedSettings; next.redactAllURLQueryValues = true; _ = model.applyRecordingChoice(next) }
                        }))
                        .toggleStyle(.goalongSwitch)
                    Text("La détection des fenêtres privées dépend du navigateur. Utilisez Pause pour une activité sensible.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.system(size: 13))
            GoalongSettingsGroup(title: "Autres sources · facultatives") {
                SourceActivationToggle(capability: .appleScreenTime) { Text("Temps d’écran Apple") }
                Divider()
                SourceActivationToggle(capability: .aiConversations) { Text("Conversations locales") }
                Button("Choisir les dossiers de conversations…") { model.selectSection(.agentActivity) }.buttonStyle(LHQuietButtonStyle())
                Divider()
                SourceActivationToggle(capability: .developerActivity) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Activité de développement")
                        Text("Commits et nombre de fichiers modifiés dans les projets choisis. Ni code, ni messages de commit.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if consents.isEnabled(.developerActivity) {
                    Button("Choisir les projets…") { showingDeveloperProjects = true }.buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("settings-developer-projects")
                }
            }
        case .applications:
            GoalongApplicationsSettings(model: model)
        case .connections:
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    GoalongSettingsLink(title: "Envoi à Goalong", value: "Compte, données et fréquence", symbol: "arrow.up.circle") { pane = .website }
                    GoalongRowDivider()
                    GoalongSettingsLink(title: "Analyse ChatGPT", value: "Données et personnalisation", symbol: "sparkles") { pane = .chatGPT }
                }
            }
        case .website:
            GoalongWebsiteSettings(model: model)
        case .chatGPT:
            GoalongChatGPTSettings(model: model)
        case .permissions:
            GoalongSettingsGroup(title: "Accès nécessaires à vos choix") {
                GoalongPermissionRow(capability: .localComputerHistory)
                Divider()
                GoalongPermissionRow(capability: .appleScreenTime)
                Divider()
                GoalongPermissionRow(capability: .aiConversations)
            }
            Text("Les fonctions désactivées ne demandent aucune autorisation.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            GoalongDisclosureGroup("Résoudre un problème") {
                Button("Ouvrir les diagnostics d’accès") { model.selectSection(.privacy) }.buttonStyle(LHSecondaryButtonStyle()).padding(.top, 10)
            }.font(.system(size: 13))
        case .storage:
            GoalongStorageSettings(model: model)
        case .advanced:
            SupportDiagnosticsPanel()
            GoalongDeveloperSettings()
            VStack(alignment: .leading, spacing: 12) {
                GoalongSettingsList(title: "Outils") {
                    GoalongSettingsLink(title: "Outils de partage et analyses", value: "", symbol: "square.and.arrow.up") { pane = .tools }
                    GoalongRowDivider()
                    GoalongSettingsLink(title: "Terminal et agents", value: "CLI", symbol: "terminal") { model.selectSection(.cli) }
                    GoalongRowDivider()
                    GoalongSettingsLink(title: "Diagnostic et preuves", value: "", symbol: "checkmark.shield") { model.selectSection(.privacy) }
                }
                Button("Ouvrir config.json") { model.openConfiguration() }.buttonStyle(LHQuietButtonStyle())
                    .font(.system(size: 13))
            }
            GoalongSettingsGroup(title: "Mises à jour") {
                GoalongUpdateStatusRow()
                Toggle("Rechercher les mises à jour automatiquement", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates }, set: { updates.setAutomaticallyChecksForUpdates($0) })).toggleStyle(.goalongSwitch)
                Text("Chaque mise à jour est signée et vérifiée avant installation ; rien ne s’installe sans votre accord. Vos réglages et votre historique sont conservés.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Revoir le démarrage") { model.showWelcome = true }.buttonStyle(LHSecondaryButtonStyle())
        case .tools:
            GoalongAdvancedTools(model: model)
        }
    }
    private var visiblePanes: [SettingsPane] {
        SettingsPane.matches(search)
    }
    private func summary(_ item: SettingsPane) -> String {
        switch item {
        case .recording: return consents.isEnabled(.localComputerHistory) ? "Activé" : "Désactivé"
        case .applications: return "Choisir les exclusions"
        case .connections: return "Choisir une connexion"
        case .website: return "Compte, données et fréquence"
        case .chatGPT: return "Données et personnalisation"
        case .permissions: return "Selon vos fonctions"
        case .storage: return "Conservation et effacement"
        case .advanced: return "Outils et diagnostics"
        default: return ""
        }
    }
}

enum SettingsPane: Hashable {
    case home, recording, applications, connections, website, chatGPT, permissions, storage, advanced, tools
    static let primary: [Self] = [.recording, .applications, .website, .chatGPT, .permissions, .storage]
    /// Start at login and background running live on the Settings home, not in a pane.
    static func matchesStartup(_ raw: String) -> Bool {
        let keywords = "démarrage démarrer ouverture session connexion login arrière-plan fermer quitter"
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        if keywords.localizedStandardContains(query) { return true }
        // "ouverture de session": any meaningful word of the query is enough.
        return query.split(whereSeparator: \.isWhitespace).contains { $0.count >= 4 && keywords.localizedStandardContains(String($0)) }
    }
    static func matches(_ raw: String) -> [Self] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return [.applications, .permissions, .storage, .advanced] }
        return (primary + [.advanced, .tools]).filter { ($0.title + " " + $0.keywords).localizedStandardContains(query) }
    }
    var title: String {
        switch self {
        case .home: return "Réglages"
        case .recording: return "Enregistrement"
        case .applications: return "Apps et sites"
        case .connections: return "Connexions"
        case .website: return "Envoi à Goalong"
        case .chatGPT: return "Analyse ChatGPT"
        case .permissions: return "Autorisations macOS"
        case .storage: return "Stockage"
        case .advanced: return "Avancé"
        case .tools: return "Outils de partage"
        }
    }
    /// Stable accessibility identifier of the pane's entry on the Settings home.
    var identifier: String {
        switch self {
        case .home: return "home"
        case .recording: return "recording"
        case .applications: return "applications"
        case .connections: return "connections"
        case .website: return "website"
        case .chatGPT: return "chatGPT"
        case .permissions: return "permissions"
        case .storage: return "storage"
        case .advanced: return "advanced"
        case .tools: return "tools"
        }
    }
    /// Tools are opened from Avancé; every other pane from the Settings home.
    var parent: SettingsPane { self == .tools ? .advanced : .home }
    var symbol: String {
        switch self {
        case .recording: return "record.circle"
        case .applications: return "app.badge.checkmark"
        case .connections: return "link"
        case .website: return "arrow.up.circle"
        case .chatGPT: return "sparkles"
        case .permissions: return "hand.raised"
        case .storage: return "internaldrive"
        default: return "slider.horizontal.3"
        }
    }
    var keywords: String {
        switch self {
        case .recording: return "arrêter pause clavier clic souris texte activité sources temps écran lecture vidéo réunion zoom inactivité présence"
        case .applications: return "ignorer exclure exclusions masquer application navigateur domaine"
        case .connections: return "connexions"
        case .website: return "compte goalong connecter partager envoyer synchroniser fréquence quotidien"
        case .chatGPT: return "chatgpt analyse prompt consignes remplacement masquer pseudonyme sources données"
        case .permissions: return "accès accessibilité disque autoriser problème réparer"
        case .storage: return "supprimer effacer historique conserver durée espace mémoire"
        case .advanced: return "terminal cli configuration json diagnostic diagnostics version mise à jour démarrage développeur developer mocks fictives aperçu"
        case .tools: return "export fichier signé signature preuve santé récapitulatif"
        default: return ""
        }
    }
}
/// Version, last check and the one relevant action, in plain words.
@MainActor struct GoalongUpdateStatusRow: View {
    @ObservedObject private var updates = SoftwareUpdateManager.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 14, weight: .medium)).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Goalong History \(updates.currentVersion)").font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if updates.isChecking || updates.isPreparingAvailableUpdate {
                ProgressView().controlSize(.small)
            } else if let version = updates.availableVersion {
                Button("Installer la \(version)") { updates.showAvailableUpdate() }
                    .buttonStyle(LHPrimaryButtonStyle())
            } else {
                // Always enabled: an unavailable updater explains why and links to the releases.
                Button("Rechercher") { updates.checkForUpdates() }.buttonStyle(LHSecondaryButtonStyle())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-update-status")
    }

    private var symbol: String {
        if updates.availableVersion != nil { return "arrow.down.circle.fill" }
        switch updates.lastCheckResult {
        case .failed: return "exclamationmark.triangle.fill"
        case .upToDate: return "checkmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        if updates.availableVersion != nil { return LHTheme.accent }
        switch updates.lastCheckResult {
        case .failed: return LHTheme.warning
        case .upToDate: return LHTheme.success
        default: return LHTheme.secondaryText
        }
    }

    private var detail: String {
        if updates.requiresSignedBuild { return "Version compilée sans mises à jour intégrées." }
        if updates.isChecking { return "Recherche en cours…" }
        if let version = updates.availableVersion { return "La version \(version) est prête à être installée." }
        let when = updates.lastCheckedAt.map { " · vérifié " + Self.relative($0) } ?? ""
        switch updates.lastCheckResult {
        case .failed: return updates.statusMessage
        case .upToDate: return "À jour" + when
        default: return updates.automaticallyChecksForUpdates ? "Vérification automatique activée" + when : "Vérification automatique désactivée" + when
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
