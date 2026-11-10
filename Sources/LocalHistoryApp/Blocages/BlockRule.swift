#if os(macOS)
import Foundation

/// One rule of the page « Blocages »: a weekly range (when), what it runs (lists, red screen, held
/// brightness) and one safety. A rule is a view of the engines' state: nothing here is stored. The lists'
/// ranges stay in `blocking.json` and the red ranges in `Braise/ranges.json`, each under its own engine.
struct BlockRule: Identifiable, Equatable {
    /// Ranges with the same key are one rule. `lock` is the stored lock, never the applied one: a
    /// password set or removed does not move a range to another rule.
    struct Key: Hashable {
        var weekdays: Set<Int>
        var start: Int
        var end: Int
        var lock: BlockLock

        init(weekdays: Set<Int>, start: Int, end: Int, lock: BlockLock) {
            self.weekdays = weekdays; self.start = start; self.end = end; self.lock = lock
        }
        init(_ range: BlockProgramRange) {
            self.init(weekdays: range.weekdays, start: range.startMinute, end: range.endMinute, lock: range.effectiveLock)
        }
        /// The same days and hours as a range, for the formatters.
        var range: BlockProgramRange { BlockProgramRange(weekdays: weekdays, startMinute: start, endMinute: end) }
        var text: String { "\(weekdays.sorted().map(String.init).joined()).\(start)-\(end).\(lock.strength)" }
        /// Every day, 00:00 → 24:00: the editor's « Toujours » (T-050). Read from the ranges, never stored apart.
        var isAlways: Bool { weekdays == Set(1...7) && start == 0 && end == 1_440 }
        static func always(lock: BlockLock) -> Key { Key(weekdays: Set(1...7), start: 0, end: 1_440, lock: lock) }
    }

    enum State: Equatable {
        case running(until: Date)
        /// Inside its hours but not applied: stopped for today, it comes back at its next start.
        case stopped(until: Date)
        case next(Date)
        /// The red range is switched off (a rule with the red screen only).
        case paused
        case idle
    }

    /// One list the rule blocks, with the ranges of its program that carry this rule.
    struct ListPart: Identifiable, Equatable {
        enum Kind: Equatable { case block, slowDown, allowOnly }
        var id: UUID
        var rangeIDs: [UUID]
        var name: String
        var kind: Kind
        var state: State
    }

    /// The red range of the rule. `intensity` 0 with a `brightness` = the brightness alone is held.
    struct RedPart: Equatable {
        var rangeID: UUID
        var intensity: Double
        var brightness: Double?
        var enabled: Bool
        var state: State
    }

    var id: String
    var key: Key
    var lists: [ListPart]
    var red: RedPart?
    /// The lock as the engines apply it: « Mot de passe » without a usable password is « Verrouillé ».
    var lock: BlockLock
    var state: State

    var isRedOnly: Bool { lists.isEmpty }
}

/// The rules, computed from what the engines hold. Pure: the same input gives the same rules.
enum BlockRules {
    struct Input {
        var lists: [BlockList] = []
        /// Nil = the red screen is not available (module off or failed start).
        var red: RedScreenProgram?
        /// Program ranges of the lists that block now (`BlockSession.Origin.program`).
        var runningRanges: Set<UUID> = []
        /// Program ranges the member stopped until their end (`BlockingDocument.programSkips`).
        var stoppedRanges: Set<UUID> = []
        /// Red ranges in progress with their end (`BraiseController.windows`).
        var redWindows: [UUID: Date] = [:]
        var hasPassword = false
        var now: Date
        var calendar: Calendar = .current
    }

