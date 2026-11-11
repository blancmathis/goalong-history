#if os(macOS)
import Foundation

/// « Pauses » of a rule or a session (T-050 D1): one budget of minutes per period, with an optional longest pause and
/// an optional number of pauses. Stored on every range of the rule (lists, red screen, « Surveillance ») and on a
/// session. Never a second mode.
struct PausePolicy: Codable, Hashable, Identifiable {
    enum Period: String, Codable, CaseIterable {
        case day, week, month
        var title: String {
            switch self { case .day: return "jour"; case .week: return "semaine"; case .month: return "mois" }
        }
        /// For « Durcir seulement »: the same budget over a longer period allows less.
        var length: Int {
            switch self { case .day: return 1; case .week: return 7; case .month: return 28 }
        }
    }

    /// What comes before each pause.
    enum Gate: Codable, Hashable {
        case none
        /// Wait this many minutes (1 min to 1 day), then the pause can be taken for `PauseEngine.claimWindow`.
        case wait(minutes: Int)
        /// Retype a random text.
        case typing
        /// The blocking password.
        case password

        var title: String {
            switch self {
            case .none: return "Rien"
            case .wait: return "Attendre"
            case .typing: return "Recopier"
            case .password: return "Mot de passe"
            }
        }
        /// Order for « Durcir seulement ». A wait is stronger when longer.
        var strength: (Int, Int) {
            switch self {
            case .none: return (0, 0)
            case .wait(let minutes): return (1, minutes)
            case .typing: return (2, 0)
            case .password: return (3, 0)
            }
        }
    }

    /// The budget's pool. Every range of one rule carries the same id. A list's former « pauses » carry the list's id:
    /// they keep counting in the list's day usage (`BlockDayUsage.breaksTaken`), as before the migration.
    var id = UUID()
    var budgetMinutes = 10
    var period: Period = .day
    /// Longest pause. Nil = up to the budget left.
    var maxPauseMinutes: Int?
    /// Most pauses per period. Nil = no count.
    var maxPauses: Int?
    var gate: Gate = .none
    /// « Pause en plus » per period, always with the password, never under « Verrouillé ». 0 = never.
    /// Nil = no cap: only a list's former pauses under « Mot de passe » (they had no cap).
    var extraPerPeriod: Int? = 0

    static let budgetRange = 1...1_440
    static let waitRange = 1...1_440
    static let extraRange = 0...10

    /// The length of one « Pause en plus ».
    var extraMinutes: Int { maxPauseMinutes ?? budgetMinutes }

    /// A list's former `BlockBreaks` (count × minutes) as a rule's pauses, with the same limits (point 10).
    static func migrated(_ breaks: BlockBreaks, listID: UUID, lock: BlockLock) -> PausePolicy {
        PausePolicy(id: listID, budgetMinutes: breaks.count * breaks.minutes, period: .day,
                    maxPauseMinutes: breaks.minutes, maxPauses: breaks.count, gate: .none,
                    extraPerPeriod: lock == .password ? nil : 0)
    }
}

/// The use of one pool in its current period. Stored in `BlockingDocument.pauses` (the former list pauses keep using
/// `BlockDayUsage`).
struct PauseUsage: Codable, Hashable {
    /// `PauseEngine.periodKey`.
    var period: String
    /// Budget used by finished pauses.
    var usedSeconds: Double = 0
    var count = 0
    var extraCount = 0
    /// The pause in progress, if any.
    var start: Date?
    var end: Date?
    var extra = false
    /// Start of the wait before a pause (« Attendre »).
    var waitStartedAt: Date?
}

/// What the gate asked before a pause has given.
enum PauseProof: Equatable {
    case none
    /// Typing or password, checked by the caller.
    case passed
}

enum PauseDecision: Equatable {
    case granted(end: Date, extra: Bool)
    /// The gate must be passed first (typing or password).
    case needsGate(PausePolicy.Gate)
    /// « Attendre »: the pause can be taken from `until`.
    case waiting(until: Date)
    /// The budget is used: a « Pause en plus » needs the password.
    case needsExtraPassword
    case refused(String)
}

/// The pause rules, pure: the same input gives the same answer. Every time comes from the caller's clock.
enum PauseEngine {
    /// After « Attendre », the pause must be taken within this time, or the wait starts again.
    static let claimWindow: TimeInterval = 5 * 60

