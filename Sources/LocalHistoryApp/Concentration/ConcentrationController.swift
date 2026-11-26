#if os(macOS)
import AppKit
import Combine
import CryptoKit
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
    /// Watchers re-read the versioned plan when these small local signals change.
    var planDay: String?
    var planRevision: Int?
    var waitingProcesses: Int?
}
struct FocusPanel: Equatable {
    enum Kind: String { case phase, sessionReview, morning, evening, limit, commitment, agenda }
    var kind: Kind
    var text: String
    var sessionID: UUID?
    var expiresAt: Date?
    var commitmentIDs: [UUID] = []
    var slotID: UUID?
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
    /// The session the « C’est fait ? » panel asks about; cleared when another panel or none replaces it.
    @Published private(set) var reviewedSession: FocusSession?
    /// The session stopped from the menu bar popover: the popover asks its « C’est fait ? » itself, in place of
    /// its content, and no floating panel opens for it. Set by the popover before its stop; any other end keeps the panel.
    var inlineReviewSessionID: UUID?
    /// False for the « C’est fait ? » of the session the popover asks about itself.
    func presentsFloating(_ value: FocusPanel) -> Bool {
        !(value.kind == .sessionReview && value.sessionID != nil && value.sessionID == inlineReviewSessionID)
    }
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
    /// Guidance yields to an existing intervention; it never changes that intervention's rules.
    var guidanceMayPresent: () -> Bool = { true }