    static func rules(_ input: Input) -> [BlockRule] {
        var keys: [BlockRule.Key] = []
        var parts: [BlockRule.Key: [BlockRule.ListPart]] = [:]
        for list in input.lists {
            var own: [BlockRule.Key: [BlockProgramRange]] = [:]
            var order: [BlockRule.Key] = []
            for range in list.program.ranges {
                let key = BlockRule.Key(range)
                if own[key] == nil { order.append(key) }
                own[key, default: []].append(range)
            }
            for key in order {
                let ranges = own[key] ?? []
                if parts[key] == nil { keys.append(key) }
                parts[key, default: []].append(BlockRule.ListPart(
                    id: list.id, rangeIDs: ranges.map(\.id), name: list.name,
                    kind: list.mode == .allowOnly ? .allowOnly : list.effectiveAction == .slowDown ? .slowDown : .block,
                    state: listState(ranges, running: input.runningRanges, stopped: input.stoppedRanges, now: input.now, calendar: input.calendar)))
            }
        }
        let redRanges = input.red?.program.ranges ?? []
        var sameKey: [BlockRule.Key: Int] = [:]
        for range in redRanges { sameKey[BlockRule.Key(range), default: 0] += 1 }
        var joined: [BlockRule.Key: BlockRule.RedPart] = [:]
        var alone: [BlockRule] = []
        if let program = input.red {
            for range in redRanges {
                let key = BlockRule.Key(range)
                let part = BlockRule.RedPart(rangeID: range.id, intensity: program.intensity(of: range.id),
                                             brightness: program.brightness(of: range.id),
                                             enabled: !program.disabled.contains(range.id),
                                             state: redState(range, program: program, windows: input.redWindows,
                                                             now: input.now, calendar: input.calendar))
                // A red range joins the lists' rule only when it is on and the one red range with these hours.
                if part.enabled, sameKey[key] == 1, parts[key] != nil, RedScreenProgram.isUsable(range) {
                    joined[key] = part
                } else {
                    alone.append(BlockRule(id: "red-\(range.id.uuidString)", key: key, lists: [], red: part,
                                           lock: applied(key.lock, hasPassword: input.hasPassword), state: part.state))
                }
            }
        }
        let shared = keys.map { key -> BlockRule in
            let lists = parts[key] ?? []
            let red = joined[key]
            return BlockRule(id: key.text, key: key, lists: lists, red: red,
                             lock: applied(key.lock, hasPassword: input.hasPassword),
                             state: combined(lists.map(\.state) + (red.map { [$0.state] } ?? [])))
        }
        return (shared + alone).sorted { order($0) < order($1) }
    }

    /// The rules of the live engines. A nil controller = its module is off or did not start. Reads only.
    @MainActor static func current(blocking: BlockingController?, braise: BraiseController?, now: Date,
                                   calendar: Calendar = .current) -> [BlockRule] {
        var input = Input(now: now, calendar: calendar)
        if let blocking {
            input.lists = blocking.lists
            input.runningRanges = Set(blocking.activeBlocks.compactMap { block -> UUID? in
                if case .program(let id) = block.origin { return id }
                return nil
            })
            input.stoppedRanges = blocking.stoppedProgramRanges
        }
        if let braise {
            input.red = braise.ranges
            input.redWindows = Dictionary(braise.windows.map { ($0.rangeID, $0.end) }, uniquingKeysWith: max)
        }
        input.hasPassword = blocking?.hasPassword ?? braise?.hasBlockingPassword ?? false
        return rules(input)
    }

    /// « Mot de passe » without a usable password is applied as « Verrouillé » (both engines).
    static func applied(_ lock: BlockLock, hasPassword: Bool) -> BlockLock {
        lock == .password && !hasPassword ? .locked : lock
    }

    /// One state for the row: what runs wins, then what is stopped today, then the next start.
    static func combined(_ states: [BlockRule.State]) -> BlockRule.State {
        var running: [Date] = [], stopped: [Date] = [], next: [Date] = []
        for state in states {
            switch state {
            case .running(let end): running.append(end)
            case .stopped(let end): stopped.append(end)
            case .next(let start): next.append(start)
            case .paused, .idle: break
            }
        }
        if let end = running.max() { return .running(until: end) }
        if let end = stopped.min() { return .stopped(until: end) }
        if let start = next.min() { return .next(start) }
        if states.contains(.paused) { return .paused }
        return .idle
    }

