#if os(macOS)
import Foundation
import LocalHistoryCore

/// The switch of a rule row (T-050 B2b, S2): turning on is immediate, turning off goes through the rule's stop (P3).
/// Shown only where the engines can do it; otherwise hidden (P4): a stopped range has no « resume », a list range no
/// « off » outside its hours, a rule with « Surveillance » or a joined red range has no single stop.
enum BlockRuleSwitch: Equatable {
    case hidden
    /// On: turning it off asks `stop` first (« Libre » asks nothing).
    case on(stop: BlockLock)
    /// Off: turning it on is immediate.
    case off

    static func of(_ rule: BlockRule, canVerifyPassword: Bool) -> BlockRuleSwitch {
        guard rule.jev == nil else { return .hidden }
        let stop = rule.lock
        if rule.lists.isEmpty, let red = rule.red {
            if !red.enabled { return .off }
            // A protected red range in progress refuses any weakening until its end: « En cours » has its stop.
            if case .running = red.state, stop != .free { return .hidden }
        } else if rule.red != nil {
            return .hidden
        } else if case .running = rule.state {
        } else {
            return .hidden
        }
        if stop == .locked || (stop == .password && !canVerifyPassword) { return .hidden }
        return .on(stop: stop)
    }
}

/// What the member gives to pass the stop of a rule.
enum BlockRuleStopProof: Equatable {
    case none
    case typed(String, challenge: String)
    case password(String)
}

/// The switch's writes, through the engines' own calls. Nil = done; otherwise the words of the refusal.
enum BlockRuleSwitchAction {
    @MainActor static func turnOn(_ rule: BlockRule, braise: BraiseController?) -> String? {
        guard let red = rule.red, rule.lists.isEmpty else { return "Cette règle ne s’allume pas ici." }
        guard let braise else { return "L’écran rouge n’est pas disponible sur ce Mac pour l’instant." }
        do { try braise.setRangeEnabled(red.rangeID, true) } catch { return words(error) }
        return nil
    }

    /// The program blocks in progress of the rule's lists.
    @MainActor static func blockIDs(_ rule: BlockRule, blocking: BlockingController?) -> [UUID] {
        let ranges = Set(rule.lists.flatMap(\.rangeIDs))
        return (blocking?.activeBlocks ?? []).compactMap { block in
            if case .program(let id) = block.origin, ranges.contains(id) { return block.id }
            return nil
        }
    }

    /// The text to retype for a « Difficile » rule: the engine's own for a list block, a fresh one for the red screen.
    @MainActor static func challenge(_ rule: BlockRule, blocking: BlockingController?) -> String {
        if let first = blockIDs(rule, blocking: blocking).first, let blocking { return blocking.typingChallenge(for: first) }
        return BlockingController.newTypingChallenge()
    }

    @MainActor static func turnOff(_ rule: BlockRule, proof: BlockRuleStopProof, blocking: BlockingController?,
                                   braise: BraiseController?) -> String? {
        guard case .on(let stop) = BlockRuleSwitch.of(rule, canVerifyPassword: blocking != nil) else {
            return "Cette règle ne s’arrête pas ici."
        }
        if rule.lists.isEmpty, let red = rule.red {
            switch (stop, proof) {
            case (.free, _): break
            case (.typing, .typed(let typed, let challenge)): if typed != challenge { return "Le texte ne correspond pas." }
            case (.password, .password(let password)):
                guard let blocking else { return "Le mot de passe vient du module Garde-fous." }
                if let refusal = passwordWords(blocking.verifyRedScreenPassword(password)) { return refusal }
            default: return "L’arrêt de cette règle est demandé d’abord."
            }
            guard let braise else { return "L’écran rouge n’est pas disponible sur ce Mac pour l’instant." }
            do { try braise.setRangeEnabled(red.rangeID, false) } catch { return words(error) }
            return nil
        }
        let ids = blockIDs(rule, blocking: blocking)
        guard let blocking, let first = ids.first else { return "Le blocage n’a pas encore commencé. Réessayez dans un instant." }
        switch (stop, proof) {
        case (.free, _): ids.forEach { blocking.stop($0) }
        case (.typing, .typed(let typed, _)):
            // One rule, one stop: the text of its first block passes the others.
            guard typed == blocking.typingChallenge(for: first) else { return "Le texte ne correspond pas." }
            ids.forEach { blocking.stop($0, typed: blocking.typingChallenge(for: $0)) }
        case (.password, .password(let password)):
            for id in ids { if let refusal = passwordWords(blocking.unlockWithPassword(password, blockID: id)) { return refusal } }
        default: return "L’arrêt de cette règle est demandé d’abord."
        }
        return blockIDs(rule, blocking: blocking).isEmpty ? nil : "L’arrêt n’a pas pu être enregistré."
    }

