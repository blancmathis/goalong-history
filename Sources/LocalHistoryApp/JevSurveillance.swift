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
    static func launched(defaults: UserDefaults = GoalongDefaults.standard, consent: Bool, scope: JevMonitoringPreferences,
                         settings: JevInterventionSettings) -> JevSurveillanceStore {
        let store = JevSurveillanceStore(defaults: defaults)
        store.migrateIfNeeded(consent: consent, scope: scope, settings: settings)
        return store
    }
    static let storageKey = "goalong.jev.surveillance.v1"
    static let unreadableText = "Réglages de surveillance illisibles : aucune surveillance jusqu’au prochain enregistrement."
    static let protectedText = "La surveillance de cette règle est en cours et « Verrouillé » : elle ne peut pas être retirée ni affaiblie tant qu’elle tourne."
    @Published private(set) var document = JevSurveillanceDocument()
    @Published private(set) var error: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = GoalongDefaults.standard) {
        self.defaults = defaults
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 512_000,
              let value = try? JSONDecoder().decode(JevSurveillanceDocument.self, from: data), value.schema == 1 else {
            error = Self.unreadableText
            return
        }
        document = value
    }

    /// The document exists: the migration ran on this Mac, or a block was saved.
    var exists: Bool { defaults.object(forKey: Self.storageKey) != nil }

    @discardableResult func save(_ next: JevSurveillanceDocument) -> Bool {
        guard let data = try? JSONEncoder().encode(next) else { return false }
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
            result.append(JevSurveillanceActivity(settings: range.settings, lock: range.lock))
        }
        if let focus = sessions.focus {
            if let mark = document.marks.last(where: { $0.kind == .focus && $0.id == focus }) {
                if mark.on { result.append(JevSurveillanceActivity(settings: mark.settings, lock: mark.lock)) }
            } else if document.sessionDefault {
                result.append(JevSurveillanceActivity(settings: document.sessionSettings, lock: .free))
            }
        }
        for mark in document.marks where mark.on {
            switch mark.kind {
            case .focus: continue
            case .block: if sessions.blocks.contains(mark.id) { result.append(.init(settings: mark.settings, lock: mark.lock)) }
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

    /// A running protected block: removing it, or changing its days, hours, stop or settings for weaker ones, goes through
    /// its stop; « Verrouillé » refuses. Stronger settings or stop are immediate.
    func check(_ write: JevRangeWrite, now: Date, calendar: Calendar = .current) -> JevWriteCheck {
        if error != nil { return .allow } // the next save replaces an unreadable document
        let id: UUID
        switch write {
        case .save(let range): id = range.id
        case .delete(let value): id = value
        }
        guard let old = document.ranges.first(where: { $0.id == id }), old.lock != .free,
              Self.isRunning(old, now: now, calendar: calendar) else { return .allow }
        switch write {
        case .delete: break
        case .save(let range):
            if range.lock.strength >= old.lock.strength, range.weekdays == old.weekdays, range.startMinute == old.startMinute,
               range.endMinute == old.endMinute, Self.score(range.settings) >= Self.score(old.settings) { return .allow }
        }
        return old.lock == .locked ? .refused(Self.protectedText) : .stop(old.lock)
    }

    /// Nil = the write may be saved without asking. Otherwise the reason it needs the stop or is refused.
    func refusal(_ write: JevRangeWrite, now: Date, calendar: Calendar = .current) -> String? {
        switch check(write, now: now, calendar: calendar) {
        case .allow: return nil
        case .refused(let reason): return reason
        case .stop(let lock): return "La surveillance de cette règle est en cours et protégée : l’arrêt « \(lock.title) » est demandé."
        }
    }

    func apply(_ write: JevRangeWrite) {
        var next = error == nil ? document : JevSurveillanceDocument()
        switch write {
        case .save(let range):
            if let index = next.ranges.firstIndex(where: { $0.id == range.id }) { next.ranges[index] = range } else { next.ranges.append(range) }
        case .delete(let id):
            next.ranges.removeAll { $0.id == id }
        }
        save(next)
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
