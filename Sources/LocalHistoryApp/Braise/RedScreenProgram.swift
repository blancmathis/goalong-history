#if os(macOS)
import BraiseCore
import Foundation

/// The red screen's ranges (T-048 B2): the blocking program model (`BlockProgram`, ISO weekdays, range
/// locks) plus one intensity per range. Stored in `Braise/ranges.json`; the old Braise rules stay
/// untouched in `settings.json`, so going back to an older Goalong loses nothing.
struct RedScreenProgram: Codable, Equatable {
    static let currentVersion = 1
    /// A protected window in progress, kept until its end even if the clock, the zone or the file moves.
    struct Hold: Codable, Equatable {
        var end: Date
        var lock: BlockLock
        var intensity: Double
        /// `BlockingClock.continuous` seconds at which the hold ends, valid in `boot` only: sleep counts, clock changes
        /// do not, and a relaunch in the same boot finds it in ranges.json. Nil in files of B2.
        var deadline: Double?
        /// `BlockingClock.bootID` of `deadline`.
        var boot: String?
        /// Hardware brightness the range holds (T-048 D2), nil = none. Absent in older files.
        var brightness: Double? = nil
    }
    /// The slider moved above the ranges in progress: their red is this strong until `until` (end of those ranges).
    struct Raise: Codable, Equatable {
        var intensity: Double
        var until: Date
    }

    var version = RedScreenProgram.currentVersion
    var program = BlockProgram()
    /// Red intensity of each range, 0…1. Absent = 100 %.
    var intensities: [UUID: Double] = [:]
    /// Ranges kept but switched off (an old Braise rule that was off stays off).
    var disabled: Set<UUID> = []
    /// « Suivre mes horaires », gone since T-050: always true after `BraiseController`'s one-time migration. Kept so an
    /// older Goalong reads the file the same way.
    var follows = false
    /// T-050 lot A2: set once the ranges of 00:00 → 24:00 saved before this version were paused (they were unusable
    /// before, shown « En pause », and now would start). Absent in older files.
    var fullDayPaused: Bool?
    /// Window stopped for today (« Arrêter »): range → end of that window.
    var skips: [UUID: Date] = [:]
    var holds: [UUID: Hold] = [:]
    var raise: Raise?
    /// Upper limit of the hardware brightness of each range (« Limite de luminosité », T-048 D2), 0.05…1. Absent = the
    /// range leaves it. Older files (one exact level) decode as that limit.
    var brightness: [UUID: Double]?
    /// The manual brightness lock, nil = off (T-048 D2).
    var brightnessLock: BrightnessLockState?

    static let maximumRanges = 32

    func intensity(of id: UUID) -> Double { intensities[id] ?? 1 }
    func brightness(of id: UUID) -> Double? { brightness?[id] }
    /// The ranges that can turn red on.
    var enabledProgram: BlockProgram {
        BlockProgram(ranges: program.ranges.filter { !disabled.contains($0.id) }, lockedUntil: program.lockedUntil)
    }

    mutating func sanitize() {
        var ids = Set<UUID>()
        program.ranges = Array(program.ranges.filter { ids.insert($0.id).inserted }.prefix(Self.maximumRanges))
        let known = Set(program.ranges.map(\.id))
        intensities = intensities.filter { known.contains($0.key) }.mapValues { $0.isFinite ? min(1, max(0, $0)) : 1 }
        disabled = disabled.intersection(known)
        holds = holds.mapValues { var hold = $0; hold.intensity = hold.intensity.isFinite ? min(1, max(0, hold.intensity)) : 1; return hold }
        if let level = raise?.intensity { raise?.intensity = level.isFinite ? min(1, max(0, level)) : 1 }
        let levels = (brightness ?? [:]).filter { known.contains($0.key) }.mapValues(BrightnessLockRules.clamp)
        brightness = levels.isEmpty ? nil : levels
        holds = holds.mapValues { var hold = $0; hold.brightness = hold.brightness.map(BrightnessLockRules.clamp); return hold }
        if let level = brightnessLock?.level { brightnessLock?.level = BrightnessLockRules.clamp(level) }
    }