    private static func order(_ rule: BlockRule) -> (Int, Int, Int, Int, String) {
        (rule.key.weekdays.min() ?? 8, rule.key.start, rule.key.end, rule.key.lock.strength, rule.id)
    }

    /// A range inside its hours runs, even before the engine's next tick has made its block: only a stop of the
    /// member says « Arrêtée ».
    private static func listState(_ ranges: [BlockProgramRange], running: Set<UUID>, stopped: Set<UUID>, now: Date,
                                  calendar: Calendar) -> BlockRule.State {
        let windows = BlockingSchedule.windows(of: BlockProgram(ranges: ranges), at: now, calendar: calendar)
        let live = windows.filter { $0.start <= now && now < $0.end }
        let runs = live.filter { running.contains($0.rangeID) || !stopped.contains($0.rangeID) }
        if let end = runs.map(\.end).max() { return .running(until: end) }
        if let end = live.map(\.end).min() { return .stopped(until: end) }
        if let start = windows.first(where: { $0.start > now })?.start { return .next(start) }
        return .idle
    }

    private static func redState(_ range: BlockProgramRange, program: RedScreenProgram, windows: [UUID: Date],
                                 now: Date, calendar: Calendar) -> BlockRule.State {
        if program.disabled.contains(range.id) || !RedScreenProgram.isUsable(range) { return .paused }
        if let end = windows[range.id], end > now { return .running(until: end) }
        if let skip = program.skips[range.id], skip > now { return .stopped(until: skip) }
        let next = BlockingSchedule.windows(of: BlockProgram(ranges: [range]), at: now, calendar: calendar, endPolicy: .last)
            .first { $0.start > now }
        return next.map { .next($0.start) } ?? .idle
    }
}

// MARK: - Words

extension BlockRule {
    /// « Lun–ven, 09:00 → 12:00 ».
    var title: String {
        if key.isAlways { return "Toujours" }
        return key.weekdays.isEmpty ? "Aucun jour, \(BlockingFormat.range(key.range))"
                             : "\(BlockingFormat.weekdays(key.weekdays)), \(BlockingFormat.range(key.range))"
    }

    /// « Bloque Réseaux sociaux et Jeux · écran rouge à 60 % ».
    var summary: String {
        var parts: [String] = []
        func sentence(_ verb: String, _ kind: ListPart.Kind) {
            let names = lists.filter { $0.kind == kind }.map(\.name)
            if !names.isEmpty { parts.append("\(verb) \(Self.joined(names))") }
        }
        sentence("Bloque", .block)
        sentence("Ralentit", .slowDown)
        sentence("Autorise seulement", .allowOnly)
        if let red {
            var screen: [String] = []
            if red.intensity > 0 || red.brightness == nil { screen.append("écran rouge à \(GoalongUIFormat.percent(red.intensity * 100))") }
            if let level = red.brightness { screen.append("luminosité à \(GoalongUIFormat.percent(level * 100))") }
            parts.append(screen.joined(separator: ", "))
        }
        guard let first = parts.first else { return "Rien à appliquer" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " · ")
    }

    /// The state in words, never a colour alone.
    func stateText(now: Date) -> String {
        switch state {
        case .running(let end): return "En cours jusqu’à \(BlockingFormat.endTime(end))"
        case .stopped(let end): return "Arrêtée jusqu’à \(BlockingFormat.endTime(end))"
        case .next(let start): return "Commence \(BlockingFormat.moment(start, now: now))"
        case .paused: return "En pause"
        case .idle: return "Inactive"
        }
    }

    /// The whole row for VoiceOver: when, what, the safety, the state.
    func spokenLabel(now: Date) -> String {
        "\(title). \(summary). Sécurité : \(lock.title). \(stateText(now: now))."
    }

    /// « A », « A et B », « A, B et C ».
    static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " et " + last
    }
}
#endif
