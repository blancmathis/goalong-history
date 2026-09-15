#if os(macOS)
import Foundation
import SwiftUI
import LocalHistoryCore

@MainActor struct GoalongChatGPTSettings: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var runtime = ChatGPTRecapRuntime.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @State private var selection = GoalongAnalysisSelection.load()
    @State private var editorTab = 0
    @State private var editing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ChatGPTAccountConnectionCard(runtime: runtime)
            GoalongSettingsGroup(title: "Votre analyse") {
                GoalongSettingsLink(title: "Données pour ChatGPT", value: sourceSummary, symbol: "line.3.horizontal.decrease.circle") { open(0) }
                Divider()
                GoalongSettingsLink(title: "Masquer des noms", value: "\(selection.replacements?.filter { !$0.search.isEmpty }.count ?? 0) remplacements", symbol: "text.badge.minus") { open(1) }
                Divider()
                GoalongSettingsLink(title: "Personnaliser le bilan", value: selection.outputGuidance?.isEmpty == false ? "Consignes ajoutées" : "Ton et informations à omettre", symbol: "text.bubble") { open(2) }
            }
            GoalongSettingsGroup(title: "Quand analyser") {
                Toggle("Autoriser les analyses", isOn: Binding(get: { consents.isEnabled(.chatGPTAnalysis) && selection.isValid(for: exclusions.policy) }, set: { value in
                    if value { open(0) }
                    else { runtime.stop(); _ = consents.set(.chatGPTAnalysis, enabled: false, surface: .settings) }
                })).toggleStyle(.switch)
                Toggle("Analyser automatiquement la veille", isOn: Binding(
                    get: { runtime.automaticRecapsEnabled && selection.isValid(for: exclusions.policy) },
                    set: { runtime.automaticRecapsEnabled = $0; if $0 { runtime.start() } }))
                    .toggleStyle(.switch).disabled(!selection.isValid(for: exclusions.policy) || !consents.isEnabled(.chatGPTAnalysis))
                HStack {
                    Button("Voir les données qui partiront") { open(3) }.buttonStyle(.bordered).controlSize(.large)
                    Spacer()
                    Button("Analyser cette journée") {
                        runtime.configure(deviceID: model.deviceID); runtime.selectDay(model.selectedDay)
                        runtime.generateRecap(); model.selectSection(.chatGPTRecap)
                    }.buttonStyle(LHPrimaryButtonStyle()).disabled(!selection.isValid(for: exclusions.policy) || !consents.isEnabled(.chatGPTAnalysis))
                }
                Text("ChatGPT reçoit uniquement votre sélection. Le bilan n’est pas envoyé au site automatiquement.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onAppear { selection = .load(); runtime.configure(deviceID: model.deviceID) }
        .sheet(isPresented: $editing) {
            GoalongAnalysisSelectionSheet(model: model, selection: selection, initialTab: editorTab) { selection = $0 }
        }
        .alert(item: $runtime.alert) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("Fermer"))) }
    }
    private var sourceSummary: String {
        guard selection.reviewed else { return "Choisir les apps et les types de données" }
        if let ids = selection.scope?.applicationIDs { return "\(ids.count) applications autorisées" }
        return "Personnaliser la sélection"
    }
    private func open(_ tab: Int) { editorTab = tab; editing = true }
}
#endif
