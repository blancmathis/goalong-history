#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore
import SwiftUI

/// The user prepares a local selection first. Only the frozen, reviewed request
/// reaches the existing isolated provider session. There is no website transport here.
@MainActor final class GoalongRhythmStudioModel: ObservableObject {
    @Published var request: GoalongContextualRhythm.Request?
    @Published var selectedEvidence = Set<String>()
    @Published var interpretation = ""
    @Published private(set) var result: GoalongContextualRhythm.Rhythm?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var status = ""
    @Published var consentToAnalyze = false
    @Published var includeInterpretation = true
    private var usedRichContext = false
    private var operation = UUID()
    private var session: CodexAppServerSession?
    private var task: Task<Void, Never>?
    var selection: GoalongContextualRhythm.Request? {
        guard var selected = request else { return nil }
        selected.rhythm.episodes = selected.rhythm.episodes?.map { row in
            var row = row; row.evidence = row.evidence?.filter { selectedEvidence.contains($0.id) }; return row
        }
        return selected
    }
    func invalidate() { cancel(); request = nil; result = nil; selectedEvidence = []; interpretation = ""; consentToAnalyze = false }
    func cancel() { operation = UUID(); task?.cancel(); session?.close(); session = nil; busy = false }
    func load(start: Date, end: Date, project: String, intent: String, masks: [String], rich: Bool) {
        guard !busy else { return }
        let consents = GoalongCapabilityConsentStore.shared
        guard consents.isEnabled(.localComputerHistory), !rich || ActivityAnalysisPreferences.richContextEnabled else { error = "Activez les sources sélectionnées dans les réglages de Goalong History."; return }
        invalidate(); usedRichContext = rich; busy = true; error = nil; status = "Lecture locale de la session…"
        let id = operation, root = AppPaths.applicationSupportDirectory
        task = Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try GoalongContextualRhythm.load(root: root, start: start, end: end, project: project, intent: intent,
                        device: "Ce Mac", masks: masks, includeRichContext: rich)
                }.value
                guard operation == id else { return }
                guard consents.isEnabled(.localComputerHistory), !rich || ActivityAnalysisPreferences.richContextEnabled else { throw GoalongContextualRhythm.Failure.invalid("Une source a été désactivée pendant la lecture.") }
                request = value; selectedEvidence = Set(value.rhythm.episodes?.flatMap { ($0.evidence ?? []).map(\.id) } ?? [])
                status = "Sélection locale prête. Choisissez les éléments à confier à l'agent."; busy = false
            } catch { guard operation == id else { return }; self.error = error.localizedDescription; busy = false }
        }
    }
    func selectionChanged() { consentToAnalyze = false; result = nil; interpretation = "" }
    func analyze() {
        guard !busy, consentToAnalyze, let selected = selection,
              GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis),
              GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory),
              !usedRichContext || ActivityAnalysisPreferences.richContextEnabled else { error = "Relisez la sélection et autorisez son analyse."; return }
        busy = true; error = nil; result = nil; status = "L'agent examine les épisodes sélectionnés…"
        let id = UUID(); operation = id
        task = Task {
            do {
                guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
                let active = try CodexAppServerSession(executableURL: executable,
                    codexHomeURL: AppPaths.chatGPTDirectory.appendingPathComponent("site-analysis-codex-home", isDirectory: true), siteAnalysisOnly: true)
                session = active
                defer { active.close(); if operation == id { session = nil } }
                guard operation == id, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis),
                      GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory),
              !usedRichContext || ActivityAnalysisPreferences.richContextEnabled else { throw GoalongContextualRhythm.Failure.invalid("Autorisation retirée.") }
                let annotation = try await Task.detached(priority: .userInitiated) {
                    let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory()
                    defer { try? FileManager.default.removeItem(at: directory) }
                    return try active.generateRhythmAnalysis(request: selected, workingDirectory: directory)
                }.value
                guard operation == id, GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis),
                      GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory),
              !usedRichContext || ActivityAnalysisPreferences.richContextEnabled else { busy = false; return }
                result = try GoalongContextualRhythm.apply(annotation, to: selected)
                interpretation = result?.interpretation ?? ""; consentToAnalyze = false; busy = false
                status = "Interprétation prête. Relisez les associations avant de préparer l'envoi au site."
            } catch { guard operation == id else { return }; self.error = error.localizedDescription; busy = false; consentToAnalyze = false }
        }
    }
    func importAnnotation(_ url: URL) {
        guard !busy, let selected = selection else { return }
        do {
            let data = try GoalongSiteAnalysisRequest.readSelectedBytes(url)
            result = try GoalongContextualRhythm.apply(GoalongContextualRhythm.parseAnnotation(data), to: selected)
            interpretation = result?.interpretation ?? ""; status = "Réponse de votre agent importée. Relisez-la avant l'envoi."
        } catch { self.error = error.localizedDescription }
    }
    func correct(id: String, relation: String) {
        guard var value = result ?? selection?.rhythm, let index = value.episodes?.firstIndex(where: { $0.id == id }),
              value.episodes?[index].relation != "unknown", ["project", "other", "unclassified"].contains(relation) else { return }
        value.episodes?[index].relation = relation
        value.episodes?[index].semantic_origin = "owner"
        value.episodes?[index].explanation = "Association corrigée par le propriétaire."
        result = GoalongContextualRhythm.measure(value)
    }
    func reviewedResult() -> GoalongContextualRhythm.Rhythm? {
        guard var value = result ?? selection?.rhythm else { return nil }
        if includeInterpretation && !interpretation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if interpretation != value.interpretation { value.interpretation_origin = "owner"; value.interpretation_refs = [] }
            value.interpretation = interpretation
        } else { value.interpretation = nil; value.interpretation_refs = nil; value.interpretation_origin = nil }
        return value
    }
}

