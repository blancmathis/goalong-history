#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore

/// P3 (T-059): a rule whose stop is stronger than « Libre » is protected at all times, running or not. Weakening it
/// (weaker stop, fewer lists or hours, more pauses, red screen or brightness weaker, off, deleted) goes through its stop.
/// The member passes the stop here once; each engine (lists, red screen, surveillance) reads this grant before a write
/// that weakens and refuses without it. Hardening never asks. A grant covers one change: its caller revokes it, and it
/// ends alone after `lifetime` seconds of uptime (a clock set back does not extend it). « Verrouillé » is never granted.
@MainActor final class RuleStopGrant {
    static let shared = RuleStopGrant()

    static let lockedText = "Cette règle est « Verrouillé » : elle peut seulement devenir plus stricte. La désactiver, la supprimer ou l’affaiblir est refusé."
    static let keptText = "La règle protégée reste inchangée."
    static let wrongText = "Texte différent. La règle protégée reste inchangée."

    /// The engines' refusal when the stop was not passed.
    static func needText(_ lock: BlockLock) -> String {
        switch lock {
        case .free: return keptText
        case .typing: return "Cette règle est protégée (« \(BlockLock.typing.title) ») : l’affaiblir demande de recopier son texte."
        case .password: return "Cette règle est protégée (« \(BlockLock.password.title) ») : l’affaiblir demande le mot de passe de blocage."
        case .locked: return lockedText
        }
    }

    var lifetime: TimeInterval = 60
    private let uptime: () -> TimeInterval
    private let verifyPassword: @MainActor (String) -> BlockingPasswordResult
    private var granted: (lock: BlockLock, until: TimeInterval)?
    /// The text the member must retype for « Difficile », issued here so a caller cannot choose it.
    private(set) var challenge: String?

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         verifyPassword: @escaping @MainActor (String) -> BlockingPasswordResult = {
             BlockingRuntime.shared.controller?.verifyRedScreenPassword($0)
                 ?? .refused(reason: "Les blocages sont arrêtés : aucun mot de passe n’est disponible.")
         }) {
        self.uptime = uptime; self.verifyPassword = verifyPassword
    }

    func newChallenge() -> String {
        let text = BlockingController.newTypingChallenge()
        challenge = text
        return text
    }

    /// True when a change that needs `lock` may be written now.
    func covers(_ lock: BlockLock) -> Bool {
        if lock == .free { return true }
        guard lock != .locked, let granted, uptime() < granted.until else { return false }
        return granted.lock.strength >= lock.strength
    }

    /// Checks the proof of `lock`. Nil = passed: the grant covers `lock` until `revoke()` or `lifetime`.
    /// `verify` replaces the blocking password check (the page's own controller).
    func pass(_ lock: BlockLock, proof: BlockRuleStopProof,
              verify: (@MainActor (String) -> BlockingPasswordResult)? = nil) -> String? {
        switch (lock, proof) {
        case (.free, _): return nil
        case (.locked, _): return Self.lockedText
        case (.typing, .typed(let typed, let shown)):
            guard let challenge, shown == challenge, typed == challenge else { return Self.wrongText }
        case (.password, .password(let password)):
            let answer = (verify ?? verifyPassword)(password)
            if answer != .ok { return RedScreenPasswordSheet.text(answer) }
        default: return Self.needText(lock)
        }
        challenge = nil
        let strongest = granted.map { $0.lock.strength >= lock.strength ? $0.lock : lock } ?? lock
        granted = (strongest, uptime() + lifetime)
        return nil
    }

    func revoke() { granted = nil; challenge = nil }

    /// Asks the stop of `lock` in a modal alert and passes it. True = the grant covers `lock`.
    static func confirm(_ lock: BlockLock, action: String = "Affaiblir la règle", grant: RuleStopGrant = .shared) -> Bool {
        if grant.covers(lock) { return true }
        // Tests never show a modal alert (nor take focus): no proof = refused.
        if NSClassFromString("XCTestCase") != nil { return false }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = action
        var field: NSTextField?
        var text = ""
        switch lock {
        case .free: return true
        case .locked:
            alert.informativeText = lockedText
            alert.addButton(withTitle: "Fermer")
            alert.runModal()
            return false
        case .typing:
            text = grant.newChallenge()
            alert.informativeText = "Cette règle est « \(BlockLock.typing.title) ». Recopiez ce texte pour l’affaiblir :\n\n\(text)"
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        case .password:
            alert.informativeText = "Cette règle est « \(BlockLock.password.title) ». Entrez le mot de passe de blocage pour l’affaiblir."
            field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let typed = field?.stringValue ?? ""
        let proof: BlockRuleStopProof = lock == .typing ? .typed(typed, challenge: text) : .password(typed)
        if let reason = grant.pass(lock, proof: proof) {
            let failure = NSAlert(); failure.messageText = action; failure.informativeText = reason
            failure.runModal()
            return false
        }
        return true
    }
}
#endif
