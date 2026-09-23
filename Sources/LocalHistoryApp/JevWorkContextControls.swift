#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct JevWorkContextControls: View {
    @ObservedObject private var store = JevWorkContextStore.shared
    @State private var draft = ""
    @State private var editing = false
    @State private var error: String?
    var body: some View {
        GoalongSettingsGroup(title: "Mes projets de travail") {
            VStack(alignment: .leading, spacing: 12) {
                if store.context.summary.isEmpty || editing || store.error != nil {
                    Text("Indiquez vos projets et la tâche du moment. Une recherche sans rapport sera considérée comme de la procrastination.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Ex. Atlas : site web ; Orion : app iOS.", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...3)
                        .accessibilityIdentifier("monitoring-work-goals")
                        .accessibilityLabel("Projets et travail à surveiller")
                    Text("Cette référence sera envoyée à TypeSafe avec les prochaines analyses autorisées. Aucun projet n’est importé depuis votre historique. Évitez les informations sensibles.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enregistrer") {
                            do { try store.save(draft); draft = store.context.summary; editing = false; error = nil }
                            catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("monitoring-save-goals")
                        if editing { Button("Annuler") { draft = store.context.summary; editing = false; error = nil } }
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Text(store.context.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Modifier") { draft = store.context.summary; editing = true }
                            .accessibilityIdentifier("monitoring-edit-goals")
                    }
                }
                if store.context.summary.isEmpty {
                    Text("Sans cette référence, seuls les fils sociaux et les vidéos sont classables. Indiquez vos projets pour analyser aussi les recherches et le travail.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = error ?? store.error { Text(message).font(.caption).foregroundStyle(LHTheme.warning) }
            }
        }.onAppear { draft = store.context.summary }
    }
}
#endif
