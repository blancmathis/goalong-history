#if os(macOS)
import AppKit
import LocalHistoryCore

/// T-050 B1 point 7: while a rule or session carries « Surveillance » with a stop other than « Libre », everything that
/// cuts Jev goes through that same stop: the consent switches (Jev, recording), « Tout suspendre », the recording pause
/// (menu, panel, dashboard, ⌘P), the key, stopping a session that carries it, turning its module off, weakening its rule.
/// « Verrouillé » refuses with its reason. « Libre »: nothing changes. A command without a dialog (the CLI) refuses.
@MainActor enum JevStopGate {
    enum Step: Equatable {
        case allow
        case typing(String)
        case password
        case refused(String)
    }

    static let lockedText = "Une surveillance « Verrouillé » est en cours : elle ne peut pas être coupée tant qu’elle tourne."
    static let noBlockingText = "Une surveillance « Mot de passe » est en cours et le blocage est désactivé. Réactivez le blocage dans Réglages › Modules pour entrer le mot de passe."
    /// Returned to the editor when the stop was not passed: nothing is saved.
    static let keptText = "La surveillance en cours reste inchangée."
    static let wrongText = "Texte différent. La surveillance continue."
    /// The editor's sentence, under « Arrêt », when « Surveillance » is checked with a stop other than « Libre ».
    static let editorText = "Tant que la surveillance tourne, couper Jev (consentement, pause, « Tout suspendre », clé, arrêt de la séance) ou l’affaiblir demande ce même arrêt."

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

    /// The step of one stop (a session's, a rule's). Jev off = nothing to cut.
    static func step(lock: BlockLock, jevEnabled: Bool) -> Step {
        step([JevSurveillanceActivity(settings: JevInterventionSettings(), lock: lock)], jevEnabled: jevEnabled)
    }

    /// The stop of what runs now: everything that cuts Jev as a whole.
    static func currentStep(monitor: JevMonitor = .shared) -> Step {
        step(monitor.currentActivity(), jevEnabled: monitor.enabled)
    }

    /// The stop of the surveillance the current Concentration session carries.
    static func focusStep(monitor: JevMonitor? = nil) -> Step {
        guard let id = ConcentrationRuntime.shared.controller?.currentSession?.id else { return .allow }
        let lock = JevSurveillanceStore.shared.sessionLock(kind: .focus, ids: [id])
        return lock == .free ? .allow : step(lock: lock, jevEnabled: (monitor ?? .shared).enabled)
    }

    /// The stop of the surveillance the Blocage sessions carry.
    static func blockStep(monitor: JevMonitor? = nil) -> Step {
        blockStep(store: .shared, blocks: BlockingRuntime.shared.controller?.activeBlocks ?? [], now: Date(), // wall: the controller's block dates
                  jevEnabled: (monitor ?? .shared).enabled)
    }

    /// Only the blocks already started carry their surveillance: a block programmed later asks nothing yet. Pure.
    static func blockStep(store: JevSurveillanceStore, blocks: [BlockingActiveBlock], now: Date, jevEnabled: Bool) -> Step {
        let lock = store.sessionLock(kind: .block, ids: JevMonitor.runningBlockIDs(blocks, now: now))
        return lock == .free ? .allow : step(lock: lock, jevEnabled: jevEnabled)
    }

    /// Quitting Goalong stops Jev until the next launch: the same stop, like the blocking lists. « Verrouillé » says
    /// that the window can be closed. Pure.
    static let quitLockedText = lockedText + " Goalong reste ouvert jusqu’à sa fin. Vous pouvez fermer la fenêtre."
    static func quitStep(_ step: Step) -> Step {
        if case .refused(let reason) = step, reason == lockedText { return .refused(quitLockedText) }
        return step
    }

    /// A recording pause set before a protected surveillance began ends when it begins (T-050 B1, question 2): only on
    /// the passage from « nothing protected » to « protected », so a pause made later through the stop itself stays.
    /// `wasProtected` nil = first look since launch: nothing is lifted. Pure.
    static func liftsManualPause(paused: Bool, step: Step, wasProtected: Bool?) -> Bool {
        paused && step != .allow && wasProtected == false
    }

    /// Asks for the stop of what runs now in a modal alert. True = Jev may be cut.
    @MainActor static func confirm(action: String, monitor: JevMonitor = .shared,
                                   verify: ((String) -> BlockingPasswordResult)? = nil) -> Bool {
        confirm(action: action, step: currentStep(monitor: monitor), verify: verify)
    }

    /// Asks for this stop in a modal alert. True = the action may go on.
    @MainActor static func confirm(action: String, step: Step, verify: ((String) -> BlockingPasswordResult)? = nil) -> Bool {
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
            alert.informativeText = "Une surveillance « \(BlockLock.typing.title) » est en cours. Recopiez ce texte pour continuer :\n\n\(text)"
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        case .password:
            alert.informativeText = "Une surveillance « \(BlockLock.password.title) » est en cours. Entrez le mot de passe de blocage pour continuer."
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