    /// Weeks start on Monday, as the rules' days.
    static func calendar(_ base: Calendar) -> Calendar {
        var calendar = base; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func bounds(_ period: PausePolicy.Period, at now: Date, calendar base: Calendar) -> DateInterval {
        let calendar = calendar(base)
        let unit: Calendar.Component = period == .day ? .day : period == .week ? .weekOfYear : .month
        return calendar.dateInterval(of: unit, for: now) ?? DateInterval(start: now, duration: 86_400)
    }

    /// « day:2026-11-11 », « week:2026-11-09 », « month:2026-11-01 »: the period and its local first day.
    static func periodKey(_ period: PausePolicy.Period, at now: Date, calendar base: Calendar) -> String {
        let start = bounds(period, at: now, calendar: base).start
        let parts = calendar(base).dateComponents([.year, .month, .day], from: start)
        return String(format: "%@:%04d-%02d-%02d", period.rawValue, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The usage in the current period: a new period starts from zero, a finished pause is counted.
    static func current(_ usage: PauseUsage?, policy: PausePolicy, now: Date, calendar: Calendar) -> PauseUsage {
        let key = periodKey(policy.period, at: now, calendar: calendar)
        guard var usage, usage.period == key else {
            // A pause running across the reset keeps its end; it no longer counts in the new period.
            var fresh = PauseUsage(period: key)
            if let start = usage?.start, let end = usage?.end, end > now { fresh.start = start; fresh.end = end; fresh.extra = true }
            return fresh
        }
        if let start = usage.start, let end = usage.end, end <= now {
            if !usage.extra { usage.usedSeconds += max(0, end.timeIntervalSince(start)) }
            usage.start = nil; usage.end = nil; usage.extra = false
        }
        return usage
    }

    /// The end of the pause in progress, if any.
    static func runningEnd(_ usage: PauseUsage?, now: Date) -> Date? {
        guard let end = usage?.end, end > now else { return nil }
        return end
    }

    /// Budget seconds left, the running pause counted up to now.
    static func secondsLeft(_ policy: PausePolicy, usage: PauseUsage, now: Date) -> Double {
        var used = usage.usedSeconds
        if !usage.extra, let start = usage.start, let end = usage.end { used += max(0, min(now, end).timeIntervalSince(start)) }
        return max(0, Double(policy.budgetMinutes * 60) - used)
    }

    /// Pauses left in the period (the count and the budget, whichever ends first).
    static func pausesLeft(_ policy: PausePolicy, usage: PauseUsage, now: Date) -> Int {
        let seconds = secondsLeft(policy, usage: usage, now: now)
        guard seconds >= 1 else { return 0 }
        let byBudget = policy.maxPauseMinutes.map { Int((seconds / Double($0 * 60)).rounded(.up)) } ?? 1
        return policy.maxPauses.map { min(byBudget, max(0, $0 - usage.count)) } ?? byBudget
    }

    /// A pause asked now. `lock` is the strongest applied lock among the blocks the pool covers.
    /// Returns the answer and the usage to store (the wait start, or the new pause).
    static func request(_ policy: PausePolicy, usage stored: PauseUsage?, lock: BlockLock, hasPassword: Bool,
                        proof: PauseProof, now: Date, calendar: Calendar) -> (PauseDecision, PauseUsage) {
        var usage = current(stored, policy: policy, now: now, calendar: calendar)
        if runningEnd(usage, now: now) != nil { return (.refused("Une pause est déjà en cours."), usage) }
        // Never a pause without an end: at the latest the next local midnight (point 6).
        let midnight = bounds(.day, at: now, calendar: calendar).end
        let left = secondsLeft(policy, usage: usage, now: now)
        let countLeft = policy.maxPauses.map { usage.count < $0 } ?? true
        if left >= 1, countLeft {
            switch policy.gate {
            case .none: break
            case .typing, .password:
                if proof != .passed { return (.needsGate(policy.gate), usage) }
            case .wait(let minutes):
                let ready = usage.waitStartedAt.map { $0.addingTimeInterval(TimeInterval(minutes * 60)) }
                if let ready, ready <= now, now < ready.addingTimeInterval(claimWindow) { break }
                if let ready, now < ready { return (.waiting(until: ready), usage) }
                usage.waitStartedAt = now
                return (.waiting(until: now.addingTimeInterval(TimeInterval(minutes * 60))), usage)
            }
            var length = left
            if let longest = policy.maxPauseMinutes { length = min(length, TimeInterval(longest * 60)) }
            let end = min(now.addingTimeInterval(length), midnight)
            usage.count += 1; usage.start = now; usage.end = end; usage.extra = false; usage.waitStartedAt = nil
            return (.granted(end: end, extra: false), usage)
        }
        // « Pause en plus » (point 7): password always, never under « Verrouillé », within its cap.
        if lock == .locked { return (.refused("Les pauses de cette période sont prises. Verrouillé : aucune pause en plus."), usage) }
        if let cap = policy.extraPerPeriod, usage.extraCount >= cap {
            return (.refused(cap == 0 ? "Les pauses de cette période sont prises." : "Les pauses de cette période sont prises, pauses en plus comprises."), usage)
        }
        guard hasPassword else { return (.refused("Les pauses de cette période sont prises. Une pause en plus demande le mot de passe de blocage."), usage) }
        guard proof == .passed else { return (.needsExtraPassword, usage) }
        let end = min(now.addingTimeInterval(TimeInterval(policy.extraMinutes * 60)), midnight)
        usage.extraCount += 1; usage.start = now; usage.end = end; usage.extra = true
        return (.granted(end: end, extra: true), usage)
    }

    /// « Reprendre » before the end: only the time used counts.
    static func ended(_ usage: PauseUsage, now: Date) -> PauseUsage {
        var usage = usage
        guard let start = usage.start, let end = usage.end, end > now else { return usage }
        if !usage.extra { usage.usedSeconds += max(0, now.timeIntervalSince(start)) }
        usage.start = nil; usage.end = nil; usage.extra = false
        return usage
    }

    /// « Durcir seulement » (point 8): nil when `next` allows no more than `current`. A pool that changes starts from
    /// zero, so it counts as more.
    static func weakening(_ current: PausePolicy?, _ next: PausePolicy?) -> String? {
        guard let next else { return nil }
        let refusal = "les pauses peuvent seulement diminuer."
        guard let current, current.id == next.id else { return refusal }
        if next.budgetMinutes > current.budgetMinutes { return refusal }
        if next.period.length < current.period.length { return refusal }
        if (next.maxPauseMinutes ?? .max) > (current.maxPauseMinutes ?? .max) { return refusal }
        if (next.maxPauses ?? .max) > (current.maxPauses ?? .max) { return refusal }
        if next.gate.strength < current.gate.strength { return refusal }
        if (next.extraPerPeriod ?? .max) > (current.extraPerPeriod ?? .max) { return refusal }
        return nil
    }
}

extension PausePolicy {
    /// Point 8: the words of « Verrouillé » when the rule has pauses.
    static let lockedText = "Goalong ne propose aucun moyen d’arrêter avant la fin. Les pauses du budget restent permises, sans pause en plus."
    static let lockedExtraReason = "Verrouillé : aucune pause en plus."
    static let extraHelp = "Une pause en plus vient après le budget, avec le mot de passe de blocage."
    static let hardenOnlyReason = "Règle en cours et protégée : les pauses peuvent seulement diminuer."

    /// For the steppers' cap: the budget as an optional key path.
    var optionalBudget: Int? { budgetMinutes }

    /// « Une pause ≤ … »: no maximum, then the usual lengths up to the budget, and the current value.
    static func longestChoices(budget: Int, current: Int?) -> [Int?] {
        var values = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240].filter { $0 < budget }
        if let current, !values.contains(current) { values.append(current) }
        return [nil] + values.sorted().map { Optional($0) }
    }

    /// « 10 min par jour · une pause ≤ 5 min · 3 pauses au plus ».
    var summary: String {
        var parts = ["\(budgetMinutes) min par \(period.title)"]
        if let longest = maxPauseMinutes { parts.append("une pause ≤ \(longest) min") }
        if let count = maxPauses { parts.append("\(count) pause\(count > 1 ? "s" : "") au plus") }
        return parts.joined(separator: " · ")
    }
}
#endif
