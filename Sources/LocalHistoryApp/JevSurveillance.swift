#if os(macOS)
import Foundation
import LocalHistoryCore
import AppleScreenTime

extension Notification.Name {
    static let jevSurveillanceDidChange = Notification.Name("goalong.jev.surveillance.changed")
}

/// The « Surveillance » block of a rule (T-050 B1 point 3): the days, hours and stop of its rule, and its own reminder
/// settings. It joins the rule's lists and red range by `BlockRule.Key`, like a red range does.
struct JevSurveillanceRange: Codable, Equatable, Identifiable {
    var id = UUID()
    var weekdays: Set<Int>
    var startMinute: Int
    var endMinute: Int
    var lock: BlockLock
    var settings: JevInterventionSettings
    /// The rule's pauses (T-050 D1): the same pool as its lists. Absent = no pause.
    var pause: PausePolicy?

    var key: BlockRule.Key { BlockRule.Key(weekdays: weekdays, start: startMinute, end: endMinute, lock: lock) }
    var program: BlockProgramRange {
        var range = BlockProgramRange(weekdays: weekdays, startMinute: startMinute, endMinute: endMinute, lock: lock)
        range.id = id
        return range
    }
}

/// The « Surveillance » choice of one session, written when the editor starts it. A session without a mark follows
/// the default (Concentration sessions only, as the old « Pendant mes séances » did).
struct JevSessionMark: Codable, Equatable {
    /// `focus` = a Concentration session, `block` = a Blocage session, `own` = no engine session (Surveillance with the
    /// red screen only, or alone): it runs from `start` to `end`.
    enum Kind: String, Codable { case focus, block, own }
    var id: UUID
    var kind: Kind
    var on: Bool
    var start: Date?
    var end: Date?
    var lock: BlockLock
    var settings: JevInterventionSettings
}

struct JevSurveillanceDocument: Codable, Equatable {
    var schema = 1
    var ranges: [JevSurveillanceRange] = []
    /// « Surveillance » checked by default in a new session, with these settings.
    var sessionDefault = false
    var sessionSettings = JevInterventionSettings()
    var marks: [JevSessionMark] = []
}

/// The sessions that run now: the Concentration one, the Blocage ones.
struct JevRunningSessions: Equatable {
    var focus: UUID?
    var blocks: Set<UUID> = []
    /// Pause pools running now (`PausePolicy.id`, T-050 D1): a rule on a pause does not watch.
    var pausedPools: Set<UUID> = []
    /// Sessions (Blocage or focus) whose own pause runs now (T-050 D1b): their « Surveillance » mark rests too.
    var pausedSessions: Set<UUID> = []
}

/// One rule or session that carries « Surveillance » now.
struct JevSurveillanceActivity: Equatable {
    var settings: JevInterventionSettings
    var lock: BlockLock
}

/// What a change of a « Surveillance » block needs (T-050 B1 corrections, P3): strengthening is immediate, weakening a
/// running protected block goes through its stop (« Mot de passe », « Taper un texte »), « Verrouillé » refuses.
enum JevWriteCheck: Equatable {
    case allow
    case stop(BlockLock)
    case refused(String)
}

/// A change of the « Surveillance » block of a rule.
enum JevRangeWrite: Equatable {
    case save(JevSurveillanceRange)
    case delete(UUID)
}

