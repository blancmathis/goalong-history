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
    @State private var presentation: GoalongAnalysisPresentation?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ChatGPTAccountConnectionCard(runtime: runtime)
            GoalongSettingsGroup(title: "Votre analyse") {
                GoalongSettingsLink(title: "Données pour ChatGPT", value: sourceSummary, symbol: "line.3.horizontal.decrease.circle") { open(0) }.accessibilityIdentifier("analysis-open-data")
                Divider()
                GoalongSettingsLink(title: "Masquer des noms", value: "\(selection.replacements?.filter { !$0.search.isEmpty }.count ?? 0) remplacements", symbol: "text.badge.minus") { open(1) }.accessibilityIdentifier("analysis-open-replacements")
                Divider()
                GoalongSettingsLink(title: "Personnaliser le bilan", value: selection.outputGuidance?.isEmpty == false ? "Consignes ajoutées" : "Ton et informations à omettre", symbol: "text.bubble") { open(2) }.accessibilityIdentifier("analysis-open-guidance")
            }
            GoalongSettingsGroup(title: "Quand analyser") {
                Toggle("Autoriser les analyses", isOn: Binding(get: { consents.isEnabled(.chatGPTAnalysis) && selection.isValid(for: exclusions.policy) }, set: { value in
                    if value { open(0) }
                    else {
                        runtime.stop()
                        if !consents.set(.chatGPTAnalysis, enabled: false, surface: .settings) {
                            error = "L’autorisation n’a pas pu être modifiée. Les analyses en cours ont été arrêtées ; réessayez pour enregistrer ce choix."
                        }
                    }
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
        .sheet(item: $presentation) { request in
            GoalongAnalysisSelectionSheet(model: model, selection: selection, initialTab: request.tab) { selection = $0 }.id(request.id)
        }
        .alert("Réglage non modifié", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(error ?? "") }
        .alert(item: $runtime.alert) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("Fermer"))) }
    }
    private var sourceSummary: String {
        guard selection.reviewed else { return "Choisir les apps et les types de données" }
        if let ids = selection.scope?.applicationIDs { return "\(ids.count) applications autorisées" }
        return "Personnaliser la sélection"
    }
    private func open(_ tab: Int) { presentation = .init(tab: tab) }
}
#endif
