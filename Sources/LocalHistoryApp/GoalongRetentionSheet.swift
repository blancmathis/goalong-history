#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct GoalongDeletionSheet: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = 600
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Effacer de l’historique").font(LHTheme.sheetTitleFont)
            Picker("Période", selection: $seconds) {
                Text("Les dix dernières minutes").tag(600)
                Text("La dernière heure").tag(3600)
                Text("Tout l’historique local").tag(0)
            }.pickerStyle(.radioGroup)
            Text("Supprime l’activité de la période et ses résumés locaux. Les appels et l’activité de développement des jours concernés sont effacés pour la journée entière. La note du jour n’est effacée qu’avec tout l’historique. Les données déjà envoyées restent conservées.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                Spacer()
                Button("Effacer…", role: .destructive) { confirming = true }.buttonStyle(LHSecondaryButtonStyle())
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
