#if os(macOS)
import Foundation

/// What the timer capsule reads from the controller. Plain values: no disk, AX or history access.
struct BlockingTimerInput: Equatable {
    struct Start: Equatable { var listID: UUID; var date: Date }
    var lists: [BlockList] = []
    var activeBlocks: [BlockingActiveBlock] = []
    var usage: BlockDayUsage
    /// Slow-down allowances by `BlockingFrictionPresentation.key`.
    var allowances: [String: Date] = [:]
    /// Starts of scheduled sessions and program windows, per list.
    var upcomingStarts: [Start] = []
    /// Last foreground sample the controller measured quota on.
    var target: BlockingObservation?
}

/// One countdown of the Blocage that ends in a veil or a slow-down screen.
struct BlockingVisibleTimer: Equatable {
    enum Kind: Int, Equatable { case quota, breakTime, slowDownAllowance, upcomingStart }
    enum Urgency: Int, Comparable {
        case neutral, warning, critical
        init(seconds: Int) { self = seconds <= 60 ? .critical : seconds <= 300 ? .warning : .neutral }
        static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    var kind: Kind
    var listID: UUID
    var listName: String
    var remaining: TimeInterval
    /// False only for a quota that does not count right now (idle, private window, locked session).
    var counting = true

    /// Rounded up: the capsule reads 0:00 exactly when the time is used.
    var seconds: Int { Int(max(0, remaining).rounded(.up)) }
    var urgency: Urgency { Urgency(seconds: seconds) }
    var clock: String { Self.clock(seconds) }
    /// Long list names are shortened so the capsule never grows toward the centre of the screen.
    var prefix: String {
        let name = listName.count > 28 ? listName.prefix(27) + "…" : listName
        return kind == .breakTime ? "Pause · \(name) · " : "\(name) · "
    }
    var text: String { prefix + clock }
    var accessibilityLabel: String {
        let left = Self.spoken(seconds)
        switch kind {
        case .quota: return "Blocage, \(listName) : \(left) de quota restantes" + (counting ? "" : ", décompte en pause")
        case .breakTime: return "Pause du blocage \(listName) : \(left) restantes"
        case .slowDownAllowance: return "Ralentissement \(listName) : \(left) accordées restantes"
        case .upcomingStart: return "Blocage \(listName) dans \(left)"
        }
    }

    static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds), hours = value / 3_600, minutes = value % 3_600 / 60, rest = value % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
    private static func spoken(_ seconds: Int) -> String {
        let hours = seconds / 3_600, minutes = seconds % 3_600 / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) heure" + (hours > 1 ? "s" : "")) }
        if minutes > 0 { parts.append("\(minutes) minute" + (minutes > 1 ? "s" : "")) }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) seconde" + (rest > 1 ? "s" : "")) }
        return parts.joined(separator: " ")
    }
}

/// Pure choice of the countdown to show: the most urgent one, or nothing.
enum BlockingTimerSelection {
    /// `BlockingController.observe` never credits more than 15 s between two samples.
    static let quotaExtrapolationLimit: TimeInterval = 15
    /// Observation starts 60 s before a block: the foreground target is only known from then.
    static let upcomingHorizon: TimeInterval = 60
    /// Same idle limit as `BlockingController.observe`.
    static let idleLimit: Double = 120

    static func select(_ input: BlockingTimerInput, at now: Date) -> BlockingVisibleTimer? {
        let usage = input.usage
        func active(_ id: UUID) -> Bool { input.activeBlocks.contains { $0.listIDs.contains(id) && $0.start <= now && $0.end > now } }
        func onBreak(_ id: UUID, at date: Date) -> Bool { usage.breakEnds[id].map { $0 > date } == true }
        func quotaLeft(_ list: BlockList) -> Double? {
            BlockingRules.effectiveQuotaSeconds(list, usage: usage).map { $0 - (usage.quotaSecondsUsed[list.id] ?? 0) }
        }
        /// Same order as `BlockingController.enforce`: a used quota veils for both actions,
        /// a block list without quota always veils.
        func veils(_ list: BlockList) -> Bool {
            quotaLeft(list).map { $0 <= 0 } ?? (list.effectiveAction == .block)
        }
        var candidates: [BlockingVisibleTimer] = []

        for list in input.lists where active(list.id) {
            if let end = usage.breakEnds[list.id], end > now {
                candidates.append(.init(kind: .breakTime, listID: list.id, listName: list.name, remaining: end.timeIntervalSince(now)))
            }
        }
        for (key, end) in input.allowances where end > now {
            guard let id = UUID(uuidString: String(key.prefix { $0 != "|" })),
                  let list = input.lists.first(where: { $0.id == id }), active(id), !onBreak(id, at: now) else { continue }
            candidates.append(.init(kind: .slowDownAllowance, listID: id, listName: list.name, remaining: end.timeIntervalSince(now)))
        }

        if let target = input.target, target.isForeground, !BlockingRules.exempt(target) {
            // A hard veil already covers the target: its quota or next start is no longer a warning.
            let veiled = input.lists.contains { list in
                active(list.id) && !onBreak(list.id, at: now) && veils(list) && BlockingRules.wouldBlock(target, list: list)
            }
            if !veiled {
                // Mirrors the lists `BlockingController.observe` charges for this target.
                let counting = target.sessionAvailable && target.idleSeconds <= idleLimit && !target.privateWindow
                let elapsed = counting ? min(quotaExtrapolationLimit, max(0, now.timeIntervalSince(target.at))) : 0
                for list in input.lists where list.quotaMinutesPerDay != nil && active(list.id) && !onBreak(list.id, at: now) {
                    guard let left = quotaLeft(list), left > 0, BlockingRules.wouldBlock(target, list: list) else { continue }
                    candidates.append(.init(kind: .quota, listID: list.id, listName: list.name,
                                            remaining: max(0, left - elapsed), counting: counting))
                }
                for start in input.upcomingStarts where start.date > now && start.date.timeIntervalSince(now) <= upcomingHorizon {
                    guard !active(start.listID), let list = input.lists.first(where: { $0.id == start.listID }),
                          !onBreak(list.id, at: start.date), BlockingRules.wouldBlock(target, list: list) else { continue }
                    // A block list with quota left lets the target through at the start; a slow-down
                    // list interrupts it unless an allowance outlasts the start.
                    let interrupts = veils(list) || (list.effectiveAction == .slowDown
                        && input.allowances[BlockingFrictionPresentation.key(target, listID: list.id)].map { $0 > start.date } != true)
                    guard interrupts else { continue }
                    candidates.append(.init(kind: .upcomingStart, listID: list.id, listName: list.name,
                                            remaining: start.date.timeIntervalSince(now)))
                }
            }
        }
        return candidates.min { ($0.remaining, $0.kind.rawValue) < ($1.remaining, $1.kind.rawValue) }
    }
}
#endif
