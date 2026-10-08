#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI

struct FocusStatus: Codable, Equatable {
    struct Session: Codable, Equatable {
        var id: UUID; var intent: String; var phase: FocusPhase.Kind; var cycle: Int; var phaseEndsAt: Date?
    }
    var schema = 1
    var state: String = "off"
    var source: String?
    var since: Date
    var session: Session?
}
struct FocusPanel: Equatable {
    enum Kind: String { case phase, sessionReview, morning, evening, limit, commitment }
    var kind: Kind
    var text: String
    var sessionID: UUID?
    var expiresAt: Date?
    var commitmentIDs: [UUID] = []
}

/// Main-actor writer; UI and socket actions share exactly these validated actions.
@MainActor final class ConcentrationController: ObservableObject {
    @Published private(set) var currentSession: FocusSession? {
        didSet {
            if oldValue?.id != currentSession?.id {
                NotificationCenter.default.post(name: .goalongFocusSessionDidChange, object: self)
            }
        }
    }
    @Published private(set) var phase: FocusPhase?
    @Published private(set) var status: FocusStatus
    @Published private(set) var sessions: [FocusSession] = []
    @Published private(set) var plan: FocusPlan
    @Published private(set) var review: FocusReview?
    @Published private(set) var settings = FocusSettings()
    @Published private(set) var itemMeasures: [FocusItemMeasure] = []
    @Published private(set) var estimateRatio: Double?
    @Published private(set) var sessionFacts = FocusFacts()
    @Published private(set) var limitMarks: [FocusLimitMark] = []
    @Published private(set) var requestedEditor: FocusPanel.Kind?
    @Published private(set) var panel: FocusPanel?
    @Published private(set) var commitments: [FocusCommitment] = []
    @Published private(set) var commitmentCards: [FocusCommitmentCard] = []
    @Published private(set) var commitmentSeries = FocusJokerSettings(day: 0, week: 0)
    @Published private(set) var commitmentJokersLeft = FocusJokerSettings()
    @Published var error: String?
    var onStatusChange: ((FocusStatus) -> Void)?
    var onPanelChange: ((FocusPanel?) -> Void)?
    var onLimitMark: ((FocusLimitMark) -> Void)?
    var onPhaseSound: (() -> Void)?
    var onOpenRequested: ((FocusPanel.Kind) -> Void)?
    var measurementRefresh: (() -> Void)?

