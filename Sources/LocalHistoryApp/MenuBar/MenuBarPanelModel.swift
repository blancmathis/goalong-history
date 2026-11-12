#if os(macOS)
import Ambiance
import Combine
import Foundation
import LocalHistoryCore

/// A projection of the app's existing controllers. It owns no capture or audio runtime.
@MainActor final class MenuBarPanelModel: ObservableObject {
    enum Tracking: Equatable { case active, paused(since: Date?), attention(String) }
    @Published var tracking: Tracking = .attention("Chargement")
    @Published var trackingDetail = "Chargement de l’état de l’enregistrement…"
    /// Title shown above the detail when the tracking needs attention, so the cause is never lost to truncation.
    var attentionTitle: String? { if case .attention(let title) = tracking { return title }; return nil }
    /// A one-tap repair that goes with the attention message or the unavailable-focus message.
    enum PanelFix {
        case permissions, modules, recording, app
        var label: String {
            switch self {
            case .permissions: return "Rétablir l’accès…"
            case .modules: return "Activer dans Réglages"
            case .recording: return "Ouvrir Réglages"
            case .app: return "Ouvrir Goalong"
            }
        }
    }
    @Published var attentionFix: PanelFix?
    @Published var focusUnavailableFix: PanelFix?
    func perform(_ fix: PanelFix) {
        switch fix {
        case .permissions: onOpenSettingsPane(.permissions)
        case .modules: openModulesSettings()
        case .recording: onOpenSettingsPane(.recording)
        case .app: openApp()
        }
    }
    /// Consent is off: the header action opens Réglages instead of pausing.
    @Published var consentOff = false
    /// Global pause is on: the header action opens Réglages, where the pause is lifted.
    @Published var globalPaused = false
    /// Header button label. During the global pause it says it opens Réglages.
    var headerActionLabel: String {
        if globalPaused { return "\(GoalongGlobalPauseText.resume)…" }
        if consentOff { return "Configurer l’enregistrement…" }
        if case .paused = tracking { return "Reprendre l’enregistrement" }
        return "Suspendre l’enregistrement"
    }

