#if os(macOS)
import SwiftUI
import LocalHistoryCore
import LocalHistoryQueryCLI
import AgentActivity

@MainActor struct GoalongAnalysisSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DashboardViewModel
    @State var selection: GoalongAnalysisSelection
    var initialTab = 0
    let onSave: (GoalongAnalysisSelection) -> Void
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @StateObject private var installedApps = GoalongApplicationCatalog()
    @State private var localCatalog: GoalongSiteSelectionCatalog?
    @State private var tab = 0
    @State private var appSearch = ""
    @State private var error: String?
    @State private var previewText: String?
    @State private var previewBusy = false
    @State private var previewGeneration = UUID()
    @State private var sampleText = "Hi Charlie — travail sur le projet"
    @State private var loaded = false
    @State private var catalogLoading = true
    @State private var catalogError: String?
    @State private var previewTask: Task<Void, Never>?
    private var scope: Binding<GoalongAnalysisScope> {
        Binding(get: { selection.scope ?? GoalongAnalysisScope() }, set: { selection.scope = $0 })
    }
    private var rules: Binding<[GoalongTextReplacement]> {
        Binding(get: { selection.replacements ?? [] }, set: { selection.replacements = $0 })
    }
    private var apps: [GoalongApplicationChoice] {
        var values: [String: GoalongApplicationChoice] = [:]
        for app in installedApps.apps { values[app.id.lowercased()] = .init(id: app.id.lowercased(), name: app.name) }
        for app in model.snapshot.trackedUsage where app.kind == .application {
            let key = GoalongAnalysisScope.key(id: app.bundleIdentifier, name: app.name)
            values[key] = .init(id: key, name: app.name)
        }
        for device in localCatalog?.devices ?? [] {
            for app in device.applications { values[app.id.lowercased()] = .init(id: app.id.lowercased(), name: app.name) }
        }
        for (id, name) in scope.wrappedValue.applicationNames where values[id] == nil { values[id] = .init(id: id, name: name) }
        return values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Votre analyse ChatGPT").font(.system(size: 25, weight: .semibold))
                    Text("Choisissez ce qui sort du Mac, puis la façon de rédiger le bilan.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("analysis-cancel")
            }.padding(24)
            Picker("Configuration ChatGPT", selection: $tab) {
                Text("Données").tag(0); Text("Remplacements").tag(1); Text("Consignes").tag(2); Text("Aperçu").tag(3)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("analysis-editor-tabs").padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(LHTheme.warning) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 16) {
                Text("Aucun envoi en configurant ces choix.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if tab != 3 { Button("Vérifier l’aperçu") { tab = 3; preparePreview() }.buttonStyle(.bordered).disabled(catalogLoading || installedApps.loading || !selection.hasSources) }
                Button("Enregistrer mes choix") { save() }.buttonStyle(LHPrimaryButtonStyle()).disabled(!selection.hasSources || previewBusy || catalogLoading || installedApps.loading)
                    .accessibilityIdentifier("analysis-save-selection")
            }.padding(20)
        }
        .frame(minWidth: 740, idealWidth: 940, maxWidth: 1080, minHeight: 580, idealHeight: 760, maxHeight: 980)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .task { await initialize() }
        .onChange(of: installedApps.loading) { isLoading in
            if !isLoading && tab == 3 && previewText == nil && !previewBusy { preparePreview() }
        }
        .onChange(of: installedApps.apps) { _ in normalizeCatalogSelection() }
        .onChange(of: selection) { _ in
            previewTask?.cancel(); previewTask = nil
            previewGeneration = UUID(); previewText = nil; previewBusy = false; error = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongExclusionsDidChange)) { _ in
            previewTask?.cancel(); previewGeneration = UUID(); previewText = nil; previewBusy = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in
            previewTask?.cancel(); previewGeneration = UUID(); previewText = nil; previewBusy = false
        }
        .onDisappear { previewTask?.cancel(); previewGeneration = UUID() }
    }
    @ViewBuilder private var content: some View {
        switch tab {
        case 0: dataChoices
        case 1: replacementChoices
        case 2: instructions
        default: preview
        }
    }
    private var dataChoices: some View {
        VStack(alignment: .leading, spacing: 20) {
            GoalongSettingsGroup(title: "Sources") {
                source("Activité de ce Mac", capability: .localComputerHistory, value: $selection.computer)
                source("Temps d’écran Apple", capability: .appleScreenTime, value: $selection.screenTime)
                source("Conversations locales", capability: .aiConversations, value: $selection.conversations)
            }
            if selection.computer {
                GoalongSettingsGroup(title: "Détails possibles · uniquement pour les apps autorisées") {
                    Grid(horizontalSpacing: 24, verticalSpacing: 14) {
                        ForEach(0..<5, id: \.self) { row in
                            GridRow {
                                ForEach(Array(GoalongAnalysisField.allCases[(row * 2)..<min(row * 2 + 2, GoalongAnalysisField.allCases.count)])) { field in
                                    Toggle(field.title, isOn: scope[dynamicMember: field.keyPath])
                                        .toggleStyle(.checkbox).font(.system(size: 13))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("analysis-field-\(field.rawValue)")
                                }
                            }
                        }
                    }
                    Text("Une app réglée sur « Durée seulement » ne transmet aucun de ces détails.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                GoalongDisclosureGroup("Exclure des sites de l’analyse") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("exemple.fr · un domaine par ligne", text: Binding(get: { scope.wrappedValue.excludedDomains.joined(separator: "\n") },
                            set: { var value = scope.wrappedValue; value.excludedDomains = $0.components(separatedBy: .newlines); scope.wrappedValue = value }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(3...6)
                        Text("Les durées Apple d’un navigateur peuvent être omises si elles ne permettent pas de retirer ces sites.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }.font(.system(size: 13))
            }
            if selection.computer || selection.screenTime { applicationChoices }
            if selection.screenTime && catalogLoading { ProgressView("Lecture des appareils…").font(.system(size: 13)) }
            if selection.screenTime, let catalogError {
                Label(catalogError, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if selection.screenTime, let catalog = localCatalog {
                GoalongSettingsGroup(title: "Appareils Apple") {
                    ForEach(catalog.devices) { device in
                        Toggle(device.name, isOn: Binding(get: { scope.wrappedValue.deviceIDs?.contains(device.id) ?? true }, set: { enabled in
                            var value = scope.wrappedValue
                            var ids = Set(value.deviceIDs ?? catalog.devices.map(\.id))
                            if enabled { ids.insert(device.id) } else { ids.remove(device.id) }
                            value.deviceIDs = ids.sorted(); scope.wrappedValue = value
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            if selection.conversations { conversationChoices }
        }
    }
    private var applicationChoices: some View {
        GoalongSettingsGroup(title: "Applications autorisées") {
            HStack {
                TextField("Rechercher une application…", text: $appSearch).textFieldStyle(.roundedBorder)
                Menu("Actions groupées") {
                    Button("Tout autoriser · durées seulement") { setAll(details: false) }
                    Button("Tout autoriser · détails choisis") { setAll(details: true) }
                    Button("Tout exclure") { var value = scope.wrappedValue; value.applicationIDs = []; value.detailApplicationIDs = []; scope.wrappedValue = value }
                }.fixedSize()
            }
            if installedApps.loading { ProgressView("Applications installées…").font(.system(size: 12)) }
            if !installedApps.loading && apps.filter({ appSearch.isEmpty || $0.name.localizedStandardContains(appSearch) }).isEmpty {
                Text(apps.isEmpty ? "Aucune application disponible." : "Aucun résultat pour cette recherche.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 14)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps.filter { appSearch.isEmpty || $0.name.localizedStandardContains(appSearch) }) { app in
                        GoalongAnalysisAppRow(app: app, scope: scope, excluded: exclusions.policy.excludes(appID: app.id, name: app.name))
                        Divider()
                    }
                }
            }.frame(height: 275)
            Text("La sélection s’applique aussi aux durées Apple. Les nouvelles apps restent exclues après validation.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var conversationChoices: some View {
        GoalongSettingsGroup(title: "Conversations · choisir les dossiers et le contenu") {
            let folders = model.agentActivityRuntime.configuration.watchedFolders.filter(\.isEnabled)
            ForEach(folders) { folder in
                Toggle("\(folder.provider.displayName) · \(folder.displayName)", isOn: Binding(get: { scope.wrappedValue.conversationFolderIDs?.contains(folder.id) ?? true }, set: { enabled in
                    var value = scope.wrappedValue; var ids = Set(value.conversationFolderIDs ?? folders.map(\.id))
                    if enabled { ids.insert(folder.id) } else { ids.remove(folder.id) }; value.conversationFolderIDs = ids.sorted(); scope.wrappedValue = value
                })).toggleStyle(.checkbox).font(.system(size: 13))
            }
            if folders.isEmpty { Text("Aucun dossier activé. Ajoutez une source dans Enregistrement.").font(.system(size: 13)).foregroundStyle(.secondary) }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    Toggle("Nombre de messages", isOn: scope.conversationCounts).toggleStyle(.checkbox)
                    Toggle("Titres des conversations", isOn: scope.conversationTitles).toggleStyle(.checkbox)
                }
                GridRow {
                    Toggle("Vos messages", isOn: scope.conversationUserMessages).toggleStyle(.checkbox)
                    Toggle("Réponses finales des assistants", isOn: scope.conversationAssistantMessages).toggleStyle(.checkbox)
                }
            }.font(.system(size: 13))
            if exclusions.policy.hasExclusions {
                Text("Des exclusions globales sont actives : les conversations dont le texte n’est pas filtrable sont omises.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var replacementChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remplacer avant l’envoi").font(.system(size: 20, weight: .semibold)).accessibilityIdentifier("analysis-replacements-title")
                    Text("Appliqué sur le Mac. L’historique original reste inchangé.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Ajouter un remplacement") { selection.replacements = (selection.replacements ?? []) + [GoalongTextReplacement()] }.buttonStyle(.bordered).disabled(rules.wrappedValue.count >= 100)
            }
            ForEach(rules) { rule in GoalongReplacementRow(rule: rule) { selection.replacements?.removeAll { $0.id == rule.wrappedValue.id } } }
            if rules.wrappedValue.isEmpty {
                Text("Exemple : Hi Charlie → Projet A").font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            GoalongSettingsGroup(title: "Tester vos remplacements") {
                TextField("Texte d’exemple", text: $sampleText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                Text(transformedExample).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Les remplacements portent sur le texte transmis et vos consignes, jamais sur les fichiers d’origine. Ils ne garantissent pas une anonymisation complète.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var transformedExample: String {
        (try? GoalongTextTransformer(rules.wrappedValue).apply(sampleText)) ?? "Vérifiez les règles de remplacement."
    }
    private var instructions: some View {
        GoalongSettingsGroup(title: "Comment rédiger le bilan") {
            Text("Vos consignes").font(.system(size: 19, weight: .semibold)).accessibilityIdentifier("analysis-guidance-title")
            TextEditor(text: Binding(get: { selection.outputGuidance ?? "" }, set: { selection.outputGuidance = String($0.prefix(4000)) }))
                .font(.system(size: 14)).padding(10).frame(minHeight: 190)
                .background(LHTheme.pageBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LHTheme.separator))
                .accessibilityLabel("Consignes de rédaction pour ChatGPT")
            Text("Exemple : Concentre-toi sur les progrès de mes projets. Ne cite pas les noms de personnes. Évite les détails de mes loisirs.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text("Les consignes influencent le bilan, pas les données envoyées.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(); Text("\(selection.outputGuidance?.count ?? 0) / 4 000").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Pour retirer une information avant l’envoi, utilisez Données ou Remplacements.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ce que ChatGPT recevra").font(.system(size: 21, weight: .semibold))
                    Text(GoalongUIFormat.day(model.selectedDay)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(previewText == nil ? "Préparer l’aperçu local" : "Actualiser") { preparePreview() }.buttonStyle(.bordered).disabled(previewBusy || catalogLoading || installedApps.loading)
            }
            if previewBusy { ProgressView("Application des filtres et remplacements sur ce Mac…").padding(.vertical, 30) }
            else if let previewText {
                GoalongAnalysisHumanPreview(text: previewText)
                if let instruction = selection.outputGuidance, !instruction.isEmpty {
                    GoalongSettingsGroup(title: "Consignes transmises après remplacement") {
                        Text((try? GoalongTextTransformer(rules.wrappedValue).apply(instruction, maximumCharacters: 4000)) ?? "Consignes non valides")
                            .font(.system(size: 13)).textSelection(.enabled)
                    }
                }
            } else { Text("Aucun envoi : cet aperçu permet de vérifier les champs et les noms après remplacement.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20) }
        }
    }
    private func source(_ title: String, capability: GoalongCapability, value: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).disabled(!consents.isEnabled(capability))
            if !consents.isEnabled(capability) {
                Button("Configurer la source") { dismiss(); model.selectSection(.settings); model.settingsPane = .recording }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
    }
    private func setAll(details: Bool) {
        var value = scope.wrappedValue
        let allowed = apps.filter { !exclusions.policy.excludes(appID: $0.id, name: $0.name) }
        value.applicationIDs = allowed.map(\.id); value.detailApplicationIDs = details ? allowed.map(\.id) : []
        if details && !value.hasEventDetails { value.windowTitles = true; value.websiteDomains = true }
        scope.wrappedValue = value
    }
    private func initialize() async {
        guard !loaded else { return }; loaded = true; tab = initialTab
        if selection.scope == nil {
            var initial = GoalongAnalysisScope()
            if selection.details { initial.windowTitles = true; initial.websiteDomains = true; initial.visibleText = true; initial.interfaceLabels = true }
            selection.scope = initial
        }
        installedApps.load()
        let day = ActivityAnalysisPaths.dayString(model.selectedDay)
        do {
            localCatalog = try await Task.detached(priority: .utility) {
                try GoalongQueryCLI.siteSelectionCatalog(rootDirectory: AppPaths.applicationSupportDirectory, day: day)
            }.value
        } catch {
            catalogError = "Les appareils Apple ne sont pas disponibles pour cette date. Choisissez une autre journée ou utilisez seulement l’activité de ce Mac."
        }
        catalogLoading = false
        normalizeCatalogSelection()
        if initialTab == 3 { preparePreview() }
    }
    private func normalizeCatalogSelection() {
        var value = scope.wrappedValue
        for app in apps { value.applicationNames[app.id] = app.name }
        scope.wrappedValue = value
    }
    private func finalized() throws -> GoalongAnalysisSelection {
        guard !catalogLoading, !installedApps.loading else { throw PrivacyScopeInput.invalid("La liste des applications et appareils est encore en cours de lecture.") }
        var next = selection, value = scope.wrappedValue
        next.computer = next.computer && consents.isEnabled(.localComputerHistory)
        next.screenTime = next.screenTime && consents.isEnabled(.appleScreenTime)
        next.conversations = next.conversations && consents.isEnabled(.aiConversations)
        guard next.hasSources else { throw PrivacyScopeInput.invalid("Activez au moins une source pour l’analyse.") }
        if value.applicationIDs == nil { value.applicationIDs = apps.filter { !exclusions.policy.excludes(appID: $0.id, name: $0.name) }.map(\.id) }
        if value.detailApplicationIDs == nil { value.detailApplicationIDs = value.applicationIDs }
        if value.deviceIDs == nil { value.deviceIDs = localCatalog?.devices.map(\.id) ?? [] }
        if value.conversationFolderIDs == nil { value.conversationFolderIDs = model.agentActivityRuntime.configuration.watchedFolders.filter(\.isEnabled).map(\.id) }
        value.applicationNames = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        value.excludedDomains = try PrivacyScopeInput.domains(value.excludedDomains.joined(separator: "\n"))
        try value.validate()
        if next.screenTime && (value.deviceIDs?.isEmpty ?? true) { throw PrivacyScopeInput.invalid("Choisissez au moins un appareil Apple, ou désactivez cette source.") }
        if (next.computer || next.screenTime) && (value.applicationIDs?.isEmpty ?? true) { throw PrivacyScopeInput.invalid("Choisissez au moins une application, ou désactivez les sources d’activité.") }
        if next.conversations && (value.conversationFolderIDs?.isEmpty ?? true) { throw PrivacyScopeInput.invalid("Choisissez un dossier de conversations, ou désactivez cette source.") }
        if next.conversations && !value.conversationCounts && !value.hasConversationText { throw PrivacyScopeInput.invalid("Choisissez le contenu des conversations à analyser, ou désactivez cette source.") }
        next.scope = value; next.version = 2; next.reviewed = true; next.revision = UUID().uuidString
        next.privacyRevision = exclusions.policy.revision
        guard !(next.replacements ?? []).contains(where: { $0.search.isEmpty && !$0.replacement.isEmpty }) else {
            throw PrivacyScopeInput.invalid("Un remplacement est incomplet : indiquez le texte à rechercher.")
        }
        next.replacements = (next.replacements ?? []).filter { !$0.search.isEmpty }
        _ = try GoalongTextTransformer(next.replacements ?? [])
        try next.validate()
        return next
    }
    private func save() {
        do {
            let next = try finalized()
            let wasAutomatic = ChatGPTRecapRuntime.shared.automaticRecapsEnabled
            try next.save()
            runtimeStop()
            guard consents.set(.chatGPTAnalysis, enabled: true, surface: .settings) else { throw PrivacyScopeInput.invalid("L’autorisation n’a pas été enregistrée.") }
            // A consent transition can start the runtime through AppDelegate. Cancel
            // that initial catch-up before restoring only future scheduled analyses.
            ChatGPTRecapRuntime.shared.stop()
            NotificationCenter.default.post(name: .goalongAnalysisSelectionDidChange, object: nil)
            if wasAutomatic { ChatGPTRecapRuntime.shared.automaticRecapsEnabled = true; ChatGPTRecapRuntime.shared.start(checkPreviousDayImmediately: false) }
            onSave(next); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func runtimeStop() {
        ChatGPTRecapRuntime.shared.stop()
        ChatGPTRecapRuntime.shared.automaticRecapsEnabled = false
    }
    private func preparePreview() {
        do {
            let next = try finalized(), date = model.selectedDay, device = model.deviceID
            let ticket = UUID(); previewGeneration = ticket; previewBusy = true; error = nil
            previewTask?.cancel()
            previewTask = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    try ChatGPTRecapContextBuilder.buildGranular(day: date, deviceID: device,
                        includeScreenTime: next.screenTime, includeAgentActivity: next.conversations, selection: next).renderedData
                }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard previewGeneration == ticket else { return }; previewText = value; previewBusy = false
                } catch { guard previewGeneration == ticket else { return }; self.error = error.localizedDescription; previewBusy = false }
            }
        } catch { self.error = error.localizedDescription }
    }
}
#endif
