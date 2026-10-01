#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// The single definition of work, shared by Activité (through the classification agent)
/// and real-time monitoring. Edited in Mon travail.
@MainActor struct JevWorkContextControls: View {
    enum Purpose { case workDefinition, monitoring }
    @ObservedObject private var store: JevWorkContextStore
    private let purpose: Purpose
    @State private var prefilledFromLegacy = false
    @State private var draft = ""
    @State private var applications = ""
    @State private var content = ""
    @State private var procrastination = ""
    @State private var editing = false
    @State private var error: String?
    private var draftBytes: Int { draft.utf8.count + applications.utf8.count + content.utf8.count + procrastination.utf8.count }

    init(store: JevWorkContextStore? = nil, purpose: Purpose = .monitoring) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        self.purpose = purpose
    }

    var body: some View {
        GoalongSettingsGroup(title: purpose == .workDefinition ? "Ce qui compte comme travail" : "Mes repères de surveillance") {
            VStack(alignment: .leading, spacing: 14) {
                if store.context.isEmpty || editing || store.error != nil {
                    Text("Ma définition du travail").font(.system(size: 14, weight: .semibold))
                    Text("Décrivez votre travail avec vos mots. Chaque rubrique est facultative ; une seule phrase précise suffit pour commencer.")
                        .font(.callout).foregroundStyle(.secondary)
                    if prefilledFromLegacy {
                        Label("Pré-rempli avec vos anciens choix Travail / Hors travail par app. Précisez à quoi sert chaque app, puis enregistrez.", systemImage: "wand.and.stars")
                            .font(.caption).foregroundStyle(LHTheme.accent).fixedSize(horizontal: false, vertical: true)
                    }
                    field("Projets et objectifs", hint: "Ex. Goalong : app macOS et site. Atlas : préparer le lancement.",
                          text: $draft, identifier: "monitoring-work-goals")
                    field("Applications et sites, et pour quoi faire", hint: "Ex. Xcode et GitHub pour Goalong. YouTube seulement pour le cours Swift choisi.",
                          text: $applications, identifier: "monitoring-work-apps")
                    field("Contenus et usages qui comptent comme travail", hint: "Ex. Documentation Swift, recherches liées à mes projets, e-mails clients, rédaction de posts Goalong.",
                          text: $content, identifier: "monitoring-work-content")
                    Text("Précisez l’usage plutôt que l’app : une même app peut servir au travail puis à autre chose, et c’est ce que vous y faites qui compte.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    field("Ce qui n’est pas du travail (procrastination)",
                          hint: "Ex. Scroller le fil Pour vous de X, regarder des vidéos de divertissement, comparer des achats sans lien avec mes projets.",
                          text: $procrastination, identifier: "monitoring-procrastination")
                    procrastinationExplanation
                    Text("Ces critères restent stockés sur ce Mac. Enregistrer autorise leur envoi à votre compte ChatGPT avec les contextes à classer si le classement est activé, et l’envoi de vos critères de travail et exemples de procrastination à TypeSafe avec les prochaines analyses si la surveillance est activée. N’indiquez ni clé API ni information sensible.")
                        .font(.caption).foregroundStyle(.secondary)
                    if draftBytes > JevWorkContext.maximumBytes {
                        Text("Description trop longue : les quatre rubriques partagent le même budget. Raccourcissez les exemples pour garder des analyses compactes.")
                            .font(.caption).foregroundStyle(LHTheme.warning)
                    }
                    HStack {
                        Button(purpose == .workDefinition ? "Enregistrer ma définition" : "Enregistrer les critères") {
                            do {
                                try store.save(draft, applications: applications, content: content, procrastination: procrastination)
                                loadDraft(); editing = false; error = nil; prefilledFromLegacy = false
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
                            Text("Ma définition du travail").font(.system(size: 14, weight: .semibold))
                            saved("Projets et objectifs", value: store.context.summary)
                            saved("Applications et sites", value: store.context.applications)
                            saved("Contenus et usages", value: store.context.content)
                        }
                        Spacer(minLength: 0)
                        Button("Modifier") { loadDraft(); editing = true }
                            .accessibilityIdentifier("monitoring-edit-goals")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ce qui n’est pas du travail (procrastination)")
                            .font(.system(size: 14, weight: .semibold))
                        if store.context.procrastination.isEmpty {
                            Text("Aucun exemple ajouté. Sans exemple, l’agent s’appuie sur votre définition du travail ; la détection générale de la surveillance reste active.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Ajouter mes exemples") { loadDraft(); editing = true }
                                .accessibilityIdentifier("monitoring-add-procrastination")
                        } else {
                            Text(store.context.procrastination)
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("monitoring-saved-procrastination")
                        }
                        procrastinationExplanation
                    }
                }
                if !store.context.hasProductivityCriteria {
                    Text("Sans critères de travail, vos exemples de procrastination n’autorisent pas automatiquement les autres usages. Le lien avec votre travail peut rester indéterminé.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = error ?? store.error { Text(message).font(.caption).foregroundStyle(LHTheme.warning) }
            }
        }.onAppear {
            if !editing { loadDraft() }
            // Former per-app choices become a starting point, never a silent rule.
            if purpose == .workDefinition, store.context.isEmpty, draft.isEmpty, applications.isEmpty,
               let legacy = GoalongWorkStore.legacyDraft() {
                if !legacy.work.isEmpty { applications = "Travail : " + legacy.work + "." }
                if !legacy.other.isEmpty { procrastination = legacy.other }
                prefilledFromLegacy = true
            }
        }
    }
    private var procrastinationExplanation: some View {
        Text("Des exemples certains, pas une liste exhaustive. La surveillance continue de repérer les autres distractions. Un usage qui correspond clairement à un exemple prime sur une autorisation générale ; précisez l’usage plutôt que seulement le site.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("monitoring-procrastination-explanation")
    }
    private func loadDraft() {
        draft = store.context.summary; applications = store.context.applications
        content = store.context.content; procrastination = store.context.procrastination
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