    struct DaySegment: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let kind: Kind
        enum Kind { case work, other, unclassified }
    }
    @Published var workSeconds: TimeInterval = 0
    /// Same rule as the Activity headline: work is unknown (« — »), never zero, until most active time is classified.
    @Published var workKnown = false
    @Published var otherSeconds: TimeInterval = 0
    @Published var segments: [DaySegment] = []
    @Published var nowFraction: Double = 0

    enum FocusKind: String, CaseIterable { case pomodoro, free }
    struct FocusRun: Equatable {
        var phaseTitle: String
        var remaining: TimeInterval?
        var elapsed: TimeInterval
        var progress: Double?
        var cycle: Int?
        var cycles: Int?
        var nextBreak: Date?
        var isPaused: Bool
    }
    @Published var focusAvailable = false
    @Published var concentrationEnabled = false
    @Published var focusUnavailableReason: String?
    @Published var focusKind: FocusKind = .pomodoro
    @Published var focusMinutes = 25
    let focusMinuteChoices = [25, 50, 90]
    @Published var focusRun: FocusRun?

    enum AmbianceTab: String, CaseIterable { case focus, relax, texture, ownFile }
    @Published var ambianceEnabled = false
    @Published var ambianceSources: [AmbianceSource] = []
    @Published var ambianceCurrent: AmbianceSource?
    @Published var ambiancePlaying = false
    @Published var ambianceLoading = false
    @Published var ambianceError: String?
    @Published var ambianceVolume: Double = 0.5 {
        didSet {
            let value = ambianceVolume.isFinite ? min(1, max(0, ambianceVolume)) : 0.5
            if value != ambianceVolume { ambianceVolume = value }
            guard !synchronizingVolume, modules.isEnabled(.ambiance),
                  let controller = ambianceModule.controller, controller.volume != value else { return }
            controller.volume = value
        }
    }

    /// One thing that runs now (T-050 B2c, point 13 and S5): a rule of the page « Blocages », the same object, or a block
    /// started outside a rule. The panel never weakens anything itself beyond what the page's switch does.
    struct LiveItem: Identifiable, Equatable {
        /// `now`: a « Libre » rule the page's switch turns off at once. `page`: its stop asks a proof, the page asks it.
        /// `none`: « Verrouillé », nothing stops it before its end (P4: no dead button).
        enum Stop: Equatable { case now, page, none }
        let id: String
        var title: String
        var detail: String
        var lock: BlockLock
        var stop: Stop
        /// D1b: what is left of its pauses, and the list a « Pause » button takes one from (nil = no button now).
        var pauses: String? = nil
        var pauseList: UUID? = nil
        var pauseMinutes: Int? = nil
        /// D1b: a session of the page that « + 15 min » prolongs in one click.
        var extendable = false
    }
    @Published var blockingEnabled = false
    @Published var live: [LiveItem] = []
    /// The rules behind `live`, kept to stop a « Libre » one with the page's own call.
    private var liveRules: [String: BlockRule] = [:]
    /// The « Surveillance » blocks of the rules: a rule that carries one has no single stop (the page hides its switch).
    var surveillanceRanges: @MainActor () -> [JevSurveillanceRange] = {
        let store = JevSurveillanceStore.shared
        return store.error == nil ? store.document.ranges : []
    }

    /// The « Écran rouge » line. Always shown: no module to enable. Changes apply at once.
    @Published private(set) var redScreen = RedScreenState()
    var hasRedScreen: Bool { redScreenControl != nil }
    func setRedScreen(_ on: Bool) { redScreenControl?.setRedScreen(on) }
    func setRedScreenIntensity(_ value: Double) {
        guard value.isFinite else { return }
        redScreenControl?.setRedScreenIntensity(value)
        // A protected range may hold the value (same state, nothing published): redraw so the thumb goes back to it.
        objectWillChange.send()
    }
    func setRedScreenFilterBrightness(_ value: Double) {
        guard value.isFinite else { return }
        redScreenControl?.setRedScreenFilterBrightness(value)
    }
    func openRedScreenSettings() { onOpenSection(.braise) }
    private let redScreenControl: (any RedScreenControlling)?
    private var redScreenWatch: AnyCancellable?

    private let state: CaptureState
    private let modules: GoalongModuleStore
    private let concentration: () -> ConcentrationController?
    private let ambianceModule: AmbianceModule
    private let blocking: () -> BlockingController?
    private let health: () -> CaptureHealthState
    private let suppression: () -> SuppressionReason?
    private let localHistoryEnabled: () -> Bool
    private let configUnreadable: () -> Bool
    private let globalPause: () -> GoalongGlobalPause
    private let clock: () -> Date
    private let calendar: Calendar
    private let loadDay: ((Date) async throws -> GoalongLocalAnalytics.Day)?
    private let playAmbiance: @MainActor (AmbianceController, AmbianceSource) -> Void
    private let onTogglePause: () -> Void
    /// T-050 B1 correction 2: the stop of the « Surveillance » the Concentration session carries. Tests replace it.
    var confirmSurveillanceStop: @MainActor () -> Bool = { JevStopGate.confirm(action: "Arrêter la séance", step: JevStopGate.focusStep()) }
    private let onOpenSection: (DashboardSection) -> Void
    /// The prepared sessions (T-050 B2) and the red screen they may hold. Renders give their own store.
    var prepared: PreparedSessionStore = .shared
    var braise: @MainActor () -> BraiseController? = { BraiseRuntime.shared.controller }
    private let onOpenSettingsPane: (SettingsPane) -> Void
    private let onOpenDay: () -> Void
    private let onShowClassicMenu: () -> Void
    private var pausedSince: Date?
    private var synchronizingVolume = false
    private var dayTask: Task<Void, Never>?
    private var dayGeneration = UUID()
    private var displayedDay: Date?

    init(state: CaptureState, modules: GoalongModuleStore, concentration: @escaping () -> ConcentrationController?,
         ambianceModule: AmbianceModule, blocking: @escaping () -> BlockingController?,
         health: @escaping () -> CaptureHealthState = { .ready },
         suppression: @escaping () -> SuppressionReason? = { nil },
         localHistoryEnabled: @escaping () -> Bool = { true },
         configUnreadable: @escaping () -> Bool = { false },
         globalPause: @escaping () -> GoalongGlobalPause = { GoalongGlobalPause.load() },
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
         loadDay: ((Date) async throws -> GoalongLocalAnalytics.Day)? = nil,
         playAmbiance: @escaping @MainActor (AmbianceController, AmbianceSource) -> Void = { $0.play($1) },
         onTogglePause: @escaping () -> Void, onOpenSection: @escaping (DashboardSection) -> Void,
         onOpenSettingsPane: ((SettingsPane) -> Void)? = nil,
         onOpenDay: @escaping () -> Void, onShowClassicMenu: @escaping () -> Void,
         redScreen: (any RedScreenControlling)? = nil) {
        self.redScreenControl = redScreen
        self.state = state; self.modules = modules; self.concentration = concentration
        self.ambianceModule = ambianceModule; self.blocking = blocking
        self.health = health; self.suppression = suppression; self.localHistoryEnabled = localHistoryEnabled
        self.configUnreadable = configUnreadable
        self.globalPause = globalPause; self.clock = clock; self.calendar = calendar; self.loadDay = loadDay
        self.playAmbiance = playAmbiance
        self.onTogglePause = onTogglePause; self.onOpenSection = onOpenSection
        self.onOpenSettingsPane = onOpenSettingsPane ?? { _ in onOpenSection(.settings) }
        self.onOpenDay = onOpenDay; self.onShowClassicMenu = onShowClassicMenu
        if let redScreen {
            self.redScreen = redScreen.redScreen
            redScreenWatch = redScreen.redScreenChanges.sink { [weak self] in self?.redScreen = $0 }
        }
    }

    /// Called on opening, then once a second only while the popover is visible.
    func refresh() {
        refreshRuntimeState()
        let now = clock(), day = calendar.startOfDay(for: now)
        nowFraction = fraction(now)
        if displayedDay != day {
            stopRefreshing(); displayedDay = day
            workSeconds = 0; workKnown = false; otherSeconds = 0; segments = []
        }
        guard dayTask == nil, let loadDay else { return }
        let generation = dayGeneration
        dayTask = Task { [weak self] in
            do {
                let value = try await loadDay(now)
                guard let self, !Task.isCancelled, self.dayGeneration == generation else { return }
                defer { self.dayTask = nil }
                guard self.calendar.isDate(value.date, inSameDayAs: self.clock()) else { return }
                self.applyDay(value)
            } catch {
                guard let self, !Task.isCancelled, self.dayGeneration == generation else { return }
                self.dayTask = nil
                self.workSeconds = 0; self.workKnown = false; self.otherSeconds = 0; self.segments = []
                self.trackingDetail += ", Journée indisponible"
            }
        }
    }

    func stopRefreshing() {
        dayTask?.cancel(); dayTask = nil; dayGeneration = UUID()
    }

    func refreshRuntimeState() {
        refreshTracking()
        refreshFocus()
        refreshAmbiance()
        refreshBlocking()
    }

    private func refreshTracking() {
        let pause = globalPause()
        consentOff = !pause.blocksActivity && !localHistoryEnabled()
        globalPaused = pause.blocksActivity
        attentionFix = nil
        // Same order as the classic menu: global pause, then consent (consent off also sets the manual pause), then manual pause.
        if pause.blocksActivity {
            if case .paused = tracking {} else { pausedSince = nil }
            tracking = .paused(since: pause.changedAt); trackingDetail = "Sources et envois suspendus"
        } else if configUnreadable() {
            pausedSince = nil
            tracking = .attention("Réglages illisibles")
            trackingDetail = ConfigManager.failClosedNotice
        } else if !localHistoryEnabled() {
            pausedSince = nil
            tracking = .attention("Enregistrement désactivé")
            trackingDetail = "Activez l’enregistrement dans Réglages"
        } else if state.isManuallyPaused {
            if case .paused = tracking {} else { pausedSince = nil }
            tracking = .paused(since: pausedSince); trackingDetail = "Enregistrement local suspendu"
        } else if [.storageUnavailable, .permissionRequired, .permissionAppearsEnabledButStaleForBuild,
                   .accessibilityContextUnavailable, .inputTapUnavailable, .awaitingInputEvidence].contains(health()) {
            let health = health()
            tracking = .attention(health.frenchTitle); trackingDetail = health.frenchDetail
            if health != .storageUnavailable && health != .awaitingInputEvidence { attentionFix = .permissions }
        } else if !state.isCapturing || suppression() == .sessionUnavailable {
            tracking = .attention("Session Mac inactive"); trackingDetail = "Le Mac est verrouillé, en veille ou indisponible"
        } else if suppression() == .accessibilityUnavailable {
            tracking = .attention("Navigateur non accessible")
            trackingDetail = "Cette fenêtre ne peut pas être lue en toute sécurité"
        } else {
            pausedSince = nil; tracking = .active; trackingDetail = "Enregistrement local actif"
        }
    }

    func togglePause() {
        let wasPaused = state.isManuallyPaused
        onTogglePause()
        if !wasPaused, state.isManuallyPaused { pausedSince = clock(); tracking = .paused(since: pausedSince) }
        refreshRuntimeState()
    }

    func applyDay(_ day: GoalongLocalAnalytics.Day) {
        workSeconds = day.seconds(.work); otherSeconds = day.seconds(.other)
        let active = day.activeSeconds
        workKnown = workSeconds > 0 || (active > 0 && (workSeconds + otherSeconds) / active >= 0.5)
        segments = day.segments.enumerated().compactMap { index, segment in
            let kind: DaySegment.Kind
            switch segment.kind {
            case .work: kind = .work
            case .other: kind = .other
            case .unclassified: kind = .unclassified
            case .idle, .concealed, .unobserved: return nil
            }
            let start = segment.start <= day.date ? 0 : fraction(segment.start)
            let end = segment.end >= day.end ? 1 : fraction(segment.end)
            guard end > start else { return nil }
            return DaySegment(id: index, start: start, end: end, kind: kind)
        }
    }

    /// Wall-clock coordinates match the view's 0/6/12/18/24 h labels, including DST days.
    private func fraction(_ date: Date) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hours = (parts.hour ?? 0) * 3600
        let minutes = (parts.minute ?? 0) * 60
        let seconds = Double(hours + minutes + (parts.second ?? 0))
        return min(1, max(0, seconds / 86400))
    }

    private func refreshFocus() {
        let enabled = modules.isEnabled(.concentration)
        concentrationEnabled = enabled
        let observing = state.isCapturing && localHistoryEnabled() && !globalPause().blocksActivity
        let controller = enabled ? concentration() : nil
        focusAvailable = enabled && observing && controller != nil
        focusUnavailableReason = !enabled ? "Activez Concentration dans Réglages."
            : !localHistoryEnabled() ? "Activez l’enregistrement dans Réglages."
            : !observing ? "Reprenez le suivi pour lancer une séance."
            : controller == nil ? "Concentration indisponible. Ouvrez l’app." : nil
        focusUnavailableFix = !enabled ? .modules : !localHistoryEnabled() ? .recording
            : (observing && controller == nil) ? .app : nil
        guard let controller else { focusRun = nil; return }
        controller.refresh()
        guard let session = controller.currentSession, let phase = controller.phase, phase.kind != .ended else {
            focusRun = nil; return
        }
        let now = clock(), elapsed = max(0, now.timeIntervalSince(session.startedAt))
        let duration = phase.endsAt.map { $0.timeIntervalSince(phase.startedAt) }
        let progress = duration.flatMap { $0 > 0 ? min(1, max(0, now.timeIntervalSince(phase.startedAt) / $0)) : nil }
        let title: String
        switch phase.kind {
        case .work: title = session.mode.kind == .pomodoro ? "Concentration" : "Séance libre"
        case .shortBreak: title = "Repos court"
        case .longBreak: title = "Repos long"
        case .ended: title = "Terminée"
        }
        focusRun = FocusRun(phaseTitle: title, remaining: phase.endsAt.map { max(0, $0.timeIntervalSince(now)) },
            elapsed: elapsed, progress: progress, cycle: session.mode.kind == .pomodoro ? phase.cycle : nil,
            cycles: session.mode.cycles, nextBreak: session.mode.kind == .pomodoro && phase.isWork ? phase.endsAt : nil,
            isPaused: false)
    }

    func startFocus() {
        refreshRuntimeState()
        guard modules.isEnabled(.concentration) else { openModulesSettings(); return }
        guard focusAvailable, let controller = concentration(), controller.currentSession == nil else { return }
        var mode = FocusMode()
        switch focusKind {
        case .pomodoro:
            guard focusMinuteChoices.contains(focusMinutes) else { return }
            mode.kind = .pomodoro; mode.workMinutes = focusMinutes; mode.cycles = 4
        case .free: mode.kind = .free; mode.minutes = nil
        }
        do { try controller.startSession(intent: "Concentration", mode: mode) }
        catch { controller.error = String(describing: error); onOpenSection(.concentration) }
        refreshFocus()
    }

    /// One click (P2): the session starts at once, or the page opens its window when its stop asks a confirmation.
    func launchPrepared(_ session: PreparedSession) {
        refreshRuntimeState()
        let focus = modules.isEnabled(.concentration) ? concentration() : nil
        switch PreparedSessionLauncher.launch(session, blocking: blocking(), braise: braise(), focus: focus, store: prepared) {
        case .started: refresh()
        case .needsEditor:
            prepared.request = session
            onOpenSection(.concentration)
        }
    }

    func pauseOrResumeFocus() {
        // FocusSession only persists start/skip/stop. Never fake a paused timer or release its blocks.
        onOpenSection(.concentration)
    }

    func stopFocus() {
        guard modules.isEnabled(.concentration), let controller = concentration() else { return }
        // T-050 B1 correction 2: a session that carries a protected « Surveillance » asks its stop.
        guard confirmSurveillanceStop() else { return }
        do { try controller.stopSession(surveillanceConfirmed: true) }
        catch { controller.error = String(describing: error); onOpenSection(.concentration) }
        refreshFocus(); refreshBlocking()
    }

    private func refreshAmbiance() {
        ambianceEnabled = modules.isEnabled(.ambiance) && ambianceModule.settings.isEnabled
        guard ambianceEnabled, let controller = ambianceModule.controller else {
            ambianceSources = []; ambianceCurrent = nil
            ambiancePlaying = false; ambianceLoading = false; ambianceError = nil
            return
        }
        ambianceSources = controller.sources
        // The controller omits uninstalled textures; the panel's contract includes unavailable sources.
        for (id, title) in [("rain", "Pluie douce"), ("ocean", "Marée"), ("brown", "Velours brun"),
                            ("pink", "Air rose"), ("aube", "Aube")] where !ambianceSources.contains(where: { $0.id == id && $0.kind == .texture }) {
            ambianceSources.append(AmbianceSource(id: id, title: title, kind: .texture, isAvailable: false))
        }
        ambiancePlaying = false; ambianceLoading = false; ambianceError = nil
        ambianceCurrent = ambianceSources.first { $0.id == ambianceModule.settings.lastSource }
        switch controller.state {
        case .playing(let source): ambianceCurrent = source; ambiancePlaying = true
        case .loading: ambianceLoading = true
        case .error(let message): ambianceError = message
        case .idle: break
        }
        synchronizingVolume = true; ambianceVolume = controller.volume; synchronizingVolume = false
    }

    func togglePlay() {
        refreshAmbiance()
        guard ambianceEnabled, let controller = ambianceModule.controller else { enableAmbiance(); return }
        if ambiancePlaying || ambianceLoading { controller.stop() }
        else if let source = ambianceCurrent ?? ambianceSources.first(where: { $0.isAvailable }) { playAmbiance(controller, source) }
        else { onOpenSection(.ambiance) }
        refreshAmbiance()
    }

    func playNext() {
        refreshAmbiance()
        guard ambianceEnabled else { enableAmbiance(); return }
        if let source = Self.nextSource(in: ambianceSources, after: ambianceCurrent) { play(source) }
    }

    static func nextSource(in sources: [AmbianceSource], after current: AmbianceSource?) -> AmbianceSource? {
        let kind = current?.kind ?? .focus
        let choices = sources.filter { $0.kind == kind && $0.isAvailable }
        guard !choices.isEmpty else { return nil }
        guard let index = choices.firstIndex(where: { $0.id == current?.id }) else { return choices[0] }
        return choices[(index + 1) % choices.count]
    }

    func play(_ source: AmbianceSource) {
        guard modules.isEnabled(.ambiance), let controller = ambianceModule.controller else { enableAmbiance(); return }
        playAmbiance(controller, source); refreshAmbiance()
    }

    /// Modules are switched on by the member in Réglages › Modules: enabling one can start a runtime or ask for a permission.
    func openModulesSettings() { onOpenSettingsPane(.modules) }

    func enableAmbiance() {
        if modules.isEnabled(.ambiance) { onOpenSection(.ambiance) } else { openModulesSettings() }
    }

    private func refreshBlocking() {
        blockingEnabled = modules.isEnabled(.blocking)
        let controller = blockingEnabled ? blocking() : nil
        controller?.refresh(enforceLast: false)
        let screen = braise(), now = clock()
        guard controller != nil || screen != nil else { live = []; liveRules = [:]; return }
        let rules = BlockRules.current(blocking: controller, braise: screen, jev: surveillanceRanges(), now: now, calendar: calendar)
            .filter { if case .running = $0.state { return true }; return false }
        liveRules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        live = rules.map { rule in
            let stop: LiveItem.Stop
            switch BlockRuleSwitch.of(rule, canVerifyPassword: controller != nil) {
            case .on(stop: .free): stop = .now
            default: stop = rule.lock == .locked ? .none : .page
            }
            var item = LiveItem(id: rule.id, title: rule.summary, detail: rule.stateText(now: now), lock: rule.lock, stop: stop,
                                pauses: rule.pauseBudget(blocking: controller))
            if let controller {
                let ranges = Set(rule.lists.flatMap(\.rangeIDs))
                let blocks = controller.activeBlocks.filter { if case .program(let id) = $0.origin { return ranges.contains(id) }; return false }
                Self.offerPause(&item, blocks: blocks, controller: controller)
            }
            return item
        }
        // Blocks started outside a rule (a prepared session, a commitment…). A session's own blocks show with the session.
        guard let controller else { return }
        let names = Dictionary(controller.lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for block in controller.activeBlocks where block.end > now {
            switch block.origin {
            case .program, .focus: continue
            case .manual, .commitment, .trigger: break
            }
            let what = BlockRule.joined(block.listIDs.compactMap { names[$0] })
            var item = LiveItem(id: block.id.uuidString, title: what.isEmpty ? "Blocage" : "Bloque \(what)",
                                detail: "En cours jusqu’à \(BlockingFormat.endTime(block.end))", lock: block.lock,
                                stop: block.lock == .locked ? .none : .page, extendable: controller.canExtend(block.id))
            item.pauses = block.listIDs.lazy.compactMap { controller.pauseBudget(listID: $0) }.first
            Self.offerPause(&item, blocks: [block], controller: controller)
            live.append(item)
        }
    }

    /// The first list of `blocks` with a pause to take now, as on the page (budget left, no pause running).
    private static func offerPause(_ item: inout LiveItem, blocks: [BlockingActiveBlock], controller: BlockingController) {
        for block in blocks {
            for id in block.listIDs where (block.breaksLeft[id] ?? 0) > 0 && block.breakEnds[id] == nil && block.pauses[id] != nil {
                guard let minutes = controller.pauseMinutes(listID: id), minutes > 0 else { continue }
                item.pauseList = id; item.pauseMinutes = minutes
                return
            }
        }
    }

    /// « Pause » of a line: the page's own call (a pause behind a text or a password opens its sheet in Goalong).
    func takeLivePause(_ id: String) {
        refreshBlocking()
        guard let list = live.first(where: { $0.id == id })?.pauseList, let controller = blocking() else { return }
        controller.breakFromVeil(listID: list)
        refreshBlocking()
    }

    /// « + 15 min » of a session line: stricter, at once (P3).
    func extendLive(_ id: String) {
        refreshBlocking()
        guard let item = live.first(where: { $0.id == id }), item.extendable, let uuid = UUID(uuidString: id),
              let controller = blocking() else { return }
        controller.extendSession(uuid)
        refreshBlocking()
    }

    /// « Arrêter » of a line of « En ce moment ». A « Libre » rule stops with the page switch's own call, which checks the
    /// rule's stop again and refuses without its proof. Anything else opens « Blocages », where its stop is asked.
    func stopLive(_ id: String) {
        refreshBlocking()
        guard let item = live.first(where: { $0.id == id }), item.stop != .none else { return }
        guard item.stop == .now, let rule = liveRules[id] else { onOpenSection(.blocking); return }
        let controller = blocking()
        if let refusal = BlockRuleSwitchAction.turnOff(rule, proof: .none, blocking: controller, braise: braise()) {
            controller?.error = refusal
            onOpenSection(.blocking)
        }
        refreshBlocking()
    }

    func openDay() { onOpenDay() }
    func openApp() { onOpenSection(.overview) }
    func openSettings() { onOpenSection(.settings) }
    func showClassicMenu() { onShowClassicMenu() }
}
#endif