/// Where the « Surveillance » blocks live. One document in the app's defaults. Unreadable = no surveillance (closed),
/// kept as it is until the next save.
@MainActor final class JevSurveillanceStore: ObservableObject {
    /// The migration runs at the first access, before any write can create the document (T-050 B1 correction 7).
    static let shared = launched(consent: GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring),
                                 scope: .shared, settings: JevInterventionPreferences.shared.settings)

    /// The store as the app opens it: migrated before anyone can read or write it.
    static func launched(defaults: UserDefaults = GoalongDefaults.standard, floor: ProtectedFloor? = .standard, consent: Bool,
                         scope: JevMonitoringPreferences, settings: JevInterventionSettings) -> JevSurveillanceStore {
        let store = JevSurveillanceStore(defaults: defaults, floor: floor)
        store.migrateIfNeeded(consent: consent, scope: scope, settings: settings)
        return store
    }
    static let storageKey = "goalong.jev.surveillance.v1"
    static let unreadableText = "Réglages de surveillance illisibles : aucune surveillance jusqu’au prochain enregistrement."
    static let protectedText = "La surveillance de cette règle est en cours et « Verrouillé » : elle ne peut pas être retirée ni affaiblie tant qu’elle tourne."
    static let combinedText = "Ce changement affaiblirait l’effet appliqué par une surveillance « Verrouillé » qui tourne en même temps : il ne peut pas être fait."
    @Published private(set) var document = JevSurveillanceDocument()
    @Published private(set) var error: String?
    /// P3 (T-059): the proof of a protected rule's stop, read before any weakening write.
    var stopGrant: RuleStopGrant = .shared
    private let defaults: UserDefaults
    /// T-059 lot 2: the protected ranges' copy outside the defaults. Nil = none (tests without it).
    private let floor: ProtectedFloor?
    /// Set when a launch put back protected ranges removed or weakened outside Goalong.
    private(set) var restoredNotice: String?

    init(defaults: UserDefaults = GoalongDefaults.standard, floor: ProtectedFloor? = nil) {
        self.defaults = defaults; self.floor = floor
        if defaults.object(forKey: Self.storageKey) != nil {
            if let data = defaults.data(forKey: Self.storageKey), data.count <= 512_000,
               let value = try? JSONDecoder().decode(JevSurveillanceDocument.self, from: data), value.schema == 1 {
                document = value
            } else {
                error = Self.unreadableText
            }
        }
        // A protected range removed or weakened in the defaults (or a document made unreadable) comes back from the copy.
        let copy = floor?.read([JevSurveillanceRange].self, key: ProtectedFloor.jevKey) ?? .absent
        if case .unavailable = copy { restoredNotice = ProtectedFloor.unavailableText; return }
        guard let kept = copy.value, !kept.isEmpty else { return }
        let restored = Self.restore(error == nil ? document : JevSurveillanceDocument(), floor: kept)
        guard restored.count > 0 else { return }
        save(restored.document)
        restoredNotice = ProtectedFloor.restoredText
    }

    /// `document` with every range of `floor` it lost or weakened put back (hardening kept). Pure.
    static func restore(_ document: JevSurveillanceDocument, floor: [JevSurveillanceRange]) -> (document: JevSurveillanceDocument, count: Int) {
        var next = document, count = 0
        for old in floor where old.lock != .free {
            if let index = next.ranges.firstIndex(where: { $0.id == old.id }) {
                let now = next.ranges[index]
                if weakens(old, now) || combinedLoss(old: old, new: now, in: next) != .free { next.ranges[index] = old; count += 1 }
            } else { next.ranges.append(old); count += 1 }
        }
        return (next, count)
    }

    /// `new` asks less than `old`: a weaker stop, fewer days or hours, weaker settings or a looser pause. Pure.
    static func weakens(_ old: JevSurveillanceRange, _ new: JevSurveillanceRange) -> Bool {
        let covered = BlockingController.programCoverage(BlockProgram(ranges: [old.program]))
            .isSubset(of: BlockingController.programCoverage(BlockProgram(ranges: [new.program])))
        let pauseKept = old.pause == new.pause || PauseEngine.weakening(old.pause, new.pause) == nil
        return !(new.lock.strength >= old.lock.strength && covered && isAtLeast(new.settings, old.settings) && pauseKept)
    }

    /// `new` reminds at least as much as `old` at every minute of a streak (T-059 lot 3, F3/F4). The engine shows the
    /// last stage reached (`stage(at:)`), not the strongest, so stages are not compared index by index: the effect in
    /// force is compared on each interval bounded by the old and new thresholds. At each one, where `old` shows a veil,
    /// `new` shows one at least as heavy (same effect or « voile et rouge »). Effects and the move stay on. Pure.
    static func isAtLeast(_ new: JevInterventionSettings, _ old: JevInterventionSettings) -> Bool {
        if old.effectsEnabled && !new.effectsEnabled { return false }
        if old.moveAfterSecondAppearance && !new.moveAfterSecondAppearance { return false }
        // The effect in force only changes at a threshold: checking each threshold covers every interval.
        let thresholds = Set((old.stages + new.stages).map(\.afterMinutes)).filter { $0 >= 1 }.sorted()
        for minute in thresholds {
            guard let was = old.stage(at: minute * 60) else { continue }
            guard let now = new.stage(at: minute * 60), now.intensity >= was.intensity,
                  now.effect == was.effect || now.effect == .dimAndRed else { return false }
        }
        return true
    }

    /// N1 (T-059 lot 3): the settings in force are one rule's whole, the highest `score` (`strongest`), never a blend. A
    /// rule kept at least as strong can still lose its rank, and the effect applied then falls (85 % → 45 %). So a change
    /// of one rule (`old` → `new`, nil = absent) is also judged on what is applied with each rule that can run at the same
    /// time: the other ranges whose hours meet it, and the session marks or default, which can run at any hour. The
    /// winner of a set only depends on the winner of the others and this rule, so each other rule alone covers every
    /// set. Returns the strongest stop of a rule whose applied effect would fall; `.free` = none. Pure.
    static func combinedLoss(old: JevSurveillanceRange?, new: JevSurveillanceRange?,
                             in document: JevSurveillanceDocument) -> BlockLock {
        guard let id = old?.id ?? new?.id else { return .free }
        func coverage(_ range: JevSurveillanceRange) -> Set<Int> {
            BlockingController.programCoverage(BlockProgram(ranges: [range.program]))
        }
        let position = document.ranges.firstIndex { $0.id == id } ?? document.ranges.count
        let minutes = [old, new].compactMap { $0 }.reduce(into: Set<Int>()) { $0.formUnion(coverage($1)) }
        // `first` = listed before this rule: it wins a tie (`strongest` keeps the first of equal scores).
        var others: [(settings: JevInterventionSettings, lock: BlockLock, first: Bool)] = []
        for (index, range) in document.ranges.enumerated() where range.id != id && !coverage(range).isDisjoint(with: minutes) {
            others.append((range.settings, range.lock, index < position))
        }
        if document.sessionDefault { others.append((document.sessionSettings, .free, false)) }
        for mark in document.marks where mark.on { others.append((mark.settings, mark.lock, false)) }
        var lost = BlockLock.free
        func lose(_ lock: BlockLock) { if lock.strength > lost.strength { lost = lock } }
        if let old, let new, !isAtLeast(new.settings, old.settings) { lose(old.lock) }
        for other in others {
            func wins(_ range: JevSurveillanceRange?) -> Bool {
                guard let range else { return false }
                let mine = score(range.settings), theirs = score(other.settings)
                return mine > theirs || (mine == theirs && !other.first)
            }
            let before = wins(old) ? old!.settings : other.settings
            let after = wins(new) ? new!.settings : other.settings
            if !isAtLeast(after, before) { lose(wins(old) ? old!.lock : other.lock) }
        }
        return lost
    }

    /// The document exists: the migration ran on this Mac, or a block was saved.
    var exists: Bool { defaults.object(forKey: Self.storageKey) != nil }

    /// The copy first, then the defaults (F5). A copy not written: the defaults go ahead only when the copy in place
    /// would take nothing back at the next launch; else false, nothing written, and `restoredNotice` says why.
    @discardableResult func save(_ next: JevSurveillanceDocument) -> Bool {
        guard let data = try? JSONEncoder().encode(next) else { return false }
        let protected = next.ranges.filter { $0.lock != .free }
        if let floor, !floor.save(protected.isEmpty ? nil : protected, key: ProtectedFloor.jevKey) {
            switch floor.known([JevSurveillanceRange].self, key: ProtectedFloor.jevKey) {
            case .absent: break
            case .value(let kept):
                guard Self.restore(next, floor: kept).count == 0 else { restoredNotice = ProtectedFloor.unsavedText; return false }
            case .unavailable: restoredNotice = ProtectedFloor.staleText
            }
        }
        defaults.set(data, forKey: Self.storageKey)
        document = next; error = nil
        NotificationCenter.default.post(name: .jevSurveillanceDidChange, object: self)
        return true
    }

    // MARK: Migration (point 4)

    enum Migration: Equatable { case alreadyDone, nothing, alwaysRule, sessionDefault }

    /// Once: the old scope becomes a rule or the session default, with the same settings. Without consent, nothing is
    /// created. The old keys stay. What ran before runs after: « Toujours » runs all the time, and a session of
    /// Concentration without a mark follows the default.
    @discardableResult
    func migrateIfNeeded(consent: Bool, scope: JevMonitoringPreferences, settings: JevInterventionSettings) -> Migration {
        guard !exists else { return .alreadyDone }
        var next = JevSurveillanceDocument()
        next.sessionSettings = settings
        var result = Migration.nothing
        // An unreadable scope kept Jev closed: nothing is created, and nothing starts.
        if consent, scope.error == nil {
            switch scope.scope {
            case .always:
                next.ranges = [JevSurveillanceRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: .free,
                                                    settings: settings)]
                result = .alwaysRule
            case .sessionsOnly:
                next.sessionDefault = true
                result = .sessionDefault
            }
        }
        save(next)
        return result
    }

    // MARK: Activity (point 3)

    /// The rules and sessions that carry « Surveillance » now. Pure.
    static func active(_ document: JevSurveillanceDocument, sessions: JevRunningSessions, now: Date,
                       calendar: Calendar = .current) -> [JevSurveillanceActivity] {
        var result: [JevSurveillanceActivity] = []
        for range in document.ranges where isRunning(range, now: now, calendar: calendar) {
            if let pool = range.pause?.id, sessions.pausedPools.contains(pool) { continue }
            result.append(JevSurveillanceActivity(settings: range.settings, lock: range.lock))
        }
        if let focus = sessions.focus, !sessions.pausedSessions.contains(focus) {
            if let mark = document.marks.last(where: { $0.kind == .focus && $0.id == focus }) {
                if mark.on { result.append(JevSurveillanceActivity(settings: mark.settings, lock: mark.lock)) }
            } else if document.sessionDefault {
                result.append(JevSurveillanceActivity(settings: document.sessionSettings, lock: .free))
            }
        }
        for mark in document.marks where mark.on {
            switch mark.kind {
            case .focus: continue
            case .block: if sessions.blocks.contains(mark.id), !sessions.pausedSessions.contains(mark.id) { result.append(.init(settings: mark.settings, lock: mark.lock)) }
            case .own: if ownRuns(mark, now: now) { result.append(.init(settings: mark.settings, lock: mark.lock)) }
            }
        }
        return result
    }

    func active(sessions: JevRunningSessions, now: Date, calendar: Calendar = .current) -> [JevSurveillanceActivity] {
        error == nil ? Self.active(document, sessions: sessions, now: now, calendar: calendar) : []
    }

    /// Inside its days and hours now.
    static func isRunning(_ range: JevSurveillanceRange, now: Date, calendar: Calendar = .current) -> Bool {
        window(range, now: now, calendar: calendar) != nil
    }

    static func window(_ range: JevSurveillanceRange, now: Date, calendar: Calendar = .current) -> BlockingSchedule.Window? {
        BlockingSchedule.windows(of: BlockProgram(ranges: [range.program]), at: now, calendar: calendar)
            .first { $0.start <= now && now < $0.end }
    }

    static func ownRuns(_ mark: JevSessionMark, now: Date) -> Bool {
        guard mark.kind == .own, let end = mark.end else { return false }
        return (mark.start ?? .distantPast) <= now && now < end
    }

    /// The strongest stop of the « Surveillance » carried by these sessions; Libre without one (a focus session without a
    /// mark follows the default, which is Libre). Pure.
    static func sessionLock(_ document: JevSurveillanceDocument, kind: JevSessionMark.Kind, ids: Set<UUID>) -> BlockLock {
        var locks: [BlockLock] = []
        for id in ids {
            let mark = kind == .focus ? document.marks.last { $0.kind == .focus && $0.id == id }
                                      : document.marks.last { $0.kind == kind && $0.id == id }
            if let mark, mark.on { locks.append(mark.lock) }
        }
        return locks.max { $0.strength < $1.strength } ?? .free
    }

    func sessionLock(kind: JevSessionMark.Kind, ids: Set<UUID>) -> BlockLock {
        error == nil ? Self.sessionLock(document, kind: kind, ids: ids) : .free
    }

    /// Several carry it: the strongest settings win, whole (effects on, then the stronger veils, then the earlier first
    /// stage). Never a mix that no rule asked for.
    static func strongest(_ list: [JevInterventionSettings]) -> JevInterventionSettings? {
        // Equal scores: the first of the list wins (the document order), so the choice stays the same from one tick to the next.
        list.max { score($0) < score($1) }
    }

    static func score(_ value: JevInterventionSettings) -> (Int, Int, Int) {
        let stages = value.stages.filter(\.enabled)
        return (value.effectsEnabled ? 1 : 0, stages.map(\.intensity).reduce(0, +), -(stages.first?.afterMinutes ?? 61))
    }

    // MARK: Writes

    /// A protected range, running or not (P3, T-059): removing it, or changing its days, hours, stop or settings for
    /// weaker ones, goes through its stop (`stopGrant`); « Verrouillé » refuses. Stronger settings or stop are immediate.
    func check(_ write: JevRangeWrite, now: Date, calendar: Calendar = .current) -> JevWriteCheck {
        if error != nil { return .allow } // the next save replaces an unreadable document
        let id: UUID
        switch write {
        case .save(let range): id = range.id
        case .delete(let value): id = value
        }
        let old = document.ranges.first { $0.id == id }
        var new: JevSurveillanceRange?
        if case .save(let range) = write { new = range }
        // The rule's own stop when it is removed or weakened; else the stop of a rule whose applied effect falls (N1).
        var lock = BlockLock.free, own = false
        if let old, old.lock != .free, new.map({ Self.weakens(old, $0) }) ?? true { lock = old.lock; own = true }
        let shared = Self.combinedLoss(old: old, new: new, in: document)
        if shared.strength > lock.strength { lock = shared; own = false }
        guard lock != .free else { return .allow }
        if lock == .locked {
            guard own, let old else { return .refused(Self.combinedText) }
            return .refused(Self.isRunning(old, now: now, calendar: calendar) ? Self.protectedText : RuleStopGrant.lockedText)
        }
        return stopGrant.covers(lock) ? .allow : .stop(lock)
    }

    /// Nil = the write may be saved without asking. Otherwise the reason it needs the stop or is refused.
    func refusal(_ write: JevRangeWrite, now: Date, calendar: Calendar = .current) -> String? {
        switch check(write, now: now, calendar: calendar) {
        case .allow: return nil
        case .refused(let reason): return reason
        case .stop(let lock): return "La surveillance de cette règle est en cours et protégée : l’arrêt « \(lock.title) » est demandé."
        }
    }

    /// Writes a change `check` allows (the stop passed through `stopGrant`). False = refused, nothing written.
    @discardableResult func apply(_ write: JevRangeWrite, now: Date = Date()) -> Bool {
        guard check(write, now: now) == .allow else { return false }
        var next = error == nil ? document : JevSurveillanceDocument()
        switch write {
        case .save(let range):
            if let index = next.ranges.firstIndex(where: { $0.id == range.id }) { next.ranges[index] = range } else { next.ranges.append(range) }
        case .delete(let id):
            next.ranges.removeAll { $0.id == id }
        }
        return save(next)
    }

    /// The editor started a session: its choice is kept for this session. A Concentration session's choice becomes the
    /// default of the next ones (correction 8: a Blocage session never changes it).
    /// `alive` = the sessions that still exist (the Concentration one, every block, a later one included). Only finished
    /// marks are removed: a mark of a running session is never dropped, however many sessions start (correction 4).
    func mark(_ mark: JevSessionMark, now: Date, alive: JevRunningSessions) {
        var next = error == nil ? document : JevSurveillanceDocument()
        next.marks = Self.pruned(next.marks.filter { $0.id != mark.id }, now: now, alive: alive)
        next.marks.append(mark)
        if mark.kind == .focus {
            next.sessionDefault = mark.on
            if mark.on { next.sessionSettings = mark.settings }
        }
        save(next)
    }

    /// The marks of sessions that still run. Pure.
    static func pruned(_ marks: [JevSessionMark], now: Date, alive: JevRunningSessions) -> [JevSessionMark] {
        marks.filter { mark in
            switch mark.kind {
            case .focus: return mark.id == alive.focus
            case .block: return alive.blocks.contains(mark.id)
            case .own: return (mark.end ?? .distantPast) > now
            }
        }
    }

    /// A session with « Surveillance » and no engine session, running now.
    func runningOwn(now: Date) -> JevSessionMark? {
        guard error == nil else { return nil }
        return document.marks.last { $0.on && Self.ownRuns($0, now: now) }
    }

    func endOwn(_ id: UUID, now: Date) {
        var next = document
        guard let index = next.marks.firstIndex(where: { $0.id == id && $0.kind == .own }) else { return }
        next.marks[index].end = now
        save(next)
    }
}
#endif
