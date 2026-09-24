#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct GoalongRetentionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = HistoryRetentionSettingsModel()
    @State private var confirming = false
    @State private var proofConsent = false
    private let activityKinds: [HistoryDataClass] = [.detailedEvents, .semanticSnapshots, .memories, .analysisCaches]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conservation de l’historique").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GoalongSettingsGroup(title: "Sur ce Mac") {
                        Toggle("Nettoyage automatique", isOn: $model.automaticCleanup).toggleStyle(.switch)
                        HStack {
                            Text("Conserver l’activité")
                            Spacer()
                            Picker("Conserver l’activité", selection: commonDuration) {
                                if commonDuration.wrappedValue == -1 { Text("Personnalisé").tag(-1) }
                                Text("Sans limite").tag(0)
                                ForEach([7, 30, 90, 365], id: \.self) { days in Text("\(days) jours").tag(days) }
                                if let extra = extraDuration { Text("\(extra) jours").tag(extra) }
                            }.labelsHidden().frame(width: 165)
                        }
                        Text(model.automaticCleanup ? "Après confirmation, les données plus anciennes pourront être effacées." : "Sans nettoyage automatique, rien n’est effacé.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    GoalongDisclosureGroup("Personnaliser par type de données") {
                        VStack(spacing: 14) {
                            ForEach(HistoryDataClass.allCases, id: \.self) { kind in
                                HStack {
                                    Text(kind.retentionTitle).font(.system(size: 13))
                                    Spacer()
                                    Picker(kind.retentionTitle, selection: duration(kind)) {
                                        Text("Sans limite").tag(0)
                                        ForEach(Array(Set([1,7,30,90,365] + [model.draft.duration(for: kind).days].compactMap { $0 })).sorted(), id: \.self) { days in
                                            Text("\(days) jours").tag(days)
                                        }
                                    }.labelsHidden().frame(width: 165)
                                }
                            }
                        }.padding(.top, 14)
                    }.font(.system(size: 13))
                    if model.automaticCleanup && model.draft.includesProofExpiry {
                        Toggle("Autoriser aussi la suppression des preuves expirées", isOn: $proofConsent).toggleStyle(.checkbox)
                        Text("La vérification des anciennes périodes pourra être perdue.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("Les originaux Apple, conversations, bilans ChatGPT, exports et copies déjà envoyées ne sont pas concernés.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(LHTheme.warning) }
                }.padding(24)
            }
            Divider()
            HStack {
                Text("Aucun changement avant validation.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Enregistrer") {
                    if model.automaticCleanup { confirming = true }
                    else if model.apply(proofDeletionConfirmed: false) { dismiss() }
                }.buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!model.hasChanges || (model.automaticCleanup && model.draft.includesProofExpiry && !proofConsent))
            }.padding(20)
        }.frame(width: 630, height: 560).background(LHTheme.pageBackground)
        .onChange(of: model.draft) { _ in proofConsent = false }
        .alert("Appliquer le nettoyage automatique ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Appliquer ces durées", role: .destructive) {
                if model.apply(proofDeletionConfirmed: proofConsent) { dismiss() }
            }
        } message: { Text(model.draft.retentionDescription + "\n\nLes données expirées peuvent être effacées immédiatement. Cette action est irréversible.") }
    }
    private var commonDuration: Binding<Int> {
        Binding(get: {
            let values = Set(activityKinds.map { model.draft.duration(for: $0).days ?? 0 })
            return values.count == 1 ? values.first! : -1
        }, set: { days in
            guard days >= 0 else { return }
            for kind in activityKinds { model.draft.setDuration(RetentionDuration(days: days), for: kind) }
        })
    }
    private var extraDuration: Int? {
        let value = commonDuration.wrappedValue
        return value > 0 && ![7,30,90,365].contains(value) ? value : nil
    }
    private func duration(_ kind: HistoryDataClass) -> Binding<Int> {
        Binding(get: { model.draft.duration(for: kind).days ?? 0 }, set: { model.draft.setDuration(RetentionDuration(days: $0), for: kind) })
    }
}

@MainActor struct GoalongDeletionSheet: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = 600
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Effacer de l’historique").font(.system(size: 23, weight: .semibold))
            Picker("Période", selection: $seconds) {
                Text("Les dix dernières minutes").tag(600)
                Text("La dernière heure").tag(3600)
                Text("Tout l’historique local").tag(0)
            }.pickerStyle(.radioGroup)
            Text("Supprime l’activité et ses résumés locaux. Les autres sources et les données déjà envoyées restent conservées.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                Spacer()
                Button("Effacer…", role: .destructive) { confirming = true }.buttonStyle(.bordered)
            }
        }.padding(26).frame(width: 520).background(LHTheme.pageBackground)
        .alert("Confirmer la suppression ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Effacer sur ce Mac", role: .destructive) {
                model.deleteDetails(since: seconds == 0 ? nil : Date().addingTimeInterval(-Double(seconds)))
                dismiss()
            }
        } message: { Text("Cette action est irréversible. Les preuves, les originaux Apple et IA, les bilans ChatGPT, les exports et les copies distantes ne sont pas supprimés.") }
    }
}
#endif