    @MainActor static func passwordWords(_ result: BlockingPasswordResult) -> String? {
        result == .ok ? nil : RedScreenPasswordSheet.text(result)
    }

    private static func words(_ error: Error) -> String {
        (error as? RedScreenRefusal)?.message ?? error.localizedDescription
    }
}

// MARK: - Modèles (A1)

/// A new rule already filled: a template, or a copy of a rule. The window opens on it; nothing is written before
/// « Enregistrer ».
struct BlockRulePreset: Equatable {
    var id: String
    var title: String
    var trigger: BlockRuleEditor.Trigger
    var draft: BlockRuleDraft
    /// A session's length.
    var minutes: Int?

    /// « Dupliquer »: the same rule, on, as a new one.
    init(copying rule: BlockRule) {
        var draft = BlockRuleDraft(rule)
        draft.paused = false
        self.init(id: "copy-\(rule.id)", title: "Copie", trigger: rule.key.isAlways ? .always : .schedule, draft: draft)
    }

    init(id: String, title: String, trigger: BlockRuleEditor.Trigger, draft: BlockRuleDraft, minutes: Int? = nil) {
        self.id = id; self.title = title; self.trigger = trigger; self.draft = draft; self.minutes = minutes
    }

    /// The four starts of the empty page and of « Nouvelle règle ». Lists are picked by name; none = the member picks.
    static func templates(lists: [BlockList]) -> [BlockRulePreset] {
        let blocking = lists.filter { $0.mode != .allowOnly }
        let social = Set(blocking.filter { fold($0.name).contains("reseaux sociaux") || fold($0.name).contains("social") }.map(\.id))
        let all = Set(blocking.map(\.id))
        var work = BlockRuleDraft(); work.weekdays = Set(1...5); work.startMinute = 9 * 60; work.endMinute = 18 * 60
        work.listIDs = social
        var evening = BlockRuleDraft(); evening.weekdays = Set(1...7); evening.startMinute = 21 * 60; evening.endMinute = 7 * 60
        evening.red = true; evening.intensity = 0.6
        var session = BlockRuleDraft(); session.listIDs = all
        var deep = BlockRuleDraft(); deep.weekdays = Set(1...5); deep.startMinute = 9 * 60; deep.endMinute = 17 * 60
        deep.listIDs = all; deep.lock = .typing
        return [
            BlockRulePreset(id: "social-work", title: "Réseaux sociaux aux heures de travail", trigger: .schedule, draft: work),
            BlockRulePreset(id: "red-evening", title: "Écran rouge le soir", trigger: .schedule, draft: evening),
            BlockRulePreset(id: "session-25", title: "Séance de 25 min", trigger: .session, draft: session, minutes: 25),
            BlockRulePreset(id: "deep-day", title: "Journée profonde", trigger: .schedule, draft: deep),
        ]
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}

// MARK: - Phrase de résumé (S3)

/// The editor's last line: the rule in plain words, with what its stop will ask.
enum BlockRuleSentence {
    struct Session: Equatable {
        /// Nil = no planned end.
        var end: Date?
        /// « en Pomodoro 25 / 5 », nil for Continu.
        var rhythm: String?
        var wholeMac = false
    }

