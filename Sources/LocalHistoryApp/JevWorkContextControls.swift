#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// The single definition of work, shared by Activité (through the classification agent)
/// and real-time monitoring. Edited in Réglages › Définition du travail, and in Activité's sheet.
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
    @State private var changeWarning: String?
    /// A definition typed but not saved when its view went away (Activité's sheet closes on Escape). Kept in memory
    /// only and given back at the next opening, as the page keeps it while it stays alive.
    private static var unsaved: (fields: [String], prefilled: Bool)?
    /// True while a definition was typed and not saved: the sheet then asks before it closes.
    static var hasUnsavedDefinition: Bool { unsaved != nil }
    /// « Abandonner »: the typed definition is not given back at the next opening.
    static func discardUnsaved() { unsaved = nil }
    /// The untouched starting point this view filled in, read once (a file and the installed apps' names).
    @State private var legacyStart: [String]?
    private var fields: [String] { [draft, applications, content, procrastination] }
    private var savedFields: [String] {
        [store.context.summary, store.context.applications, store.context.content, store.context.procrastination]
    }
    /// The starting point made from the former per-app choices, in the order of `fields`.
    private static func legacyFields() -> [String]? {
        guard let legacy = GoalongWorkStore.legacyDraft() else { return nil }
        return ["", legacy.work.isEmpty ? "" : "Travail : " + legacy.work + ".", "", legacy.other]
    }
    private var draftBytes: Int { draft.utf8.count + applications.utf8.count + content.utf8.count + procrastination.utf8.count }

    init(store: JevWorkContextStore? = nil, purpose: Purpose = .monitoring) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        self.purpose = purpose
    }

    var body: some View {
        GoalongSettingsGroup(title: purpose == .workDefinition ? "" : "Mes repères pour Jev") {
            VStack(alignment: .leading, spacing: 20) {
                if store.context.isEmpty || editing || store.error != nil {
                    editor
                } else {
                    summary
                }
                // Only meaningful once there are examples to weigh against missing criteria.
                if !store.context.hasProductivityCriteria,
                   !(editing || store.context.isEmpty ? procrastination : store.context.procrastination).isEmpty {
                    GoalongNote("Sans critères de travail, vos exemples hors travail n’autorisent pas automatiquement les autres usages. Le lien avec votre travail peut rester indéterminé.")
                }
                if let message = error ?? store.error { GoalongNote(message, tone: .warning) }
            }
        }
        .alert("Changer la définition du travail ?", isPresented: Binding(get: { changeWarning != nil }, set: { if !$0 { changeWarning = nil } })) {
            Button("Annuler", role: .cancel) { changeWarning = nil }
            Button("Enregistrer") { changeWarning = nil; saveDraft() }
        } message: { Text(changeWarning ?? "") }
        .onAppearWhenShown {
            if !editing {
                if purpose == .workDefinition, let left = Self.unsaved, left.fields.count == 4 {
                    draft = left.fields[0]; applications = left.fields[1]
                    content = left.fields[2]; procrastination = left.fields[3]
                    prefilledFromLegacy = left.prefilled
                    editing = !store.context.isEmpty
                } else {
                    loadDraft()
                }
            }
            // Former per-app choices become a starting point, never a silent rule.
            if purpose == .workDefinition, store.context.isEmpty, draft.isEmpty, applications.isEmpty,
               let legacy = Self.legacyFields() {
                if !legacy[1].isEmpty { applications = legacy[1] }
                if !legacy[3].isEmpty { procrastination = legacy[3] }
                prefilledFromLegacy = true
                legacyStart = legacy
            }
        }
        .onChange(of: fields) { now in
            // Only what the user typed: neither the saved definition nor the untouched starting point.
            guard purpose == .workDefinition else { return }
            let typed = (editing || store.context.isEmpty) && now != savedFields
                && now != legacyStart
            Self.unsaved = typed ? (now, prefilledFromLegacy) : nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ma définition du travail").font(LHTheme.cardTitleFont).accessibilityAddTraits(.isHeader)
                Text(store.context.isEmpty || editing
                     ? "Avec vos mots. Chaque rubrique est facultative : une phrase précise suffit pour commencer."
                     : "Appliquée à Activité et à Jev.")
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
            sectionLabel("Travail", mark: LHTheme.workData)
            field("Projets et objectifs", hint: "Ex. Goalong : app macOS et site. Atlas : préparer le lancement.",
                  text: $draft, identifier: "monitoring-work-goals")
            field("Applications et sites utiles", hint: "Ex. Xcode et GitHub pour Goalong. YouTube seulement pour le cours Swift choisi.",
                  text: $applications, identifier: "monitoring-work-apps")
            field("Contenus et usages qui comptent comme travail",
                  detail: "Précisez l’usage plutôt que l’app : c’est ce que vous y faites qui compte.",
                  hint: "Ex. Documentation Swift, recherches liées à mes projets, e-mails clients, rédaction de posts Goalong.",
                  text: $content, identifier: "monitoring-work-content")
            sectionLabel("Hors travail", mark: LHTheme.otherData).padding(.top, 8)
            field("Ce qui n’est pas du travail",
                  detail: "Des exemples clairs, pas une liste complète.", help: procrastinationText,
                  hint: "Ex. Faire défiler le fil « Pour vous » de X, regarder des vidéos de divertissement, comparer des achats sans lien avec mes projets.",
                  text: $procrastination, identifier: "monitoring-procrastination")
            GoalongNote("Ces critères restent sur ce Mac. Si le classement est activé, Enregistrer autorise leur envoi au classement automatique (ChatGPT). Si Jev est activé, Enregistrer envoie aussi vos critères et exemples hors travail à TypeSafe, son fournisseur. N’y mettez aucune information sensible.",
                        tone: .privacy)
            HStack(spacing: 10) {
                if draftBytes > 0 { budget }
                Spacer(minLength: 12)
                if editing {
                    Button("Annuler") { loadDraft(); editing = false; error = nil; Self.unsaved = nil }
                        .accessibilityIdentifier("monitoring-cancel-goals")
                }
                Button(purpose == .workDefinition ? "Enregistrer ma définition" : "Enregistrer les critères") {
                    // Only a change of meaning drops verdicts; an open « travail » commitment then needs a warning (T-045 H5-03).
                    let next = try? JevWorkContext(summary: draft, applications: applications, content: content, procrastination: procrastination)
                    let changes = next.map { GoalongWorkDefinition($0).revision != GoalongWorkDefinition(store.context).revision } ?? false
                    changeWarning = changes ? FocusCommitmentRules.definitionChangeWarning(
                        GoalongWorkStore.openCommitments(controller: ConcentrationRuntime.shared.controller, store: .standard), at: GoalongToday.now) : nil
                    if changeWarning == nil { saveDraft() }
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
            GoalongShareBar(share: ratio, color: over ? LHTheme.warning : LHTheme.secondaryText).frame(width: 64)
            Text(over ? "Trop long" : ratio > 0.8 ? "Presque plein" : "Longueur")
                .font(.system(size: 12)).foregroundStyle(over ? LHTheme.warning : LHTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Longueur de la définition : \(GoalongUIFormat.percent(ratio * 100)) du maximum")
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
                            Text("Aucun exemple ajouté. Sans exemple, le classement automatique s’appuie sur votre définition du travail ; Jev repère toujours les autres distractions.")
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
        }
    }

    /// A rubric heading carries the mark its time will wear on the thread.
    private func sectionLabel(_ title: String, mark: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(mark).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
        }
        .accessibilityAddTraits(.isHeader)
    }
    private var procrastinationText: String {
        "Des exemples clairs, pas une liste complète. Jev continue de repérer les autres distractions. Un usage qui correspond clairement à un exemple prime sur une autorisation générale ; précisez l’usage plutôt que seulement le site."
    }
    private func saveDraft() {
        do {
            try store.save(draft, applications: applications, content: content, procrastination: procrastination)
            loadDraft(); editing = false; error = nil; prefilledFromLegacy = false; Self.unsaved = nil
            GoalongToastCenter.shared.show(purpose == .workDefinition ? "Définition enregistrée" : "Critères enregistrés")
        } catch { self.error = GoalongUserFacingError.message(error) }
    }

    private func loadDraft() {
        draft = store.context.summary; applications = store.context.applications
        content = store.context.content; procrastination = store.context.procrastination
    }
    private func field(_ title: String, detail: String? = nil, help: String? = nil, hint: String,
                       text: Binding<String>, identifier: String) -> some View {
        GoalongFormField(title: title, detail: detail, help: help) {
            TextField("", text: text, axis: .vertical)
                .lineLimit(2...6)
                .goalongPlaceholder(hint, isEmpty: text.wrappedValue.isEmpty, alignment: .topLeading, top: 8)
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
                Text(title).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 160, alignment: .leading)
                value().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            if title != "Hors travail" { Rectangle().fill(LHTheme.separator).frame(height: 1) }
        }
    }
}
#endif