    /// One Braise rule → one range with the same meaning. Braise counts weekdays from Sunday = 1 and
    /// a range belongs to the day it starts on (« lundi 22:00–08:00 finit mardi matin »): the same
    /// rule as `BlockProgramRange`, with ISO weekdays (Monday = 1). A Braise end at 00:00 is the
    /// program's 24:00 (same instant). A rule that was off, or that Braise never applied (no day,
    /// same start and end), stays as a range switched off.
    static func migrated(from preferences: Preferences) -> RedScreenProgram {
        var value = RedScreenProgram()
        value.follows = preferences.mode == .auto
        for rule in preferences.rules.prefix(maximumRanges) {
            let days = Set(rule.weekdays.compactMap { isoWeekday(fromFoundation: $0) })
            let end = rule.endMinute == 0 ? 1_440 : rule.endMinute
            value.program.ranges.append(BlockProgramRange(id: rule.id, weekdays: days, startMinute: rule.startMinute,
                                                          endMinute: end, lock: nil))
            value.intensities[rule.id] = preferences.intensity
            if !rule.enabled || !rule.isValid { value.disabled.insert(rule.id) }
        }
        value.sanitize()
        return value
    }

    static func isoWeekday(fromFoundation day: Int) -> Int? {
        guard (1...7).contains(day) else { return nil }
        return day == 1 ? 7 : day - 1
    }

    /// A range that can be switched on: a day, and a start different from its end (00:00–24:00 is a whole day, « Toujours »).
    static func isUsable(_ range: BlockProgramRange) -> Bool {
        !range.weekdays.isEmpty && range.weekdays.isSubset(of: Set(1...7)) && (0..<1_440).contains(range.startMinute)
            && (1...1_440).contains(range.endMinute) && range.startMinute != range.endMinute
    }
}

/// One window of a range, in progress or to come.
struct RedScreenWindow: Equatable {
    var rangeID: UUID
    var start: Date
    var end: Date
    var lock: BlockLock
    var intensity: Double
    /// Hardware brightness the window holds (T-048 D2), nil = none.
    var brightness: Double? = nil
    var isProtected: Bool { lock != .free }
}

/// The rules of the ranges, pure: what is red now, and what a change may do while a window is protected.
/// Same rules as a blocking program (docs/BLOCKING.md « Range lock », « stricter only »).
enum RedScreenRules {
    /// T-059 lot 2: a brightness raised by no more than `BrightnessLockRules.tolerance` keeps its old value, on a
    /// protected range and on the brightness lock. The tolerance absorbs the hardware's rounding; it must not add up
    /// over many small saves into a brighter screen. Pure.
    static func snappingBrightness(_ next: RedScreenProgram, from current: RedScreenProgram) -> RedScreenProgram {
        var value = next
        let tolerance = BrightnessLockRules.tolerance
        for range in current.program.ranges where range.effectiveLock != .free {
            guard let old = current.brightness(of: range.id), let new = value.brightness(of: range.id),
                  new > old, new <= old + tolerance else { continue }
            value.brightness?[range.id] = old
        }
        if let old = current.brightnessLock?.level, let new = value.brightnessLock?.level, new > old, new <= old + tolerance {
            value.brightnessLock?.level = old
        }
        return value
    }

    /// A « Mot de passe » range without a usable blocking password cannot be stopped: it counts as « Verrouillé ».
    static func effectiveLock(_ lock: BlockLock, hasPassword: Bool) -> BlockLock {
        lock == .password && !hasPassword ? .locked : lock
    }

