#if os(macOS)
import Foundation
import SwiftUI
import LocalHistoryCore

/// Local source access and outgoing analysis authorization are deliberately separate.
struct GoalongAnalysisSelection: Codable, Equatable {
    var version = 1
    var reviewed = false
    var computer = false
    var screenTime = false
    var conversations = false
    var details = false
    var revision = UUID().uuidString
    var privacyRevision: String?
    var hasSources: Bool { computer || screenTime || conversations }
    func isValid(for policy: GoalongPrivacyPolicy) -> Bool {
        reviewed && hasSources && !policy.blocked && privacyRevision == policy.revision
    }
    static func load(root: URL = AppPaths.applicationSupportDirectory) -> Self {
        let file = root.appendingPathComponent("chatgpt-analysis-selection.json")
        guard let data = try? Data(contentsOf: file), data.count < 8192,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else {
            var empty = Self(); empty.revision = "unreviewed"; return empty
        }
        return value
    }
    func save(root: URL = AppPaths.applicationSupportDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("chatgpt-analysis-selection.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard Self.load(root: root) == self else { throw NSError(domain: "GoalongAnalysisSelection", code: 1) }
    }
}

@MainActor struct GoalongChatGPTSettings: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var runtime = ChatGPTRecapRuntime.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @State private var selection = GoalongAnalysisSelection.load()
    @State private var choosing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChatGPTAccountConnectionCard(runtime: runtime)
            GoalongSettingsGroup(title: "Données pour ChatGPT") {
                HStack {
                    Text(selection.isValid(for: exclusions.policy) ? selectionLabel : "Sélection à confirmer").font(.system(size: 13))
                    Spacer()
                    Button("Choisir…") { choosing = true }.buttonStyle(.bordered)
                }
                Toggle("Autoriser les analyses", isOn: Binding(get: { consents.isEnabled(.chatGPTAnalysis) && selection.isValid(for: exclusions.policy) }, set: { enabled in
                    if enabled { choosing = true }
                    else {
                        runtime.stop()
                        if !consents.set(.chatGPTAnalysis, enabled: false, surface: .settings) { error = "L’autorisation n’a pas pu être désactivée." }
                    }
                })).toggleStyle(.switch)
                Toggle("Analyser automatiquement la veille", isOn: Binding(
                    get: { runtime.automaticRecapsEnabled && selection.isValid(for: exclusions.policy) },
                    set: { runtime.automaticRecapsEnabled = $0; if $0 { runtime.start() } }))
                    .toggleStyle(.switch).disabled(!selection.isValid(for: exclusions.policy) || !consents.isEnabled(.chatGPTAnalysis))
                if !selection.isValid(for: exclusions.policy) && runtime.automaticRecapsEnabled {
                    Text("Ancienne programmation suspendue : confirmez les données à analyser.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("ChatGPT reçoit la sélection pour l’analyser. Cette action n’envoie rien au site Goalong.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if exclusions.policy.hasExclusions {
                Text("Exclusions actives : les textes non filtrables sont bloqués.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if selection.isValid(for: exclusions.policy) {
                Button("Analyser la journée sélectionnée") {
                    runtime.configure(deviceID: model.deviceID); runtime.selectDay(model.selectedDay)
                    runtime.generateRecap(); model.selectSection(.chatGPTRecap)
                }.buttonStyle(.bordered).disabled(!consents.isEnabled(.chatGPTAnalysis))
            }
        }
        .onAppear { runtime.configure(deviceID: model.deviceID); if consents.isEnabled(.chatGPTAnalysis) { runtime.activate() } }
        .sheet(isPresented: $choosing) { GoalongAnalysisSelectionSheet(selection: selection) { value in selection = value } }
        .alert(item: $runtime.alert) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("Fermer"))) }
        .alert("Réglage non modifié", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
    private var selectionLabel: String {
        [(selection.computer ? "Activité de ce Mac" : nil), (selection.screenTime ? "Temps d’écran" : nil),
         (selection.conversations ? "Conversations" : nil)].compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor struct GoalongAnalysisSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var selection: GoalongAnalysisSelection
    let onSave: (GoalongAnalysisSelection) -> Void
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Données pour ChatGPT").font(.system(size: 23, weight: .semibold))
            Text("Ces données quitteront le Mac lors des analyses que vous lancerez ou programmerez.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            GoalongSettingsGroup(title: "Sources autorisées") {
                source("Applications et durées de ce Mac", capability: .localComputerHistory, value: $selection.computer)
                source("Temps d’écran Apple", capability: .appleScreenTime, value: $selection.screenTime)
                source("Conversations locales", capability: .aiConversations, value: $selection.conversations)
                    .disabled(exclusions.policy.hasExclusions)
            }
            Toggle("Inclure les titres et le contexte détaillé", isOn: $selection.details)
                .toggleStyle(.checkbox).disabled(!selection.computer || exclusions.policy.hasExclusions)
            if selection.details || selection.conversations {
                Text("Peut transmettre des messages et documents personnels.").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
            if exclusions.policy.hasExclusions {
                Text("Les exclusions retirent aussi les textes et totaux non filtrables.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(LHTheme.warning) }
            Divider()
            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                Spacer()
                Button("Autoriser cette sélection") { save() }.buttonStyle(LHPrimaryButtonStyle()).disabled(!selection.hasSources)
            }
        }.padding(26).frame(width: 560).background(LHTheme.pageBackground)
    }
    private func source(_ label: String, capability: GoalongCapability, value: Binding<Bool>) -> some View {
        HStack {
            Toggle(label, isOn: value).toggleStyle(.checkbox).disabled(!consents.isEnabled(capability))
            Spacer()
            if !consents.isEnabled(capability) { Text("Source désactivée").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
    private func save() {
        var next = selection
        next.computer = next.computer && consents.isEnabled(.localComputerHistory)
        next.screenTime = next.screenTime && consents.isEnabled(.appleScreenTime)
        next.conversations = next.conversations && consents.isEnabled(.aiConversations) && !exclusions.policy.hasExclusions
        next.details = next.details && next.computer && !exclusions.policy.hasExclusions
        guard next.hasSources else { error = "Choisissez au moins une source disponible."; return }
        next.reviewed = true; next.revision = UUID().uuidString; next.privacyRevision = exclusions.policy.revision
        do {
            ChatGPTRecapRuntime.shared.stop()
            ChatGPTRecapRuntime.shared.automaticRecapsEnabled = false
            try next.save()
            guard consents.set(.chatGPTAnalysis, enabled: true, surface: .settings) else { error = "L’autorisation n’a pas pu être enregistrée."; return }
            NotificationCenter.default.post(name: .goalongAnalysisSelectionDidChange, object: nil)
            onSave(next); dismiss()
        } catch { self.error = "La sélection n’a pas été enregistrée." }
    }
}
#endif
