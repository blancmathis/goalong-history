#if os(macOS)
import SwiftUI

@MainActor struct JevConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = JevMonitor.shared
    @State private var key = ""
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connexion à TypeSafe").font(LHTheme.sheetTitleFont)
                .accessibilityAddTraits(.isHeader)
            Text(monitor.hasKey ? "Une clé est enregistrée sur ce Mac. Vous pouvez la remplacer ou la supprimer." : "Ajoutez votre clé API TypeSafe pour utiliser la surveillance temps réel.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Clé API TypeSafe", text: $key)
                .textFieldStyle(GoalongFieldStyle()).accessibilityIdentifier("jev-api-key")
            Text("L’usage de l’API est facturé par TypeSafe. Enregistrer une clé ne donne aucune nouvelle autorisation d’envoi. La surveillance reste soumise à votre choix d’activation sur sa page.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Clé conservée dans un fichier privé (0600), jamais dans l’historique ni les journaux de diagnostic.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = monitor.error {
                Text(error).font(.callout).foregroundStyle(LHTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if monitor.hasKey {
                    Button("Supprimer la clé", role: .destructive) { confirmingRemoval = true }
                        .accessibilityIdentifier("jev-remove-key")
                }
                Spacer()
                Button("Fermer") { key = ""; dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("jev-connection-close")
                Button("Enregistrer") {
                    monitor.saveKey(key)
                    // Do not discard the typed value when validation or storage failed.
                    if monitor.error == nil { key = ""; dismiss() }
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("jev-save-key")
            }
        }
        .padding(26).frame(width: 510, alignment: .leading)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onDisappear { key = "" }
        .alert("Supprimer la clé TypeSafe ?", isPresented: $confirmingRemoval) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer la clé", role: .destructive) { monitor.removeKey() }
        } message: {
            Text("La surveillance ne pourra plus rien analyser sans une nouvelle clé. Votre historique et vos autres réglages restent inchangés.")
        }
    }
}
#endif