struct GoalongRhythmStudio: View {
    let day: Date
    let masks: [String]
    let onAccept: (GoalongContextualRhythm.Rhythm) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GoalongRhythmStudioModel()
    @StateObject private var connection = GoalongSiteAnalysisModel()
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @State private var start: Date
    @State private var end: Date
    @State private var project = ""
    @State private var intent = ""
    @State private var rich = false
    init(day: Date, masks: [String], onAccept: @escaping (GoalongContextualRhythm.Rhythm) -> Void) {
        self.day = day; self.masks = masks; self.onAccept = onAccept
        let base = Calendar.current.startOfDay(for: day)
        _start = State(initialValue: base.addingTimeInterval(9*3600)); _end = State(initialValue: base.addingTimeInterval(10*3600))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Comprendre une session").font(.title2.weight(.semibold)); Spacer(); Button("Fermer") { model.cancel(); dismiss() } }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choisissez un projet et une plage de la journée. Les durées viennent des observations ; l'agent explique leur contexte.").foregroundStyle(.secondary)
                    HStack { DatePicker("Début", selection: $start, displayedComponents: .hourAndMinute); DatePicker("Fin", selection: $end, displayedComponents: .hourAndMinute) }
                    TextField("Projet", text: $project).textFieldStyle(.roundedBorder)
                    TextField("Ce que vous souhaitiez faire pendant cette session", text: $intent).textFieldStyle(.roundedBorder)
                    Toggle("Inclure les extraits de contexte enrichi déjà autorisés", isOn: $rich)
                    Text("Les titres et domaines disponibles servent de contexte. Le texte enrichi est facultatif et peut contenir des informations personnelles ; relisez les extraits avant analyse.").font(.caption).foregroundStyle(.secondary)
                    Button("Préparer la sélection locale") { model.load(start: start, end: end, project: project, intent: intent, masks: masks, rich: rich) }.disabled(model.busy || project.isEmpty)
                    if let selected = model.selection {
                        Divider()
                        Text("Contexte à analyser").font(.headline)
                        Text("Décochez les éléments privés. Les épisodes sans contexte restent à préciser.").font(.caption)
                        ForEach(selected.rhythm.episodes ?? [], id: \.id) { row in
                            DisclosureGroup("\(row.application ?? "Non observé") · +\(duration(row.offset_ms)) · \(duration(row.duration_ms))") {
                                ForEach(model.request?.rhythm.episodes?.first(where: {$0.id == row.id})?.evidence ?? [], id: \.id) { item in
                                    Toggle(isOn: Binding(get: { model.selectedEvidence.contains(item.id) }, set: { include in
                                        if include { model.selectedEvidence.insert(item.id) } else { model.selectedEvidence.remove(item.id) }; model.selectionChanged()
                                    })) { Text(item.text).font(.caption).textSelection(.enabled) }
                                }
                                if row.evidence?.isEmpty != false { Text("Contexte non fourni").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        DisclosureGroup("Voir la sélection exacte pour l'agent") { Text(String(decoding: (try? selected.encoded()) ?? Data(), as: UTF8.self)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        HStack {
                            Text(connection.accountLabel).font(.caption)
                            Spacer()
                            Button(connection.connected ? "Déconnecter ChatGPT" : "Connecter ChatGPT") { if connection.connected { connection.disconnect() } else { connection.connect() } }.disabled(connection.busy || model.busy)
                        }
                        Toggle("J'autorise l'envoi de cette sélection à l'agent connecté", isOn: $model.consentToAnalyze)
                        Button("Analyser le contexte de cette session") { model.analyze() }.disabled(!connection.connected || !model.consentToAnalyze || model.busy)
                        HStack {
                            Button("Préparer pour mon autre agent…") { exportRequest(selected) }.disabled(model.busy)
                            Button("Importer sa réponse…") { importResponse() }.disabled(model.busy)
                        }
                        Text("L'autre agent reçoit seulement le fichier que vous lui fournissez et suit ses propres conditions. Aucune analyse n'envoie de données au site.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let value = model.result {
                        Divider(); Text("Relire et corriger").font(.headline)
                        HStack { metric("Lié au projet", value.project_ms); metric("Plus longue séquence", value.longest_project_ms); VStack { Text("Consultations brèves").font(.caption); Text("\(value.brief_consultations) · \(duration(value.brief_consultation_ms))").font(.headline) } }
                        ForEach(value.episodes ?? [], id: \.id) { row in
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("\(row.application ?? "Non observé") · \(duration(row.duration_ms))").font(.subheadline)
                                    Spacer()
                                    if row.relation != "unknown" { Picker("Association", selection: Binding(get: { row.relation }, set: { model.correct(id: row.id, relation: $0) })) {
                                        Text("Projet").tag("project"); Text("Autre sujet").tag("other"); Text("À préciser").tag("unclassified")
                                    }.frame(width: 180) }
                                }
                                if let explanation = row.explanation { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                                ForEach(row.evidence ?? [], id: \.id) { Text("Élément choisi : \($0.text)").font(.caption).textSelection(.enabled) }
                            }
                        }
                        Toggle("Inclure l'interprétation relue", isOn: $model.includeInterpretation)
                        TextEditor(text: $model.interpretation).frame(height: 100).accessibilityLabel("Interprétation de la session")
                        Text("L'association et le texte restent des interprétations. Les trous de collecte ne sont jamais changés en pauses.").font(.caption)
                    }
                    if model.busy { HStack { ProgressView(); Text(model.status); Button("Annuler") { model.cancel() } } }
                    if let error = model.error ?? connection.error { Text(error).foregroundStyle(.red) }
                    if !model.status.isEmpty && !model.busy { Text(model.status).font(.caption) }
                }.padding(22)
            }
            Divider()
            HStack { Text("Vous choisirez ensuite les champs transmis au site.").font(.caption); Spacer(); Button("Utiliser cette session relue") {
                if let value = model.reviewedResult() { onAccept(value); dismiss() }
            }.disabled(model.result == nil || model.busy).buttonStyle(LHPrimaryButtonStyle()) }.padding(20)
        }.frame(width: 760, height: 820)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .onChange(of: start) { _ in model.invalidate() }.onChange(of: end) { _ in model.invalidate() }
        .onChange(of: project) { _ in model.invalidate() }.onChange(of: intent) { _ in model.invalidate() }.onChange(of: rich) { _ in model.invalidate() }
        .onDisappear { model.cancel() }
    }
    private func duration(_ ms: Int) -> String { let seconds = Double(ms)/1000; return seconds < 60 ? String(format: "%g s", seconds) : String(format: "%g min", seconds/60) }
    private func metric(_ label: String, _ ms: Int) -> some View { VStack(alignment: .leading) { Text(label).font(.caption); Text(duration(ms)).font(.headline) } }
    private func exportRequest(_ selected: GoalongContextualRhythm.Request) {
        guard let window = windowHost.window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "goalong-session-\(selected.date).json"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let object: [String: Any] = ["instructions": selected.prompt, "request": try JSONSerialization.jsonObject(with: selected.encoded())]
                try GoalongSiteAnalysisExportWriter.write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: url)
            } catch { model.error = error.localizedDescription }
        }
    }
    private func importResponse() {
        guard let window = windowHost.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { model.importAnnotation(url) } }
    }
}
#endif
