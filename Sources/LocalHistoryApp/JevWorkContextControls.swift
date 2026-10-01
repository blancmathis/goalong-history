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
        GoalongSettingsGroup(title: purpose == .workDefinition ? "" : "Mes repères de surveillance") {
            VStack(alignment: .leading, spacing: 20) {
                if store.context.isEmpty || editing || store.error != nil {
                    editor
                } else {
                    summary
                }
                // Only meaningful once there are examples to weigh against missing criteria.
                if !store.context.hasProductivityCriteria,
                   !(editing || store.context.isEmpty ? procrastination : store.context.procrastination).isEmpty {
                    GoalongNote("Sans critères de travail, vos exemples de procrastination n’autorisent pas automatiquement les autres usages. Le lien avec votre travail peut rester indéterminé.")
                }
                if let message = error ?? store.error { GoalongNote(message, tone: .warning) }
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

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "briefcase").font(.system(size: 16, weight: .medium)).foregroundStyle(LHTheme.accent)
                .frame(width: 36, height: 36)
                .background(LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ma définition du travail").font(LHTheme.cardTitleFont).accessibilityAddTraits(.isHeader)
                Text(store.context.isEmpty || editing
                     ? "Décrivez votre travail avec vos mots. Chaque rubrique est facultative ; une seule phrase précise suffit pour commencer."
                     : "Appliquée à Activité et à la surveillance temps réel.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !(store.context.isEmpty || editing || store.error != nil) {
                Button("Modifier") { loadDraft(); editing = true }
                    .accessibilityIdentifier("monitoring-edit-goals")
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if prefilledFromLegacy {
                GoalongNote("Pré-rempli avec vos anciens choix Travail / Hors travail par app. Précisez à quoi sert chaque app, puis enregistrez.",
                            symbol: "wand.and.stars", tone: .privacy)
            }
            sectionLabel("Travail", symbol: "checkmark.circle")
            field("Projets et objectifs", hint: "Ex. Goalong : app macOS et site. Atlas : préparer le lancement.",
                  text: $draft, identifier: "monitoring-work-goals")
            field("Applications et sites, et pour quoi faire", hint: "Ex. Xcode et GitHub pour Goalong. YouTube seulement pour le cours Swift choisi.",
                  text: $applications, identifier: "monitoring-work-apps")
            field("Contenus et usages qui comptent comme travail",
                  detail: "Précisez l’usage plutôt que l’app : une même app peut servir au travail puis à autre chose, et c’est ce que vous y faites qui compte.",
                  hint: "Ex. Documentation Swift, recherches liées à mes projets, e-mails clients, rédaction de posts Goalong.",
                  text: $content, identifier: "monitoring-work-content")
            Rectangle().fill(LHTheme.separator).frame(height: 1)
            sectionLabel("Hors travail", symbol: "cup.and.saucer")
            field("Ce qui n’est pas du travail (procrastination)",
                  detail: procrastinationText,
                  hint: "Ex. Scroller le fil Pour vous de X, regarder des vidéos de divertissement, comparer des achats sans lien avec mes projets.",
                  text: $procrastination, identifier: "monitoring-procrastination")
            GoalongNote("Ces critères restent stockés sur ce Mac. Enregistrer autorise leur envoi à votre compte ChatGPT avec les contextes à classer si le classement est activé, et l’envoi de vos critères de travail et exemples de procrastination à TypeSafe avec les prochaines analyses si la surveillance est activée. N’indiquez ni clé API ni information sensible.",
                        tone: .privacy)
            HStack(spacing: 10) {
                if draftBytes > 0 { budget }
                Spacer(minLength: 12)
                if editing {
                    Button("Annuler") { loadDraft(); editing = false; error = nil }
                        .accessibilityIdentifier("monitoring-cancel-goals")
                }
                Button(purpose == .workDefinition ? "Enregistrer ma définition" : "Enregistrer les critères") {
                    do {
                        try store.save(draft, applications: applications, content: content, procrastination: procrastination)
                        loadDraft(); editing = false; error = nil; prefilledFromLegacy = false
                        GoalongToastCenter.shared.show(purpose == .workDefinition ? "Définition enregistrée" : "Critères enregistrés")
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .disabled(draftBytes > JevWorkContext.maximumBytes)
                .accessibilityIdentifier("monitoring-save-goals")
            }
            if draftBytes > JevWorkContext.maximumBytes {
                GoalongNote("Description trop longue : les quatre rubriques partagent le même budget. Raccourcissez les exemples pour garder des analyses compactes.",
                            tone: .warning)
            }
        }
    }

    /// How much of the shared budget the four fields use, so length never surprises at save.
    private var budget: some View {
        let ratio = min(1, Double(draftBytes) / Double(JevWorkContext.maximumBytes))
        let over = draftBytes > JevWorkContext.maximumBytes
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(LHTheme.separator)
                Capsule().fill(over ? LHTheme.warning : LHTheme.accent.opacity(0.75)).frame(width: 64 * ratio)
            }.frame(width: 64, height: 4)
            Text(over ? "Trop long" : ratio > 0.8 ? "Presque plein" : "Longueur")
                .font(.system(size: 11)).foregroundStyle(over ? LHTheme.warning : LHTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Longueur de la définition : \(Int(ratio * 100)) % du maximum")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(spacing: 0) {
                saved("Projets et objectifs", value: store.context.summary)
                saved("Applications et sites", value: store.context.applications)
                saved("Contenus et usages", value: store.context.content)
                summaryRow("Hors travail") {
                    if store.context.procrastination.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Aucun exemple ajouté. Sans exemple, l’agent s’appuie sur votre définition du travail ; la détection générale de la surveillance reste active.")
                                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            Button("Ajouter mes exemples") { loadDraft(); editing = true }
                                .controlSize(.small).accessibilityIdentifier("monitoring-add-procrastination")
                        }
                    } else {
                        Text(store.context.procrastination)
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .accessibilityIdentifier("monitoring-saved-procrastination")
                    }
                }
            }
            .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            procrastinationExplanation
        }
    }

    /// A rubric heading: a waypoint on the trail (lime for work, hollow for the rest).
    private func sectionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(symbol == "checkmark.circle" ? LHTheme.accent : .clear)
                .overlay(Circle().strokeBorder(symbol == "checkmark.circle" ? .clear : LHTheme.secondaryText, lineWidth: 1.5))
                .frame(width: 8, height: 8)
            Text(title).font(.system(size: 15, weight: .semibold, design: .serif))
        }
        .accessibilityAddTraits(.isHeader)
    }
    private var procrastinationText: String {
        "Des exemples certains, pas une liste exhaustive. La surveillance continue de repérer les autres distractions. Un usage qui correspond clairement à un exemple prime sur une autorisation générale ; précisez l’usage plutôt que seulement le site."
    }
    private var procrastinationExplanation: some View {
        GoalongNote(procrastinationText)
            .accessibilityIdentifier("monitoring-procrastination-explanation")
    }
    private func loadDraft() {
        draft = store.context.summary; applications = store.context.applications
        content = store.context.content; procrastination = store.context.procrastination
    }
    private func field(_ title: String, detail: String? = nil, hint: String, text: Binding<String>, identifier: String) -> some View {
        GoalongFormField(title: title, detail: detail) {
            TextField(hint, text: text, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier(identifier).accessibilityLabel(title)
        }
    }
    @ViewBuilder private func saved(_ title: String, value: String) -> some View {
        if !value.isEmpty {
            summaryRow(title) {
                Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
    private func summaryRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 168, alignment: .leading)
                value().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if title != "Hors travail" { Rectangle().fill(LHTheme.separator).frame(height: 1).padding(.leading, 14) }
        }
    }
}
#endif
