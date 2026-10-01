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
        case .analysisCaches: return "Fichiers temporaires d’analyse"
        case .minuteSeals: return "Preuves locales"
        case .anchorReceipts: return "Reçus de vérification"
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
        case .anchorReceipts: anchorReceipts = duration
        }
    }
    var includesProofExpiry: Bool { minuteSeals.days != nil || anchorReceipts.days != nil }
    var retentionDescription: String {
        HistoryDataClass.allCases.map { kind in
            let duration = duration(for: kind).days.map { $0 == 1 ? "1 jour" : "\($0) jours" } ?? "sans limite"
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

    init(store: HistoryRetentionStore? = nil) {
        let resolved = store ?? HistoryRetentionStore(legacyRetentionDays: 30)
        self.store = resolved
        draft = resolved.policy; savedPolicy = resolved.policy
        automaticCleanup = resolved.isAutomaticCleanupEnabled
        savedAutomaticCleanup = resolved.isAutomaticCleanupEnabled
    }
    var hasChanges: Bool { draft != savedPolicy || automaticCleanup != savedAutomaticCleanup }
    @discardableResult func apply(proofDeletionConfirmed: Bool) -> Bool {
        guard !automaticCleanup || !draft.includesProofExpiry || proofDeletionConfirmed else {
            error = "Confirmez séparément la suppression des preuves, ou conservez indéfiniment sceaux et reçus."
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
            self.error = "La modification de conservation n’a pas été confirmée : \(error.localizedDescription). Rouvrez ce panneau pour vérifier la règle enregistrée avant de réessayer."
            return false
        }
    }
}

@MainActor struct HistoryRetentionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HistoryRetentionSettingsModel
    @State private var proofDeletionConfirmed = false
    @State private var showingConfirmation = false

    init(model: HistoryRetentionSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? HistoryRetentionSettingsModel())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Durée de conservation locale").font(LHTheme.sheetTitleFont)
                    Text("Règles distinctes pour les détails, souvenirs et preuves.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Supprimer automatiquement les données expirées", isOn: $model.automaticCleanup)
                        .toggleStyle(.goalongSwitch).font(.system(size: 14, weight: .semibold))
                        .accessibilityIdentifier("retention-automatic")
                    Text(model.automaticCleanup
                         ? "Après confirmation, les données expirées peuvent être supprimées tout de suite puis lors du nettoyage quotidien. Réduire une durée s’applique aussi aux données existantes."
                         : "Le nettoyage automatique est désactivé : les données restent jusqu’à ce que vous les supprimiez. Choisir une durée ci-dessous n’active pas la suppression.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    ForEach(HistoryDataClass.allCases, id: \.self) { kind in
                        HStack(alignment: .center, spacing: 16) {
                            Text(kind.retentionTitle).font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker(kind.retentionTitle, selection: durationBinding(kind)) {
                                Text("Jusqu’à ce que je supprime").tag(0)
                                ForEach(durationOptions(kind), id: \.self) { days in Text(days == 1 ? "1 jour" : "\(days) jours").tag(days) }
                            }.labelsHidden().frame(width: 170)
                                .accessibilityIdentifier("retention-\(kind.rawValue)")
                        }.padding(12).background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.automaticCleanup && model.draft.includesProofExpiry {
                        Toggle("J’autorise aussi la suppression des sceaux et reçus expirés. La vérification de ces périodes peut devenir impossible.", isOn: $proofDeletionConfirmed)
                            .font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                            .accessibilityIdentifier("retention-confirm-proofs")
                    }
                    Text("Ces règles couvrent l’activité gérée par Goalong, le texte affiché, les souvenirs dérivés, les caches d’analyse, les sceaux et les reçus. Elles ne suppriment ni les originaux Temps d’écran d’Apple, ni les conversations IA d’origine, ni l’historique des analyses ChatGPT, ni les fichiers exportés, sauvegardes ou données déjà envoyées à un site ou un service : ceux-ci se suppriment depuis leurs propres réglages.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(24)
            }
            Divider()
            HStack {
                Text("Rien n’est appliqué avant votre confirmation.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(model.automaticCleanup ? "Vérifier et appliquer…" : "Enregistrer sans suppression automatique") {
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
