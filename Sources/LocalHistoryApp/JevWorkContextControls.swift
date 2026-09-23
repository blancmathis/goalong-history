#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct JevWorkContextControls: View {
    @ObservedObject private var store = JevWorkContextStore.shared
    @State private var draft = ""
    @State private var applications = ""
    @State private var content = ""
    @State private var editing = false
    @State private var error: String?
    private var draftBytes: Int { draft.utf8.count + applications.utf8.count + content.utf8.count }

    var body: some View {
        GoalongSettingsGroup(title: "Ce qui est productif pour moi") {
            VStack(alignment: .leading, spacing: 14) {
                if store.context.isEmpty || editing || store.error != nil {
                    Text("Décrivez ce qui compte comme du travail. Vous pouvez remplir une, deux ou trois rubriques.")
                        .font(.callout).foregroundStyle(.secondary)
                    field("Projets et objectifs", hint: "Ex. Goalong : app macOS et site. Atlas : préparer le lancement.",
                          text: $draft, identifier: "monitoring-work-goals")
                    field("Applications et sites", hint: "Ex. Xcode pour coder, Figma pour le design, GitHub pour les revues.",
                          text: $applications, identifier: "monitoring-work-apps")
                    field("Contenus et usages productifs", hint: "Ex. Documentation Swift, recherches liées à mes projets, rédaction de posts Goalong. Autoriser les vidéos du cours Swift choisi.",
                          text: $content, identifier: "monitoring-work-content")
                    Text("Précisez l’usage prévu : une application ouverte ne suffit pas à prouver du travail. Un contenu explicitement autorisé peut compter comme productif ; les recherches hors critères restent des distractions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Enregistrer autorise l’envoi de ces critères à TypeSafe avec les prochaines analyses si la surveillance est activée. Ils restent stockés sur ce Mac, sans import automatique de votre historique. N’indiquez ni clé API ni information sensible.")
                        .font(.caption).foregroundStyle(.secondary)
                    if draftBytes > JevWorkContext.maximumBytes {
                        Text("Description trop longue : raccourcissez les exemples pour garder des analyses compactes.")
                            .font(.caption).foregroundStyle(LHTheme.warning)
                    }
                    HStack {
                        Button("Enregistrer les critères") {
                            do {
                                try store.save(draft, applications: applications, content: content)
                                loadDraft(); editing = false; error = nil
                            } catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("monitoring-save-goals")
                        if editing {
                            Button("Annuler") { loadDraft(); editing = false; error = nil }
                                .accessibilityIdentifier("monitoring-cancel-goals")
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            saved("Projets et objectifs", value: store.context.summary)
                            saved("Applications et sites", value: store.context.applications)
                            saved("Contenus et usages", value: store.context.content)
                        }
                        Spacer(minLength: 0)
                        Button("Modifier") { loadDraft(); editing = true }
                            .accessibilityIdentifier("monitoring-edit-goals")
                    }
                }
                if store.context.isEmpty {
                    Text("Sans critères, la surveillance ne peut pas distinguer vos recherches de travail de vos recherches personnelles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = error ?? store.error { Text(message).font(.caption).foregroundStyle(LHTheme.warning) }
            }
        }.onAppear { if !editing { loadDraft() } }
    }
    private func loadDraft() {
        draft = store.context.summary; applications = store.context.applications; content = store.context.content
    }
    private func field(_ title: String, hint: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            TextField(hint, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
                .accessibilityIdentifier(identifier).accessibilityLabel(title)
        }
    }
    @ViewBuilder private func saved(_ title: String, value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
