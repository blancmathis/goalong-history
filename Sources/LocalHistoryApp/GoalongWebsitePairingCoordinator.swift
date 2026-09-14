#if os(macOS)
import AppKit
import LocalHistoryQueryCLI
import LocalHistoryCore

@MainActor
final class GoalongWebsitePairingCoordinator {
    private var busy = false
    private var pendingPrompt: (alert: NSAlert, parent: NSWindow)?

    func cancelPendingPrompt() {
        guard let prompt = pendingPrompt,
              prompt.parent.attachedSheet === prompt.alert.window else { return }
        prompt.parent.endSheet(prompt.alert.window, returnCode: .cancel)
    }

    private func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        pendingPrompt = (alert, window)
        defer { pendingPrompt = nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.attachedSheet?.makeKeyAndOrderFront(nil)
        }
    }

    func connect(url: URL, window: NSWindow) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            if url.host == "share" {
                let requested = try GoalongSiteSharingLink.destination(url: url)
                let defaults = UserDefaults.standard
                let savedOrigin = defaults.string(forKey: "goalong.website.origin") ?? ""
                let savedAccount = defaults.string(forKey: "goalong.website.accountID") ?? ""
                let fingerprint = defaults.string(forKey: "goalong.website.accountCredentialFingerprint") ?? ""
                let tokenPath = defaults.string(forKey: "goalong.website.tokenFilePath") ?? ""
                guard requested.origin == savedOrigin, requested.accountID == savedAccount,
                      let token = try? GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath)),
                      SHA256Digest.hashHex(Data(token.utf8)) == fingerprint else {
                    throw GoalongSiteExportError.invalid("Le compte actuellement ouvert sur le site n’est pas confirmé comme celui relié à ce Mac. Reliez ce compte depuis les réglages du site ; aucun accès ni choix n’a été modifié.")
                }
                // This merely reveals the picker. It neither modifies nor starts a send.
                return true
            }
            let pairing = try GoalongSitePairing(url: url)
            NSApp.activate(ignoringOtherApps: true)
            let confirmation = NSAlert()
            confirmation.messageText = "Relier ce Mac à votre compte Goalong ?"
            confirmation.informativeText = "Site : \(pairing.origin)\n\nL’accès sera enregistré automatiquement sur ce Mac. Il permet uniquement l’envoi des journées que vous choisirez. Cette liaison ne transmet aucune activité et ne change pas vos permissions.\n\nSi un compte est déjà configuré, cette liaison le remplacera dans l’app."
            confirmation.addButton(withTitle: "Relier mon Mac")
            confirmation.addButton(withTitle: "Annuler")
            guard await present(confirmation, on: window) == .alertFirstButtonReturn else { return false }
            let directory = AppPaths.applicationSupportDirectory.appendingPathComponent("website-connections", isDirectory: true)
            let saved = try await Task.detached(priority: .userInitiated) {
                let response = try pairing.exchange()
                let accountID = try GoalongSitePairing.accountID(response: response)
                let file = try pairing.save(response: response, directory: directory)
                let token = try GoalongSiteSubmission.readToken(file: file)
                return (file: file, accountID: accountID, fingerprint: SHA256Digest.hashHex(Data(token.utf8)))
            }.value
            // A schedule approved for the old account must not survive re-pairing.
            GoalongWebsiteAutoSender.shared.forget()
            UserDefaults.standard.set(pairing.origin, forKey: "goalong.website.origin")
            UserDefaults.standard.set(saved.file.path, forKey: "goalong.website.tokenFilePath")
            UserDefaults.standard.set(saved.accountID, forKey: "goalong.website.accountID")
            UserDefaults.standard.set(saved.fingerprint, forKey: "goalong.website.accountCredentialFingerprint")
            // The caller opens the data picker directly; no second modal to dismiss.
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Connexion à relancer"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "Fermer")
            _ = await present(alert, on: window)
            return false
        }
    }
}
#endif
