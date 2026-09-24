#if os(macOS)
import SwiftUI
import AppKit

@MainActor struct SettingsPage: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @State private var search = ""
    @State private var showingRetention = false
    @State private var pendingPrivate = false
    @State private var pendingUnredacted = false
    @State private var startupError: String?
    private var pane: SettingsPane {
        get { model.settingsPane }
        nonmutating set { model.settingsPane = newValue }
    }
    private var recording: Binding<DashboardSettingsDraft> {
        Binding(get: { model.appliedSettings }, set: { _ = model.applyRecordingChoice($0) })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(pane.title).font(LHTheme.pageTitleFont).accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: pane == .chatGPT ? 960 : 840, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(pane)
        .safeAreaInset(edge: .top, spacing: 0) {
            if pane != .home { SettingsBackBar { pane = .home } }
        }
        .background(LHTheme.pageBackground)
        .onAppear { launchAtLogin.refresh() }
        .sheet(isPresented: $showingRetention) { HistoryRetentionSettingsSheet() }
        .alert("Inclure la navigation privée ?", isPresented: $pendingPrivate) {
            Button("Annuler", role: .cancel) {}
            Button("Inclure") { var next = model.appliedSettings; next.capturePrivateBrowsing = true; _ = model.applyRecordingChoice(next) }
        } message: { Text("Les fenêtres privées détectées pourront être enregistrées sur ce Mac. Aucun envoi n’est autorisé par ce choix.") }
        .alert("Conserver les paramètres des adresses ?", isPresented: $pendingUnredacted) {
            Button("Annuler", role: .cancel) {}
            Button("Conserver les valeurs") { var next = model.appliedSettings; next.redactAllURLQueryValues = false; _ = model.applyRecordingChoice(next) }
        } message: { Text("Les paramètres peuvent contenir des recherches ou des informations personnelles. Ils seront conservés sur ce Mac lorsque l’enregistrement des adresses est activé.") }
        .alert("Démarrage non modifié", isPresented: Binding(get: { startupError != nil }, set: { if !$0 { startupError = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(startupError ?? "") }
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .home:
            GoalongDataStatus(model: model)
            TextField("Rechercher un réglage…", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher un réglage")
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(visiblePanes, id: \.self) { item in
                        GoalongSettingsLink(title: item.title, value: summary(item), symbol: item.symbol) { pane = item }
                        if item != visiblePanes.last { Divider().padding(.leading, 64) }
                    }
                    if visiblePanes.isEmpty { Text("Aucun résultat").foregroundStyle(.secondary).padding(20) }
                }
            }
            if search.isEmpty {
                BackgroundContinuitySettings()
                DisclosureGroup("Confidentialité · tout suspendre") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("À réserver aux activités sensibles. Cet arrêt suspend l’historique, les analyses et les envois. Pour une pause détente, utilisez « Faire une pause » dans la barre latérale : l’historique continue.")
                            .font(.callout).foregroundStyle(.secondary)
                        GoalongGlobalPauseControl(model: model)
                    }.padding(.top, 12)
                }.accessibilityIdentifier("settings-privacy-stop")
                VStack(alignment: .trailing, spacing: 14) {
                    GoalongSettingsLink(title: "Avancé", value: "Outils et diagnostics", symbol: "slider.horizontal.3") { pane = .advanced }
                        .accessibilityIdentifier("settings-advanced")
                        .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LHTheme.separator))
                    Button(updates.availableVersion == nil ? "Version \(updates.currentVersion)" : "Mise à jour disponible") { updates.showAvailableUpdate() }
                        .buttonStyle(.borderless)
                }.font(.system(size: 12))
            }
        case .recording:
            GoalongRecordingCoverageNotice(model: model)
            GoalongSettingsGroup(title: "Sur ce Mac") {
                SourceActivationToggle(capability: .localComputerHistory) { Text("Enregistrer mon activité").font(.system(size: 14, weight: .medium)) }
                Text("Enregistrer n’autorise aucun envoi.").font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("Ouvrir Goalong à la connexion", isOn: Binding(
                    get: { consents.isEnabled(.launchAtLogin) }, set: { saveStartup($0) }))
                    .toggleStyle(.switch)
            }
            GoalongSettingsGroup(title: "Suivi du temps d’écran") {
                Text("Lire, réfléchir ou regarder sans cliquer compte aussi. Seule la fenêtre au premier plan est suivie ; les apps en arrière-plan ne s’ajoutent pas au total.")
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
                Text("Les appels et lectures vidéo détectés au premier plan continuent au-delà de ce délai. Le verrouillage, la veille et l’arrêt de confidentialité interrompent toujours le suivi.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.appliedSettings.foregroundIdleSeconds == 0 {
                    Label("Ce mode peut compter votre absence si vous laissez une fenêtre visible et le Mac déverrouillé.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Le délai repart après une interaction. Pour une longue lecture immobile, augmentez-le. Une fenêtre ouverte ne permet pas de savoir avec certitude si vous êtes encore devant l’écran.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            GoalongSettingsGroup(title: "Données enregistrées") { RecordingChoicesView(draft: recording) }
            VisibleContextControl()
            DisclosureGroup("Confidentialité avancée") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Inclure les fenêtres privées détectées", isOn: Binding(
                        get: { model.appliedSettings.capturePrivateBrowsing },
                        set: { value in
                            if value { pendingPrivate = true }
                            else { var next = model.appliedSettings; next.capturePrivateBrowsing = false; _ = model.applyRecordingChoice(next) }
                        })).toggleStyle(.switch)
                    Toggle("Masquer les valeurs des paramètres d’URL", isOn: Binding(
                        get: { model.appliedSettings.redactAllURLQueryValues },
                        set: { value in
                            if !value { pendingUnredacted = true }
                            else { var next = model.appliedSettings; next.redactAllURLQueryValues = true; _ = model.applyRecordingChoice(next) }
                        }))
                        .toggleStyle(.switch)
                    Text("La détection des fenêtres privées dépend du navigateur. Utilisez Pause pour une activité sensible.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.system(size: 13))
            GoalongSettingsGroup(title: "Autres sources · facultatives") {
                SourceActivationToggle(capability: .appleScreenTime) { Text("Temps d’écran Apple") }
                Divider()
                SourceActivationToggle(capability: .aiConversations) { Text("Conversations locales") }
                Button("Choisir les dossiers de conversations…") { model.selectSection(.agentActivity) }.buttonStyle(.borderless)
            }
        case .applications:
            GoalongApplicationsSettings(model: model)
        case .connections:
            GoalongSettingsLink(title: "Envoi à Goalong", value: "Compte, données et fréquence", symbol: "arrow.up.circle") { pane = .website }
            GoalongSettingsLink(title: "Analyse ChatGPT", value: "Données et personnalisation", symbol: "sparkles") { pane = .chatGPT }
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
            DisclosureGroup("Résoudre un problème") {
                Button("Ouvrir les diagnostics d’accès") { model.selectSection(.privacy) }.buttonStyle(.bordered).padding(.top, 10)
            }.font(.system(size: 13))
        case .storage:
            GoalongStorageSettings(model: model)
        case .advanced:
            GoalongDeveloperSettings()
            GoalongSettingsGroup(title: "Outils") {
                GoalongSettingsLink(title: "Outils de partage et analyses", value: "", symbol: "square.and.arrow.up") { pane = .tools }
                GoalongSettingsLink(title: "Terminal et agents", value: "CLI", symbol: "terminal") { model.selectSection(.cli) }
                GoalongSettingsLink(title: "Diagnostic et preuves", value: "", symbol: "checkmark.shield") { model.selectSection(.privacy) }
                Button("Ouvrir config.json") { model.openConfiguration() }.buttonStyle(.bordered)
            }
            GoalongSettingsGroup(title: "Mises à jour") {
                HStack { Text("Goalong History \(updates.currentVersion)"); Spacer(); Button("Rechercher") { updates.checkForUpdates() } }
                Toggle("Rechercher les mises à jour automatiquement", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates }, set: { updates.setAutomaticallyChecksForUpdates($0) })).toggleStyle(.switch)
            }
            Button("Revoir le démarrage") { model.showWelcome = true }.buttonStyle(.bordered)
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
        default: return ""
        }
    }
    private func saveStartup(_ enabled: Bool) {
        guard launchAtLogin.setUserPreference(enabled, surface: .settings) else {
            startupError = launchAtLogin.message ?? "Le réglage n’a pas pu être enregistré."
            return
        }
        if enabled && launchAtLogin.requiresApproval { launchAtLogin.openLoginItemsSettings() }
    }
}

enum SettingsPane: Hashable {
    case home, recording, applications, connections, website, chatGPT, permissions, storage, advanced, tools
    static let primary: [Self] = [.recording, .applications, .website, .chatGPT, .permissions, .storage]
    static func matches(_ raw: String) -> [Self] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return [.applications, .permissions, .storage] }
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
    var subtitle: String { "" }
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
        case .recording: return "arrêter pause clavier clic souris texte activité sources démarrage temps écran lecture vidéo réunion zoom inactivité présence"
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
#endif
