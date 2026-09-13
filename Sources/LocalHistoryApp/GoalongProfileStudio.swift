#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI

@MainActor final class GoalongProfileStudioModel: ObservableObject {
    @Published var request: GoalongProfileAnalysis.Request?
    @Published var result: GoalongProfileAnalysis.Result?
    @Published var evidence: [GoalongProfileAnalysis.Evidence] = []
    @Published var selectedEvidence = Set<String>()
    @Published var selectedItems = Set<String>()
    @Published var consent = false
    @Published var reviewed = false
    @Published var error: String?
    @Published var status = ""
    @Published private(set) var busy = false
    private var task: Task<Void, Never>?
    private var session: CodexAppServerSession?
    private var operation = UUID()
    private var nativeSource = false
    private var richSource = false
    private var conversationSource = false
    var archive: GoalongProfileAnalysis.Archive? { guard let request, let result else { return nil }; return .init(request: request, result: result) }
    func invalidate() { cancel(); request = nil; result = nil; selectedItems = []; consent = false; reviewed = false }
    func cancel() { operation = UUID(); task?.cancel(); session?.close(); session = nil; busy = false }
    private var sourcesEnabled: Bool { (!nativeSource || (GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) && (!richSource || ActivityAnalysisPreferences.richContextEnabled))) && (!conversationSource || GoalongCapabilityConsentStore.shared.isEnabled(.aiConversations)) }
    func load(start: Date, end: Date, rich: Bool, computer: Bool = true, conversations: Bool = false, conversationsFrom: Date? = nil) {
        invalidate(); evidence = []; selectedEvidence = []; nativeSource = computer; richSource = computer && rich; conversationSource = conversations
        guard computer || conversations, sourcesEnabled else { error = "Choisissez une source et activez-la dans les réglages."; return }
        busy = true; error = nil; status = "Lecture locale des événements horodatés…"; let id = operation
        task = Task {
            do {
                let selection = try await Task.detached(priority: .userInitiated) {
                    var rows = computer ? try GoalongProfileAnalysis.load(root: AppPaths.applicationSupportDirectory, start: start, end: end, rich: rich) : []
                    var notice = ""
                    if conversations {
                        let selected = try GoalongConversationEvidence.load(root: AppPaths.applicationSupportDirectory, start: conversationsFrom ?? start, end: end)
                        rows += selected.evidence; notice = selected.notice
                    }
                    return (rows.enumerated().map { index, row in var row = row; row.id = "e\(index + 1)"; return row }, notice)
                }.value
                let rows = selection.0
                guard operation == id else { return }
                guard sourcesEnabled else { throw GoalongProfileAnalysis.invalid("Une source a été désactivée pendant la lecture.") }
                evidence = rows; selectedEvidence = Set(rows.map(\.id)); busy = false; status = "\(rows.count) événements chargés localement. Préparez ensuite le prompt pour appliquer vos règles. \(selection.1)"
            } catch { guard operation == id else { return }; self.error = error.localizedDescription; busy = false }
        }
    }
    func prepare(day: Date, modules: Set<String>, policy: GoalongProfileAnalysis.Policy, includeConversations: Bool = false) {
        invalidate(); error = nil
        do {
            guard sourcesEnabled else { throw GoalongProfileAnalysis.invalid("Une source sélectionnée a été désactivée.") }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
            request = try GoalongProfileAnalysis.prepare(date: formatter.string(from: day), timezone: TimeZone.current.identifier,
                evidence: evidence.filter { selectedEvidence.contains($0.id) }, policy: policy, selected: GoalongProfileAnalysis.modules.filter { modules.contains($0) }, includeConversations: includeConversations)
            status = "Prompt préparé. Les termes exclus ont retiré les événements concernés ; les alias ont été appliqués."
        } catch { self.error = error.localizedDescription }
    }
    func analyze() {
        guard !busy, consent, let selected = request, sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { error = "Relisez la sélection et autorisez son envoi à l’agent."; return }
        busy = true; result = nil; selectedItems = []; reviewed = false; error = nil; status = "Analyse des seules rubriques choisies…"; let id = UUID(); operation = id
        task = Task {
            do {
                guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
                let active = try CodexAppServerSession(executableURL: executable, codexHomeURL: AppPaths.chatGPTDirectory.appendingPathComponent("site-analysis-codex-home", isDirectory: true), siteAnalysisOnly: true)
                session = active; defer { active.close(); if operation == id { session = nil } }
                guard operation == id, sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { throw GoalongProfileAnalysis.invalid("Autorisation retirée.") }
                let output = try await Task.detached(priority: .userInitiated) {
                    let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
                    return try active.generateProfileAnalysis(request: selected, workingDirectory: directory)
                }.value
                guard operation == id else { return }
                guard sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { throw GoalongProfileAnalysis.invalid("Autorisation retirée pendant l’analyse.") }
                result = try GoalongProfileAnalysis.apply(output, to: selected); busy = false; consent = false
                status = "Analyse terminée. Elle reste locale. Relisez, corrigez et choisissez éventuellement les résultats à transmettre."
            } catch { guard operation == id else { return }; self.error = error.localizedDescription; busy = false; consent = false }
        }
    }
    func importResult(_ url: URL) {
        do { guard let request, sourcesEnabled else { throw GoalongProfileAnalysis.invalid("Préparez ou rouvrez d’abord la sélection locale.") }
            result = try GoalongProfileAnalysis.apply(GoalongProfileAnalysis.parseResult(GoalongSiteAnalysisRequest.readSelectedBytes(url)), to: request)
            selectedItems = []; reviewed = false; status = "Réponse contrôlée. Aucun résultat n’a été envoyé."
        } catch { self.error = error.localizedDescription }
    }
    func save() {
        do {
            guard let request else { return }
            let folder = AppPaths.chatGPTDirectory.appendingPathComponent("profile-analyses", isDirectory: true)
            try ChatGPTSecureStorage.prepareDirectory(folder)
            let bytes: Data
            if let archive { bytes = try GoalongContextualRhythm.encode(GoalongProfileAnalysis.Archive(request: request, result: GoalongProfileAnalysis.apply(archive.result, to: request)), limit: 256*1024) }
            else { bytes = try request.encoded() }
            let url = folder.appendingPathComponent(request.request_id + (result == nil ? ".request.json" : ".analysis.json"))
            try ChatGPTSecureStorage.writeFileAtomically(bytes, to: url)
            status = "Enregistré dans Goalong History. Aucun envoi au site."
        } catch { self.error = error.localizedDescription }
    }
    func open(_ url: URL) {
        do {
            let bytes = try GoalongSiteAnalysisRequest.readSelectedBytes(url)
            invalidate()
            if let saved = try? GoalongProfileAnalysis.parseArchive(bytes) {
                let checked = try GoalongProfileAnalysis.apply(saved.result, to: saved.request); request = saved.request; result = checked
            } else { let saved = try GoalongProfileAnalysis.parseRequest(bytes); _ = try saved.context(); request = saved }
            nativeSource = false; richSource = false; conversationSource = false; evidence = []; selectedEvidence = []; status = "Dossier local rouvert. Relisez-le avant tout envoi."
        } catch { self.error = error.localizedDescription }
    }
    func correct(_ id: String, field: String, text: String) {
        guard let index = result?.items.firstIndex(where: { $0.id == id }) else { return }
        if field == "title" { result?.items[index].title = text } else if field == "summary" { result?.items[index].summary = text } else { result?.items[index].caveat = text }
        result?.items[index].status = result?.items[index].evidence_refs.isEmpty == true ? "unknown" : "declared"; reviewed = false
    }
    func projection() throws -> Data {
        guard reviewed, let archive else { throw GoalongProfileAnalysis.invalid("Relisez les cartes et confirmez la sélection d’envoi.") }
        return try GoalongProfileAnalysis.siteImport(archive, selectedIDs: selectedItems)
    }
}

