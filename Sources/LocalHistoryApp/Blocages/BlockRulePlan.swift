#if os(macOS)
import Foundation

/// What the editor of a schedule rule holds. `lock` is the stored lock of the rule's ranges.
struct BlockRuleDraft: Equatable {
    var weekdays: Set<Int> = Set(1...5)
    var startMinute = 9 * 60
    var endMinute = 12 * 60
    var listIDs: Set<UUID> = []
    var red = false
    var intensity = 0.6
    /// Nil = the brightness stays free.
    var brightness: Double?
    var lock: BlockLock = .free
    /// A rule with the red screen only can be switched off without being removed.
    var paused = false

    init() {}

    init(_ rule: BlockRule) {
        weekdays = rule.key.weekdays; startMinute = rule.key.start; endMinute = rule.key.end
        listIDs = Set(rule.lists.map(\.id))
        lock = rule.key.lock
        if let part = rule.red {
            red = part.intensity > 0 || part.brightness == nil
            if red { intensity = part.intensity }
            brightness = part.brightness
            paused = !part.enabled
        }
    }

    var hasRedPart: Bool { red || brightness != nil }

    /// Why the rule cannot be saved as it is. Nil = it can be handed to the engines.
    var problem: String? {
        if weekdays.isEmpty || startMinute == endMinute { return "Choisissez au moins un jour et deux heures différentes." }
        if listIDs.isEmpty && !hasRedPart { return "Choisissez ce que la règle bloque." }
        return nil
    }
}

/// A rule saved as writes to the two engines. The engines keep every check: this plan only says which
/// ranges change. Ranges already in a rule keep their identifier, so holds, skips and blocks in progress stay
/// tied to them.
enum BlockRulePlan {
    struct Writes {
        var lists: [BlockList] = []
        var red: [BraiseController.RangeWrite] = []
        var deleting: Set<UUID> = []

        var touchesRed: Bool { !red.isEmpty || !deleting.isEmpty }
        var isEmpty: Bool { lists.isEmpty && !touchesRed }
    }

    /// The writes that turn `rule` into `draft`. A nil draft removes the rule; a nil rule creates one. Pure.
    static func writes(_ draft: BlockRuleDraft?, replacing rule: BlockRule?, lists: [BlockList],
                       red: RedScreenProgram?) -> Writes {
        var result = Writes()
        let carried = Dictionary((rule?.lists ?? []).map { ($0.id, Set($0.rangeIDs)) }, uniquingKeysWith: { $0.union($1) })
        for list in lists {
            let own = carried[list.id] ?? []
            var next = list
            if let draft, draft.listIDs.contains(list.id) {
                if own.isEmpty {
                    let key = BlockRule.Key(weekdays: draft.weekdays, start: draft.startMinute, end: draft.endMinute, lock: draft.lock)
                    if !next.program.ranges.contains(where: { BlockRule.Key($0) == key }) {
                        next.program.ranges.append(BlockProgramRange(weekdays: draft.weekdays, startMinute: draft.startMinute,
                                                                     endMinute: draft.endMinute, lock: draft.lock))
                    }
                } else {
                    next.program.ranges = next.program.ranges.map { own.contains($0.id) ? edited($0, draft) : $0 }
                }
            } else {
                next.program.ranges.removeAll { own.contains($0.id) }
            }
            if next != list { result.lists.append(next) }
        }
        guard let program = red else { return result }
        let existing = rule?.red.flatMap { part in program.program.ranges.first { $0.id == part.rangeID } }
        if let draft, draft.hasRedPart {
            let range = existing.map { edited($0, draft) }
                ?? BlockProgramRange(weekdays: draft.weekdays, startMinute: draft.startMinute, endMinute: draft.endMinute, lock: draft.lock)
            let intensity = draft.red ? draft.intensity : 0
            let enabled = draft.listIDs.isEmpty ? !draft.paused : true
            let same = existing == range && program.intensity(of: range.id) == intensity
                && program.brightness(of: range.id) == draft.brightness && program.disabled.contains(range.id) != enabled
            if !same {
                result.red = [BraiseController.RangeWrite(range: range, intensity: intensity, enabled: enabled,
                                                          brightness: .some(draft.brightness))]
            }
        } else if let existing {
            result.deleting = [existing.id]
        }
        return result
    }

    /// The range with the rule's days and hours. Its stored lock is rewritten only when the rule's lock changes.
    private static func edited(_ range: BlockProgramRange, _ draft: BlockRuleDraft) -> BlockProgramRange {
        var next = range
        next.weekdays = draft.weekdays; next.startMinute = draft.startMinute; next.endMinute = draft.endMinute
        if next.effectiveLock != draft.lock { next.lock = draft.lock }
        return next
    }

    /// Checks both engines, then writes: the lists in one change, then the red ranges in one change. A refusal
    /// of either engine comes back as its own words and nothing is written. Nil = saved.
    @MainActor static func apply(_ writes: Writes, blocking: BlockingController?, braise: BraiseController?) -> String? {
        if !writes.lists.isEmpty {
            guard let blocking else { return "Le blocage est désactivé. Activez-le dans Réglages › Modules." }
            for list in writes.lists {
                if case .refused(let reason) = blocking.editCheck(list) { return "« \(list.name) » : \(reason)" }
            }
        }
        if writes.touchesRed {
            guard let braise else { return "L’écran rouge n’est pas disponible sur ce Mac pour l’instant." }
            do { try braise.checkRanges(writes.red, deleting: writes.deleting) } catch { return words(error) }
        }
        if !writes.lists.isEmpty, let refusal = blocking?.saveAll(writes.lists) { return refusal }
        if writes.touchesRed, let braise {
            do { try braise.saveRanges(writes.red, deleting: writes.deleting) } catch {
                return writes.lists.isEmpty ? words(error) : "Les listes sont enregistrées, pas l’écran rouge. \(words(error))"
            }
        }
        return nil
    }

    private static func words(_ error: Error) -> String {
        (error as? RedScreenRefusal)?.message ?? error.localizedDescription
    }
}
#endif