    /// The windows in progress at `now`: scheduled ones and held ones, minus the ones stopped for today.
    /// `stillHeld` lets the controller keep a hold whose wall-clock end a forward clock jump passed.
    static func activeWindows(_ value: RedScreenProgram, at now: Date, calendar: Calendar, hasPassword: Bool,
                              stillHeld: (UUID, RedScreenProgram.Hold) -> Bool = { _, _ in false }) -> [RedScreenWindow] {
        var result: [UUID: RedScreenWindow] = [:]
        let ranges = Dictionary(value.program.ranges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // « Suivre mes horaires » rules the ranges and their holds. A one-time window (`BraiseController.holdNow`:
        // a hold of no range) runs without it, and never turns the ranges on.
        let scheduled = value.follows
            ? BlockingSchedule.windows(of: value.enabledProgram, at: now, calendar: calendar, endPolicy: .last) : []
        for window in scheduled where window.start <= now && now < window.end {
            if let skip = value.skips[window.rangeID], skip > now { continue }
            let lock = effectiveLock(ranges[window.rangeID]?.effectiveLock ?? .free, hasPassword: hasPassword)
            let candidate = RedScreenWindow(rangeID: window.rangeID, start: window.start, end: window.end, lock: lock,
                                            intensity: value.intensity(of: window.rangeID), brightness: value.brightness(of: window.rangeID))
            if let existing = result[window.rangeID], existing.end >= candidate.end { continue }
            result[window.rangeID] = candidate
        }
        for (id, hold) in value.holds where hold.end > now || stillHeld(id, hold) {
            guard value.follows || ranges[id] == nil else { continue }
            if let skip = value.skips[id], skip > now { continue }
            if let existing = result[id], existing.end >= hold.end, existing.lock.strength >= hold.lock.strength { continue }
            let lock = effectiveLock(hold.lock, hasPassword: hasPassword)
            result[id] = RedScreenWindow(rangeID: id, start: result[id]?.start ?? now, end: max(hold.end, result[id]?.end ?? hold.end),
                                         lock: lock, intensity: max(hold.intensity, result[id]?.intensity ?? 0),
                                         brightness: [hold.brightness, result[id]?.brightness].compactMap { $0 }.min())
        }
        return result.values.sorted { ($0.end, $0.rangeID.uuidString) < ($1.end, $1.rangeID.uuidString) }
    }

    /// The next instant where the ranges may change what is on screen.
    static func nextBoundary(_ value: RedScreenProgram, after now: Date, calendar: Calendar) -> Date? {
        // A one-time window ends at its hold's end, with or without « Suivre mes horaires ».
        let known = Set(value.program.ranges.map(\.id))
        var dates = value.holds.filter { !known.contains($0.key) }.map(\.value.end)
        if value.follows {
            dates += BlockingSchedule.windows(of: value.enabledProgram, at: now, calendar: calendar, endPolicy: .last)
                .flatMap { [$0.start, $0.end] }
            dates += value.skips.values; dates += value.holds.values.map(\.end)
        }
        return dates.filter { $0 > now }.min()
    }

    /// The strongest lock among the protected windows in progress, with the latest end.
    static func strongest(_ windows: [RedScreenWindow]) -> RedScreenWindow? {
        windows.filter(\.isProtected).max { ($0.lock.strength, $0.end) < ($1.lock.strength, $1.end) }
    }

    /// While a protected window runs, the ranges can only get stricter: the blocking program rule
    /// (no minute lost, no lock lowered), the same rule for each intensity level, and « Suivre mes
    /// horaires » stays on. Nil = allowed.
    static func weakening(from current: RedScreenProgram, to next: RedScreenProgram, hasPassword: Bool) -> String? {
        if current.follows, !next.follows { return "« Suivre mes horaires » reste coché jusqu’à la fin de la plage." }
        let old = current.enabledProgram, new = next.enabledProgram
        if let reason = BlockingController.programWeakening(old, new, effectiveLock: { effectiveLock($0, hasPassword: hasPassword) }) {
            return reason
        }
        let levels = Set(old.ranges.map { current.intensity(of: $0.id) }).sorted()
        for level in levels where level > 0 {
            let before = BlockingController.programCoverage(BlockProgram(ranges: old.ranges.filter { current.intensity(of: $0.id) >= level }))
            let after = BlockingController.programCoverage(BlockProgram(ranges: new.ranges.filter { next.intensity(of: $0.id) >= level }))
            if !before.isSubset(of: after) { return "l’intensité d’une plage peut seulement monter." }
        }
        // Brightness (T-048 D2): darker is stricter. Every minute held at or below a level keeps that cover.
        for level in Set(old.ranges.compactMap { current.brightness(of: $0.id) }).sorted() {
            let before = BlockingController.programCoverage(BlockProgram(ranges: old.ranges.filter { (current.brightness(of: $0.id) ?? 2) <= level }))
            let after = BlockingController.programCoverage(BlockProgram(ranges: new.ranges.filter {
                (next.brightness(of: $0.id) ?? 2) <= level + BrightnessLockRules.tolerance }))
            if !before.isSubset(of: after) { return "la limite de luminosité d’une plage peut seulement baisser." }
        }
        return nil
    }

    /// P3 (T-059): the stop a change needs, running or not. Each protected level (« Difficile » and stronger) keeps its
    /// ranges, minutes, red and brightness unless that level's stop is passed. Nil = the change only adds or hardens.
    static func weakeningStop(from current: RedScreenProgram, to next: RedScreenProgram, hasPassword: Bool) -> BlockLock? {
        for lock in [BlockLock.locked, .password, .typing] {
            func atLeast(_ value: RedScreenProgram) -> RedScreenProgram {
                var copy = value
                copy.program.ranges = value.program.ranges.filter { effectiveLock($0.effectiveLock, hasPassword: hasPassword).strength >= lock.strength }
                copy.follows = current.follows
                return copy
            }
            let old = atLeast(current)
            guard !old.enabledProgram.ranges.isEmpty else { continue }
            if weakening(from: old, to: atLeast(next), hasPassword: hasPassword) != nil { return lock }
        }
        return nil
    }
}
#endif