/// A document-sized window keeps the long, scrollable review usable on smaller displays.
@MainActor final class GoalongProfileWindow: NSObject, ObservableObject, NSWindowDelegate {
    private var studioWindow: NSWindow?
    func show(onSend: @escaping (Data) -> Void) {
        if let studioWindow { studioWindow.makeKeyAndOrderFront(nil); return }
        let view = GoalongProfileStudio(onSend: { [weak self] data in
            self?.studioWindow?.close()
            onSend(data)
        }, onClose: { [weak self] in self?.studioWindow?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view
            .background(LHTheme.pageBackground)
            .foregroundStyle(LHTheme.text)
            .tint(LHTheme.accent)
            .accentColor(LHTheme.accent)))
        window.title = "Comprendre mon travail — Goalong History"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(LHTheme.pageBackground)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 700, height: 540)
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1100, height: 800)
        window.setContentSize(NSSize(width: min(830, screen.width - 40), height: min(760, screen.height - 80)))
        window.isReleasedWhenClosed = false
        window.delegate = self
        studioWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        studioWindow?.contentViewController = nil
        studioWindow = nil
    }
}

struct GoalongProfileStudio: View {
    let onSend: (Data) -> Void
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GoalongProfileStudioModel()
    @StateObject private var connection = GoalongSiteAnalysisModel()
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var rich = false
    @State private var computer = true
    @State private var conversations = false
    @State private var conversationsFrom = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
    @State private var modules = Set(GoalongProfileAnalysis.modules.filter { $0 != "ai" })
    @State private var exclusions = ""
    @State private var aliases = ""
    @State private var instructions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Comprendre mon travail").font(.title2.weight(.semibold)); Spacer(); Button("Fermer") { model.cancel(); closeStudio() } }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Analysez votre activité pour vous-même. Vous pourrez conserver le résultat ici, puis choisir séparément ce qui part dans votre compte Goalong.").foregroundStyle(.secondary)
                    HStack { Button("Ouvrir une analyse ou une sélection enregistrée…") { openSaved() }; Spacer() }
                    GoalongProfileSection("1. Choisir les données") {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Journée analysée — jusqu’à", selection: $end)
                            Toggle("Computer History — activité de l’ordinateur", isOn: $computer)
                            if computer { DatePicker("Activité depuis", selection: $start); Toggle("Inclure le contexte enrichi déjà autorisé", isOn: $rich) }
                            Toggle("Conversation History — utiliser les conversations IA comme contexte", isOn: $conversations)
                            if conversations {
                                DatePicker("Conversations actives depuis", selection: $conversationsFrom, displayedComponents: .date)
                                Text("Journée analysée et jours précédents, jusqu’à 31 jours. Les échanges peuvent éclairer les projets, décisions et méthodes même si « Usage de l’IA » est décochée. Seules les sources déjà autorisées sont lues. Les dates sélectionnent les conversations ; selon la source, des messages antérieurs peuvent être inclus sans timestamp individuel. Les timestamps fournis par la source sont conservés.").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Événements, applications, fenêtres, navigation, interactions et contexte disponibles avec leurs timestamps. Les champs protégés et les événements supprimés sont exclus. Les extraits sont bornés ; les absences restent inconnues.").font(.caption).foregroundStyle(.secondary)
                            HStack { Button("Charger les sources choisies") { model.load(start: start, end: end, rich: rich, computer: computer, conversations: conversations, conversationsFrom: conversationsFrom) }; Button("Ajouter des preuves (mesures, IA, historique)…") { importEvidence() } }.disabled(model.busy)
                            if !model.evidence.isEmpty { DisclosureGroup("Choisir les événements (\(model.selectedEvidence.count)/\(model.evidence.count))") {
                                HStack { Button("Tout sélectionner") { model.selectedEvidence = Set(model.evidence.map(\.id)); model.invalidate() }; Button("Tout décocher") { model.selectedEvidence = []; model.invalidate() } }
                                LazyVStack(alignment: .leading) { ForEach(model.evidence, id: \.id) { e in Toggle(isOn: Binding(get: { model.selectedEvidence.contains(e.id) }, set: { yes in if yes { model.selectedEvidence.insert(e.id) } else { model.selectedEvidence.remove(e.id) }; model.invalidate() })) { Text("\(e.start) · \(e.application) · \(e.text)").font(.caption).lineLimit(3) } } }
                            } }
                        }.padding(8)
                    }
                    GoalongProfileSection("2. Choisir les analyses et protéger le contexte") {
                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                                ForEach(GoalongProfileAnalysis.modules, id: \.self) { key in Toggle(GoalongProfileAnalysis.labels[key] ?? key, isOn: Binding(get: { modules.contains(key) }, set: { yes in if yes { modules.insert(key) } else { modules.remove(key) }; settingsChanged() })) }
                            }
                            Text("Décochez une rubrique pour que l’agent ne l’analyse pas. La rubrique « Usage de l’IA » est indépendante de la source Conversation History choisie plus haut.").font(.caption)
                            Text("Exclure des applications, projets ou termes — un par ligne").font(.subheadline)
                            TextEditor(text: $exclusions).frame(height: 60).accessibilityLabel("Termes à exclure")
                            Text("Les événements contenant ces termes sont retirés avant analyse. Toute réapparition littérale dans un résultat est masquée.").font(.caption).foregroundStyle(.secondary)
                            Text("Remplacer des noms — une ligne « nom privé => alias »").font(.subheadline)
                            TextEditor(text: $aliases).frame(height: 60).accessibilityLabel("Règles de remplacement")
                            Text("Exemple : Projet Atlas => Projet secret. Les remplacements s’appliquent avant analyse et avant export.").font(.caption).foregroundStyle(.secondary)
                            Text("Ce que l’agent ne doit pas aborder — complément personnel").font(.subheadline)
                            TextEditor(text: $instructions).frame(height: 80).accessibilityLabel("Consignes personnelles de confidentialité")
                            Text("Pour masquer un nom précis, ajoutez-le aussi aux règles ci-dessus. Les consignes libres guident l’agent ; elles ne garantissent pas à elles seules qu’un sujet ne sera jamais évoqué. Relisez les résultats.").font(.caption).foregroundStyle(.secondary)
                            Button("Préparer le prompt protégé") { prepare() }.disabled(model.busy || model.selectedEvidence.isEmpty || modules.isEmpty)
                        }.padding(8)
                    }
                    if let request = model.request {
                        Text("Période du dossier préparé : \((try? request.context().date) ?? ""). Le prompt précise les timestamps disponibles et les fenêtres de sélection des conversations.").font(.caption)
                        GoalongProfileSection("3. Vérifier et analyser") {
                            VStack(alignment: .leading, spacing: 12) {
                                DisclosureGroup("Voir le prompt exact — consigne principale fixe") { Text((try? request.prompt()) ?? "Sélection invalide").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                HStack { Text(connection.accountLabel).font(.caption); Spacer(); Button(connection.connected ? "Déconnecter ChatGPT" : "Connecter ChatGPT") { if connection.connected { connection.disconnect() } else { connection.connect() } }.disabled(model.busy || connection.busy) }
                                Toggle("J’autorise l’envoi de ce contexte à l’agent connecté", isOn: $model.consent)
                                Button("Lancer l’analyse") { model.analyze() }.disabled(model.busy || !connection.connected || !model.consent)
                                HStack { Button("Exporter le prompt pour mon agent…") { exportPrompt(request) }; Button("Importer sa réponse…") { importResult() }; Button("Enregistrer ici") { model.save() } }.disabled(model.busy)
                                Text("L’export du prompt contient seulement le contexte préparé, sans les noms originaux des règles de remplacement. Votre agent suit ses propres conditions. Aucun de ces boutons n’envoie au site.").font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                    }
                    if let result = model.result {
                        GoalongProfileSection("4. Relire et choisir les résultats à transmettre") {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Aucun résultat n’est sélectionné par défaut. Les preuves, leurs timestamps et vos règles privées restent dans Goalong History.").font(.caption)
                                ForEach(result.items, id: \.id) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Toggle("Transmettre : \(GoalongProfileAnalysis.labels[item.module] ?? item.module)", isOn: Binding(get: { model.selectedItems.contains(item.id) }, set: { yes in if yes { model.selectedItems.insert(item.id) } else { model.selectedItems.remove(item.id) }; model.reviewed = false }))
                                        TextField("Titre", text: Binding(get: { item.title }, set: { model.correct(item.id, field: "title", text: $0) })).textFieldStyle(.roundedBorder)
                                        TextEditor(text: Binding(get: { item.summary }, set: { model.correct(item.id, field: "summary", text: $0) })).frame(height: 70).accessibilityLabel("Synthèse \(item.title)")
                                        TextField("Limites", text: Binding(get: { item.caveat }, set: { model.correct(item.id, field: "caveat", text: $0) })).textFieldStyle(.roundedBorder)
                                        Text("\(item.status) · \(item.evidence_refs.count) éléments de preuve locaux").font(.caption).foregroundStyle(.secondary)
                                        DisclosureGroup("Examiner les preuves") { ForEach((try? model.request?.context().evidence.filter { item.evidence_refs.contains($0.id) }) ?? [], id: \.id) { e in Text("\(e.start) · \(e.application)\n\(e.text)").font(.caption).textSelection(.enabled) } }
                                        Divider()
                                    }
                                }
                                Button("Conserver l’analyse dans Goalong History") { model.save() }
                                Toggle("J’ai relu les résultats sélectionnés et leur confidentialité", isOn: $model.reviewed)
                                if let archive = model.archive, let projection = try? GoalongProfileAnalysis.project(archive, selectedIDs: model.selectedItems), let bytes = try? GoalongContextualRhythm.encode(projection) {
                                    DisclosureGroup("Voir exactement les cartes sélectionnées") { Text(String(decoding: bytes, as: UTF8.self)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                }
                                HStack { Button("Exporter les cartes sélectionnées…") { exportCards() }; Button("Préparer l’envoi à mon compte Goalong") { do { let bytes = try model.projection(); onSend(bytes); closeStudio() } catch { model.error = error.localizedDescription } } }.disabled(!model.reviewed || model.selectedItems.isEmpty || model.busy)
                                Text("Le partage avec les autres se règle ensuite sur le site, rubrique par rubrique et selon le public choisi.").font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                    }
                    if model.busy { HStack { ProgressView(); Text(model.status); Button("Annuler") { model.cancel() } } }
                    else if !model.status.isEmpty { Text(model.status).font(.caption) }
                    if let error = model.error ?? connection.error { Text(error).foregroundStyle(.red) }
                }.padding(22)
            }
        }.frame(minWidth: 700, idealWidth: 830, minHeight: 540, idealHeight: 760)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .onChange(of: start) { _ in model.invalidate(); model.evidence = []; model.selectedEvidence = [] }
        .onChange(of: end) { _ in model.invalidate(); model.evidence = []; model.selectedEvidence = [] }
        .onChange(of: rich) { _ in resetSources() }
        .onChange(of: computer) { _ in resetSources() }
        .onChange(of: conversationsFrom) { _ in resetSources() }
        .onChange(of: conversations) { _ in if model.request == nil { model.cancel() } else { settingsChanged() } }
        .onChange(of: exclusions) { _ in settingsChanged() }.onChange(of: aliases) { _ in settingsChanged() }.onChange(of: instructions) { _ in settingsChanged() }
        .onDisappear { model.cancel() }
    }
    private func closeStudio() { if let onClose { onClose() } else { dismiss() } }
    private func prepare() {
        do {
            let split: (String) -> [String] = { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            let replacements = try split(aliases).map { line -> GoalongProfileAnalysis.Replacement in
                let parts = line.components(separatedBy: "=>"); guard parts.count == 2 else { throw GoalongProfileAnalysis.invalid("Chaque remplacement doit suivre : nom privé => alias.") }
                return .init(term: parts[0].trimmingCharacters(in: .whitespaces), replacement: parts[1].trimmingCharacters(in: .whitespaces))
            }
            model.prepare(day: end.addingTimeInterval(-0.001), modules: modules, policy: .init(excluded_terms: split(exclusions), replacements: replacements, additional_instructions: instructions), includeConversations: conversations)
        } catch { model.error = error.localizedDescription }
    }
    private func chooseFile(_ action: @escaping (URL) -> Void, directory: URL? = nil) {
        guard let window = windowHost.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false; panel.directoryURL = directory
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { action(url) } }
    }
    private func saveFile(_ name: String, data: Data) {
        guard let window = windowHost.window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { do { try GoalongSiteAnalysisExportWriter.write(data, to: url); model.status = "Fichier exporté. Aucun envoi au site." } catch { model.error = error.localizedDescription } } }
    }
    private func exportPrompt(_ r: GoalongProfileAnalysis.Request) { do { model.save(); saveFile("goalong-prompt.txt", data: Data(try r.prompt().utf8)) } catch { model.error = error.localizedDescription } }
    private func exportCards() { do { saveFile("goalong-cartes.json", data: try model.projection()) } catch { model.error = error.localizedDescription } }
    private func importResult() { chooseFile { model.importResult($0) } }
    private func openSaved() { chooseFile({ url in
        model.open(url)
        if let request = model.request, let c = try? request.context() {
            exclusions = request.policy.excluded_terms.joined(separator: "\n")
            aliases = request.policy.replacements.map { $0.term + " => " + $0.replacement }.joined(separator: "\n")
            instructions = request.policy.additional_instructions; modules = Set(c.modules)
            conversations = c.include_conversations ?? c.modules.contains("ai")
        }
    }, directory: AppPaths.chatGPTDirectory.appendingPathComponent("profile-analyses")) }
    private func settingsChanged() {
        guard let request = model.request, let c = try? request.context() else { return }
        let expectedAliases = request.policy.replacements.map { $0.term + " => " + $0.replacement }.joined(separator: "\n")
        if exclusions != request.policy.excluded_terms.joined(separator: "\n") || aliases != expectedAliases || instructions != request.policy.additional_instructions || modules != Set(c.modules) || conversations != (c.include_conversations ?? c.modules.contains("ai")) { model.invalidate() }
    }
    private func resetSources() { model.invalidate(); model.evidence = []; model.selectedEvidence = [] }
    private func importEvidence() {
        chooseFile { url in
            do {
                struct Input: Decodable { var evidence: [GoalongProfileAnalysis.Evidence] }
                let bytes = try GoalongSiteAnalysisRequest.readSelectedBytes(url)
                let input = try JSONDecoder().decode(Input.self, from: bytes)
                model.invalidate()
                for var e in input.evidence { e.id = "e\(model.evidence.count + 1)"; model.evidence.append(e); model.selectedEvidence.insert(e.id) }
                model.status = "Preuves ajoutées localement. Vérifiez les dates et préparez le prompt pour appliquer vos règles."
            } catch { model.error = error.localizedDescription }
        }
    }
}

/// Explicit headings and ordinary containers keep the review readable by accessibility clients.
private struct GoalongProfileSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
    }
}

#endif