    private let store: FocusStore
    private let clock: () -> Date
    private let calendar: Calendar
    private let blocking: () -> BlockingController?
    private let audio: FocusSessionAudio
    private let runsTimers: Bool
    private var timer: Timer?
    private var detection = FocusDetection()
    private var observation: FocusObservation?
    private var latestInput: Date?
    private var phaseBlockID: UUID?
    private var phaseBlockKey: String?
    private var storageFailed = false
    private var promptState: FocusPromptState
    private var phaseIdentity: String?
    private var currentDay: String
    private var measuredDays: [String: GoalongLocalAnalytics.Day] = [:]
    private var definitionAvailable = false
    private var lastMeasureRequest = Date.distantPast
    private var lastCommitmentCardRefresh = Date.distantPast
    var hasTimer: Bool { timer != nil }
    var hasLockedSessionBlock: Bool { hasLockedPhaseBlock }
    var hasLockedBlock: Bool {
        hasLockedPhaseBlock || blocking()?.activeBlocks.contains { block in
            if case .commitment = block.origin { return block.end > clock() }; return false
        } == true
    }
    private var hasLockedPhaseBlock: Bool {
        guard let id = phaseBlockID else { return false }
        return blocking()?.activeBlocks.contains { $0.id == id && $0.lock == .locked && $0.end > clock() } == true
    }
    var blockLists: [BlockList] { blocking()?.lists ?? [] }
    var sessionStartLimitWarnings: [FocusLimitMark] {
        let week = FocusCalendar.weekKey(clock(), calendar: calendar)
        return limitMarks.filter { $0.kind == "weekly" ? $0.period == week : $0.period == currentDay }
    }
    var menuBarText: String {
        guard let phase else { return status.state }
        let seconds = phase.endsAt.map { max(0, Int($0.timeIntervalSince(clock()))) }
        return (phase.isWork ? "Concentration" : "Pause") + (seconds.map { " \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "")
    }

    init(store: FocusStore, clock: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         blocking: @escaping () -> BlockingController? = { nil }, audio: FocusSessionAudio = NoOpFocusSessionAudio(), runsTimers: Bool = false) throws {
        self.store = store; self.clock = clock; self.calendar = calendar; self.blocking = blocking; self.audio = audio; self.runsTimers = runsTimers
        let day = BlockingController.dayKey(clock(), calendar: calendar); currentDay = day
        status = FocusStatus(since: clock()); plan = FocusPlan(day: day); promptState = FocusPromptState(day: day)
        try store.recover(); settings = try store.settings(); limitMarks = try store.marks(); commitments = try store.commitments()
        // Preserve once-per-week warnings made by the pre-ISO implementation.
        for i in limitMarks.indices where limitMarks[i].kind == "weekly" && FocusValidation.day(limitMarks[i].period) {
            limitMarks[i].period = FocusCalendar.weekKey(limitMarks[i].at, calendar: calendar)
        }
        promptState = try store.prompts() ?? promptState
        if promptState.day != day { promptState = FocusPromptState(day: day) }
        try loadDay(day)
        // A free open session may have started on any retained day, not only yesterday.
        var running: [FocusSession] = []
        for date in try store.sessionDays() {
            for var value in try store.sessions(date) where value.endedAt == nil {
                let restored = FocusPhases.phase(value, at: clock())
                if restored.kind == .ended {
                    value.events.append(.init(kind: .stop, at: restored.startedAt, reason: .appClosed))
                    value.distractions?.finish(lists: blockLists, ignored: ignoredDistractionIDs)
                    try persist(value)
                } else { running.append(value) }
            }
        }
        guard running.count <= 1 else { throw FocusFailure.storageFailed }
        currentSession = running.first
        // Reconcile a previously saved Blocking phase by session-owned deterministic ID.
        if let value = currentSession {
            let p = FocusPhases.phase(value, at: clock())
            let id = blockID(value.id, phase: p)
            if blocking()?.activeBlocks.contains(where: { $0.id == id }) == true { phaseBlockID = id; phaseBlockKey = phaseKey(p) }
        }
        try reconcileCommitmentBlocks(); refresh()
    }
    private func loadDay(_ day: String) throws {
        sessions = try store.sessions(day); plan = try store.plan(day) ?? FocusPlan(day: day); review = try store.review(day)
    }
    private func admit() throws { if storageFailed { throw FocusFailure.storageFailed } }
    private func saving(_ action: () throws -> Void) throws {
        try admit()
        do { try action() } catch {
            if (error as? FocusFailure) != .invalidArgument { storageFailed = true }
            self.error = String(describing: error); throw error
        }
    }
    private func persist(_ value: FocusSession) throws {
        let day = BlockingController.dayKey(value.startedAt, calendar: calendar)
        var values = try store.sessions(day)
        if let i = values.firstIndex(where: { $0.id == value.id }) { values[i] = value } else { values.append(value) }
        try saving { try store.saveSessions(values, day: day) }
        if day == currentDay { sessions = values }
    }
    func startSession(intent: String, mode: FocusMode, planItemId: UUID? = nil, blockListIds: [UUID] = [],
                      blockDuringBreaks: Bool = false, lock: Bool = false, ambiance: Bool = false) throws {
        try admit(); refresh()
        guard currentSession == nil else { throw FocusFailure.invalidArgument }
        if let id = planItemId, !plan.items.contains(where: { $0.id == id && $0.status == .open }) { throw FocusFailure.notFound }
        if !blockListIds.isEmpty {
            guard let b = blocking() else { throw FocusFailure.moduleDisabled }
            guard Set(blockListIds).isSubset(of: Set(b.lists.map(\.id))) else { throw FocusFailure.notFound }
        }
        let now = clock()
        var value = FocusSession(intent: intent, planItemId: planItemId, mode: mode, blockListIds: blockListIds,
            blockDuringBreaks: blockDuringBreaks, lock: lock, ambiance: ambiance, startedAt: now, events: [.init(kind: .start, at: now)])
        value.plannedEndAt = FocusPhases.plannedEnd(value)
        guard value.valid else { throw FocusFailure.invalidArgument }
        try persist(value)
        currentSession = value
        do { try syncBlock(value, phase: FocusPhases.phase(value, at: now)) }
        catch {
            value.events.append(.init(kind: .stop, at: now, reason: .member)); try persist(value); currentSession = nil; throw error
        }
        error = nil; refresh()
    }
    func skipPhase() throws {
        try admit(); refresh()
        guard var value = currentSession else { throw FocusFailure.notFound }
        if hasLockedPhaseBlock { throw FocusFailure.locked }
        guard value.mode.kind == .pomodoro, value.events.count < 1023 else { throw FocusFailure.invalidArgument }
        value.events.append(.init(kind: .skip, at: clock())); value.plannedEndAt = FocusPhases.plannedEnd(value)
        try persist(value); currentSession = value; refresh()
    }
    func stopSession(outcome: FocusSession.Outcome? = nil, note: String? = nil) throws {
        try admit(); refresh()
        guard var value = currentSession else { throw FocusFailure.notFound }
        if hasLockedPhaseBlock { throw FocusFailure.locked }
        guard note.map({ FocusValidation.text($0, maximum: 140) }) ?? true else { throw FocusFailure.invalidArgument }
        value.outcome = outcome; value.note = note
        try finish(value, at: clock(), reason: outcome == .done ? .completed : .member)
    }
    private func finish(_ session: FocusSession, at end: Date, reason: FocusSession.Event.Reason) throws {
        var value = session; value.events.append(.init(kind: .stop, at: end, reason: reason))
        value.distractions?.finish(lists: blockLists, ignored: ignoredDistractionIDs)
        try persist(value)
        try blocking()?.creditEarnedTime(for: value)
        if let id = phaseBlockID { blocking()?.stop(id) }
        currentSession = nil; phase = nil; phaseBlockID = nil; phaseBlockKey = nil; phaseIdentity = nil; audio.stop()
        sessionFacts = facts(value)
        showPanel(.init(kind: .sessionReview, text: "C’est fait ?", sessionID: value.id))
        refresh()
    }
    func recordOutcome(sessionID: UUID, outcome: FocusSession.Outcome?, note: String? = nil) throws {
        try admit()
        guard note.map({ FocusValidation.text($0, maximum: 140) }) ?? true else { throw FocusFailure.invalidArgument }
        for day in try store.sessionDays().reversed() {
            if var value = try store.sessions(day).first(where: { $0.id == sessionID && $0.endedAt != nil }) {
                value.outcome = outcome; value.note = note; try persist(value); dismissPanel(); return
            }
        }
        throw FocusFailure.notFound
    }
    func sessions(on day: String) throws -> [FocusSession] { try store.sessions(day) }
    /// Pomodoro breaks remain part of the active session; detected focus is not a session.
    var jevSessionID: UUID? {
        guard !storageFailed, let value = currentSession, value.endedAt == nil,
              FocusPhases.phase(value, at: clock()).kind != .ended || hasLockedPhaseBlock else { return nil }
        return value.id
    }
    private var ignoredDistractionIDs: Set<String> { Set((settings.ignoredDistractionTargets ?? []).map(\.id)) }
    /// Called only after JevMonitor revalidates consent, privacy generation and request freshness.
    func recordJevDistraction(window: JevWindow, verdict: JevVerdict, sessionID: UUID) throws {
        try admit()
        guard jevSessionID == sessionID, var value = currentSession else { return }
        var record = value.distractions ?? FocusDistractionRecord()
        guard record.record(window, verdict: verdict, sessionStart: value.startedAt, now: clock()) else { return }
        value.distractions = record; try persist(value); currentSession = value
    }
    private func endedSession(_ id: UUID) throws -> FocusSession {
        try admit()
        for day in try store.sessionDays().reversed() {
            if let value = try store.sessions(day).first(where: { $0.id == id && $0.endedAt != nil }) { return value }
        }
        throw FocusFailure.notFound
    }
    func distractionSuggestions(sessionID: UUID) throws -> [FocusDistractionSuggestion] {
        try endedSession(sessionID).distractions?.suggestions(lists: blockLists, ignored: ignoredDistractionIDs) ?? []
    }
    func acceptDistractionSuggestion(sessionID: UUID, targetID: String, listID: UUID) throws {
        var value = try endedSession(sessionID)
        guard let i = value.distractions?.counts.firstIndex(where: { $0.id == targetID }),
              let suggestion = value.distractions?.suggestions(lists: blockLists, ignored: ignoredDistractionIDs).first(where: { $0.id == targetID }) else { throw FocusFailure.notFound }
        guard let b = blocking() else { throw FocusFailure.moduleDisabled }
        try b.addDistraction(suggestion.target, to: listID)
        value.distractions?.counts[i].state = .accepted
        value.distractions?.counts[i].acceptedListID = listID
        try persist(value)
    }
    func ignoreDistractionSuggestion(sessionID: UUID, targetID: String, always: Bool = false) throws {
        var value = try endedSession(sessionID)
        guard let i = value.distractions?.counts.firstIndex(where: { $0.id == targetID }),
              let suggestion = value.distractions?.suggestions(lists: blockLists, ignored: ignoredDistractionIDs).first(where: { $0.id == targetID }) else { throw FocusFailure.notFound }
        if always {
            var next = settings
            next.ignoredDistractionTargets = (next.ignoredDistractionTargets ?? []) + [suggestion.target]
            try updateSettings(next)
        }
        value.distractions?.counts[i].state = .ignored
        try persist(value)
    }
    func plan(on day: String) throws -> FocusPlan { try store.plan(day) ?? FocusPlan(day: day) }
    func review(on day: String) throws -> FocusReview { try store.review(day) ?? FocusReview(day: day) }
    func setPlan(_ value: FocusPlan) throws {
        guard value.valid, !value.items.isEmpty else { throw FocusFailure.invalidArgument }
        try saving { try store.savePlans([value]) }; if value.day == currentDay { plan = value }; updateMeasures()
    }
    @discardableResult func addPlanItem(title: String, day: String, project: String? = nil, estimateMinutes: Int? = nil) throws -> FocusPlanItem {
        var value = try plan(on: day)
        let item = FocusPlanItem(title: title, project: project, estimateMinutes: estimateMinutes)
        value.items.append(item); try setPlan(value); return item
    }
    func setItemStatus(_ id: UUID, day: String, status: FocusPlanItem.Status) throws {
        guard status == .done || status == .dropped else { throw FocusFailure.invalidArgument }
        var value = try plan(on: day); guard let i = value.items.firstIndex(where: { $0.id == id }) else { throw FocusFailure.notFound }
        value.items[i].status = status; value.items[i].toDay = nil; try setPlan(value)
    }
    func movePlanItem(_ id: UUID, day: String, to target: String) throws {
        guard FocusValidation.day(target), target != day else { throw FocusFailure.invalidArgument }
        var source = try plan(on: day), destination = try plan(on: target)
        guard let i = source.items.firstIndex(where: { $0.id == id }) else { throw FocusFailure.notFound }
        var item = source.items[i]; item.status = .open; item.toDay = nil
        if !destination.items.contains(where: { $0.id == id }) { destination.items.append(item) }
        source.items[i].status = .moved; source.items[i].toDay = target
        try saving { try store.savePlans([source, destination]) }
        if day == currentDay { plan = source } else if target == currentDay { plan = destination }; updateMeasures()
    }
    func setReview(_ value: FocusReview) throws {
        guard value.valid else { throw FocusFailure.invalidArgument }
        var source = try plan(on: value.day), changed: [String: FocusPlan] = [:]
        for item in value.items {
            guard let i = source.items.firstIndex(where: { $0.id == item.id }) else { throw FocusFailure.notFound }
            if let target = item.toDay {
                guard target != value.day else { throw FocusFailure.invalidArgument }
                var destination = try changed[target] ?? plan(on: target)
                var moved = source.items[i]; moved.status = .open; moved.toDay = nil
                if !destination.items.contains(where: { $0.id == moved.id }) { destination.items.append(moved) }
                changed[target] = destination; source.items[i].status = .moved; source.items[i].toDay = target
            } else {
                source.items[i].status = item.outcome == .done ? .done : .open; source.items[i].toDay = nil
            }
        }
        if let title = value.tomorrowFirst, !title.isEmpty {
            let tomorrow = try dayAfter(value.day)
            var next = try changed[tomorrow] ?? plan(on: tomorrow)
            // Updating the same review replaces its previous carry-forward item, without inventing duplicates.
            let carryID = carryItemID(day: value.day)
            next.items.removeAll { $0.id == carryID }
            next.items.insert(FocusPlanItem(id: carryID, title: title), at: 0); changed[tomorrow] = next
        }
        changed[source.day] = source
        try saving { try store.savePlans(Array(changed.values), review: value) }
        if let today = changed[currentDay] { plan = today }; if value.day == currentDay { review = value }; updateMeasures()
    }
    private func carryItemID(day: String) -> UUID {
        let digits = day.replacingOccurrences(of: "-", with: "")
        return UUID(uuidString: "F0C05000-0000-4000-8000-0000" + digits)!
    }
    private func dayAfter(_ day: String) throws -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        guard let date = f.date(from: day), let next = calendar.date(byAdding: .day, value: 1, to: date) else { throw FocusFailure.invalidArgument }
        return BlockingController.dayKey(next, calendar: calendar)
    }
    func updateSettings(_ value: FocusSettings) throws {
        guard value.valid else { throw FocusFailure.invalidArgument }; try saving { try store.saveSettings(value) }; settings = value
        if !settings.detectionEnabled { detection.reset() }; refreshCommitmentCards(); refresh()
    }
    func noteInput(at date: Date, count: Int) { if count > 0 { latestInput = date } }
    func observe(_ value: FocusObservation) {
        var value = value
        value.input = latestInput.map { value.at.timeIntervalSince($0) >= 0 && value.at.timeIntervalSince($0) < 60 } ?? false
        observation = value
        if settings.detectionEnabled && currentSession == nil { _ = detection.observe(value) } else { detection.reset() }
        refresh()
        if value.observing, value.available, value.idleSeconds < 120 { checkPrompts(activity: true) }
        if value.observing, value.at.timeIntervalSince(lastMeasureRequest) >= 60 { lastMeasureRequest = value.at; measurementRefresh?() }
    }
    func applyMeasurements(_ days: [GoalongLocalAnalytics.Day], hasDefinition: Bool) {
        measuredDays = Dictionary(uniqueKeysWithValues: days.map { (BlockingController.dayKey($0.date, calendar: calendar), $0) })
        definitionAvailable = hasDefinition; updateMeasures(); checkLimits(); settleCommitments()
        if let currentSession { sessionFacts = facts(currentSession) }
    }
    private func updateMeasures() {
        refreshCommitmentCards()
        let values = sessions + (currentSession.map { value in sessions.contains(where: { $0.id == value.id }) ? [] : [value] } ?? [])
        itemMeasures = plan.items.map { FocusMeasurement.item($0, sessions: values, day: measuredDays[plan.day], now: clock()) }
        var past: [FocusItemMeasure] = []
        // Last 20 valued items in chronological order; unavailable measurements are excluded.
        for day in measuredDays.keys.sorted() {
            if let p = try? store.plan(day), let values = try? store.sessions(day) {
                past += p.items.map { FocusMeasurement.item($0, sessions: values, day: measuredDays[day], now: clock()) }
            }
        }
        estimateRatio = FocusMeasurement.estimateRatio(past)
    }
    func measures(for value: FocusPlan) throws -> [FocusItemMeasure] {
        let values = try store.sessions(value.day)
        return value.items.map { FocusMeasurement.item($0, sessions: values, day: measuredDays[value.day], now: clock()) }
    }
    func facts(for session: FocusSession) -> FocusFacts { facts(session) }
    private func facts(_ session: FocusSession) -> FocusFacts {
        var total = FocusFacts()
        for day in measuredDays.values.sorted(by: { $0.date < $1.date }) {
            let f = FocusMeasurement.facts(day: day, from: session.startedAt, to: session.endedAt ?? clock())
            guard day.end > session.startedAt && day.date < (session.endedAt ?? clock()) else { continue }
            total.available = total.available || f.available; total.activeSeconds += f.activeSeconds; total.workSeconds += f.workSeconds
            total.otherSeconds += f.otherSeconds; total.unclassifiedSeconds += f.unclassifiedSeconds; total.appSwitches += f.appSwitches
            total.longestStretchSeconds = max(total.longestStretchSeconds, f.longestStretchSeconds)
        }
        return total
    }
    private func checkLimits() {
        let today = measuredDays[currentDay]
        let weekStart = FocusCalendar.weekInterval(clock(), calendar: calendar).start
        let week = measuredDays.values.filter { $0.date >= weekStart && $0.date <= clock() }
        let marks = FocusLimitRules.crossings(limits: settings.limits,
            dailySeconds: definitionAvailable ? today?.seconds(.work) ?? 0 : today?.activeSeconds ?? 0,
            weeklySeconds: week.reduce(0) { $0 + (definitionAvailable ? $1.seconds(.work) : $1.activeSeconds) },
            hasDefinition: definitionAvailable, at: clock(), calendar: calendar, marks: limitMarks)
        guard !marks.isEmpty else { return }
        do { try saving { try store.saveMarks(limitMarks + marks) }; limitMarks += marks }
        catch { return }
        for mark in marks { onLimitMark?(mark) }
        let mark = marks.last!
        showPanel(.init(kind: .limit, text: mark.kind == "endOfDay" ? "Fin de journée — votre limite." : "\(mark.kind == "weekly" ? settings.limits.weeklyHours ?? 0 : settings.limits.dailyHours ?? 0) h \(mark.usesActiveTime ? "d’activité (sans définition du travail)" : "de travail") — votre limite."))
    }
    func refresh() {
        if phaseBlockID != nil || commitments.contains(where: { $0.result?.stake.state == .applied }) { blocking()?.refresh(enforceLast: false) }
        let now = clock(), day = BlockingController.dayKey(now, calendar: calendar)
        if day != currentDay {
            do { try loadDay(day); currentDay = day; promptState = FocusPromptState(day: day); measurementRefresh?() } catch { self.error = String(describing: error); storageFailed = true }
        }
        if let value = currentSession {
            var p = FocusPhases.phase(value, at: now)
            // Blocking's clock protection may move a locked deadline. Focus cannot cut it short.
            if hasLockedPhaseBlock, let id = phaseBlockID, let block = blocking()?.activeBlocks.first(where: { $0.id == id }), p.kind == .ended || phaseKey(p) != phaseBlockKey {
                p = phase ?? p; p.endsAt = block.end
            }
            if p.kind == .ended {
                do { try finish(value, at: p.startedAt, reason: .completed) } catch { self.error = String(describing: error) }
            } else {
                let key = phaseKey(p)
                do { try syncBlock(value, phase: p) } catch { self.error = String(describing: error) }
                if phaseIdentity != key {
                    if phaseIdentity != nil { showPanel(.init(kind: .phase, text: p.isWork ? "On reprend : \(value.intent)" : "Pause — \(Int((p.endsAt?.timeIntervalSince(p.startedAt) ?? 0) / 60)) min", expiresAt: now.addingTimeInterval(6))); if settings.phaseSound { onPhaseSound?() } }
                    if value.ambiance { if p.isWork { audio.startWork() } else { audio.startBreak() } }
                    phaseIdentity = key
                }
                if phase != p { phase = p }
            }
        }
        if panel?.expiresAt.map({ $0 <= now }) == true { dismissPanel() }
        if abs(now.timeIntervalSince(lastCommitmentCardRefresh)) >= 60 || commitmentCards.contains(where: { ($0.editMode == "free" && $0.editUntil <= now) || ($0.exitUntil.map { $0 <= now } == true && ($0.canUseJoker || $0.canDeclare)) }) { refreshCommitmentCards() }
        checkPrompts(activity: false); checkLimits(); publishStatus(); scheduleTimer()
    }
    private func phaseKey(_ phase: FocusPhase) -> String { "\(phase.kind.rawValue)|\(phase.cycle)|\(phase.startedAt.timeIntervalSince1970)" }
    private func blockID(_ id: UUID, phase: FocusPhase) -> UUID {
        // Stable ownership across relaunch; user-authored Blocking sessions are never adopted.
        var bytes = Array(withUnsafeBytes(of: id.uuid) { $0 })
        let n = UInt64(max(0, phase.startedAt.timeIntervalSince1970))
        for i in 0..<8 { bytes[i] ^= UInt8(truncatingIfNeeded: n >> (i * 8)) }
        bytes[8] ^= phase.isWork ? 0xA5 : 0x5A
        return bytes.withUnsafeBufferPointer { UUID(uuid: $0.baseAddress!.withMemoryRebound(to: uuid_t.self, capacity: 1) { $0.pointee }) }
    }
    private func syncBlock(_ value: FocusSession, phase p: FocusPhase) throws {
        guard !value.blockListIds.isEmpty else { return }
        guard let b = blocking() else { throw FocusFailure.moduleDisabled }
        let key = phaseKey(p)
        if phaseBlockKey == key, let id = phaseBlockID, b.activeBlocks.contains(where: { $0.id == id && $0.end > clock().addingTimeInterval(p.endsAt == nil ? 20 : 0) }) { return }
        if let id = phaseBlockID {
            if hasLockedPhaseBlock { throw FocusFailure.locked }; b.stop(id)
        }
        phaseBlockID = nil; phaseBlockKey = nil
        guard p.isWork || value.blockDuringBreaks else { return }
        // Open free sessions renew one short free lease on the existing Blocking clock.
        let end = p.endsAt ?? clock().addingTimeInterval(60)
        let id = blockID(value.id, phase: p)
        try b.startFocusBlock(id: id, listIDs: value.blockListIds, until: end, lock: value.lock && p.isWork ? .locked : .free)
        phaseBlockID = id; phaseBlockKey = key
    }
    private func publishStatus() {
        var next = FocusStatus(since: status.since)
        if let value = currentSession, let p = phase {
            next.state = p.isWork ? "focus" : "break"; next.source = p.isWork ? "session" : nil
            next.session = .init(id: value.id, intent: value.intent, phase: p.kind, cycle: p.cycle, phaseEndsAt: p.endsAt)
        } else if let observation, observation.observing {
            if !observation.available || observation.idleSeconds >= 120 { next.state = "away" }
            else if settings.detectionEnabled, detection.enteredAt != nil { next.state = "focus"; next.source = "detected" }
            else { next.state = "active" }
        }
        guard next != status else { return }
        next.since = clock(); status = next
        onStatusChange?(next)
        do { try store.appendStatus(FocusJSON.encode(next), day: currentDay) } catch { self.error = String(describing: error) }
    }
    private func checkPrompts(activity: Bool) {
        let minute = calendar.component(.hour, from: clock()) * 60 + calendar.component(.minute, from: clock())
        let evening = settings.limits.endMinute ?? settings.eveningMinute
        let allowedEvening = settings.limits.endMinute == nil || settings.limits.weekdays.contains(BlockingSchedule.isoWeekday(clock(), calendar: calendar))
        var request: FocusPanel.Kind?
        if settings.morningPrompt, activity, minute >= settings.morningMinute, plan.items.isEmpty, !promptState.morningShown { promptState.morningShown = true; request = .morning }
        if settings.eveningPrompt, allowedEvening, minute >= evening, review == nil, !promptState.eveningShown { promptState.eveningShown = true; request = .evening }
        if settings.morningPrompt, plan.items.isEmpty, let at = promptState.morningReminderAt, at <= clock(), !promptState.morningReminded { promptState.morningReminded = true; request = .morning }
        if settings.eveningPrompt, review == nil, let at = promptState.eveningReminderAt, at <= clock(), !promptState.eveningReminded { promptState.eveningReminded = true; request = .evening }
        if let request {
            do { try saving { try store.savePrompts(promptState) } } catch { return }
            showPanel(.init(kind: request, text: request == .morning ? "Plan du matin" : "Bilan du soir"))
        }
    }
    func promptLater() {
        guard let kind = panel?.kind, kind == .morning || kind == .evening else { return }
        if kind == .morning, !promptState.morningReminded { promptState.morningReminderAt = clock().addingTimeInterval(1800) }
        if kind == .evening, !promptState.eveningReminded { promptState.eveningReminderAt = clock().addingTimeInterval(1800) }
        do { try saving { try store.savePrompts(promptState) } } catch { return }; dismissPanel(); scheduleTimer()
    }
    func promptNow() { guard let kind = panel?.kind else { return }; requestedEditor = kind; onOpenRequested?(kind); dismissPanel() }
    func dismissEditor() { requestedEditor = nil }
    func dismissPanel() { showPanel(nil) }
    private func showPanel(_ value: FocusPanel?) { if panel != value { panel = value; onPanelChange?(value) } }
    private func scheduleTimer() {
        timer?.invalidate(); timer = nil; guard runsTimers else { return }
        let now = clock()
        var boundaries = [phase?.endsAt, panel?.expiresAt, promptState.morningReminded ? nil : promptState.morningReminderAt,
                          promptState.eveningReminded ? nil : promptState.eveningReminderAt].compactMap { $0 }
        boundaries += commitmentCards.compactMap(\.exitUntil)
        boundaries += commitmentCards.filter { $0.editMode == "free" }.map(\.editUntil)
        if currentSession?.mode.kind == .free, currentSession?.mode.minutes == nil, phaseBlockID != nil { boundaries.append(now.addingTimeInterval(45)) }
        if settings.eveningPrompt || settings.limits.endMinute != nil {
            let minute = settings.limits.endMinute ?? settings.eveningMinute
            let end = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now)!
            if end > now { boundaries.append(end) }
        }
        boundaries.append(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
        guard let next = boundaries.filter({ $0 > now }).min() else { return }
        let t = Timer(timeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func shutdown() {
        if let value = currentSession, !hasLockedPhaseBlock { try? finish(value, at: clock(), reason: .moduleDisabled) }
        timer?.invalidate(); timer = nil; audio.stop(); showPanel(nil); observation = nil; detection.reset()
    }
}

extension ConcentrationController {
    var todayCommitment: FocusCommitmentCard? { commitmentCards.first { $0.commitment.period == .init(kind: .day, key: currentDay) } }
    var weekCommitment: FocusCommitmentCard? { commitmentCards.first { $0.commitment.period == .init(kind: .week, key: FocusCalendar.weekKey(clock(), calendar: calendar)) } }
    func commitCheck(_ value: FocusCommitment, replacing old: FocusCommitment) -> FocusCommitRule.Check {
        FocusCommitRule.check(old: old, new: value, now: clock(), calendar: calendar)
    }
    @discardableResult func setCommitment(period: FocusCommitmentPeriod, kind: FocusCommitment.Kind, target: Int,
                                         task: String? = nil, stake: FocusStake? = nil) throws -> FocusCommitment {
        try admit()
        let old = commitments.first { $0.period == period }
        var value = FocusCommitment(id: old?.id ?? UUID(), period: period, kind: kind, target: target, task: task, stake: stake,
                                    createdAt: old?.createdAt ?? clock(), edits: old?.edits ?? [], result: old?.result)
        guard value.valid else { throw FocusFailure.invalidArgument }
        if let old {
            if case .locked = FocusCommitRule.check(old: old, new: value, now: clock(), calendar: calendar) { throw FocusFailure.locked }
            if old == value { return old }
            value.edits.append(.init(at: clock(), target: target, stake: stake))
            guard value.valid else { throw FocusFailure.invalidArgument }
        } else if !FocusCommitmentRules.mayCreate(period, at: clock(), calendar: calendar) { throw FocusFailure.invalidArgument }
        if let stake, old?.stake != stake {
            guard let b = blocking() else { throw FocusFailure.moduleDisabled }
            guard Set(stake.listIds).isSubset(of: Set(b.lists.map(\.id))) else { throw FocusFailure.notFound }
        }
        try saveCommitmentValues(commitments.filter { $0.period != period } + [value]); refreshCommitmentCards()
        measurementRefresh?(); return value
    }
    func deleteCommitment(period: FocusCommitmentPeriod) throws {
        try admit()
        guard let old = commitments.first(where: { $0.period == period }) else { throw FocusFailure.notFound }
        guard FocusCommitRule.check(old: old, new: nil, now: clock(), calendar: calendar) == .free else { throw FocusFailure.locked }
        try saveCommitmentValues(commitments.filter { $0.id != old.id }); refreshCommitmentCards()
    }
    func useCommitmentJoker(period: FocusCommitmentPeriod) throws { try resolveCommitment(period: period, declare: false) }
    func declareCommitmentHeld(period: FocusCommitmentPeriod) throws { try resolveCommitment(period: period, declare: true) }
    private func resolveCommitment(period: FocusCommitmentPeriod, declare: Bool) throws {
        try admit(); blocking()?.refresh(enforceLast: false)
        guard let i = commitments.firstIndex(where: { $0.period == period }), var result = commitments[i].result else { throw FocusFailure.notFound }
        let value = commitments[i]
        guard let end = exitUntil(value), clock() < end else { throw FocusFailure.locked }
        if declare {
            guard FocusCommitmentRules.mayDeclare(value) else { throw FocusFailure.invalidArgument }
            result.outcome = .held; result.declared = true
        } else {
            guard FocusCommitmentRules.jokersLeft(period: period, commitments: commitments, settings: settings.jokerSettings, calendar: calendar) > 0 else { throw FocusFailure.locked }
            result.jokerAt = clock()
        }
        // Persist release intent first. Relaunch/retry can finish a release without losing the joker.
        result.stake = .init(state: .cancelled, blockId: result.stake.blockId, at: clock())
        var next = commitments; next[i].result = result
        try saveCommitmentValues(next)
        try reconcileCommitmentBlocks(); refreshCommitmentCards()
        if panel?.kind == .commitment { updateCommitmentPanel(panel!.commitmentIDs) }
    }
    private func saveCommitmentValues(_ values: [FocusCommitment]) throws {
        var retained = values
        try saving { retained = try store.saveCommitments(values) }; commitments = retained
    }
    private func exitUntil(_ value: FocusCommitment) -> Date? {
        FocusCommitmentRules.stakeWindow(value, blockEnd: blocking()?.activeBlocks.first { $0.id == value.result?.stake.blockId }?.end, calendar: calendar)
    }
    func commitmentProgress(_ value: FocusCommitment) throws -> FocusCommitmentProgress {
        if let result = value.result {
            return .init(measured: result.measured, unmeasuredMinutes: result.unmeasuredMinutes, usesActiveTime: result.usesActiveTime ?? (value.kind == .work && !definitionAvailable))
        }
        guard let bounds = value.period.interval(calendar: calendar) else { throw FocusFailure.invalidArgument }
        if clock() <= bounds.start { return .init(usesActiveTime: value.kind == .work && !definitionAvailable) }
        var values: [FocusSession] = [], plans: [FocusPlan] = []
        if value.kind == .sessions {
            for day in try store.sessionDays() where FocusCalendar.dayInterval(day, calendar: calendar)!.start < bounds.end {
                values += try store.sessions(day).filter { ($0.endedAt ?? clock()) > bounds.start }
            }
        }
        if value.kind == .plan {
            for day in try store.planDays() {
                let start = FocusCalendar.dayInterval(day, calendar: calendar)!.start
                if start >= bounds.start && start < bounds.end, let p = try store.plan(day) { plans.append(p) }
            }
        }
        return FocusCommitmentRules.progress(value, days: Array(measuredDays.values), sessions: values, plans: plans, at: clock(), hasDefinition: definitionAvailable, calendar: calendar)
    }
    private func settleCommitments() {
        do {
            var next = commitments, ids: [UUID] = []
            for i in next.indices where next[i].result == nil {
                guard let bounds = next[i].period.interval(calendar: calendar), bounds.end <= clock() else { continue }
                let progress = try commitmentProgress(next[i])
                next[i].result = FocusCommitmentRules.settle(next[i], progress: progress, at: clock(), blockingOn: blocking() != nil,
                    listIDs: Set(blockLists.map(\.id)), calendar: calendar)
                ids.append(next[i].id)
            }
            if !ids.isEmpty { try saveCommitmentValues(next) }
            try reconcileCommitmentBlocks(); refreshCommitmentCards()
            if !ids.isEmpty { updateCommitmentPanel(ids) }
        } catch { self.error = String(describing: error) }
    }
    private func reconcileCommitmentBlocks() throws {
        let b = blocking(); b?.refresh(enforceLast: false)
        var next = commitments
        for i in next.indices {
            let value = next[i]
            guard let result = value.result else { continue }
            if result.stake.state == .cancelled, let id = result.stake.blockId { try b?.endCommitmentBlock(id: id) }
            if result.stake.state == .applied, let stake = value.stake {
                let active = b?.activeBlocks.first { $0.id == value.id && $0.origin == .commitment(value.id) }
                let end = FocusCommitmentRules.stakeEnd(stake, settledAt: result.settledAt, calendar: calendar)!
                if active != nil {
                    if result.stake.at == nil { next[i].result?.stake.at = clock() }
                } else if result.stake.at == nil || end > clock() {
                    let ids = stake.listIds.filter { b?.list($0) != nil }
                    let reason: FocusCommitmentResult.Stake.Reason?
                    if end <= clock() { reason = .late }
                    else if b == nil { reason = .blockingOff }
                    else if ids.isEmpty { reason = .noList }
                    else { reason = nil }
                    if let reason {
                        // A saved intent is not proof the second store was ever written.
                        next[i].result?.stake = .init(state: .skipped, reason: reason)
                    } else {
                        try b?.startCommitmentBlock(id: value.id, listIDs: ids, until: end)
                        next[i].result?.stake.at = clock()
                    }
                }
            }
        }
        if next != commitments { try saveCommitmentValues(next) }
    }
    private func refreshCommitmentCards() {
        do {
            let day = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(clock(), calendar: calendar))
            let week = FocusCommitmentPeriod(kind: .week, key: FocusCalendar.weekKey(clock(), calendar: calendar))
            let series = FocusJokerSettings(day: FocusCommitmentRules.series(commitments, kind: .day, calendar: calendar), week: FocusCommitmentRules.series(commitments, kind: .week, calendar: calendar))
            let left = FocusJokerSettings(day: FocusCommitmentRules.jokersLeft(period: day, commitments: commitments, settings: settings.jokerSettings, calendar: calendar),
                week: FocusCommitmentRules.jokersLeft(period: week, commitments: commitments, settings: settings.jokerSettings, calendar: calendar))
            var reserves: [String: Int] = [:]
            let cards = try commitments.sorted { $0.period.key < $1.period.key }.map { value -> FocusCommitmentCard in
                let end = exitUntil(value), open = end.map { clock() < $0 } ?? false
                let reserveKey = value.period.kind.rawValue + (FocusCommitmentRules.jokerMonth(value.period, calendar: calendar) ?? "")
                let jokers = reserves[reserveKey] ?? FocusCommitmentRules.jokersLeft(period: value.period, commitments: commitments, settings: settings.jokerSettings, calendar: calendar)
                reserves[reserveKey] = jokers
                let limit = value.period.kind == .day ? settings.limits.dailyHours : settings.limits.weeklyHours
                let editMode: String
                switch FocusCommitRule.check(old: value, new: value, now: clock(), calendar: calendar) {
                case .free: editMode = "free"
                case .harderOnly: editMode = "harderOnly"
                case .locked: editMode = "locked"
                }
                return FocusCommitmentCard(commitment: value, progress: try commitmentProgress(value), series: value.period.kind == .day ? series.day : series.week,
                    jokersLeft: jokers, canUseJoker: open && jokers > 0, canDeclare: open && FocusCommitmentRules.mayDeclare(value), exitUntil: end,
                    limitHours: (value.kind == .work || value.kind == .task) && limit.map({ value.target > $0 * 60 }) == true ? limit : nil,
                    editMode: editMode, editUntil: max(value.createdAt.addingTimeInterval(600), value.period.interval(calendar: calendar)!.start))
            }
            if commitmentSeries != series { commitmentSeries = series }; if commitmentJokersLeft != left { commitmentJokersLeft = left }
            if commitmentCards != cards { commitmentCards = cards }; lastCommitmentCardRefresh = clock()
            scheduleTimer()
        } catch { self.error = String(describing: error) }
    }
    private func updateCommitmentPanel(_ ids: [UUID]) {
        let cards = commitmentCards.filter { ids.contains($0.id) }
        let text = cards.map { "\($0.commitment.period.key) : \(Int($0.progress.measured)) / \($0.commitment.target) — \($0.commitment.result?.declared == true ? "tenu, déclaré" : $0.commitment.result?.jokerAt != nil ? "joker" : $0.commitment.result?.outcome == .held ? "tenu" : "non tenu")" }.joined(separator: "\n")
        showPanel(.init(kind: .commitment, text: text, commitmentIDs: ids))
    }
}
#endif
