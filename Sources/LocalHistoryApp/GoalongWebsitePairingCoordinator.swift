#if os(macOS)
import AppKit
import LocalHistoryQueryCLI

@MainActor
final class GoalongWebsitePairingCoordinator {
    private var busy = false

    func connect(url: URL) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let pairing = try GoalongSitePairing(url: url)
            NSApp.activate(ignoringOtherApps: true)
            let confirmation = NSAlert()
            confirmation.messageText = "Relier ce Mac à votre compte Goalong ?"
            confirmation.informativeText = "Site : \(pairing.origin)\n\nL’accès sera enregistré automatiquement sur ce Mac. Il permet uniquement l’envoi des journées que vous choisirez. Cette liaison ne transmet aucune activité et ne change pas vos permissions.\n\nSi un compte est déjà configuré, cette liaison le remplacera dans l’app."
            confirmation.addButton(withTitle: "Relier mon Mac")
            confirmation.addButton(withTitle: "Annuler")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return false }
            let directory = AppPaths.applicationSupportDirectory.appendingPathComponent("website-connections", isDirectory: true)
            let file = try await Task.detached(priority: .userInitiated) {
                let response = try pairing.exchange()
                return try pairing.save(response: response, directory: directory)
            }.value
            UserDefaults.standard.set(pairing.origin, forKey: "goalong.website.origin")
            UserDefaults.standard.set(file.path, forKey: "goalong.website.tokenFilePath")
            let done = NSAlert()
            done.messageText = "Votre Mac est relié à Goalong"
            done.informativeText = "Vous pouvez maintenant choisir une journée et regarder les données avant de les envoyer. Vos choix de partage restent sur le site."
            done.addButton(withTitle: "Choisir mes données")
            done.runModal()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Connexion à relancer"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "Fermer")
            alert.runModal()
            return false
        }
    }
}
#endif
