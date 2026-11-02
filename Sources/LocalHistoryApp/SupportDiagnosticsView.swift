#if os(macOS)
import AppKit
import SwiftUI

/// Contextual shortcut used by permission recovery and error states.
@MainActor struct SupportDiagnosticsExportButton: View {
    @ObservedObject private var controller = SupportRequestController.shared
    var body: some View {
        Button {
            controller.present()
        } label: {
            Label("Signaler un problème…", systemImage: "stethoscope")
        }
        .buttonStyle(LHSecondaryButtonStyle())
        .disabled(controller.isPreparing)
        .accessibilityIdentifier("support-export-diagnostics")
    }
}

@MainActor struct SupportDiagnosticsPanel: View {
    @State private var enabled = SupportDiagnostics.shared.isEnabled
    @State private var confirmClear = false
    @State private var feedback: String?
    var body: some View {
        GoalongSettingsGroup(title: "Aide et diagnostic") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Un problème ? Envoyez un rapport en un clic.").font(.system(size: 13, weight: .semibold))
                Text("Goalong résume ce qu’il a détecté et prépare un fichier technique que vous relisez avant de l’envoyer. Il ne contient ni votre historique, ni les sites visités, ni aucun texte.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SupportDiagnosticsExportButton()
            Divider()
            Toggle("Conserver les journaux techniques sur ce Mac", isOn: $enabled)
                .toggleStyle(.goalongSwitch).onChange(of: enabled) { SupportDiagnostics.shared.setEnabled($0) }
            // One sentence of help, the rest in a disclosure (DESIGN §12, UI-11C).
            Text("Recommandé : 7 jours et 5,3 Mo au plus, sur ce Mac, jamais envoyés automatiquement.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            GoalongDisclosureGroup("En savoir plus") {
                Text("Désactivé, plus aucun nouvel événement n’est conservé. Les journaux déjà enregistrés restent jusqu’à leur expiration ou jusqu’à « Effacer les journaux ».")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }.font(.system(size: 12))
            HStack {
                Button("Noter l’heure du problème") {
                    SupportDiagnostics.shared.record(.userMarkedIssue, component: .support)
                    feedback = "Heure notée. Reproduisez le problème puis signalez-le."
                }.disabled(!enabled)
                    .help("Marque l’instant où le problème se produit pour le retrouver dans le rapport.")
                Button("Effacer les journaux…") { confirmClear = true }
            }.buttonStyle(LHSecondaryButtonStyle())
            if let feedback { Text(feedback).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText) }
        }
        .confirmationDialog("Effacer uniquement les journaux techniques ?", isPresented: $confirmClear) {
            Button("Effacer les journaux", role: .destructive) {
                Task {
                    let success = await Task.detached(priority: .utility) { (try? SupportDiagnostics.shared.clear()) != nil }.value
                    feedback = success ? "Journaux effacés. Votre historique et vos réglages sont inchangés." : "Certains journaux n’ont pas pu être effacés."
                }
            }
        } message: { Text("Les rapports déjà envoyés ne sont pas concernés. L’historique d’activité n’est pas modifié.") }
    }
}
#endif
