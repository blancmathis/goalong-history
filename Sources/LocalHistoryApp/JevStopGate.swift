#if os(macOS)
import AppKit
import LocalHistoryCore

/// T-050 B1 point 7: while a rule or session carries « Surveillance » with a stop other than « Libre », everything that
/// cuts Jev (the consent switch, « Tout suspendre », ⌘P) goes through that same stop. « Libre »: nothing changes.
@MainActor enum JevStopGate {
    enum Step: Equatable {
        case allow
        case typing(String)
        case password
        case refused(String)
    }

    static let lockedText = "Une surveillance « Verrouillé » est en cours : Jev ne peut pas être coupé avant sa fin."
    static let noBlockingText = "Une surveillance « Mot de passe » est en cours et le blocage est désactivé : Jev ne peut pas être coupé avant sa fin."
    static let wrongText = "Texte différent. Jev continue."
    /// The editor's sentence, under « Arrêt », when « Surveillance » is checked with a stop other than « Libre ».
    static let editorText = "Tant que la surveillance tourne, couper Jev (consentement, « Tout suspendre », ⌘P) demande ce même arrêt."

    /// The strongest stop among what runs now. Jev off = nothing to cut. Pure.
    static func step(_ activity: [JevSurveillanceActivity], jevEnabled: Bool,
                     challenge: () -> String = BlockingController.newTypingChallenge) -> Step {
        guard jevEnabled, let lock = activity.map(\.lock).max(by: { $0.strength < $1.strength }) else { return .allow }
        switch lock {
        case .free: return .allow
        case .typing: return .typing(challenge())
        case .password: return .password
        case .locked: return .refused(lockedText)
        }
    }

    /// Nil = Jev may be cut. Otherwise the reason it stays. `verify` = the blocking password (nil: blocking off). Pure.
    static func refusal(_ step: Step, typed: String, verify: ((String) -> BlockingPasswordResult)?) -> String? {
        switch step {
        case .allow: return nil
        case .refused(let reason): return reason
        case .typing(let text): return typed == text ? nil : wrongText
        case .password:
            guard let verify else { return noBlockingText }
            let answer = verify(typed)
            return answer == .ok ? nil : RedScreenPasswordSheet.text(answer)
        }
    }

    static func needsAsking(_ step: Step) -> Bool { step != .allow }

    /// Asks for the stop in a modal alert. True = Jev may be cut.
    @MainActor static func confirm(action: String, monitor: JevMonitor = .shared,
                                   verify: ((String) -> BlockingPasswordResult)? = nil) -> Bool {
        let step = step(monitor.currentActivity(), jevEnabled: monitor.enabled)
        guard needsAsking(step) else { return true }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = action
        var field: NSTextField?
        switch step {
        case .allow: return true
        case .refused(let reason):
            alert.informativeText = reason
            alert.addButton(withTitle: "Fermer")
            alert.runModal()
            return false
        case .typing(let text):
            alert.informativeText = "Une surveillance « \(BlockLock.typing.title) » est en cours. Recopiez ce texte pour couper Jev :\n\n\(text)"
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        case .password:
            alert.informativeText = "Une surveillance « \(BlockLock.password.title) » est en cours. Entrez le mot de passe de blocage pour couper Jev."
            field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let password = verify ?? BlockingRuntime.shared.controller.map { controller in { controller.verifyRedScreenPassword($0) } }
        if let reason = refusal(step, typed: field?.stringValue ?? "", verify: password) {
            let failure = NSAlert(); failure.messageText = action; failure.informativeText = reason
            failure.runModal()
            return false
        }
        return true
    }
}
#endif