    private let store: FocusStore
    private let clock: () -> Date
    private let continuous: () -> Double
    private let boot: () -> String
    /// Proof of real time from launch on: without a stored commitment anchor, a clock set back later in this
    /// boot still cannot open a period already over (T-044 C3, #109). Stored, so a relaunch in the same
    /// boot keeps the proof of an earlier launch (C4-03).
    private var launchClock: BlockingClockState
    /// Latest wall clock set back within `bootCorrectionWindow` of boot (T-044 C5-05). Proof recorded
    /// before it no longer counts: it came from a clock that was ahead.
    private var clockCorrection: BlockingClockState?
    /// A clock ahead at boot is set right by the network within minutes. In this window a set-back opens
    /// nothing a reboot would not (L-05), so it is believed. Later, a set-back stays caught (#109, #119).
    static let bootCorrectionWindow: Double = 600
    private let calendar: Calendar
    private let blocking: () -> BlockingController?
    private let audio: FocusSessionAudio
    private let runsTimers: Bool
    private var timer: Timer?
    private var systemObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var detection = FocusDetection()
    private var observation: FocusObservation?
    private var latestInput: Date?
    private var phaseBlockID: UUID?
    private var phaseBlockKey: String?
    /// The Blocking session this focus session owns now (« + 15 min » leaves it to the focus timer).
    var ownedPhaseBlockID: UUID? { phaseBlockID }
    private var storageFailed = false
    /// A stop that could not be saved. `retryStorage` writes it before it clears the latch.
    private var pendingStop: (session: FocusSession, end: Date, reason: FocusSession.Event.Reason)?
    private var lastStorageRetry = Date.distantPast
    private var promptState: FocusPromptState
    private var phaseIdentity: String?
    private var currentDay: String
    private var measuredDays: [String: GoalongLocalAnalytics.Day] = [:]
    private var definitionAvailable = false
    private var lastMeasureRequest = Date.distantPast
    private var lastAgendaAutoAdjustment = Date.distantPast
    private var lastPublishedJevPlanAction: String?
    private var lastCommitmentCardRefresh = Date.distantPast
    /// Decoded session files for commitment progress. This controller is their only writer: `persist` keeps it current.
    private var sessionCache: [String: [FocusSession]] = [:]
    var hasTimer: Bool { timer != nil }
    var hasLockedSessionBlock: Bool { hasLockedPhaseBlock }
    /// T-050 B1 correction 2: the stop of the « Surveillance » a session carries (Libre without one, or with Jev off).
    var surveillanceLock: @MainActor (UUID) -> BlockLock = { _ in .free }
    /// The current session carries a protected « Surveillance »: stopping it goes through that stop first.
    var surveillanceProtected: Bool { currentSession.map { surveillanceLock($0.id) != .free } ?? false }
    var hasLockedBlock: Bool {
        guard !hasLockedPhaseBlock else { return true }
        guard let b = blocking() else { return false }
        return b.activeBlocks.contains { block in
            if case .commitment = block.origin { return block.end > b.now }; return false
        }
    }
    /// End of the locked block that refuses the stop of this session (nil when the stop is possible). Text only: the engine still decides.
    var lockedPhaseBlockEnd: Date? {
        guard let id = phaseBlockID, let b = blocking() else { return nil }
        return b.activeBlocks.first { $0.id == id && $0.lock == .locked && $0.end > b.now }?.end
    }
    private var hasLockedPhaseBlock: Bool {
        guard let id = phaseBlockID, let b = blocking() else { return false }
        return b.activeBlocks.contains { $0.id == id && $0.lock == .locked && $0.end > b.now }
    }
    var blockLists: [BlockList] { blocking()?.lists ?? [] }
    var sessionStartLimitWarnings: [FocusLimitMark] {
        let week = FocusCalendar.weekKey(clock(), calendar: calendar)
        return limitMarks.filter { $0.kind == "weekly" ? $0.period == week : $0.period == currentDay }
    }
    var menuBarText: String {
        guard let phase else { return status.state }
        let seconds = phase.endsAt.map { max(0, Int($0.timeIntervalSince(clock()))) }
        return (phase.isWork ? "Concentration" : "Repos") + (seconds.map { " \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "")
    }

    init(store: FocusStore, clock: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent, // wall: the raw clock; stake decisions read `stakeNow()`
         blocking: @escaping () -> BlockingController? = { nil }, audio: FocusSessionAudio = NoOpFocusSessionAudio(), runsTimers: Bool = false,
         continuous: @escaping () -> Double = BlockingClock.continuous, boot: @escaping () -> String = BlockingClock.bootID) throws {
        self.store = store; self.clock = clock; self.continuous = continuous; self.boot = boot; launchClock = .init(wall: clock(), continuous: continuous(), boot: boot()); self.calendar = calendar; self.blocking = blocking; self.audio = audio; self.runsTimers = runsTimers
        let day = FocusCalendar.dayKey(clock(), calendar: calendar); currentDay = day
        status = FocusStatus(since: clock()); plan = FocusPlan(day: day); promptState = FocusPromptState(day: day)
        try store.recover(); try store.migrateLegacyDays(calendar: calendar, now: clock()); settings = try store.settings(); limitMarks = try store.marks(); commitments = try store.commitments()
        clockCorrection = (try? store.clockCorrection()).flatMap { $0.boot == launchClock.boot ? $0 : nil }
        if let proven = FocusCommitRule.anchoredNow(try? store.clockAnchor(), clock: launchClock), proven > launchClock.wall {
            launchClock.wall = proven
        }
        try? store.saveClockAnchor(launchClock)
        // Preserve once-per-week warnings made by the pre-ISO implementation.
        for i in limitMarks.indices where limitMarks[i].kind == "weekly" && FocusValidation.day(limitMarks[i].period) {
            limitMarks[i].period = FocusCalendar.weekKey(limitMarks[i].at, calendar: calendar)
        }
        promptState = try store.prompts() ?? promptState
        if promptState.day != day { promptState = FocusPromptState(day: day) }
        try loadDay(day)
        // A stop that quit or module-off could not save: close it before any open session is restored.
        if let tomb = try store.pendingStopTombstone() {
            let tombDay = tomb.day
            if var value = try store.sessions(tombDay).first(where: { $0.id == tomb.sessionID && $0.endedAt == nil }) {
                value.events.append(.init(kind: .stop, at: tomb.end, reason: tomb.reason))
                value.distractions?.finish(lists: blockLists, ignored: ignoredDistractionIDs)
                try persist(value)
                try? blocking()?.creditEarnedTime(for: value)
            }
            try store.clearPendingStopTombstone()
        }
        // A free open session may have started on any retained day, not only yesterday.
        var running: [FocusSession] = []
        try repairDuplicateSessions()
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
        observeClockChanges()
    }
    /// A zone change or a wake moves the evening prompt and the end-of-day limit; the timer was set with the old ones.
    /// `refresh` recomputes both from the live calendar and shows each prompt once (`promptState` keeps what was shown).
    private func observeClockChanges() {
        guard runsTimers else { return }
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            systemObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    private func loadDay(_ day: String) throws {
        sessions = try store.sessions(day)
        var value = try store.plan(day) ?? freshDayPlan(day)
        // A non-nil process list, including [], is an explicit daily snapshot. Never
        // resurrect a removed process from yesterday when the app relaunches.
        if value.processes == nil, let priorDay = try store.planDays().filter({ $0 < day }).max(),
           let prior = try store.plan(priorDay), let processes = prior.processes, !processes.isEmpty {
            let previous = value
            value.processes = processes.filter { !$0.status.isFinished }
            value = try versioned(value, replacing: previous, actor: "day", reason: "Processus en cours repris du dernier jour")
            try store.savePlans([value])
        }
        plan = value; review = try store.review(day)
    }
    private func admit() throws { if storageFailed { throw FocusFailure.storageFailed } }
    /// Clears the write latch only after the files read back cleanly. No write happens here.
    @discardableResult func retryStorage() -> Bool {
        guard storageFailed else { return true }
        defer { scheduleTimer() }
        let now = clock(), day = FocusCalendar.dayKey(now, calendar: calendar)
        lastStorageRetry = now
        do {
            try store.recover(); try loadDay(day)
            sessionCache.removeAll()
            if day != currentDay { currentDay = day; promptState = FocusPromptState(day: day); measurementRefresh?() }
        } catch { return false }
        if let pending = pendingStop {
            // Save the stop first, so the disk never holds two open sessions. A failure re-sets the latch.
            storageFailed = false
            var value = pending.session
            value.events.append(.init(kind: .stop, at: pending.end, reason: pending.reason))
            value.distractions?.finish(lists: blockLists, ignored: ignoredDistractionIDs)
            let shown = error
            do { try persist(value) } catch { storageFailed = true; self.error = shown; return false }
            pendingStop = nil
            do { try blocking()?.creditEarnedTime(for: value) } catch { self.error = String(describing: error); return true }
        }
        storageFailed = false; error = nil
        return true
    }
    /// The disk keeps the open session until `retryStorage` saves the pending stop. If the app quits first, `flushPendingStop`
    /// leaves a tombstone that the next launch applies. Without it, only a timed session that has ended is closed on launch.
    private func endInMemory(_ session: FocusSession, at end: Date, reason: FocusSession.Event.Reason) {
        if pendingStop == nil { pendingStop = (session, end, reason) }
        if let id = phaseBlockID, !hasLockedPhaseBlock { blocking()?.stop(id); phaseBlockID = nil; phaseBlockKey = nil }
        currentSession = nil; phase = nil; phaseIdentity = nil; lastSyncErrorShown = nil; audio.stop()
    }
    private func saving(_ action: () throws -> Void) throws {
        try admit()
        do { try action() } catch {
            if (error as? FocusFailure) != .invalidArgument { storageFailed = true; scheduleTimer() }
            self.error = String(describing: error); throw error
        }
    }
    /// The file day of a session is fixed when it is first written: a zone change moves `startedAt` to another day, and
    /// the copy would then be written twice (concentration-02). Older data: the day of the file that holds the UUID.
    private var storageDays: [UUID: String] = [:]
    private func storageDay(of value: FocusSession) throws -> String {
        if let day = storageDays[value.id] { return day }
        for day in try store.sessionDays() where try store.sessions(day).contains(where: { $0.id == value.id }) {
            storageDays[value.id] = day; return day
        }
        let day = FocusCalendar.dayKey(value.startedAt, calendar: calendar)
        storageDays[value.id] = day
        return day
    }
    /// A zone change used to leave two copies of one session in two day files. Keep the closed one, else the one with
    /// the longer history, and remove the others.
    private func repairDuplicateSessions() throws {
        var copies: [UUID: [(day: String, value: FocusSession)]] = [:]
        for day in try store.sessionDays() { for value in try store.sessions(day) { copies[value.id, default: []].append((day, value)) } }
        for (id, list) in copies where list.count > 1 {
            let keep = list.max { a, b in
                (a.value.endedAt != nil ? 1 : 0, a.value.events.count) < (b.value.endedAt != nil ? 1 : 0, b.value.events.count)
            }!
            for copy in list where copy.day != keep.day {
                try store.saveSessions(try store.sessions(copy.day).filter { $0.id != id }, day: copy.day)
                sessionCache[copy.day] = nil
            }
            storageDays[id] = keep.day
        }
    }
    private func persist(_ value: FocusSession) throws {
        let day = try storageDay(of: value)
        var values = try store.sessions(day)
        if let i = values.firstIndex(where: { $0.id == value.id }) { values[i] = value } else { values.append(value) }
        try saving { try store.saveSessions(values, day: day) }
        sessionCache[day] = values; storageDays[value.id] = day
        if day == currentDay { sessions = values }
    }
    /// The plan link a draft may still pass: the item can be done, moved or removed since it was chosen,
    /// or today's plan replaced at midnight. A stale link is dropped, the session keeps its intention.
    func openPlanItemID(_ id: UUID?) -> UUID? {
        guard let id, plan.items.contains(where: { $0.id == id && $0.status == .open }) else { return nil }
        return id
    }
    /// The slot a start applies to: the one the member chose when the action has several, else the first unfinished one.
    private func agendaSlot(forItem id: UUID, slotID: UUID?) -> FocusAgendaSlot? {
        guard let slots = plan.agenda?.slots else { return nil }
        if let slotID, let chosen = slots.first(where: { $0.id == slotID && $0.itemID == id && !$0.state.isFinished }) { return chosen }
        return slots.first { $0.itemID == id && !$0.state.isFinished }
    }
    func startSession(intent: String, mode: FocusMode, planItemId: UUID? = nil, blockListIds: [UUID] = [],
                      blockDuringBreaks: Bool = false, lock: Bool = false, ambiance: Bool = false,
                      pause: PausePolicy? = nil, planSlotId: UUID? = nil) throws {
        try admit(); refresh()
        guard currentSession == nil else { throw FocusFailure.invalidArgument }
        if let id = planItemId, !plan.items.contains(where: { $0.id == id && $0.status == .open }) { throw FocusFailure.notFound }
        if let id = planItemId, let slot = agendaSlot(forItem: id, slotID: planSlotId) {
            _ = try preparedStart(slot.id, in: plan)
        }
        if !blockListIds.isEmpty {
            guard let b = blocking() else { throw FocusFailure.moduleDisabled }
            guard Set(blockListIds).isSubset(of: Set(b.lists.map(\.id))) else { throw FocusFailure.notFound }
        }
        let now = clock()
        var value = FocusSession(intent: intent, planItemId: planItemId, mode: mode, blockListIds: blockListIds,
            blockDuringBreaks: blockDuringBreaks, lock: lock, ambiance: ambiance, startedAt: now, events: [.init(kind: .start, at: now)])
        value.pause = blockListIds.isEmpty ? nil : pause
        value.plannedEndAt = FocusPhases.plannedEnd(value)
        guard value.valid else { throw FocusFailure.invalidArgument }
        try persist(value)
        currentSession = value
        do { try syncBlock(value, phase: FocusPhases.phase(value, at: now)) }
        catch {
            value.events.append(.init(kind: .stop, at: now, reason: .member)); try persist(value); currentSession = nil; throw error
        }
        error = nil
        if let id = planItemId, let slot = agendaSlot(forItem: id, slotID: planSlotId) {
            do { try applyDayPlan(preparedStart(slot.id, in: plan), expectedRevision: plan.effectiveRevision, reason: "Action démarrée") }
            catch { self.error = "La séance a démarré, mais son créneau n’a pas pu être mis à jour : \(FocusUIError.message(error))" }
        }
        refresh()
    }
    func skipPhase() throws {
        try admit(); refresh()
        guard var value = currentSession else { throw FocusFailure.notFound }
        if hasLockedPhaseBlock { throw FocusFailure.locked }
        guard value.mode.kind == .pomodoro, value.events.count < 1023 else { throw FocusFailure.invalidArgument }
        value.events.append(.init(kind: .skip, at: eventTime(value))); value.plannedEndAt = FocusPhases.plannedEnd(value)
        try persist(value); currentSession = value; refresh()
    }
    /// `surveillanceConfirmed` = the caller passed the stop of the session's « Surveillance » (`JevStopGate`). Without
    /// it (the CLI, any other caller), a protected surveillance refuses the stop.
    func stopSession(outcome: FocusSession.Outcome? = nil, note: String? = nil, surveillanceConfirmed: Bool = false) throws {
        if !surveillanceConfirmed, surveillanceProtected { throw FocusFailure.locked }
        if storageFailed, currentSession != nil {
            // Nothing can be written: end the session in memory only. A retry, or the stop tombstone at quit, closes it on disk.
            if hasLockedPhaseBlock { throw FocusFailure.locked }
            endInMemory(currentSession!, at: eventTime(currentSession!), reason: .member); publishStatus(); scheduleTimer(); throw FocusFailure.storageFailed
        }
        try admit(); refresh()
        guard var value = currentSession else { throw FocusFailure.notFound }
        if hasLockedPhaseBlock { throw FocusFailure.locked }
        guard note.map({ FocusValidation.text($0, maximum: 140) }) ?? true else { throw FocusFailure.invalidArgument }
        value.outcome = outcome; value.note = note
        try finish(value, at: eventTime(value), reason: outcome == .done ? .completed : .member)
    }
    /// A wall clock set back must not give an event older than the session's last one: the file would refuse it and
    /// « Arrêter » would do nothing. Events stay in order.
    private func eventTime(_ value: FocusSession) -> Date { max(clock(), value.events.last?.at ?? value.startedAt) }
    private func finish(_ session: FocusSession, at end: Date, reason: FocusSession.Event.Reason) throws {
        var value = session; value.events.append(.init(kind: .stop, at: end, reason: reason))
        value.distractions?.finish(lists: blockLists, ignored: ignoredDistractionIDs)
        try persist(value)
        // The stop is on disk: the session ends in memory too, even if the earned-time credit fails.
        do { try blocking()?.creditEarnedTime(for: value) } catch { self.error = String(describing: error) }
        if let id = phaseBlockID { blocking()?.stop(id) }
        currentSession = nil; phase = nil; phaseBlockID = nil; phaseBlockKey = nil; phaseIdentity = nil; lastSyncErrorShown = nil; audio.stop()
        sessionFacts = facts(value); reviewedSession = value
        showPanel(.init(kind: .sessionReview, text: "C’est fait ?", sessionID: value.id))
        refresh()
    }
    func recordOutcome(sessionID: UUID, outcome: FocusSession.Outcome?, note: String? = nil) throws {
        try admit()
        guard note.map({ FocusValidation.text($0, maximum: 140) }) ?? true else { throw FocusFailure.invalidArgument }
        for day in try store.sessionDays().reversed() {
            if var value = try store.sessions(day).first(where: { $0.id == sessionID && $0.endedAt != nil }) {
                value.outcome = outcome; value.note = note; try persist(value)
                if let id = value.planItemId,
                   !(currentSession?.planItemId == id && currentSession?.id != sessionID) {
                    var linked = try plan(on: day)
                    if let i = linked.items.firstIndex(where: { $0.id == id && $0.status == .open }) {
                        if outcome == .done { linked.items[i].status = .done; linked.items[i].toDay = nil }
                        if var agenda = linked.agenda {
                            for k in agenda.slots.indices where agenda.slots[k].itemID == id && !agenda.slots[k].state.isFinished {
                                agenda.slots[k].state = outcome == .done ? .done : .unscheduled
                            }
                            linked.agenda = agenda
                        }
                        try applyDayPlan(linked, expectedRevision: linked.effectiveRevision, reason: outcome == .done ? "Résultat déclaré terminé" : "Séance terminée ; action à reprendre")
                    }
                }
                if panel?.sessionID == sessionID { dismissPanel() }; return
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
    func plan(on day: String) throws -> FocusPlan { try store.plan(day) ?? freshDayPlan(day) }
    func review(on day: String) throws -> FocusReview { try store.review(day) ?? FocusReview(day: day) }
    func setPlan(_ value: FocusPlan) throws {
        guard value.items.count <= FocusPlan.maximumItems else { throw FocusFailure.planFull }
        guard !value.items.isEmpty else { throw FocusFailure.invalidArgument }
        let old = try plan(on: value.day)
        // An older client only knows the item list. Preserve newer fields it did not send.
        var next = value
        if next.agenda == nil { next.agenda = old.agenda }
        if next.processes == nil { next.processes = old.processes }
        next.receipts = old.receipts; next.changes = old.changes; next.previousAgenda = old.previousAgenda
        if next.revision == nil { next.revision = old.revision }
        reconcileSlots(&next)
        try applyDayPlan(next, expectedRevision: value.revision ?? old.effectiveRevision, reason: "Plan modifié")
    }
    /// A task renamed in « Vérifier et corriger »: linked plan items follow, or their project minutes read 0 (T-045 H5-04).
    /// Returns the unreadable days left on the old name (T-045 L3-3).
    @discardableResult func renamePlanProject(from old: String, to new: String) -> [String] {
        var changed: [FocusPlan] = [], skipped: [String] = []
        try? saving { (changed, skipped) = try store.renamePlanProjectReporting(from: old, to: new) }
        if let today = changed.first(where: { $0.day == currentDay }) { plan = today }
        if !changed.isEmpty { updateMeasures(); publishStatus() }
        return skipped
    }
    @discardableResult func addPlanItem(title: String, day: String, project: String? = nil, estimateMinutes: Int? = nil) throws -> FocusPlanItem {
        var value = try plan(on: day)
        let item = FocusPlanItem(title: title, project: project, estimateMinutes: estimateMinutes)
        value.items.append(item); try setPlan(value); return item
    }
    func setItemStatus(_ id: UUID, day: String, status: FocusPlanItem.Status) throws {
        guard status == .done || status == .dropped else { throw FocusFailure.invalidArgument }
        try settleItem(id, day: day, status: status)
    }
    /// Reopens an item; a copy an earlier move left open in another day is withdrawn.
    func reopenPlanItem(_ id: UUID, day: String) throws { try settleItem(id, day: day, status: .open) }
    private func settleItem(_ id: UUID, day: String, status: FocusPlanItem.Status) throws {
        var value = try plan(on: day), changed: [String: FocusPlan] = [:]
        guard let i = value.items.firstIndex(where: { $0.id == id }) else { throw FocusFailure.notFound }
        if value.items[i].status == .moved, let previous = value.items[i].toDay { try withdrawMovedCopy(id, from: previous, into: &changed) }
        value.items[i].status = status; value.items[i].toDay = nil
        guard !changed.isEmpty else { try setPlan(value); return }
        guard value.valid, !value.items.isEmpty else { throw FocusFailure.invalidArgument }
        changed[day] = value; try savePlanChanges(changed)
    }
    func movePlanItem(_ id: UUID, day: String, to target: String) throws {
        guard FocusValidation.day(target), target != day else { throw FocusFailure.invalidArgument }
        var source = try plan(on: day), changed: [String: FocusPlan] = [:]
        guard let i = source.items.firstIndex(where: { $0.id == id }) else { throw FocusFailure.notFound }
        guard source.items[i].status != .done, source.items[i].status != .dropped else { throw FocusFailure.itemFinished }
        if source.items[i].status == .moved, let previous = source.items[i].toDay, previous != target {
            try withdrawMovedCopy(id, from: previous, into: &changed)
        }
        var destination = try changed[target] ?? plan(on: target)
        var item = source.items[i]; item.status = .open; item.toDay = nil
        if let k = destination.items.firstIndex(where: { $0.id == id }) {
            // Back to the first day: its entry, left « moved », opens again.
            if destination.items[k].status == .moved { destination.items[k].status = .open; destination.items[k].toDay = nil }
        } else { destination.items.append(item) }
        source.items[i].status = .moved; source.items[i].toDay = target
        changed[target] = destination; changed[day] = source
        try savePlanChanges(changed)
    }
    /// A moved item left an open copy in `day`. Removes that copy only while it is still open there:
    /// a copy the member finished, moved or dropped in its new day stays.
    private func withdrawMovedCopy(_ id: UUID, from day: String, into changed: inout [String: FocusPlan]) throws {
        var value = try changed[day] ?? plan(on: day)
        guard let j = value.items.firstIndex(where: { $0.id == id }), value.items[j].status == .open else { return }
        value.items.remove(at: j); changed[day] = value
    }
    private func savePlanChanges(_ changed: [String: FocusPlan], review value: FocusReview? = nil) throws {
        // A move or a review carry can target a plan that is already full.
        guard changed.values.allSatisfy({ $0.items.count <= FocusPlan.maximumItems }) else { throw FocusFailure.planFull }
        var values: [FocusPlan] = []
        for var next in changed.values {
            reconcileSlots(&next)
            values.append(try versioned(next, replacing: plan(on: next.day), actor: "member", reason: value == nil ? "Tâche déplacée ou mise à jour" : "Bilan enregistré"))
        }
        try saving { try store.savePlans(values, review: value) }
        if let today = values.first(where: { $0.day == currentDay }) { plan = today }
        if let value, value.day == currentDay { review = value }
        updateMeasures(); publishStatus(); scheduleTimer()
    }
    func setReview(_ value: FocusReview) throws {
        guard value.valid else { throw FocusFailure.invalidArgument }
        var source = try plan(on: value.day), changed: [String: FocusPlan] = [:]
        for item in value.items {
            guard let i = source.items.firstIndex(where: { $0.id == item.id }) else { throw FocusFailure.notFound }
            // A dropped task stays dropped: the UI never lists it, but the CLI can name it.
            if source.items[i].status == .dropped { continue }
            // A new answer replaces an earlier move: its still-open copy leaves the old target day.
            if source.items[i].status == .moved, let previous = source.items[i].toDay, previous != item.toDay {
                try withdrawMovedCopy(item.id, from: previous, into: &changed)
            }
            if let target = item.toDay {
                guard target != value.day else { throw FocusFailure.invalidArgument }
                var destination = try changed[target] ?? plan(on: target)
                var moved = source.items[i]; moved.status = .open; moved.toDay = nil
                if let k = destination.items.firstIndex(where: { $0.id == moved.id }) {
                    if destination.items[k].status == .moved { destination.items[k].status = .open; destination.items[k].toDay = nil }
                } else { destination.items.append(moved) }
                changed[target] = destination; source.items[i].status = .moved; source.items[i].toDay = target
            } else {
                source.items[i].status = item.outcome == .done ? .done : .open; source.items[i].toDay = nil
            }
        }
        let carryID = carryItemID(day: value.day)
        if let title = value.tomorrowFirst, !title.isEmpty {
            let tomorrow = try dayAfter(value.day)
            var next = try changed[tomorrow] ?? plan(on: tomorrow)
            // Updating the same review keeps its carry-forward item (and its progress), without inventing duplicates.
            if let k = next.items.firstIndex(where: { $0.id == carryID }) {
                next.items[k].title = title
            } else {
                next.items.insert(FocusPlanItem(id: carryID, title: title), at: 0)
            }
            changed[tomorrow] = next
        } else {
            // Clearing the field withdraws the carried task, unless it is already done or moved on.
            let tomorrow = try dayAfter(value.day)
            var next = try changed[tomorrow] ?? plan(on: tomorrow)
            if let k = next.items.firstIndex(where: { $0.id == carryID }), next.items[k].status == .open {
                next.items.remove(at: k); changed[tomorrow] = next
            }
        }
        changed[source.day] = source
        try savePlanChanges(changed, review: value)
    }
    private func carryItemID(day: String) -> UUID {
        let digits = day.replacingOccurrences(of: "-", with: "")
        return UUID(uuidString: "F0C05000-0000-4000-8000-0000" + digits)!
    }
    /// The civil day after `day`, in this controller's time zone. The page and the review sheet use it too.
    func dayAfter(_ day: String) throws -> String {
        guard let interval = FocusCalendar.dayInterval(day, calendar: calendar) else { throw FocusFailure.invalidArgument }
        return FocusCalendar.dayKey(interval.end, calendar: calendar)
    }
    func updateSettings(_ value: FocusSettings) throws {
        guard value.valid else { throw FocusFailure.invalidArgument }
        if value == settings { return }
        guard settings.effectiveGuideRevision < 1_000_000_000 else { throw FocusFailure.invalidArgument }
        var next = value; next.guideRevision = settings.effectiveGuideRevision + 1
        let coachChanged = next.coachSettings != settings.coachSettings
        try saving { try store.saveSettings(next) }; settings = next
        if coachChanged { NotificationCenter.default.post(name: .goalongFocusCoachSettingsDidChange, object: self) }
        if !settings.dayGuideSettings.enabled || !settings.dayGuideSettings.remindersEnabled {
            if panel?.kind == .agenda { dismissPanel() }
        }
        if !settings.detectionEnabled { detection.reset() }; refreshCommitmentCards(); refresh()
    }
    func updateDayGuideSettings(_ value: FocusDayGuideSettings) throws {
        var next = settings; next.dayGuide = value; try updateSettings(next)
    }
    func updateCoachSettings(_ value: FocusDayCoachSettings) throws {
        var next = settings; next.coach = value; try updateSettings(next)
    }
    /// Configuration only. Choosing a provider never grants a capability consent or starts inference.
    func configureDayGuide(body: Data, expectedRevision: Int) throws {
        try admit()
        try GoalongFocusCLI.validateGuideInput(body)
        guard settings.effectiveGuideRevision == expectedRevision else { throw FocusFailure.conflict }
        guard body.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any], !object.isEmpty,
              Set(object.keys).isSubset(of: ["dayGuide", "coach", "morningPrompt", "morningMinute", "eveningPrompt", "eveningMinute"]) else { throw FocusFailure.invalidArgument }
        struct Patch: Decodable {
            var morningPrompt: Bool?; var morningMinute: Int?; var eveningPrompt: Bool?; var eveningMinute: Int?
        }
        let patch = try FocusJSON.decode(Patch.self, from: body)
        var next = settings
        func merged<T: Codable>(_ current: T, with raw: Any) throws -> T? {
            if raw is NSNull { return nil }
            guard let fields = raw as? [String: Any],
                  var value = try JSONSerialization.jsonObject(with: FocusJSON.encode(current)) as? [String: Any] else { throw FocusFailure.invalidArgument }
            for (key, field) in fields { value[key] = field }
            return try FocusJSON.decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
        if let raw = object["dayGuide"] { next.dayGuide = try merged(settings.dayGuideSettings, with: raw) }
        if let raw = object["coach"] { next.coach = try merged(settings.coachSettings, with: raw) }
        if let value = patch.morningPrompt { next.morningPrompt = value }
        if let value = patch.morningMinute { next.morningMinute = value }
        if let value = patch.eveningPrompt { next.eveningPrompt = value }
        if let value = patch.eveningMinute { next.eveningMinute = value }
        try updateSettings(next)
    }
    func noteInput(at date: Date, count: Int) { if count > 0 { latestInput = date } }
    func observe(_ value: FocusObservation) {
        var value = value
        value.input = latestInput.map { value.at.timeIntervalSince($0) >= 0 && value.at.throttleElapsed(since: $0) < 60 } ?? false
        observation = value
        if settings.detectionEnabled && currentSession == nil { _ = detection.observe(value) } else { detection.reset() }
        refresh()
        if value.observing, value.available, value.idleSeconds < 120 {
            reflowOverdueAgenda(); checkPrompts(activity: true); checkAgendaPrompt()
        }
        // Also without observation: sessions, plans and period ends still need a measurement (T-044 B2-02).
        if value.at.throttleElapsed(since: lastMeasureRequest) >= 60 { lastMeasureRequest = value.at; measurementRefresh?() }
    }
    func applyMeasurements(_ days: [GoalongLocalAnalytics.Day], hasDefinition: Bool) {
        measuredDays = Dictionary(uniqueKeysWithValues: days.map { (FocusCalendar.dayKey($0.date, calendar: calendar), $0) })
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
        acceptBootClockCorrection()
        if storageFailed, clock().throttleElapsed(since: lastStorageRetry) >= 60 { retryStorage() }
        if phaseBlockID != nil || commitments.contains(where: { $0.result?.stake.state == .applied }) { blocking()?.refresh(enforceLast: false) }
        let now = clock(), day = FocusCalendar.dayKey(now, calendar: calendar)
        if day != currentDay {
            do { try loadDay(day); currentDay = day; promptState = FocusPromptState(day: day); measurementRefresh?() } catch { self.error = String(describing: error); storageFailed = true }
        }
        if let value = currentSession {
            var p = FocusPhases.phase(value, at: now)
            // Blocking's clock protection may move a locked deadline. Focus cannot cut it short.
            if hasLockedPhaseBlock, let id = phaseBlockID, let b = blocking(), let block = b.activeBlocks.first(where: { $0.id == id }), p.kind == .ended || phaseKey(p) != phaseBlockKey {
                p = phase ?? p; p.endsAt = b.wallFrame(block.end)
            }
            if p.kind == .ended {
                do { try finish(value, at: p.startedAt, reason: .completed) } catch {
                    // The stop cannot be saved: end the session in memory so it does not run on and re-raise the error.
                    if self.error == nil { self.error = String(describing: error) }
                    endInMemory(value, at: p.startedAt, reason: .completed)
                }
            } else {
                let key = phaseKey(p)
                do { try syncBlock(value, phase: p); lastSyncErrorShown = nil } catch {
                    // Refresh runs every few seconds: publish a failure once, not on each tick.
                    let message = String(describing: error)
                    if lastSyncErrorShown != message { lastSyncErrorShown = message; self.error = message }
                }
                if phaseIdentity != key {
                    if phaseIdentity != nil { showPanel(.init(kind: .phase, text: p.isWork ? "On reprend : \(value.intent)" : "Repos — \(Int((p.endsAt?.timeIntervalSince(p.startedAt) ?? 0) / 60)) min", expiresAt: now.addingTimeInterval(6))); if settings.phaseSound { onPhaseSound?() } }
                    if value.ambiance { if p.isWork { audio.startWork() } else { audio.startBreak() } }
                    phaseIdentity = key
                }
                if phase != p { phase = p }
            }
        }
        if panel?.expiresAt.map({ $0 <= now }) == true { dismissPanel() }
        if now.throttleElapsed(since: lastCommitmentCardRefresh) >= 60 || commitmentCards.contains(where: { ($0.editMode == "free" && $0.editUntil <= now) || ($0.exitUntil.map { $0 <= now } == true && ($0.canUseJoker || $0.canDeclare)) }) { refreshCommitmentCards() }
        checkPrompts(activity: false); checkLimits(); checkAgendaPrompt(); publishStatus(); scheduleTimer()
    }
    /// The last block failure published: a member who closed it is not shown the same one again.
    private var lastSyncErrorShown: String?
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
        if phaseBlockKey == key, let id = phaseBlockID, b.activeBlocks.contains(where: { $0.id == id && $0.end > b.now.addingTimeInterval(p.endsAt == nil ? 20 : 0) }) { return }
        if let id = phaseBlockID {
            if hasLockedPhaseBlock { throw FocusFailure.locked }; b.stop(id)
        }
        phaseBlockID = nil; phaseBlockKey = nil
        guard p.isWork || value.blockDuringBreaks else { return }
        // Open free sessions renew one short free lease on the existing Blocking clock.
        let end = p.endsAt ?? clock().addingTimeInterval(60)
        let id = blockID(value.id, phase: p)
        // A list deleted since the start (by an older build or by hand) must not release the others.
        let existing = Set(b.lists.map(\.id))
        let listIDs = value.blockListIds.filter(existing.contains)
        guard !listIDs.isEmpty else { throw FocusFailure.notFound }
        try b.startFocusBlock(id: id, listIDs: listIDs, until: end, lock: value.lock && p.isWork ? .locked : .free, pause: value.pause)
        phaseBlockID = id; phaseBlockKey = key
    }
    private func publishStatus() {
        let chosenAction = currentJevPlanAction
        if chosenAction != lastPublishedJevPlanAction {
            lastPublishedJevPlanAction = chosenAction
            NotificationCenter.default.post(name: Notification.Name("goalongFocusPlanContextDidChange"), object: self)
        }
        var next = FocusStatus(since: status.since)
        next.planDay = plan.day; next.planRevision = plan.effectiveRevision
        next.waitingProcesses = FocusDayPlanner.waitingProcesses(plan: plan).count
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
        // The question about the session that just ended comes first; the prompts return once it is answered or gone.
        if panel?.kind == .sessionReview { return }
        // A guided day already carries its morning/evening anchors.
        if settings.dayGuideSettings.enabled, plan.agenda != nil { return }
        let minute = calendar.component(.hour, from: clock()) * 60 + calendar.component(.minute, from: clock())
        let evening = eveningMinute(on: clock())
        var request: FocusPanel.Kind?
        if settings.morningPrompt, activity, minute >= settings.morningMinute, plan.items.isEmpty, !promptState.morningShown { promptState.morningShown = true; request = .morning }
        if settings.eveningPrompt, minute >= evening, review == nil, !promptState.eveningShown { promptState.eveningShown = true; request = .evening }
        if settings.morningPrompt, plan.items.isEmpty, let at = promptState.morningReminderAt, at <= clock(), !promptState.morningReminded { promptState.morningReminded = true; request = .morning }
        if settings.eveningPrompt, review == nil, let at = promptState.eveningReminderAt, at <= clock(), !promptState.eveningReminded { promptState.eveningReminded = true; request = .evening }
        if let request {
            do { try saving { try store.savePrompts(promptState) } } catch { return }
            showPanel(.init(kind: request, text: request == .morning ? "Plan du matin" : "Bilan du soir"))
        }
    }
    /// The end of day replaces the evening review time, but only on its weekdays.
    private func eveningMinute(on date: Date) -> Int {
        guard let end = settings.limits.endMinute,
              settings.limits.weekdays.contains(BlockingSchedule.isoWeekday(date, calendar: calendar)) else { return settings.eveningMinute }
        return end
    }
    func promptLater() {
        guard let kind = panel?.kind, kind == .morning || kind == .evening else { return }
        if kind == .morning, !promptState.morningReminded { promptState.morningReminderAt = clock().addingTimeInterval(1800) }
        if kind == .evening, !promptState.eveningReminded { promptState.eveningReminderAt = clock().addingTimeInterval(1800) }
        do { try saving { try store.savePrompts(promptState) } } catch { return }; dismissPanel(); scheduleTimer()
    }
    func promptNow() { guard let kind = panel?.kind else { return }; requestedEditor = kind; onOpenRequested?(kind); dismissPanel() }
    /// An explicit programme link carries its destination through the kept Garde-fous page.
    /// The caller owns navigation; ordinary session links keep their existing destination.
    func requestDayPlan() { requestedEditor = .agenda }
    func dismissEditor() { requestedEditor = nil }
    func dismissPanel() { showPanel(nil) }
    /// A floating panel has no room for an error, and `error` shows on the Concentration page only:
    /// open that page so the click does not look lost.
    func reportPanelError(_ message: String) {
        error = message
        onOpenRequested?(panel?.kind ?? .sessionReview)
    }
    private func showPanel(_ value: FocusPanel?) {
        if value?.kind != .sessionReview { reviewedSession = nil }
        // The claim ends with its question (answered, closed, or another session's question). A phase notice in between keeps it.
        if value == nil || (value?.kind == .sessionReview && value?.sessionID != inlineReviewSessionID) { inlineReviewSessionID = nil }
        if panel != value { panel = value; onPanelChange?(value) }
    }
    private func scheduleTimer() {
        timer?.invalidate(); timer = nil; guard runsTimers else { return }
        let now = clock()
        var boundaries = [phase?.endsAt, panel?.expiresAt, promptState.morningReminded ? nil : promptState.morningReminderAt,
                          promptState.eveningReminded ? nil : promptState.eveningReminderAt].compactMap { $0 }
        boundaries += commitmentCards.compactMap(\.exitUntil)
        if settings.dayGuideSettings.enabled, let agenda = plan.agenda {
            boundaries += agenda.slots.filter { !$0.state.isFinished && $0.state != .unscheduled }.compactMap {
                FocusDayPlanner.date(day: plan.day, minute: $0.startMinute, timeZoneID: agenda.timeZoneID)
            }
            if let until = promptState.agendaSnoozedUntil { boundaries.append(until) }
        }
        boundaries += commitmentCards.filter { $0.editMode == "free" }.map(\.editUntil)
        if storageFailed { boundaries.append(max(now.addingTimeInterval(1), lastStorageRetry.addingTimeInterval(60))) }
        if currentSession?.mode.kind == .free, currentSession?.mode.minutes == nil, phaseBlockID != nil { boundaries.append(now.addingTimeInterval(45)) }
        if settings.eveningPrompt || settings.limits.endMinute != nil {
            let minute = eveningMinute(on: now)
            let end = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now)!
            if end > now { boundaries.append(end) }
        }
        boundaries.append(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
        guard let next = boundaries.filter({ $0 > now }).min() else { return }
        let t = Timer(timeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    /// Saves a stop that could not be written (one forced retry). If the store still fails, a small tombstone outside the
    /// sessions folder keeps the stop for the next launch. Called at quit and on module-off.
    func flushPendingStop() {
        guard let pending = pendingStop else { return }
        lastStorageRetry = .distantPast
        if retryStorage(), pendingStop == nil { try? store.clearPendingStopTombstone(); return }
        guard pendingStop != nil else { return }
        try? store.savePendingStopTombstone(.init(sessionID: pending.session.id, day: (try? storageDay(of: pending.session)) ?? FocusCalendar.dayKey(pending.session.startedAt, calendar: calendar),
                                                  end: pending.end, reason: pending.reason))
    }
    func shutdown() {
        flushPendingStop()
        if let value = currentSession, !hasLockedPhaseBlock { try? finish(value, at: eventTime(value), reason: .moduleDisabled) }
        timer?.invalidate(); timer = nil; audio.stop(); showPanel(nil); observation = nil; detection.reset()
        systemObservers.forEach(NotificationCenter.default.removeObserver); systemObservers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers.removeAll()
    }
}

// MARK: - Versioned day planning
extension ConcentrationController {
    private struct DayPatch: Decodable {
        var actor: String?; var reason: String?; var intention: String?
        var items: [FocusPlanItem]?; var removeItemIDs: [UUID]?
        var processes: [FocusAgentProcess]?; var removeProcessIDs: [UUID]?
        var agenda: FocusAgenda?; var reflow: Bool?
    }
    private func freshDayPlan(_ day: String) -> FocusPlan {
        var value = FocusPlan(day: day)
        if let template = settings.agendaTemplate, template.valid(forDay: day, items: []) { value.agenda = template }
        return value
    }
    /// Never leave a dangling task reference after an older client's move/remove command.
    private func reconcileSlots(_ value: inout FocusPlan) {
        guard var agenda = value.agenda else { return }
        for i in agenda.slots.indices {
            guard let id = agenda.slots[i].itemID else { continue }
            guard let item = value.items.first(where: { $0.id == id }) else {
                agenda.slots[i].itemID = nil
                if !agenda.slots[i].state.isFinished { agenda.slots[i].state = .skipped }
                continue
            }
            if item.status != .open, !agenda.slots[i].state.isFinished {
                agenda.slots[i].state = item.status == .done ? .done : .skipped
            }
        }
        value.agenda = agenda
    }
    private func versioned(_ draft: FocusPlan, replacing old: FocusPlan, actor: String, reason: String,
                           receipt: (id: String, digest: String)? = nil) throws -> FocusPlan {
        guard draft.day == old.day, old.effectiveRevision < 1_000_000_000,
              FocusValidation.text(actor, maximum: 140, required: true),
              FocusValidation.text(reason, maximum: 500, required: true) else { throw FocusFailure.invalidArgument }
        var value = draft
        if var processes = value.processes {
            for i in processes.indices {
                guard let previous = old.processes?.first(where: { $0.id == processes[i].id }),
                      processes[i].status == .waitingForYou, processes[i].answer == previous.answer,
                      processes[i].question != previous.question || previous.status != .waitingForYou else { continue }
                // A full upsert often carries the previous answer. A new question must not be hidden by it.
                processes[i].answer = nil
            }
            value.processes = processes
        }
        value.revision = old.effectiveRevision + 1
        value.receipts = old.receipts
        if let receipt {
            guard FocusValidation.text(receipt.id, maximum: 128, required: true) else { throw FocusFailure.invalidArgument }
            value.receipts = Array(((old.receipts ?? []) + [.init(id: receipt.id, revision: value.effectiveRevision, digest: receipt.digest)]).suffix(64))
        }
        value.changes = Array(((old.changes ?? []) + [.init(at: clock(), actor: actor, reason: reason, revision: value.effectiveRevision)]).suffix(64))
        guard value.items.count <= FocusPlan.maximumItems else { throw FocusFailure.planFull }
        guard value.valid,
              (value.agenda == old.agenda || (value.agenda.map({ TimeZone(identifier: $0.timeZoneID) == calendar.timeZone }) ?? true)) else { throw FocusFailure.invalidArgument }
        return value
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func repeated(_ old: FocusPlan, requestID: String, digest: String) throws -> Bool {
        guard FocusValidation.text(requestID, maximum: 128, required: true) else { throw FocusFailure.invalidArgument }
        guard let previous = old.receipts?.first(where: { $0.id == requestID }) else { return false }
        guard previous.digest == digest else { throw FocusFailure.requestConflict }
        return true
    }
    private func saveDay(_ value: FocusPlan) throws {
        try saving { try store.savePlans([value]) }
        if value.day == currentDay { plan = value }
        updateMeasures(); publishStatus(); scheduleTimer()
    }
    /// Full native editor save, guarded by the revision the editor actually displayed.
    func applyDayPlan(_ value: FocusPlan, expectedRevision: Int, reason: String = "Plan modifié",
                      requestID: String? = nil, actor: String = "member") throws {
        try admit()
        let old = try plan(on: value.day)
        let hash = try digest(FocusJSON.encode(value))
        if let requestID, try repeated(old, requestID: requestID, digest: hash) { return }
        guard expectedRevision == old.effectiveRevision else { throw FocusFailure.conflict }
        if requestID == nil, value == old {
            // A freshly installed template can already be returned by plan(on:) before a daily file exists.
            // Keep the published plan in sync even when there is no new revision to persist.
            if old.day == currentDay, plan != old {
                plan = old; updateMeasures(); publishStatus(); scheduleTimer()
            }
            return
        }
        try saveDay(versioned(value, replacing: old, actor: actor, reason: reason,
                              receipt: requestID.map { (id: $0, digest: hash) }))
    }
    /// Main-actor read/modify/write: agents cannot overwrite one another with stale snapshots.
    func patchPlan(day: String, expectedRevision: Int, requestID: String, body: Data) throws -> FocusPlan {
        try admit()
        guard body.count <= 65_536, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys).isSubset(of: ["actor", "reason", "intention", "items", "removeItemIDs", "processes", "removeProcessIDs", "agenda", "reflow"]) else { throw FocusFailure.invalidArgument }
        try validatePatchObjects(object)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let hash = digest(Data("patch:".utf8) + canonical)
        let old = try plan(on: day)
        if try repeated(old, requestID: requestID, digest: hash) { return old }
        guard expectedRevision == old.effectiveRevision else { throw FocusFailure.conflict }
        let patch = try FocusJSON.decode(DayPatch.self, from: canonical)
        var value = old
        if let items = patch.items {
            guard Set(items.map(\.id)).count == items.count else { throw FocusFailure.invalidArgument }
            for item in items {
                if let i = value.items.firstIndex(where: { $0.id == item.id }) { value.items[i] = item } else { value.items.append(item) }
            }
        }
        if let removed = patch.removeItemIDs {
            guard Set(removed).count == removed.count,
                  Set(removed).isDisjoint(with: Set((patch.items ?? []).map(\.id))) else { throw FocusFailure.invalidArgument }
            value.items.removeAll { removed.contains($0.id) }
        }
        if let incoming = patch.processes {
            guard Set(incoming.map(\.id)).count == incoming.count else { throw FocusFailure.invalidArgument }
            var processes = value.processes ?? []
            for var process in incoming {
                process.updatedAt = clock()
                if let i = processes.firstIndex(where: { $0.id == process.id }) { processes[i] = process } else { processes.append(process) }
            }
            value.processes = processes
        }
        if let removed = patch.removeProcessIDs {
            guard Set(removed).count == removed.count,
                  Set(removed).isDisjoint(with: Set((patch.processes ?? []).map(\.id))) else { throw FocusFailure.invalidArgument }
            value.processes?.removeAll { removed.contains($0.id) }
        }
        if object.keys.contains("intention") { value.intention = patch.intention }
        if let agenda = patch.agenda { value.agenda = agenda }
        reconcileSlots(&value)
        if patch.reflow == true { value = adjusted(value) }
        let result = try versioned(value, replacing: old, actor: patch.actor ?? "agent", reason: patch.reason ?? "Plan ajusté par un agent", receipt: (requestID, hash))
        try saveDay(result)
        return result
    }
    private func validatePatchObjects(_ object: [String: Any]) throws {
        let itemKeys: Set<String> = ["id", "title", "project", "estimateMinutes", "status", "toDay", "nextAction", "doneWhen", "actionKind", "contextURL", "processIDs"]
        let processKeys: Set<String> = ["id", "title", "project", "agent", "externalID", "contextURL", "status", "question", "answer", "updatedAt"]
        for (key, keys) in [("items", itemKeys), ("processes", processKeys)] where object[key] != nil {
            guard let rows = object[key] as? [[String: Any]], rows.allSatisfy({
                Set($0.keys).isSubset(of: keys) && ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil
            }) else { throw FocusFailure.invalidArgument }
        }
        if let raw = object["agenda"] {
            guard let agenda = raw as? [String: Any], Set(agenda.keys).isSubset(of: ["timeZoneID", "startMinute", "endMinute", "bufferMinutes", "guided", "autoAdjust", "reminderLimit", "slots"]) else { throw FocusFailure.invalidArgument }
            if let rawSlots = agenda["slots"] {
                let keys: Set<String> = ["id", "itemID", "title", "startMinute", "endMinute", "fixed", "state", "earliestMinute", "latestEndMinute", "instructions", "reminder", "contextURL"]
                guard let slots = rawSlots as? [[String: Any]], slots.allSatisfy({
                    Set($0.keys).isSubset(of: keys) && ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil
                }) else { throw FocusFailure.invalidArgument }
            }
        }
    }
    private func adjusted(_ source: FocusPlan) -> FocusPlan {
        var value = source
        let result = FocusDayPlanner.reflow(plan: value, now: clock())
        if result.agenda != value.agenda { value.previousAgenda = value.agenda; value.agenda = result.agenda }
        var messages = result.conflicts
        if !result.unplaced.isEmpty { messages.append("\(result.unplaced.count) créneau(x) à replacer : la journée n’a pas été prolongée.") }
        if !messages.isEmpty { error = messages.joined(separator: " ") }
        return value
    }
    func reflowPlan(on day: String, expectedRevision: Int, requestID: String) throws -> FocusPlan {
        try admit()
        let old = try plan(on: day), hash = digest(Data("reflow:\(day)".utf8))
        if try repeated(old, requestID: requestID, digest: hash) { return old }
        guard old.effectiveRevision == expectedRevision else { throw FocusFailure.conflict }
        let value = try versioned(adjusted(old), replacing: old, actor: "agent", reason: "Programme recalé dans les horaires autorisés", receipt: (requestID, hash))
        try saveDay(value); return value
    }
    func reflowDayPlan() throws {
        _ = try reflowPlan(on: currentDay, expectedRevision: plan.effectiveRevision, requestID: UUID().uuidString)
    }
    private func reflowOverdueAgenda() {
        guard settings.dayGuideSettings.enabled, currentSession == nil, panel == nil, !storageFailed,
              clock().throttleElapsed(since: lastAgendaAutoAdjustment) >= 300,
              let agenda = plan.agenda, agenda.autoAdjust,
              !agenda.slots.contains(where: { $0.state == .active }),
              let minute = FocusDayPlanner.localMinute(at: clock(), timeZoneID: agenda.timeZoneID),
              FocusDayPlanner.dayKey(at: clock(), timeZoneID: agenda.timeZoneID) == plan.day,
              minute < agenda.endMinute,
              agenda.slots.contains(where: { !$0.fixed && $0.state == .planned && $0.endMinute < minute }) else { return }
        lastAgendaAutoAdjustment = clock()
        let value = adjusted(plan)
        guard value.agenda != plan.agenda else { return }
        do { try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Reprise tardive : programme recalé, repères fixes conservés", actor: "agenda") }
        catch { self.error = FocusUIError.message(error) }
    }
    private func undoValue(_ old: FocusPlan) throws -> FocusPlan {
        guard var agenda = old.previousAgenda else { throw FocusFailure.notFound }
        // Undo times, never a completion, answer or current work session that happened since.
        let current = Dictionary(uniqueKeysWithValues: (old.agenda?.slots ?? []).map { ($0.id, $0) })
        for i in agenda.slots.indices {
            if let now = current[agenda.slots[i].id] {
                if now.state.isFinished { agenda.slots[i].state = now.state }
                if now.state == .active { agenda.slots[i] = now }
            }
        }
        let known = Set(agenda.slots.map(\.id))
        agenda.slots += (old.agenda?.slots ?? []).filter { !known.contains($0.id) }
        var value = old; value.agenda = agenda; value.previousAgenda = nil; reconcileSlots(&value)
        return value
    }
    func undoPlan(on day: String, expectedRevision: Int, requestID: String) throws -> FocusPlan {
        try admit()
        let old = try plan(on: day), hash = digest(Data("undo:\(day)".utf8))
        if try repeated(old, requestID: requestID, digest: hash) { return old }
        guard old.effectiveRevision == expectedRevision else { throw FocusFailure.conflict }
        let value = try versioned(undoValue(old), replacing: old, actor: "member", reason: "Dernier décalage annulé", receipt: (requestID, hash))
        try saveDay(value); return value
    }
    func undoDayAdjustment() throws {
        _ = try undoPlan(on: currentDay, expectedRevision: plan.effectiveRevision, requestID: UUID().uuidString)
    }
    func updateAgendaTemplate(_ agenda: FocusAgenda?) throws {
        guard agenda?.validTemplate ?? true,
              agenda.map({ TimeZone(identifier: $0.timeZoneID) == calendar.timeZone }) ?? true else { throw FocusFailure.invalidArgument }
        var next = settings; next.agendaTemplate = agenda; try updateSettings(next)
        if plan.agenda == nil, let agenda, agenda.valid(forDay: plan.day, items: plan.items) {
            var value = plan; value.agenda = agenda
            try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Repères quotidiens installés")
        }
    }
    private func preparedStart(_ id: UUID, in source: FocusPlan) throws -> FocusPlan {
        guard var agenda = source.agenda, let i = agenda.slots.firstIndex(where: { $0.id == id }),
              !agenda.slots[i].state.isFinished,
              !agenda.slots.contains(where: { $0.state == .active && $0.id != id }),
              FocusDayPlanner.dayKey(at: clock(), timeZoneID: agenda.timeZoneID) == source.day,
              let minute = FocusDayPlanner.localMinute(at: clock(), timeZoneID: agenda.timeZoneID) else { throw FocusFailure.invalidArgument }
        if agenda.slots[i].fixed {
            guard minute >= agenda.slots[i].startMinute, minute < agenda.slots[i].endMinute else { throw FocusFailure.invalidArgument }
        } else if agenda.slots[i].state != .active {
            let duration = agenda.slots[i].durationMinutes
            agenda.slots[i].startMinute = minute; agenda.slots[i].endMinute = minute + duration
            guard minute >= max(agenda.startMinute, agenda.slots[i].earliestMinute ?? 0),
                  agenda.slots[i].endMinute <= min(agenda.endMinute, agenda.slots[i].latestEndMinute ?? 1440) else { throw FocusFailure.invalidArgument }
        }
        let selected = agenda.slots[i]
        guard !agenda.slots.contains(where: { $0.id != id && $0.fixed && !$0.state.isFinished && $0.state != .unscheduled && $0.startMinute < selected.endMinute && selected.startMinute < $0.endMinute }) else { throw FocusFailure.invalidArgument }
        agenda.slots[i].state = .active
        var value = source; value.agenda = agenda
        if agenda.autoAdjust { value = adjusted(value) }
        return value
    }
    func startPlannedItem(_ id: UUID, mode: FocusMode? = nil, slotID: UUID? = nil) throws {
        guard let item = plan.items.first(where: { $0.id == id && $0.status == .open }) else { throw FocusFailure.notFound }
        // The agenda supplies the next transition. An explicit Pomodoro/timer remains available unchanged.
        try startSession(intent: item.title, mode: mode ?? FocusMode(minutes: nil), planItemId: id, planSlotId: slotID)
    }
    func startAgendaSlot(_ id: UUID) throws {
        guard currentSession == nil else { throw FocusFailure.invalidArgument }
        let value = try preparedStart(id, in: plan)
        guard let slot = value.agenda?.slots.first(where: { $0.id == id }) else { throw FocusFailure.notFound }
        if let itemID = slot.itemID { try startPlannedItem(itemID, slotID: id) }
        else { try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Créneau démarré") }
        dismissPanel()
    }
    func finishAgendaSlot(_ id: UUID) throws {
        guard let slot = plan.agenda?.slots.first(where: { $0.id == id }), !slot.state.isFinished else { throw FocusFailure.notFound }
        if let itemID = slot.itemID, currentSession?.planItemId == itemID {
            // Uses the existing surveillance/locked-block guards without an alternate stop path.
            try stopSession(outcome: .done)
        }
        var value = plan
        if let i = value.agenda?.slots.firstIndex(where: { $0.id == id }) { value.agenda?.slots[i].state = .done }
        if let itemID = slot.itemID, let i = value.items.firstIndex(where: { $0.id == itemID }) { value.items[i].status = .done; value.items[i].toDay = nil }
        if value.agenda?.autoAdjust == true { value = adjusted(value) }
        try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Créneau terminé par déclaration")
        if panel?.kind == .sessionReview, let sessionID = panel?.sessionID { try recordOutcome(sessionID: sessionID, outcome: .done) }
    }
    func shiftAgendaSlot(_ id: UUID, minutes: Int) throws {
        guard (1...180).contains(minutes), var agenda = plan.agenda,
              let i = agenda.slots.firstIndex(where: { $0.id == id }), !agenda.slots[i].fixed,
              !agenda.slots[i].state.isFinished else { throw FocusFailure.invalidArgument }
        let old = agenda
        let nowMinute = FocusDayPlanner.localMinute(at: clock(), timeZoneID: agenda.timeZoneID) ?? 0
        if agenda.slots[i].state == .active { agenda.slots[i].endMinute = max(agenda.slots[i].endMinute, nowMinute) + minutes }
        else {
            let duration = agenda.slots[i].durationMinutes
            agenda.slots[i].startMinute = max(agenda.slots[i].startMinute, nowMinute) + minutes
            agenda.slots[i].endMinute = agenda.slots[i].startMinute + duration
            agenda.slots[i].state = .planned
        }
        let selected = agenda.slots[i]
        guard selected.endMinute <= min(agenda.endMinute, selected.latestEndMinute ?? 1440),
              !agenda.slots.contains(where: { $0.id != id && $0.fixed && !$0.state.isFinished && $0.state != .unscheduled && $0.startMinute < selected.endMinute && selected.startMinute < $0.endMinute }) else { throw FocusFailure.invalidArgument }
        var value = plan; value.agenda = agenda
        if agenda.autoAdjust { value = adjusted(value) }
        value.previousAgenda = old
        try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Créneau décalé de \(minutes) min ; repères fixes conservés")
    }
    func answerProcess(_ id: UUID, answer: String) throws {
        guard FocusValidation.text(answer, maximum: 1000, required: true),
              let i = plan.processes?.firstIndex(where: { $0.id == id && $0.status == .waitingForYou }) else { throw FocusFailure.invalidArgument }
        var value = plan
        value.processes?[i].answer = answer; value.processes?[i].updatedAt = clock()
        // A stored answer is not evidence that another process has received it or resumed.
        try applyDayPlan(value, expectedRevision: plan.effectiveRevision, reason: "Réponse enregistrée ; reprise à confirmer par l’agent")
    }
    /// Only an explicitly chosen work session may supply context. Never send the agent queue or documentation.
    var currentJevPlanAction: String? {
        guard settings.usePlanContext == true, let id = currentSession?.planItemId,
              let item = plan.items.first(where: { $0.id == id }) else { return nil }
        return [item.title, item.nextAction].compactMap { $0 }.joined(separator: " — ")
    }
    private func checkAgendaPrompt() {
        let promptTime = clock() // wall: civil agenda reminder only; never a blocking or stake decision.
        guard settings.dayGuideSettings.enabled, settings.dayGuideSettings.remindersEnabled,
              !storageFailed, panel == nil, guidanceMayPresent(), let agenda = plan.agenda,
              let minute = FocusDayPlanner.localMinute(at: promptTime, timeZoneID: agenda.timeZoneID),
              !settings.dayGuideSettings.isQuiet(minute: minute),
              (promptState.agendaPromptCount ?? 0) < agenda.reminderLimit,
              (promptState.agendaSnoozedUntil ?? .distantPast) <= promptTime,
              FocusDayPlanner.dayKey(at: promptTime, timeZoneID: agenda.timeZoneID) == plan.day,
              TimeZone(identifier: agenda.timeZoneID) == calendar.timeZone else { return }
        // No replay of the day's missed reminders on wake, and no mid-session work interruption.
        let shown = Set(promptState.agendaShownIDs ?? [])
        let candidates = agenda.slots.filter { slot in
            guard let start = FocusDayPlanner.date(day: plan.day, minute: slot.startMinute, timeZoneID: agenda.timeZoneID),
                  let end = FocusDayPlanner.date(day: plan.day, minute: slot.endMinute, timeZoneID: agenda.timeZoneID) else { return false }
            return (slot.reminder == .notify || (slot.reminder == .inherit && agenda.guided))
                && slot.state == .planned && start <= promptTime && promptTime < end
                && !shown.contains(slot.id) && (currentSession == nil || slot.fixed)
                && (FocusDayPlanner.task(for: slot, in: plan).map { $0.status == .open } ?? true)
        }.sorted { $0.startMinute < $1.startMinute }
        guard let slot = candidates.first else { return }
        var prompts = promptState
        prompts.agendaShownIDs = Array((prompts.agendaShownIDs ?? []) + [slot.id])
        prompts.agendaPromptCount = (prompts.agendaPromptCount ?? 0) + 1
        do { try saving { try store.savePrompts(prompts) } } catch { return }
        promptState = prompts
        let action = FocusDayPlanner.task(for: slot, in: plan)?.nextAction
        let instructions = slot.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instructions.flatMap { $0.isEmpty ? nil : $0 } ?? action ?? slot.title
        showPanel(.init(kind: .agenda, text: text, expiresAt: promptTime.addingTimeInterval(45), slotID: slot.id))
    }
    func snoozeAgendaPrompt() {
        guard let id = panel?.slotID else { return }
        var prompts = promptState
        prompts.agendaSnoozedUntil = clock().addingTimeInterval(900)
        prompts.agendaShownIDs?.removeAll { $0 == id }
        do { try saving { try store.savePrompts(prompts) } } catch { return }
        promptState = prompts; dismissPanel(); scheduleTimer()
    }
}

extension ConcentrationController {
    var todayCommitment: FocusCommitmentCard? { commitmentCards.first { $0.commitment.period == .init(kind: .day, key: currentDay) } }
    var weekCommitment: FocusCommitmentCard? { commitmentCards.first { $0.commitment.period == .init(kind: .week, key: FocusCalendar.weekKey(clock(), calendar: calendar)) } }
    func commitCheck(_ value: FocusCommitment, replacing old: FocusCommitment) -> FocusCommitRule.Check {
        FocusCommitRule.check(old: old, new: value, now: stakeNow(), clock: clockState(), calendar: calendar)
    }
    private func clockState() -> BlockingClockState { .init(wall: clock(), continuous: continuous(), boot: boot()) }
    /// Persists `lockedAt` on every commitment whose free window is seen closed (T-044 C1-02), and
    /// `exitClosedAt` on every missed result whose exits are seen closed (C2-02).
    private func latchCommitmentLocks() throws {
        let now = stakeNow(), state = clockState()
        var next = commitments
        for i in next.indices where next[i].result == nil && next[i].lockedAt == nil {
            guard let deadline = FocusCommitRule.editUntil(next[i], calendar: calendar),
                  FocusCommitRule.windowClosed(next[i], deadline: deadline, now: now, clock: state) else { continue }
            next[i].lockedAt = now
        }
        for i in next.indices where next[i].result?.exitClosedAt == nil && exitUntil(next[i]) != nil && !exitOpen(next[i]) {
            next[i].result?.exitClosedAt = now
        }
        if next != commitments { try saveCommitmentValues(next) }
    }
    @discardableResult func setCommitment(period: FocusCommitmentPeriod, kind: FocusCommitment.Kind, target: Int,
                                         task: String? = nil, stake: FocusStake? = nil) throws -> FocusCommitment {
        try admit(); try latchCommitmentLocks()
        let old = commitments.first { $0.period == period }
        var value = FocusCommitment(id: old?.id ?? UUID(), period: period, kind: kind, target: target, task: task, stake: stake,
                                    createdAt: old?.createdAt ?? clock(), edits: old?.edits ?? [], result: old?.result,
                                    createdClock: old == nil ? clockState() : old?.createdClock, lockedAt: old?.lockedAt)
        guard value.valid else { throw FocusFailure.invalidArgument }
        if let old {
            if case .locked = FocusCommitRule.check(old: old, new: value, now: stakeNow(), clock: clockState(), calendar: calendar) { throw FocusFailure.locked }
            if old == value { return old }
            value.edits.append(.init(at: clock(), target: target, stake: stake))
            guard value.valid else { throw FocusFailure.invalidArgument }
        } else if !FocusCommitmentRules.mayCreate(period, at: clock(), realNow: realNow(), calendar: calendar) { throw FocusFailure.invalidArgument }
        if let stake, old?.stake != stake {
            guard let b = blocking() else { throw FocusFailure.moduleDisabled }
            guard Set(stake.listIds).isSubset(of: Set(b.lists.map(\.id))) else { throw FocusFailure.notFound }
        }
        try saveCommitmentValues(commitments.filter { $0.period != period } + [value]); refreshCommitmentCards()
        measurementRefresh?(); return value
    }
    func deleteCommitment(period: FocusCommitmentPeriod) throws {
        try admit(); try latchCommitmentLocks()
        guard let old = commitments.first(where: { $0.period == period }) else { throw FocusFailure.notFound }
        guard FocusCommitRule.check(old: old, new: nil, now: stakeNow(), clock: clockState(), calendar: calendar) == .free else { throw FocusFailure.locked }
        try saveCommitmentValues(commitments.filter { $0.id != old.id }); refreshCommitmentCards()
    }
    func useCommitmentJoker(period: FocusCommitmentPeriod) throws { try resolveCommitment(period: period, declare: false) }
    func declareCommitmentHeld(period: FocusCommitmentPeriod) throws { try resolveCommitment(period: period, declare: true) }
    private func resolveCommitment(period: FocusCommitmentPeriod, declare: Bool) throws {
        try admit(); blocking()?.refresh(enforceLast: false); try latchCommitmentLocks()
        guard let i = commitments.firstIndex(where: { $0.period == period }), var result = commitments[i].result else { throw FocusFailure.notFound }
        let value = commitments[i]
        guard exitOpen(value) else { throw FocusFailure.locked }
        if declare {
            guard FocusCommitmentRules.mayDeclare(value) else { throw FocusFailure.invalidArgument }
            result.outcome = .held; result.declared = true
        } else {
            guard FocusCommitmentRules.jokersLeft(period: period, commitments: commitments, settings: settings.jokerSettings, calendar: calendar) > 0 else { throw FocusFailure.locked }
            result.jokerAt = clock()
        }
        // Persist release intent first. Relaunch/retry can finish a release without losing the joker.
        // Only an applied stake is released: none or skipped has no block to lift (T-044 B2-01).
        if result.stake.state == .applied { result.stake = .init(state: .cancelled, blockId: result.stake.blockId, at: clock()) }
        var next = commitments; next[i].result = result
        try saveCommitmentValues(next)
        try reconcileCommitmentBlocks(); refreshCommitmentCards()
        if panel?.kind == .commitment { updateCommitmentPanel(panel!.commitmentIDs) }
    }
    private func saveCommitmentValues(_ values: [FocusCommitment]) throws {
        var retained = values
        try saving { retained = try store.saveCommitments(values) }; commitments = retained
        NotificationCenter.default.post(name: .goalongFocusCommitmentsDidChange, object: self)
    }
    /// In the wall frame of this controller: Blocking keeps its ends in its trusted frame.
    private func stakeBlockEnd(_ value: FocusCommitment) -> Date? {
        guard let b = blocking() else { return nil }
        return b.activeBlocks.first { $0.id == value.result?.stake.blockId }.map { b.wallFrame($0.end) }
    }
    private func exitUntil(_ value: FocusCommitment) -> Date? {
        FocusCommitmentRules.stakeWindow(value, blockEnd: stakeBlockEnd(value), calendar: calendar)
    }
    /// A running stake block is compared in Blocking's trusted frame (its end with `b.now`), anything else
    /// in this controller's frame.
    private func exitOpen(_ value: FocusCommitment) -> Bool {
        if let b = blocking(), let block = b.activeBlocks.first(where: { $0.id == value.result?.stake.blockId }) {
            return FocusCommitmentRules.exitOpen(value, blockEnd: block.end, now: b.now, clock: clockState(), calendar: calendar)
        }
        return FocusCommitmentRules.exitOpen(value, blockEnd: nil, now: stakeNow(), clock: clockState(), calendar: calendar)
    }
    /// The trusted now of stake decisions (T-044 r5, same rule as `BlockingClock.trusted`): the wall clock,
    /// never earlier than the time proven by continuous time in this boot. A clock set back cannot delay a
    /// settlement, reopen an exit or an edit. Stored dates stay in the wall frame.
    private func stakeNow() -> Date { max(clock(), realNow() ?? .distantPast) }
    /// Latest moment proven by continuous time since a stored anchor or the launch of this boot (T-044 C2-02).
    private func realNow() -> Date? {
        let state = clockState()
        return (commitments.flatMap { [$0.createdClock, $0.result?.settledClock] } + [launchClock])
            .compactMap { $0 }.filter { a in clockCorrection.map { a.boot != $0.boot || a.continuous >= $0.continuous } ?? true }
            .compactMap { FocusCommitRule.anchoredNow($0, clock: state) }.max()
    }
    /// C5-05: a wall clock found behind the proven time within `bootCorrectionWindow` of boot is a clock
    /// that was ahead and is now right. What was already decided stays latched (edit window, exits,
    /// results, and Blocking's own trusted clock); only what comes next reads the corrected time.
    /// Locks that cannot be saved refuse the correction: the next refresh in the window tries again.
    private func acceptBootClockCorrection() {
        let state = clockState()
        guard state.continuous <= Self.bootCorrectionWindow, let proven = realNow(), state.wall < proven.addingTimeInterval(-60) else { return }
        guard (try? latchCommitmentLocks()) != nil else { return }
        clockCorrection = state; launchClock = state
        try? store.saveClockCorrection(state); try? store.saveClockAnchor(state)
        lastCommitmentCardRefresh = .distantPast
    }
    func commitmentProgress(_ value: FocusCommitment, now decision: Date? = nil) throws -> FocusCommitmentProgress {
        let at = decision ?? clock()
        if let result = value.result {
            return .init(measured: result.measured, unmeasuredMinutes: result.unmeasuredMinutes, usesActiveTime: result.usesActiveTime ?? (value.kind == .work && !definitionAvailable))
        }
        guard let bounds = value.period.interval(calendar: calendar) else { throw FocusFailure.invalidArgument }
        if at <= bounds.start { return .init(usesActiveTime: value.kind == .work && !definitionAvailable) }
        var values: [FocusSession] = [], plans: [FocusPlan] = []
        if value.kind == .sessions {
            // Any older day can hold an open or long session, so every day is checked, but each file is decoded once.
            let days = try store.sessionDays(), listed = Set(days)
            sessionCache = sessionCache.filter { listed.contains($0.key) }
            for day in days where FocusCalendar.dayInterval(day, calendar: calendar)!.start < bounds.end {
                let decoded = try sessionCache[day] ?? store.sessions(day); sessionCache[day] = decoded
                values += decoded.filter { ($0.endedAt ?? at) > bounds.start }
            }
        }
        if value.kind == .plan {
            for day in try store.planDays() {
                let start = FocusCalendar.dayInterval(day, calendar: calendar)!.start
                if start >= bounds.start && start < bounds.end, let p = try store.plan(day) { plans.append(p) }
            }
        }
        return FocusCommitmentRules.progress(value, days: Array(measuredDays.values), sessions: values, plans: plans, at: at, hasDefinition: definitionAvailable, calendar: calendar)
    }
    private func settleCommitments() {
        do {
            var next = commitments, ids: [UUID] = []
            for i in next.indices where next[i].result == nil {
                guard let bounds = next[i].period.interval(calendar: calendar), bounds.end <= stakeNow() else { continue }
                // One decision time for admission, progress and settlement (never earlier than the period's end): a raw clock set
                // back would be refused by the rule while the id was still published. Wall frame, so no double compensation.
                let decision = max(clock(), bounds.end)
                let progress = try commitmentProgress(next[i], now: decision)
                next[i].result = FocusCommitmentRules.settle(next[i], progress: progress, at: decision, blockingOn: blocking() != nil,
                    listIDs: Set(blockLists.map(\.id)), calendar: calendar)
                guard next[i].result != nil else { continue }
                next[i].result?.settledClock = clockState()
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
                } else if result.stake.at == nil || end > stakeNow() {
                    let ids = stake.listIds.filter { b?.list($0) != nil }
                    let reason: FocusCommitmentResult.Stake.Reason?
                    if end <= stakeNow() { reason = .late }
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
            try latchCommitmentLocks()
            let day = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(clock(), calendar: calendar))
            let week = FocusCommitmentPeriod(kind: .week, key: FocusCalendar.weekKey(clock(), calendar: calendar))
            let series = FocusJokerSettings(day: FocusCommitmentRules.series(commitments, kind: .day, calendar: calendar), week: FocusCommitmentRules.series(commitments, kind: .week, calendar: calendar))
            let left = FocusJokerSettings(day: FocusCommitmentRules.jokersLeft(period: day, commitments: commitments, settings: settings.jokerSettings, calendar: calendar),
                week: FocusCommitmentRules.jokersLeft(period: week, commitments: commitments, settings: settings.jokerSettings, calendar: calendar))
            var reserves: [String: Int] = [:]
            let cards = try commitments.sorted { $0.period.key < $1.period.key }.map { value -> FocusCommitmentCard in
                let end = exitUntil(value), open = exitOpen(value)
                let reserveKey = value.period.kind.rawValue + (FocusCommitmentRules.jokerMonth(value.period, calendar: calendar) ?? "")
                let jokers = reserves[reserveKey] ?? FocusCommitmentRules.jokersLeft(period: value.period, commitments: commitments, settings: settings.jokerSettings, calendar: calendar)
                reserves[reserveKey] = jokers
                let limit = value.period.kind == .day ? settings.limits.dailyHours : settings.limits.weeklyHours
                let editMode: String
                switch FocusCommitRule.check(old: value, new: value, now: stakeNow(), clock: clockState(), calendar: calendar) {
                case .free: editMode = "free"
                case .harderOnly: editMode = "harderOnly"
                case .locked: editMode = "locked"
                }
                return FocusCommitmentCard(commitment: value, progress: try commitmentProgress(value), series: value.period.kind == .day ? series.day : series.week,
                    jokersLeft: jokers, canUseJoker: open && jokers > 0, canDeclare: open && FocusCommitmentRules.mayDeclare(value), exitUntil: end,
                    limitHours: (value.kind == .work || value.kind == .task) && limit.map({ value.target > $0 * 60 }) == true ? limit : nil,
                    editMode: editMode, editUntil: FocusCommitRule.editUntil(value, calendar: calendar)!)
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
