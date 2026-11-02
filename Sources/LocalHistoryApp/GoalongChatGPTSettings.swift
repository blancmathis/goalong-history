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
            // Its sentence is under the pane title (SettingsPane.lead), close to it.
            ChatGPTAccountConnectionCard(runtime: runtime, updateIsPrimary: true)
            GoalongSettingsList(title: "Votre analyse") {
                GoalongSettingsLink(title: "Données pour ChatGPT", value: sourceSummary, symbol: "line.3.horizontal.decrease.circle") { open(0) }.accessibilityIdentifier("analysis-open-data")
                GoalongRowDivider()
                GoalongSettingsLink(title: "Masquer des noms", value: replacementSummary, symbol: "text.badge.minus") { open(1) }.accessibilityIdentifier("analysis-open-replacements")
                GoalongRowDivider()
                GoalongSettingsLink(title: "Personnaliser le bilan", value: selection.outputGuidance?.isEmpty == false ? "Consignes ajoutées" : "Ton et informations à omettre", symbol: "text.bubble") { open(2) }.accessibilityIdentifier("analysis-open-guidance")
            }
            // R-71 (déc. 11, R282-1): this version cannot reach ChatGPT, so nothing can be switched ON
            // until the update. Withdrawing the consent or stopping the automatic analysis stays possible.
            GoalongSettingsGroup(title: "Quand analyser") {
                Toggle("Autoriser les analyses", isOn: Binding(get: { selection.allowsAnalysis(consented: consents.isEnabled(.chatGPTAnalysis), policy: exclusions.policy) }, set: { value in
                    if value { open(0) }
                    else {
                        runtime.stop()
                        if !consents.set(.chatGPTAnalysis, enabled: false, surface: .settings) {
                            error = "L’autorisation n’a pas pu être modifiée. Les analyses en cours ont été arrêtées ; réessayez pour enregistrer ce choix."
                        }
                    }
                })).toggleStyle(.goalongSwitch)
                    .accessibilityIdentifier("analysis-allow")
                    .disabled(Self.switchDisabled(isOn: selection.allowsAnalysis(consented: consents.isEnabled(.chatGPTAnalysis), policy: exclusions.policy), locked: locked, otherwiseBlocked: false))
                let automatic = Self.automaticSwitch(stored: runtime.automaticRecapsEnabled,
                                                     selectionValid: selection.isValid(for: exclusions.policy),
                                                     consented: consents.isEnabled(.chatGPTAnalysis), locked: locked)
                Toggle("Analyser automatiquement la journée d’hier", isOn: Binding(
                    get: { automatic.isOn },
                    set: { runtime.automaticRecapsEnabled = $0; if $0 { runtime.start() } }))
                    .toggleStyle(.goalongSwitch)
                    .accessibilityIdentifier("analysis-automatic")
                    .disabled(automatic.disabled)
                HStack {
                    Button("Voir les données qui partiront") { open(3) }.buttonStyle(LHSecondaryButtonStyle())
                    Spacer()
                    // Until the account is connected, the account card holds the only lime (UI-49).
                    if runtime.isAccountConnected {
                        analyzeButton.buttonStyle(LHPrimaryButtonStyle())
                    } else {
                        analyzeButton.buttonStyle(LHSecondaryButtonStyle())
                    }
                }
                // The hint names the action the account card really offers; when that is an update,
                // the card already says it once (UI-12B, 38).
                if !runtime.isAccountConnected && runtime.connectionState != .codexUnavailable {
                    Text("Connectez ChatGPT pour analyser une journée.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                Text("ChatGPT reçoit uniquement votre sélection. Le bilan n’est pas envoyé au site automatiquement.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .onAppear { selection = .load(); runtime.configure(deviceID: model.knownDeviceID ?? "") }
        .sheet(item: $presentation) { request in
            GoalongAnalysisSelectionSheet(model: model, selection: selection, initialTab: request.tab) { selection = $0 }.id(request.id)
                .goalongControls()
        }
        .alert("Réglage non modifié", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) {}
        } message: { Text(error ?? "") }
        .alert(item: $runtime.alert) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("Fermer"))) }
    }
    /// R-71: an app version that cannot connect blocks switching ON (allow, automatic, analyse).
    static func analysisLocked(_ state: ChatGPTConnectionState) -> Bool { state == .codexUnavailable }
    /// R282-1: a switch that is ON can always be turned off; only turning ON is blocked.
    static func switchDisabled(isOn: Bool, locked: Bool, otherwiseBlocked: Bool) -> Bool { !isOn && (locked || otherwiseBlocked) }
    /// R282-6: the automatic switch is greyed from the value it shows, not the stored one. A stored ON with a
    /// selection that is no longer valid shows OFF, so it is greyed like any OFF switch that cannot be turned on.
    static func automaticSwitch(stored: Bool, selectionValid: Bool, consented: Bool, locked: Bool) -> (isOn: Bool, disabled: Bool) {
        let shown = stored && selectionValid
        return (shown, switchDisabled(isOn: shown, locked: locked, otherwiseBlocked: !selectionValid || !consented))
    }
    private var locked: Bool { Self.analysisLocked(runtime.connectionState) }

    private var analyzeButton: some View {
        Button("Analyser cette journée") {
            runtime.configure(deviceID: model.knownDeviceID ?? ""); runtime.selectDay(model.selectedDay)
            runtime.generateRecap(); model.selectSection(.chatGPTRecap)
        }.disabled(locked || !selection.isValid(for: exclusions.policy) || !consents.isEnabled(.chatGPTAnalysis) || !runtime.isAccountConnected || runtime.isGenerating || model.knownDeviceID == nil)
    }
    private var sourceSummary: String {
        guard selection.reviewed else { return "Choisir les apps et les types de données" }
        if let ids = selection.scope?.applicationIDs {
            return ids.count > 1 ? "\(ids.count) applications autorisées" : "\(ids.count) application autorisée"
        }
        return "Personnaliser la sélection"
    }
    private var replacementSummary: String {
        let count = selection.replacements?.filter { !$0.search.isEmpty }.count ?? 0
        return count == 0 ? "Aucun remplacement" : count == 1 ? "1 remplacement" : "\(count) remplacements"
    }
    private func open(_ tab: Int) { presentation = .init(tab: tab) }
}
#endif
