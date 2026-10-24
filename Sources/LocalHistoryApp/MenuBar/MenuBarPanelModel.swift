#if os(macOS)
import Ambiance
import Combine
import Foundation
import LocalHistoryCore

/// A projection of the app's existing controllers. It owns no capture or audio runtime.
@MainActor final class MenuBarPanelModel: ObservableObject {
    enum Tracking: Equatable { case active, paused(since: Date?), attention(String) }
    @Published var tracking: Tracking = .attention("Chargement")
    @Published var trackingDetail = "Chargement de l’état du suivi…"
    /// Title shown above the detail when the tracking needs attention, so the cause is never lost to truncation.
    var attentionTitle: String? { if case .attention(let title) = tracking { return title }; return nil }
    /// A one-tap repair that goes with the attention message or the unavailable-focus message.
    enum PanelFix {
        case permissions, modules, recording, app
        var label: String {
            switch self {
            case .permissions: return "Réparer…"
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
        if case .paused = tracking { return "Reprendre le suivi" }
        return "Mettre le suivi en pause"
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

    struct BlockList: Identifiable, Equatable {
        let id: String
        var title: String
        var detail: String
        var isActive: Bool
        var isLocked: Bool
    }
    @Published var blockingEnabled = false
    @Published var blockLists: [BlockList] = []

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
    private let onOpenSection: (DashboardSection) -> Void
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
         onOpenDay: @escaping () -> Void, onShowClassicMenu: @escaping () -> Void) {
        self.state = state; self.modules = modules; self.concentration = concentration
        self.ambianceModule = ambianceModule; self.blocking = blocking
        self.health = health; self.suppression = suppression; self.localHistoryEnabled = localHistoryEnabled
        self.configUnreadable = configUnreadable
        self.globalPause = globalPause; self.clock = clock; self.calendar = calendar; self.loadDay = loadDay
        self.playAmbiance = playAmbiance
        self.onTogglePause = onTogglePause; self.onOpenSection = onOpenSection
        self.onOpenSettingsPane = onOpenSettingsPane ?? { _ in onOpenSection(.settings) }
        self.onOpenDay = onOpenDay; self.onShowClassicMenu = onShowClassicMenu
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
                self.trackingDetail += " · Journée indisponible"
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
            tracking = .paused(since: pausedSince); trackingDetail = "Enregistrement local en pause"
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
        case .shortBreak: title = "Pause courte"
        case .longBreak: title = "Pause longue"
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

    func pauseOrResumeFocus() {
        // FocusSession only persists start/skip/stop. Never fake a paused timer or release its blocks.
        onOpenSection(.concentration)
    }

    func stopFocus() {
        guard modules.isEnabled(.concentration), let controller = concentration() else { return }
        do { try controller.stopSession() }
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
        guard blockingEnabled, let controller = blocking() else { blockLists = []; return }
        controller.refresh(enforceLast: false)
        blockLists = controller.lists.map { list in
            let active = controller.activeBlocks.filter { $0.listIDs.contains(list.id) }
            let locked = controller.isStricterOnly(list.id)
            let contents = "\(FrenchCount.count(list.sites.count, "site", "sites")) · \(FrenchCount.count(list.apps.count, "app", "apps"))"
            let detail = locked ? "Verrouillée · " + contents
                : active.isEmpty ? contents : "Active · " + contents
            return BlockList(id: list.id.uuidString, title: list.name, detail: detail,
                             isActive: !active.isEmpty, isLocked: locked)
        }
    }

    // SwiftUI's synchronous Binding setter can lose actor isolation in Swift 5 mode.
    // Marshal the whole action, including refresh/publication, before entering the engine.
    nonisolated func setBlockList(_ id: String, active: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { setBlockListOnMainActor(id, active: active) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setBlockListOnMainActor(id, active: active)
            }
        }
    }

    private func setBlockListOnMainActor(_ id: String, active: Bool) {
        guard modules.isEnabled(.blocking), let uuid = UUID(uuidString: id), let controller = blocking() else { return }
        controller.refresh(enforceLast: false)
        guard controller.list(uuid) != nil, !controller.isStricterOnly(uuid) else { refreshBlocking(); return }
        let blocks = controller.activeBlocks.filter { $0.listIDs.contains(uuid) }
        if active, blocks.isEmpty, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock())) {
            controller.start(listIDs: [uuid], until: end, lock: .free)
        } else if !active {
            // A shared session cannot be stopped for one list without changing the others.
            guard blocks.allSatisfy({ $0.listIDs.count == 1 && $0.lock == .free }) else { onOpenSection(.blocking); return }
            for block in blocks { controller.stop(block.id) }
        }
        if controller.error != nil { onOpenSection(.blocking) }
        refreshBlocking()
    }

    func requestStopBlocking(_ id: String) {
        guard let uuid = UUID(uuidString: id), blocking()?.list(uuid) != nil else { return }
        onOpenSection(.blocking)
    }

    func openDay() { onOpenDay() }
    func openApp() { onOpenSection(.overview) }
    func openSettings() { onOpenSection(.settings) }
    func showClassicMenu() { onShowClassicMenu() }
}
#endif
