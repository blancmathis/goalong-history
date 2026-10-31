#if os(macOS)
import SwiftUI

@MainActor struct JevConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = JevMonitor.shared
    @State private var key = ""
    @State private var confirmingRemoval = false
    /// Only errors from saving or removing the key. The shared monitor error also holds network errors.
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connexion à Jev").font(LHTheme.sheetTitleFont)
                .accessibilityAddTraits(.isHeader)
            // UI-15B (5): the opening sentence says what Jev does before asking for its key.
            Text(monitor.hasKey ? "Jev vous rappelle votre projet quand il repère une distraction. Une clé est enregistrée sur ce Mac : vous pouvez la remplacer ou la supprimer."
                                : "Jev vous rappelle votre projet quand il repère une distraction. Ajoutez votre clé d’accès pour le connecter.")
                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Clé d’accès Jev").font(.callout.weight(.medium))
            SecureField("", text: $key)
                .labelsHidden()
                .textFieldStyle(GoalongFieldStyle())
                .goalongPlaceholder("Collez votre clé", isEmpty: key.isEmpty)
                .accessibilityLabel("Clé d’accès Jev")
                .accessibilityIdentifier("jev-api-key")
            Text("L’usage est facturé par TypeSafe, le fournisseur de Jev ; enregistrer une clé n’autorise aucun envoi.")
                .font(.callout).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Label("Clé conservée dans un fichier privé de ce Mac, jamais dans l’historique ni les journaux de diagnostic.", systemImage: "lock")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = keyError {
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
                    keyError = monitor.error
                    if keyError == nil { key = ""; dismiss() }
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("jev-save-key")
            }
        }
        .padding(26).frame(width: 510, alignment: .leading)
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onDisappear { key = "" }
        .alert("Supprimer la clé Jev ?", isPresented: $confirmingRemoval) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer la clé", role: .destructive) { monitor.removeKey(); keyError = monitor.error }
        } message: {
            Text("La surveillance ne pourra plus rien analyser sans une nouvelle clé. Votre historique et vos autres réglages restent inchangés.")
        }
    }
}
#endif
