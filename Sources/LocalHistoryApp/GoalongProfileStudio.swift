#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI

extension Notification.Name {
    static let goalongProfileAnalysisDidSave = Notification.Name("goalong.profile-analysis.did-save")
}

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
    /// Privacy-policy and pause revisions captured before the native events were read.
    private var guardRevisions: (privacy: String, pause: String)?
    private var pauseObserver: NSObjectProtocol?
    init() {
        pauseObserver = NotificationCenter.default.addObserver(forName: .goalongGlobalPauseDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.nativeSource, self.busy || self.request != nil, GoalongGlobalPause.isPaused(in: AppPaths.applicationSupportDirectory) else { return }
                self.dropNativeSelection("Pause globale active : la sélection a été retirée. Rechargez-la après la reprise.")
            }
        }
    }
    deinit { if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) } }
    private func dropNativeSelection(_ message: String) {
        invalidate(); evidence = []; selectedEvidence = []; guardRevisions = nil; error = message
    }
    /// Refuses a send when the global exclusions or the global pause changed since the events were read.
    nonisolated static func revalidate(native: Bool, revisions: (privacy: String, pause: String)?, root: URL) throws {
        guard native else { return }
        guard let revisions, GoalongPrivacyPolicy.load(in: root).revision == revisions.privacy else {
            throw GoalongProfileAnalysis.invalid("Les exclusions ont changé. Rechargez la sélection avant de continuer.")
        }
        try GoalongGlobalPause.revalidate(revisions.pause, in: root)
    }
    private func revalidateNative() throws {
        do { try Self.revalidate(native: nativeSource, revisions: guardRevisions, root: AppPaths.applicationSupportDirectory) }
        catch { dropNativeSelection(goalongUserMessage(error)); throw error }
    }
    var archive: GoalongProfileAnalysis.Archive? { guard let request, let result else { return nil }; return .init(request: request, result: result) }
    func invalidate() { cancel(); request = nil; result = nil; selectedItems = []; consent = false; reviewed = false }
    func cancel() { operation = UUID(); task?.cancel(); session?.close(); session = nil; busy = false }
    private var sourcesEnabled: Bool { (!nativeSource || (GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) && (!richSource || ActivityAnalysisPreferences.richContextEnabled))) && (!conversationSource || GoalongCapabilityConsentStore.shared.isEnabled(.aiConversations)) }
    func load(start: Date, end: Date, rich: Bool, computer: Bool = true, conversations: Bool = false, conversationsFrom: Date? = nil) {
        invalidate(); evidence = []; selectedEvidence = []; nativeSource = computer; richSource = computer && rich; conversationSource = conversations
        guard computer || conversations, sourcesEnabled else { error = "Choisissez une source et activez-la dans les réglages."; return }
        let root = AppPaths.applicationSupportDirectory
        if computer {
            do { guardRevisions = (GoalongPrivacyPolicy.load(in: root).revision, try GoalongGlobalPause.admit(in: root)) }
            catch { guardRevisions = nil; self.error = goalongUserMessage(error); return }
        } else { guardRevisions = nil }
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
                try Self.revalidate(native: computer, revisions: guardRevisions, root: root)
                evidence = rows; selectedEvidence = Set(rows.map(\.id)); busy = false; status = "\(GoalongUIFormat.count(rows.count, "événement")) chargé\(rows.count > 1 ? "s" : "") sur ce Mac. Préparez ensuite l’analyse pour appliquer vos règles. \(selection.1)"
            } catch { guard operation == id else { return }; self.error = goalongUserMessage(error); busy = false }
        }
    }
    func prepare(day: Date, modules: Set<String>, policy: GoalongProfileAnalysis.Policy, includeConversations: Bool = false) {
        invalidate(); error = nil
        do {
            guard sourcesEnabled else { throw GoalongProfileAnalysis.invalid("Une source sélectionnée a été désactivée.") }
            try revalidateNative()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
            request = try GoalongProfileAnalysis.prepare(date: formatter.string(from: day), timezone: TimeZone.current.identifier,
                evidence: evidence.filter { selectedEvidence.contains($0.id) }, policy: policy, selected: GoalongProfileAnalysis.modules.filter { modules.contains($0) }, includeConversations: includeConversations)
            status = "Prompt préparé. Les termes exclus ont retiré les événements concernés ; les alias ont été appliqués."
        } catch { self.error = goalongUserMessage(error) }
    }
    func analyze() {
        guard !busy, consent, let selected = request, sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { error = "Relisez la sélection et autorisez son envoi à l’agent."; return }
        do { try revalidateNative() } catch { return }
        busy = true; result = nil; selectedItems = []; reviewed = false; error = nil; status = "Analyse des seules rubriques choisies…"; let id = UUID(); operation = id
        let native = nativeSource, revisions = guardRevisions, root = AppPaths.applicationSupportDirectory
        task = Task {
            do {
                guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
                let home = AppPaths.chatGPTDirectory.appendingPathComponent("site-analysis-codex-home", isDirectory: true)
                guard let active = try await GoalongWorkAgent.makeOffMain({ try CodexAppServerSession(executableURL: executable, codexHomeURL: home, siteAnalysisOnly: true, homeLeaseWait: 0) },
                                                                          isStale: { [weak self] in self?.operation != id }, close: { $0.close() }) else { return }
                session = active; defer { active.close(); if operation == id { session = nil } }
                guard operation == id, sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { throw GoalongProfileAnalysis.invalid("Autorisation retirée.") }
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.revalidate(native: native, revisions: revisions, root: root)
                    let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
                    return try active.generateProfileAnalysis(request: selected, workingDirectory: directory)
                }.value
                guard operation == id else { return }
                guard sourcesEnabled, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) else { throw GoalongProfileAnalysis.invalid("Autorisation retirée pendant l’analyse.") }
                try Self.revalidate(native: native, revisions: revisions, root: root)
                result = try GoalongProfileAnalysis.apply(output, to: selected); busy = false; consent = false
                status = "Analyse terminée. Elle reste locale. Relisez, corrigez et choisissez éventuellement les résultats à transmettre."
            } catch { guard operation == id else { return }; self.error = goalongUserMessage(error); busy = false; consent = false }
        }
    }
    func importResult(_ url: URL) {
        do { guard let request, sourcesEnabled else { throw GoalongProfileAnalysis.invalid("Préparez ou rouvrez d’abord la sélection locale.") }
            result = try GoalongProfileAnalysis.apply(GoalongProfileAnalysis.parseResult(GoalongSiteAnalysisRequest.readSelectedBytes(url)), to: request)
            error = nil; selectedItems = []; reviewed = false; status = "Réponse contrôlée. Aucun résultat n’a été envoyé."
        } catch { self.error = goalongUserMessage(error) }
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
            NotificationCenter.default.post(name: .goalongProfileAnalysisDidSave, object: nil)
        } catch { self.error = goalongUserMessage(error) }
    }
    func open(_ url: URL) {
        do {
            let bytes = try GoalongSiteAnalysisRequest.readSelectedBytes(url)
            invalidate()
            if let saved = try? GoalongProfileAnalysis.parseArchive(bytes) {
                let checked = try GoalongProfileAnalysis.apply(saved.result, to: saved.request); request = saved.request; result = checked
            } else { let saved = try GoalongProfileAnalysis.parseRequest(bytes); _ = try saved.context(); request = saved }
            nativeSource = false; richSource = false; conversationSource = false; guardRevisions = nil; evidence = []; selectedEvidence = []; status = "Dossier local rouvert. Relisez-le avant tout envoi."
        } catch { self.error = goalongUserMessage(error) }
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
    private var studioModel: GoalongProfileStudioModel?
    private var studioDay: Date?
    private var studioLocalOnly = false
    enum Reopen: Equatable { case front, rebuild, keepWork, modeMismatch }
    /// A new day replaces the window's content only while nothing is loaded, running or analysed there.
    /// The same holds for the mode (local-only or with sending): an idle window takes the caller's mode, one with work keeps its own.
    static func reopen(shownDay: Date?, requestedDay: Date?, idle: Bool, calendar: Calendar = .current,
                       shownLocalOnly: Bool? = nil, requestedLocalOnly: Bool = false) -> Reopen {
        let sameMode = shownLocalOnly.map { $0 == requestedLocalOnly } ?? true
        if let requestedDay, !(shownDay.map { calendar.isDate($0, inSameDayAs: requestedDay) } ?? false) { return idle ? .rebuild : .keepWork }
        if !sameMode { return idle ? .rebuild : .modeMismatch }
        return .front
    }
    func show(localOnly: Bool = false, initialDay: Date? = nil, onSend: @escaping (Data) -> Void) {
        if let studioWindow {
            let model = studioModel
            let idle = model.map { !$0.busy && $0.request == nil && $0.result == nil } ?? true
            // One window serves every entry point: an idle one takes the mode (local-only or with sending) of the caller.
            let action = Self.reopen(shownDay: studioDay, requestedDay: initialDay, idle: idle, shownLocalOnly: studioLocalOnly, requestedLocalOnly: localOnly)
            switch action {
            case .front: break
            case .rebuild:
                let frame = studioWindow.frame
                studioWindow.contentViewController = content(localOnly: localOnly, initialDay: initialDay, onSend: onSend)
                studioWindow.setFrame(frame, display: true)
            case .keepWork:
                model?.status = "Une analyse est déjà ouverte pour une autre journée. Fermez-la pour analyser la journée choisie."
            case .modeMismatch:
                model?.status = studioLocalOnly
                    ? "Cette analyse est ouverte en mode local. Fermez-la pour préparer un envoi à votre compte Goalong."
                    : "Cette analyse est ouverte pour un envoi. Fermez-la pour une analyse locale seule."
            }
            studioWindow.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentViewController: content(localOnly: localOnly, initialDay: initialDay, onSend: onSend))
        window.title = ProductIdentity.windowTitle("Comprendre mon travail — Goalong History")
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
    private func content(localOnly: Bool, initialDay: Date?, onSend: @escaping (Data) -> Void) -> NSViewController {
        let model = GoalongProfileStudioModel()
        studioModel = model; studioLocalOnly = localOnly; studioDay = initialDay.map { Calendar.current.startOfDay(for: $0) }
        let view = GoalongProfileStudio(onSend: { [weak self] data in
            self?.studioWindow?.close()
            onSend(data)
        }, onClose: { [weak self] in self?.studioWindow?.close() }, localOnly: localOnly, initialDay: initialDay, model: model)
        return NSHostingController(rootView: view
            .environment(\.locale, GoalongUIFormat.locale)
            .background(LHTheme.pageBackground)
            .foregroundStyle(LHTheme.text)
            .tint(LHTheme.accent)
            .accentColor(LHTheme.accent)
            .goalongControls())
    }
    func windowWillClose(_ notification: Notification) {
        studioWindow?.contentViewController = nil
        studioWindow = nil; studioModel = nil; studioDay = nil
    }
}

/// Owns the profile studio window and the analysis it hands off, for the life of the dashboard.
/// A pane that opens the studio can disappear before the member sends; the hand-off must survive that.
@MainActor final class GoalongProfileStudioHost: ObservableObject {
    struct Share: Equatable { let data: Data; let privacyRevision: String }
    @Published var pending: Share?
    /// Brings the dashboard back, so the share sheet has a view to appear on. Wired by the app delegate.
    var onNeedsPresentation: (() -> Void)?
    let window = GoalongProfileWindow()
    private let currentRevision: () -> String
    init(currentRevision: @escaping () -> String = { GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision }) {
        self.currentRevision = currentRevision
    }
    func show(localOnly: Bool = false, initialDay: Date? = nil) {
        window.show(localOnly: localOnly, initialDay: initialDay) { [weak self] in self?.receive($0) }
    }
    /// The privacy revision is captured when the member sends.
    func receive(_ data: Data) { pending = Share(data: data, privacyRevision: currentRevision()); onNeedsPresentation?() }
}

/// Presents the reviewed analysis for sending, from a view that always exists in the dashboard.
struct GoalongProfileShareHost: View {
    @ObservedObject var host: GoalongProfileStudioHost
    var body: some View {
        Color.clear.sheet(isPresented: Binding(get: { host.pending != nil }, set: { if !$0 { host.pending = nil } })) {
            if let share = host.pending {
                GoalongWebsiteConnectionSheet(preparedAnalysis: share.data, privacyRevision: share.privacyRevision).goalongControls()
            }
        }
    }
}

struct GoalongProfileStudio: View {
    let onSend: (Data) -> Void
    var onClose: (() -> Void)? = nil
    var localOnly = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GoalongProfileStudioModel
    @StateObject private var connection = GoalongSiteAnalysisModel()
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @State private var start = Calendar.current.startOfDay(for: GoalongToday.now)
    /// True when the last day picked for the start came after the analysed day and was brought back to it (UI-14, M3).
    @State private var startCapped = false
    @State private var end = GoalongToday.now
    @State private var rich = false
    @State private var computer = true
    @State private var conversations = false
    @State private var conversationsFrom = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: GoalongToday.now))!
    @State private var modules = Set(GoalongProfileAnalysis.modules.filter { $0 != "ai" })
    @State private var exclusions = ""
    @State private var aliases = ""
    @State private var instructions = ""
    init(onSend: @escaping (Data) -> Void, onClose: (() -> Void)? = nil, localOnly: Bool = false, initialDay: Date? = nil,
         model: GoalongProfileStudioModel? = nil) {
        self.onSend = onSend; self.onClose = onClose; self.localOnly = localOnly
        _model = StateObject(wrappedValue: model ?? GoalongProfileStudioModel())
        let day = Calendar.current.startOfDay(for: initialDay ?? GoalongToday.now)
        _start = State(initialValue: day)
        _end = State(initialValue: min(GoalongToday.now, Calendar.current.date(byAdding: .day, value: 1, to: day) ?? GoalongToday.now))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Comprendre mon travail").font(.system(size: 22, weight: .bold)).tracking(-0.4).accessibilityAddTraits(.isHeader); Spacer(); Button("Fermer") { model.cancel(); closeStudio() } }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Analysez votre activité pour vous-même. Vous pourrez conserver le résultat ici, puis choisir séparément ce qui part dans votre compte Goalong.").foregroundStyle(LHTheme.secondaryText)
                    HStack { Button("Ouvrir une analyse ou une sélection enregistrée…") { openSaved() }; Spacer() }
                    GoalongProfileSection("Choisir les données") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Journée analysée").font(.system(size: 13))
                                DateSelectionControl(date: analyzedDay, onChange: selectDay, showsToday: false)
                            }
                            Toggle("Activité de ce Mac", isOn: $computer)
                            if computer {
                                // UI-12A: the same day selector as above, never the system DatePicker; at most the analysed day.
                                HStack(spacing: 8) {
                                    Text("Début de l’activité").font(.system(size: 13))
                                    DateSelectionControl(date: start, onChange: { day in
                                        let picked = Calendar.current.startOfDay(for: day)
                                        startCapped = picked > analyzedDay
                                        start = min(picked, analyzedDay)
                                    }, showsToday: false)
                                }
                                if startCapped {
                                    Text("Le début ne peut pas dépasser la journée analysée : il revient à ce jour.")
                                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                        .accessibilityIdentifier("profile-start-capped")
                                }
                                Toggle("Inclure les textes de fenêtres déjà autorisés", isOn: $rich) }
                            Toggle("Conversations IA, comme contexte", isOn: $conversations)
                            if conversations {
                                HStack(spacing: 8) {
                                    Text("Conversations actives depuis").font(.system(size: 13))
                                    DateSelectionControl(date: conversationsFrom, onChange: { conversationsFrom = Calendar.current.startOfDay(for: $0) }, showsToday: false)
                                }
                                Text("La journée analysée et jusqu’à 31 jours avant. Seules les sources déjà autorisées sont lues. Les échanges éclairent vos projets et décisions, même si « Usage de l’IA » est décochée. Certains messages plus anciens peuvent venir sans heure précise.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            }
                            Text("Goalong lit les applications, fenêtres, sites et interactions, avec leurs heures. Les champs protégés et les éléments supprimés sont exclus. Les textes longs sont coupés, et un moment sans données reste inconnu.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            Button("Ajouter un fichier de données…") { importEvidence() }.disabled(model.busy)
                            if !model.evidence.isEmpty { GoalongDisclosureGroup("Choisir les événements (\(model.selectedEvidence.count)/\(model.evidence.count))") {
                                HStack { Button("Tout sélectionner") { model.selectedEvidence = Set(model.evidence.map(\.id)); model.invalidate() }; Button("Tout décocher") { model.selectedEvidence = []; model.invalidate() } }
                                LazyVStack(alignment: .leading) { ForEach(model.evidence, id: \.id) { e in Toggle(isOn: Binding(get: { model.selectedEvidence.contains(e.id) }, set: { yes in if yes { model.selectedEvidence.insert(e.id) } else { model.selectedEvidence.remove(e.id) }; model.invalidate() })) { Text("\(e.start), \(e.application), \(e.text)").font(.system(size: 12)).lineLimit(3) } } }
                            } }
                        }.padding(8)
                    }
                    GoalongProfileSection("Choisir les analyses et ce qui reste privé") {
                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                                ForEach(GoalongProfileAnalysis.modules, id: \.self) { key in Toggle(GoalongProfileAnalysis.labels[key] ?? key, isOn: Binding(get: { modules.contains(key) }, set: { yes in if yes { modules.insert(key) } else { modules.remove(key) }; settingsChanged() })) }
                            }
                            // Ten ticked boxes: ink, so the lime stays rare (UI-14, écran 11).
                            .toggleStyle(.goalongCheckboxInk)
                            Text("Décochez une rubrique pour que l’agent ne l’analyse pas. La rubrique « Usage de l’IA » ne dépend pas du choix des conversations IA plus haut.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            Text("Exclure des applications, projets ou termes — un par ligne").font(.system(size: 13, weight: .medium))
                            GoalongTextArea(text: $exclusions, minHeight: 60).accessibilityLabel("Termes à exclure")
                            Text("Les événements contenant ces termes sont retirés avant analyse. Toute réapparition littérale dans un résultat est masquée.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            Text("Remplacer des noms — une ligne « nom privé => alias »").font(.system(size: 13, weight: .medium))
                            GoalongTextArea(text: $aliases, minHeight: 60).accessibilityLabel("Règles de remplacement")
                            Text("Exemple : Projet Atlas => Projet secret. Les remplacements s’appliquent avant analyse et avant export.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            Text("Ce que l’agent ne doit pas aborder — complément personnel").font(.system(size: 13, weight: .medium))
                            GoalongTextArea(text: $instructions, minHeight: 80).accessibilityLabel("Consignes personnelles de confidentialité")
                            Text("Pour masquer un nom précis, ajoutez-le aussi aux règles ci-dessus. Les consignes libres guident l’agent ; elles ne garantissent pas à elles seules qu’un sujet ne sera jamais évoqué. Relisez les résultats.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        }.padding(8)
                    }
                    if let request = model.request {
                        Text("Période préparée : \((try? request.context().date) ?? ""). La consigne indique l’heure connue de chaque élément.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        GoalongProfileSection("Vérifier et analyser") {
                            VStack(alignment: .leading, spacing: 12) {
                                GoalongDisclosureGroup("Voir la consigne exacte") { Text((try? request.prompt()) ?? "Sélection invalide").font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                                HStack { Text(connection.accountLabel).font(.system(size: 12)); Spacer(); Button(connection.connected ? "Déconnecter ChatGPT" : "Connecter ChatGPT") { if connection.connected { connection.disconnect() } else { connection.connect() } }.disabled(model.busy || connection.busy) }
                                Toggle("J’autorise l’envoi de ce contexte à l’agent connecté", isOn: $model.consent)
                                HStack { Button("Exporter la consigne pour mon agent…") { exportPrompt(request) }; Button("Importer sa réponse…") { importResult() }; Button("Enregistrer ici") { model.save() } }.disabled(model.busy)
                                Text("L’export contient seulement les données préparées, sans les noms d’origine de vos remplacements. Votre agent suit ses propres conditions. Aucun de ces boutons n’envoie au site.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            }.padding(8)
                        }
                    }
                    if let result = model.result {
                        GoalongProfileSection(localOnly ? "Relire et conserver" : "Relire et choisir les résultats à transmettre") {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(localOnly ? "Relisez les cartes avant de les conserver. Elles apparaîtront dans Analyses, sans envoi au site." : "Aucun résultat n’est sélectionné par défaut. Les éléments sources, leurs heures et vos règles privées restent sur ce Mac.").font(.system(size: 12))
                                ForEach(result.items, id: \.id) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if !localOnly { Toggle("Transmettre : \(GoalongProfileAnalysis.labels[item.module] ?? item.module)", isOn: Binding(get: { model.selectedItems.contains(item.id) }, set: { yes in if yes { model.selectedItems.insert(item.id) } else { model.selectedItems.remove(item.id) }; model.reviewed = false })) }
                                        TextField("Titre", text: Binding(get: { item.title }, set: { model.correct(item.id, field: "title", text: $0) })).textFieldStyle(GoalongFieldStyle())
                                        GoalongTextArea(text: Binding(get: { item.summary }, set: { model.correct(item.id, field: "summary", text: $0) }), minHeight: 70).accessibilityLabel("Synthèse \(item.title)")
                                        TextField("Limites", text: Binding(get: { item.caveat }, set: { model.correct(item.id, field: "caveat", text: $0) })).textFieldStyle(GoalongFieldStyle())
                                        Text("\(item.status), \(GoalongUIFormat.count(item.evidence_refs.count, "élément source", plural: "éléments sources"))").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                        GoalongDisclosureGroup("Voir les éléments sources") { ForEach((try? model.request?.context().evidence.filter { item.evidence_refs.contains($0.id) }) ?? [], id: \.id) { e in Text("\(e.start), \(e.application)\n\(e.text)").font(.system(size: 12)).textSelection(.enabled) } }
                                        Divider()
                                    }
                                }
                                if !localOnly {
                                Toggle("J’ai relu les résultats sélectionnés et leur confidentialité", isOn: $model.reviewed)
                                if let archive = model.archive, let projection = try? GoalongProfileAnalysis.project(archive, selectedIDs: model.selectedItems), let bytes = try? GoalongContextualRhythm.encode(projection) {
                                    GoalongDisclosureGroup("Voir exactement les cartes sélectionnées") { Text(String(decoding: bytes, as: UTF8.self)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                                }
                                HStack { Button("Exporter les cartes sélectionnées…") { exportCards() }; Button("Préparer l’envoi à mon compte Goalong") { do { let bytes = try model.projection(); onSend(bytes); closeStudio() } catch { model.error = goalongUserMessage(error) } } }.disabled(!model.reviewed || model.selectedItems.isEmpty || model.busy)
                                Text("Le partage avec les autres se règle ensuite sur le site, rubrique par rubrique et selon le public choisi.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                }
                            }.padding(8)
                        }
                    }
                    if model.busy { HStack { ProgressView(); Text(model.status); Button("Annuler") { model.cancel() } } }
                    else if !model.status.isEmpty { Text(model.status).font(.system(size: 12)) }
                    if let error = model.error ?? connection.error { Text(error).foregroundStyle(.red) }
                }.padding(22)
            }
            // One lime action, at the foot: the next step of the analysis (DESIGN §9).
            GoalongSheetFooter(inset: 22) {
                Spacer()
                nextStepButton.buttonStyle(LHPrimaryButtonStyle())
            }
        }.frame(minWidth: 700, idealWidth: 830, minHeight: 540, idealHeight: 760)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .onChange(of: start) { _ in model.invalidate(); model.evidence = []; model.selectedEvidence = [] }
        .onChange(of: end) { _ in model.invalidate(); model.evidence = []; model.selectedEvidence = [] }
        .onChange(of: rich) { _ in resetSources() }
        .onChange(of: computer) { _ in resetSources() }
        .onChange(of: conversationsFrom) { _ in resetSources() }
        // Before a request exists, a source change drops loaded data so the footer offers « Charger les données » again.
        .onChange(of: conversations) { _ in if model.request == nil { resetSources() } else { settingsChanged() } }
        .onChange(of: exclusions) { _ in settingsChanged() }.onChange(of: aliases) { _ in settingsChanged() }.onChange(of: instructions) { _ in settingsChanged() }
        .onDisappear { model.cancel() }
    }
    private func closeStudio() { if let onClose { onClose() } else { dismiss() } }
    @ViewBuilder private var nextStepButton: some View {
        if model.result != nil {
            Button("Conserver l’analyse") { model.save() }.disabled(model.busy)
        } else if model.request != nil {
            Button("Lancer l’analyse") { model.analyze() }.disabled(model.busy || !connection.connected || !model.consent)
        } else if !model.evidence.isEmpty {
            Button("Préparer l’analyse") { prepare() }.disabled(model.busy || model.selectedEvidence.isEmpty || modules.isEmpty)
        } else {
            Button("Charger les données") { model.load(start: start, end: end, rich: rich, computer: computer, conversations: conversations, conversationsFrom: conversationsFrom) }
                .disabled(model.busy || (!computer && !conversations))
        }
    }
    /// The analysed day, as the app writes days (« 23 oct. 2026 »); `end` is exclusive.
    private var analyzedDay: Date { Calendar.current.startOfDay(for: end.addingTimeInterval(-0.001)) }
    private func selectDay(_ day: Date) {
        let start = Calendar.current.startOfDay(for: day)
        self.start = start
        startCapped = false
        end = min(GoalongToday.now, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? GoalongToday.now)
    }
    private func prepare() {
        do {
            let split: (String) -> [String] = { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            let replacements = try split(aliases).map { line -> GoalongProfileAnalysis.Replacement in
                let parts = line.components(separatedBy: "=>"); guard parts.count == 2 else { throw GoalongProfileAnalysis.invalid("Chaque remplacement doit suivre : nom privé => alias.") }
                return .init(term: parts[0].trimmingCharacters(in: .whitespaces), replacement: parts[1].trimmingCharacters(in: .whitespaces))
            }
            model.prepare(day: end.addingTimeInterval(-0.001), modules: modules, policy: .init(excluded_terms: split(exclusions), replacements: replacements, additional_instructions: instructions), includeConversations: conversations)
        } catch { model.error = goalongUserMessage(error) }
    }
    private func chooseFile(_ action: @escaping (URL) -> Void, directory: URL? = nil) {
        guard let window = windowHost.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false; panel.directoryURL = directory
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { action(url) } }
    }
    private func saveFile(_ name: String, data: Data) {
        guard let window = windowHost.window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { do { try GoalongSiteAnalysisExportWriter.write(data, to: url); model.status = "Fichier exporté. Aucun envoi au site." } catch { model.error = goalongUserMessage(error) } } }
    }
    private func exportPrompt(_ r: GoalongProfileAnalysis.Request) { do { model.save(); saveFile("goalong-prompt.txt", data: Data(try r.prompt().utf8)) } catch { model.error = goalongUserMessage(error) } }
    private func exportCards() { do { saveFile("goalong-cartes.json", data: try model.projection()) } catch { model.error = goalongUserMessage(error) } }
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
                model.status = "Données ajoutées sur ce Mac. Vérifiez les dates, puis préparez l’analyse pour appliquer vos règles."
            } catch { model.error = goalongUserMessage(error) }
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
        // A group title above a group surface, as in Réglages (DESIGN §6, §8).
        let shape = RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText).accessibilityAddTraits(.isHeader)
            content.frame(maxWidth: .infinity, alignment: .leading)
                .padding(LHTheme.cardInset)
                .background(LHTheme.cardBackground, in: shape)
                .overlay(shape.strokeBorder(LHTheme.separator))
        }
    }
}

#endif
