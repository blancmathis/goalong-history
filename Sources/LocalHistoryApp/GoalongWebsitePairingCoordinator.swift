#if os(macOS)
import AppKit
import LocalHistoryQueryCLI

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
            let pairing = try GoalongSitePairing(url: url)
            NSApp.activate(ignoringOtherApps: true)
            let confirmation = NSAlert()
            confirmation.messageText = "Relier ce Mac à votre compte Goalong ?"
            confirmation.informativeText = "Site : \(pairing.origin)\n\nL’accès sera enregistré automatiquement sur ce Mac. Il permet uniquement l’envoi des journées que vous choisirez. Cette liaison ne transmet aucune activité et ne change pas vos permissions.\n\nSi un compte est déjà configuré, cette liaison le remplacera dans l’app."
            confirmation.addButton(withTitle: "Relier mon Mac")
            confirmation.addButton(withTitle: "Annuler")
            guard await present(confirmation, on: window) == .alertFirstButtonReturn else { return false }
            let directory = AppPaths.applicationSupportDirectory.appendingPathComponent("website-connections", isDirectory: true)
            let file = try await Task.detached(priority: .userInitiated) {
                let response = try pairing.exchange()
                return try pairing.save(response: response, directory: directory)
            }.value
            UserDefaults.standard.set(pairing.origin, forKey: "goalong.website.origin")
            UserDefaults.standard.set(file.path, forKey: "goalong.website.tokenFilePath")
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
