#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SupportExportController: ObservableObject {
    static let shared = SupportExportController()
    @Published private(set) var isPreparing = false
    @Published var message: String?

    func export(completion: (() -> Void)? = nil) {
        guard !isPreparing else { completion?(); return }
        isPreparing = true; message = nil
        let live = SupportDiagnosticsRuntime.shared.snapshot()
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<Data, Error> in
                Result { try SupportReport.build(live: live).data() }
            }.value
            switch result {
            case .failure(let error):
                SupportDiagnostics.shared.failure(error, component: .support)
                message = "Le rapport n’a pas pu être préparé. Aucune donnée n’a été envoyée."
                isPreparing = false; completion?()
            case .success(let data):
                let panel = NSSavePanel()
                panel.title = "Exporter le diagnostic de Goalong"
                panel.message = "Fichier technique lisible avant partage : états, erreurs numériques, version, chronologie et résumés de crash. Aucun historique, contenu privé ou envoi automatique."
                panel.nameFieldStringValue = "Goalong-diagnostic-\(SupportDiagnostics.day(Date()).dropFirst(4)).json"
                panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
                NSApplication.shared.activate(ignoringOtherApps: true)
                panel.begin { response in
                    Task { @MainActor in
                        defer { self.isPreparing = false; completion?() }
                        guard response == .OK, let url = panel.url else { return }
                        let saved = await Task.detached(priority: .utility) {
                            Result { try SupportReportWriter.write(data, to: url) }
                        }.value
                        switch saved {
                        case .success:
                            SupportDiagnostics.shared.record(.reportExported, component: .support,
                                values: [.byteCount: .count(data.count)])
                            self.message = "Rapport enregistré. Vous pouvez le lire puis le joindre à votre message au support. Rien n’a été envoyé."
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        case .failure(let error):
                            SupportDiagnostics.shared.failure(error, component: .support)
                            self.message = "Le fichier n’a pas pu être enregistré. Essayez un autre dossier."
                        }
                    }
                }
            }
        }
    }
}

@MainActor struct SupportDiagnosticsExportButton: View {
    @ObservedObject private var controller = SupportExportController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(controller.isPreparing ? "Préparation du diagnostic…" : "Exporter un diagnostic…") { controller.export() }
                .buttonStyle(.bordered).disabled(controller.isPreparing)
                .accessibilityIdentifier("support-export-diagnostics")
            if let message = controller.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor struct SupportDiagnosticsPanel: View {
    @State private var enabled = SupportDiagnostics.shared.isEnabled
    @State private var confirmClear = false
    @State private var feedback: String?
    var body: some View {
        GoalongSettingsGroup(title: "Diagnostic et assistance") {
            Toggle("Conserver les journaux techniques sur ce Mac", isOn: $enabled)
                .toggleStyle(.switch).onChange(of: enabled) { SupportDiagnostics.shared.setEnabled($0) }
            Text("Autorisations, état des services, erreurs, mises à jour et indices de crash. Aucun contenu d’écran, historique, conversation, adresse web, mot de passe ou identifiant de compte. Aucun envoi automatique.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Conservation : jusqu’à 7 jours, au maximum 3,5 Mio de journaux. Vous choisissez quand exporter et à qui transmettre le fichier.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            SupportDiagnosticsExportButton()
            HStack {
                Button("Marquer le problème maintenant") {
                    SupportDiagnostics.shared.record(.userMarkedIssue, component: .support)
                    feedback = enabled ? "Repère ajouté. Reproduisez le problème puis exportez le diagnostic." : "Activez les journaux pour ajouter un repère."
                }.disabled(!enabled)
                Button("Effacer les journaux…") { confirmClear = true }
            }.buttonStyle(.bordered)
            if let feedback { Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Effacer uniquement les journaux techniques ?", isPresented: $confirmClear) {
            Button("Effacer les journaux", role: .destructive) {
                Task {
                    let success = await Task.detached(priority: .utility) { (try? SupportDiagnostics.shared.clear()) != nil }.value
                    feedback = success ? "Journaux effacés. Votre historique et vos réglages sont inchangés." : "Certains journaux n’ont pas pu être effacés."
                }
            }
        } message: { Text("Les rapports déjà exportés restent dans le dossier où vous les avez enregistrés. L’historique d’activité n’est pas modifié.") }
    }
}
#endif
