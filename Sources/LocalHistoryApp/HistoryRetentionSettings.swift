#if os(macOS)
import SwiftUI
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let goalongRetentionPolicyDidChange = Notification.Name("goalongRetentionPolicyDidChange")
}

extension HistoryDataClass {
    var retentionTitle: String {
        switch self {
        case .detailedEvents: return "Activité détaillée"
        case .semanticSnapshots: return "Texte affiché"
        case .memories: return "Historique et résumés locaux"
        case .analysisCaches: return "Fichiers temporaires"
        case .minuteSeals: return "Preuves d’activité"
        case .activitySummaries: return "Résumés de journée"
        case .anchorReceipts: return "Reçus de date"
        }
    }
}
extension HistoryRetentionPolicy {
    mutating func setDuration(_ duration: RetentionDuration, for kind: HistoryDataClass) {
        switch kind {
        case .detailedEvents: detailedEvents = duration
        case .semanticSnapshots: semanticSnapshots = duration
        case .memories: memories = duration
        case .analysisCaches: analysisCaches = duration
        case .minuteSeals: minuteSeals = duration
        case .activitySummaries: activitySummaries = duration
        case .anchorReceipts: anchorReceipts = duration
        }
    }
    /// What « Preuves d’activité » and « Reçus de date » are, in one sentence under the list (UI-15A, 28).
    static let proofExplanation = "Les preuves d’activité signent chaque minute enregistrée et les reçus de date datent ces signatures : ensemble, ils montrent que l’historique n’a pas été modifié."
    /// Shared labels so every entry point names the same policy the same way.
    static let noLimitLabel = "Jusqu’à suppression"
    static let automaticCleanupLabel = "Supprimer automatiquement les données expirées"
    static func automaticCleanupSummary(enabled: Bool) -> String {
        enabled ? "Suppression automatique activée" : "Jusqu’à suppression manuelle"
    }
    var includesProofExpiry: Bool { minuteSeals.days != nil || anchorReceipts.days != nil }
    var retentionDescription: String {
        HistoryDataClass.allCases.map { kind in
            let duration = duration(for: kind).days.map { GoalongUIFormat.count($0, "jour") } ?? "jusqu’à suppression"
            return "\(kind.retentionTitle) : \(duration)"
        }.joined(separator: "\n")
    }
}

@MainActor final class HistoryRetentionSettingsModel: ObservableObject {
    @Published var draft: HistoryRetentionPolicy
    @Published var automaticCleanup: Bool
    @Published var error: String?
    @Published private(set) var savedPolicy: HistoryRetentionPolicy
    @Published private(set) var savedAutomaticCleanup: Bool
    private let store: HistoryRetentionStore

    init(store: HistoryRetentionStore? = nil, legacyRetentionDays: Int = 30) {
        let resolved = store ?? HistoryRetentionStore(legacyRetentionDays: legacyRetentionDays)
        self.store = resolved
        draft = resolved.policy; savedPolicy = resolved.policy
        automaticCleanup = resolved.isAutomaticCleanupEnabled
        savedAutomaticCleanup = resolved.isAutomaticCleanupEnabled
    }
    var hasChanges: Bool { draft != savedPolicy || automaticCleanup != savedAutomaticCleanup }
    @discardableResult func apply(proofDeletionConfirmed: Bool) -> Bool {
        guard !automaticCleanup || !draft.includesProofExpiry || proofDeletionConfirmed else {
            error = "Confirmez séparément la suppression des preuves, ou conservez indéfiniment preuves et reçus."
            return false
        }
        do {
            if automaticCleanup { try store.activate(draft) }
            else { _ = try store.save(draft) }
            savedPolicy = store.policy
            savedAutomaticCleanup = store.isAutomaticCleanupEnabled
            automaticCleanup = savedAutomaticCleanup
            error = nil
            NotificationCenter.default.post(name: .goalongRetentionPolicyDidChange, object: nil)
            return true
        } catch {
            self.error = "La modification de conservation n’a pas été confirmée. \(GoalongUserFacingError.message(error)) Rouvrez ce panneau pour vérifier la règle enregistrée avant de réessayer."
            return false
        }
    }
}