    /// Nil = nothing chosen yet: the footer already says what is missing.
    static func text(trigger: BlockRuleEditor.Trigger, draft: BlockRuleDraft, lists: [BlockList], lock: BlockLock,
                     session: Session? = nil, now: Date) -> String? {
        let what: String
        if session?.wholeMac == true {
            what = "Bloque tout le Mac"
        } else {
            let rule = BlockRule(draft, lists: lists)
            guard !rule.lists.isEmpty || rule.red != nil || rule.jev != nil else { return nil }
            what = rule.summary
        }
        var when: [String] = []
        switch trigger {
        case .always: when = ["tout le temps"]
        case .schedule:
            let key = BlockRule.Key(weekdays: draft.weekdays, start: draft.startMinute, end: draft.endMinute, lock: lock)
            guard !draft.weekdays.isEmpty, draft.startMinute != draft.endMinute else { return nil }
            when = ["\(BlockingFormat.weekdays(draft.weekdays).lowercased()), \(BlockingFormat.range(key.range))"]
        case .session:
            if let rhythm = session?.rhythm { when.append(rhythm) }
            if let end = session?.end { when.append(BlockingFormat.until(end, now: now)) }
        }
        let stop: String
        switch lock {
        case .free: stop = "Arrêt libre."
        case .typing: stop = "Pour l’arrêter, il faudra recopier un texte."
        case .password: stop = "Pour l’arrêter, il faudra le mot de passe."
        case .locked:
            if trigger == .session, let end = session?.end {
                stop = "Vous ne pourrez pas l’arrêter avant \(BlockingFormat.deadline(end, now: now))."
            } else {
                stop = "Vous ne pourrez pas l’arrêter pendant ses horaires."
            }
        }
        let pauses = lock == .locked && draft.pause != nil ? " Les pauses du budget restent permises, sans pause en plus." : ""
        return ([what] + when).joined(separator: ", ") + ". " + stop + pauses
    }
}

private extension BlockRule {
    /// The rule a draft would make, for its words only.
    init(_ draft: BlockRuleDraft, lists: [BlockList]) {
        let key = BlockRule.Key(weekdays: draft.weekdays, start: draft.startMinute, end: draft.endMinute, lock: draft.lock)
        let parts = lists.filter { draft.listIDs.contains($0.id) }.map { list in
            ListPart(id: list.id, rangeIDs: [], name: list.name,
                     kind: list.mode == .allowOnly ? .allowOnly : list.effectiveAction == .slowDown ? .slowDown : .block, state: .idle)
        }
        let red = draft.hasRedPart ? RedPart(rangeID: UUID(), intensity: draft.red ? draft.intensity : 0,
                                             brightness: draft.brightness, enabled: true, state: .idle) : nil
        let jev = draft.surveillance.map { JevPart(rangeID: UUID(), settings: $0, state: .idle) }
        self.init(id: "draft", key: key, lists: parts, red: red, lock: draft.lock, state: .idle, jev: jev)
    }
}

// MARK: - Alerte de la Surveillance seule (lot B2a, F2)

extension BlockingNowPlan {
    /// The lock alert of a session with « Surveillance » only: it speaks of the watch, not of lists.
    /// No guard holds the watch: it promises what Goalong does (it refuses to quit), not a restart it cannot survive.
    func watchLockMessage(_ lock: BlockLock, calendar: Calendar = .current) -> String {
        let deadline = BlockingFormat.deadline(end, now: now, calendar: calendar)
        return lock == .password
            ? "Sans le mot de passe, la surveillance reste active \(BlockingFormat.untilPhrase(deadline))."
            : "Personne ne pourra arrêter la surveillance avant \(deadline). Goalong reste ouvert jusqu’à sa fin."
    }
}
#endif
