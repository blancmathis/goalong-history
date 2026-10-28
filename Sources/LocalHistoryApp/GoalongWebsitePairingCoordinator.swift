#if os(macOS)
import AppKit
import LocalHistoryQueryCLI
import LocalHistoryCore

@MainActor
final class GoalongWebsitePairingCoordinator {
    private var busy = false
    static var connectionsDirectory: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("website-connections", isDirectory: true)
    }
    /// Deletes the credential file when pairing created it (never a file the user picked) and drops
    /// the account details bound to it. The access stays valid on the site until it is revoked there.
    /// Returns true only when the file was deleted.
    @discardableResult static func forgetStoredToken(path: String) -> Bool {
        GoalongWebsiteAutoSender.shared.forget()
        let deleted = GoalongSitePairing.discardManagedToken(path: path, directory: connectionsDirectory)
        for key in ["goalong.website.accountID", "goalong.website.accountCredentialFingerprint", GoalongWebsiteAutoSender.refusedCredentialKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return deleted
    }
    /// True for a file that « Relier mon Mac » created (<UUID>.token in the connections folder).
    /// Only such a file is deleted on disconnect; a file the user picked stays.
    static func isManagedTokenPath(_ path: String, directory: URL? = nil) -> Bool {
        guard !path.isEmpty else { return false }
        let directory = directory ?? connectionsDirectory
        let file = URL(fileURLWithPath: path)
        return file.lastPathComponent.range(of: "^[0-9A-F-]{36}\\.token$", options: .regularExpression) != nil
            && file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path
    }
    /// Pairing the same account on the same site again keeps the daily plan (paused for a review).
    /// Any other account, or an unknown previous account, drops it.
    static func keepsSchedule(savedOrigin: String, savedAccountID: String, newOrigin: String, newAccountID: String) -> Bool {
        !savedAccountID.isEmpty && savedAccountID == newAccountID && !savedOrigin.isEmpty && savedOrigin == newOrigin
    }
    /// What the confirmation says about an existing daily plan. It promises to keep the plan only
    /// when `connect` can keep it: account and site recorded, and the plan bound to the same site.
    static func scheduleNotice(planOrigin: String?, savedOrigin: String, savedAccountID: String, newOrigin: String) -> String {
        guard let planOrigin else { return "" }
        let keepable = keepsSchedule(savedOrigin: savedOrigin, savedAccountID: savedAccountID, newOrigin: newOrigin, newAccountID: savedAccountID)
            && planOrigin == newOrigin
        return keepable
            ? " Avec le même compte, l’envoi quotidien reste programmé, en pause jusqu’à votre relecture. Avec un autre compte, il sera supprimé."
            : " L’envoi quotidien programmé sera supprimé."
    }
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
            let notice = Self.scheduleNotice(planOrigin: GoalongWebsiteAutoSender.shared.savedConfiguration?.origin,
                savedOrigin: UserDefaults.standard.string(forKey: "goalong.website.origin") ?? "",
                savedAccountID: UserDefaults.standard.string(forKey: "goalong.website.accountID") ?? "",
                newOrigin: pairing.origin)
            confirmation.informativeText = "Site : \(pairing.origin)\n\nL’accès sera enregistré automatiquement sur ce Mac. Il permet uniquement l’envoi des journées que vous choisirez. Cette liaison ne transmet aucune activité et ne change pas vos permissions.\n\nSi un compte est déjà configuré, cette liaison le remplacera dans l’app." + notice
            confirmation.addButton(withTitle: "Relier mon Mac")
            confirmation.addButton(withTitle: "Annuler")
            guard await present(confirmation, on: window) == .alertFirstButtonReturn else { return false }
            let directory = Self.connectionsDirectory
            let previousTokenPath = UserDefaults.standard.string(forKey: "goalong.website.tokenFilePath") ?? ""
            let saved = try await Task.detached(priority: .userInitiated) {
                let response = try pairing.exchange()
                let accountID = try GoalongSitePairing.accountID(response: response)
                let file = try pairing.save(response: response, directory: directory)
                let token = try GoalongSiteSubmission.readToken(file: file)
                return (file: file, accountID: accountID, fingerprint: SHA256Digest.hashHex(Data(token.utf8)))
            }.value
            // A schedule approved for another account must not survive re-pairing. The same
            // account keeps it, bound to the new access and paused until the user reviews it.
            let previousOrigin = UserDefaults.standard.string(forKey: "goalong.website.origin") ?? ""
            let previousAccount = UserDefaults.standard.string(forKey: "goalong.website.accountID") ?? ""
            if Self.keepsSchedule(savedOrigin: previousOrigin, savedAccountID: previousAccount,
                                  newOrigin: pairing.origin, newAccountID: saved.accountID ?? ""),
               GoalongWebsiteAutoSender.shared.savedConfiguration?.origin == pairing.origin {
                GoalongWebsiteAutoSender.shared.rebind(tokenPath: saved.file.path, credentialFingerprint: saved.fingerprint)
            } else {
                GoalongWebsiteAutoSender.shared.forget()
            }
            UserDefaults.standard.removeObject(forKey: GoalongWebsiteAutoSender.refusedCredentialKey)
            UserDefaults.standard.set(pairing.origin, forKey: "goalong.website.origin")
            UserDefaults.standard.set(saved.file.path, forKey: "goalong.website.tokenFilePath")
            UserDefaults.standard.set(saved.accountID, forKey: "goalong.website.accountID")
            UserDefaults.standard.set(saved.fingerprint, forKey: "goalong.website.accountCredentialFingerprint")
            // The replaced credential is deleted only now that the new one is saved and selected.
            if previousTokenPath != saved.file.path {
                GoalongSitePairing.discardManagedToken(path: previousTokenPath, directory: directory)
            }
            // The caller opens the data picker directly; no second modal to dismiss.
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Connexion non confirmée"
            alert.informativeText = goalongUserMessage(error)
            alert.addButton(withTitle: "Fermer")
            _ = await present(alert, on: window)
            return false
        }
    }
}
#endif