@MainActor struct HistoryRetentionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HistoryRetentionSettingsModel
    @State private var proofDeletionConfirmed = false
    @State private var showingConfirmation = false

    init(model: HistoryRetentionSettingsModel? = nil, legacyRetentionDays: Int = 30) {
        _model = StateObject(wrappedValue: model ?? HistoryRetentionSettingsModel(legacyRetentionDays: legacyRetentionDays))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Durée de conservation locale").font(LHTheme.sheetTitleFont)
                    Text("Choisissez combien de temps chaque type de donnée reste sur ce Mac.").font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle(HistoryRetentionPolicy.automaticCleanupLabel, isOn: $model.automaticCleanup)
                        .toggleStyle(.goalongSwitch).font(.system(size: 13, weight: .semibold))
                        .accessibilityIdentifier("retention-automatic")
                    Text(model.automaticCleanup
                         ? "Après confirmation, les données expirées peuvent être supprimées tout de suite puis lors du nettoyage quotidien. Réduire une durée s’applique aussi aux données existantes."
                         : "Le nettoyage automatique est désactivé : les données restent jusqu’à ce que vous les supprimiez. Activez le nettoyage pour choisir les durées.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    LHCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(HistoryDataClass.allCases, id: \.self) { kind in
                                HStack(alignment: .center, spacing: 16) {
                                    // The title stays in ink: only the value says the row is inactive (UI-12B, 28).
                                    Text(kind.retentionTitle).font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(LHTheme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    // A duration only counts once automatic cleanup is on (UI-44). Off, the value
                                    // reads as plain text instead of a greyed menu (UI-9 C).
                                    if model.automaticCleanup {
                                        Picker(kind.retentionTitle, selection: durationBinding(kind)) {
                                            Text(HistoryRetentionPolicy.noLimitLabel).tag(0)
                                            ForEach(durationOptions(kind), id: \.self) { days in Text(GoalongUIFormat.count(days, "jour")).tag(days) }
                                        }.labelsHidden().frame(width: 230)
                                            .accessibilityIdentifier("retention-\(kind.rawValue)")
                                    } else {
                                        // Off, nothing expires: every row says what really happens, not a dormant duration (UI-11C).
                                        Text(HistoryRetentionPolicy.noLimitLabel)
                                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                                            .frame(width: 230, alignment: .trailing)
                                            .accessibilityIdentifier("retention-\(kind.rawValue)")
                                    }
                                }.padding(.horizontal, LHTheme.cardInset).frame(minHeight: 44)
                                if kind != HistoryDataClass.allCases.last { GoalongRowDivider(inset: LHTheme.cardInset) }
                            }
                        }
                    }
                    // UI-15A (28): the two proof rows are said in one visible sentence; the rest stays one click away.
                    GoalongHelpText(lead: HistoryRetentionPolicy.proofExplanation,
                                    more: "Les fichiers temporaires sont des calculs d’analyse que Goalong peut refaire.")
                    if model.automaticCleanup && model.draft.includesProofExpiry {
                        Toggle("J’autorise aussi la suppression des preuves et reçus expirés. La vérification de ces périodes peut devenir impossible.", isOn: $proofDeletionConfirmed)
                            .toggleStyle(.goalongCheckbox)
                            .font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                            .accessibilityIdentifier("retention-confirm-proofs")
                    }
                    Text("Ces règles ne touchent ni les originaux d’Apple et des agents IA, ni les exports, sauvegardes et données envoyées, ni les bilans ChatGPT, qu’on efface avec « Effacer de l’historique… ».")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(24)
            }
            // A soft fade shows that the list continues under the footer.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [LHTheme.pageBackground.opacity(0), LHTheme.pageBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18).allowsHitTesting(false)
            }
            Divider()
            HStack {
                Text("Rien n’est appliqué avant votre confirmation.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                Spacer()
                // Cancel and the main action sit together in the footer (UI-44).
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(LHSecondaryButtonStyle())
                Button(model.automaticCleanup ? "Vérifier et appliquer…" : "Enregistrer") {
                    if model.automaticCleanup { showingConfirmation = true }
                    else if model.apply(proofDeletionConfirmed: false) { dismiss() }
                }.buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!model.hasChanges || (model.automaticCleanup && model.draft.includesProofExpiry && !proofDeletionConfirmed))
                    .accessibilityIdentifier("retention-apply")
            }.padding(20)
        }
        .frame(width: 700, height: 670).background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onChange(of: model.draft) { _ in proofDeletionConfirmed = false }
        .alert("Appliquer la suppression automatique ?", isPresented: $showingConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Appliquer ces règles", role: .destructive) {
                if model.apply(proofDeletionConfirmed: proofDeletionConfirmed) { dismiss() }
            }
        } message: {
            Text(model.draft.retentionDescription + "\n\nLes données locales expirées peuvent être supprimées immédiatement, sans retour possible. Les exports et copies distantes ne sont pas concernés.")
        }
    }
    private func durationOptions(_ kind: HistoryDataClass) -> [Int] {
        Array(Set([1, 7, 30, 90, 365] + [model.draft.duration(for: kind).days].compactMap { $0 })).sorted()
    }
    private func durationBinding(_ kind: HistoryDataClass) -> Binding<Int> {
        Binding(get: { model.draft.duration(for: kind).days ?? 0 },
                set: { model.draft.setDuration(RetentionDuration(days: $0), for: kind) })
    }
}
#endif
