#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine
import LocalHistoryCore

/// Daily review and longer-term perspective share one window-local selection.
struct GoalongAnalyticsPage: View {
    /// R14b: counts this body's evaluations in DashboardRestTests (off in the app).
    var bodyProbe = DashboardBodyProbe("activite")
    let model: DashboardViewModel
    @ObservedObject var navigationStore: DashboardNavigation
    @ObservedObject var settingsStore: DashboardSettingsState
    @ObservedObject var runtimeStore: DashboardRuntimeState
    @ObservedObject var snapshotStore: DashboardSnapshotStore

    init(model: DashboardViewModel, navigation: Binding<GoalongActivityNavigation>, analytics: GoalongAnalyticsModel) {
        self.model = model
        _navigationStore = ObservedObject(wrappedValue: model.navigationStore)
        _settingsStore = ObservedObject(wrappedValue: model.settingsStore)
        _runtimeStore = ObservedObject(wrappedValue: model.runtimeStore)
        _snapshotStore = ObservedObject(wrappedValue: model.snapshotStore)
        _navigation = navigation
        _analytics = ObservedObject(wrappedValue: analytics)
    }
    @Binding var navigation: GoalongActivityNavigation
    @ObservedObject var analytics: GoalongAnalyticsModel
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @StateObject private var developer = GoalongDeveloperModel()
    @StateObject private var system = GoalongSystemSourcesModel()
    /// The last complete read of calls, agenda, devices, Health and note, with its day; kept while the next one runs.
    @State private var shownSystem: (day: Date, value: GoalongSystemSourcesDay)?
    @State private var editingNote = false
    @State private var importingHealth = false
    @State private var focusMinutes = 25
    @State private var revision = 0
    @State private var manualRefreshRevision = 0
    @State private var laneRevision = 0
    @State private var showingDeveloperProjects = false
    @State private var forceNextRead = false
    @State private var showingAnalysisChoice = false
    @State private var reviewRequest: GoalongWorkReviewRequest?
    /// The named view of Activité on screen (nil = summary); kept when the day or period changes.
    @State private var detail: GoalongActivityDetail? = GoalongAnalyticsPage.initialDetail
    @AppStorage(GoalongDeveloperPreferences.enabledKey) private var developerMode = false
    #if DEBUG
    /// Test gallery only: the named view the page opens on (default: the summary).
    static var galleryDetail: GoalongActivityDetail?
    private static var initialDetail: GoalongActivityDetail? { galleryDetail }
    /// Test gallery only: the page opens on the developer preview (default: the page's own data).
    static var galleryStartsInPreview = false
    @State private var showingPreview = galleryStartsInPreview
    #else
    private static var initialDetail: GoalongActivityDetail? { nil }
    @State private var showingPreview = false
    #endif
    @State private var previewNavigation = GoalongActivityNavigation()
    /// R14a: the latest selection asked; a check that ends after a newer click is dropped.
    @State private var pendingSelection = 0
    /// The selection the last click asked for, while its check runs: the next click starts from it (R14a, N2: two quick
    /// « jour suivant » give J+2). A reference, so that a click does not update the page by itself.
    @State private var latestSelection = GoalongSelectionChain()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// Automatic refreshes of today wait at least ten times the last read duration, so a
    /// very busy day never keeps a core busy while the page is simply left open.
    @State private var lastReadSeconds: TimeInterval = 0
    @State private var lastAutomaticRefresh = Date.distantPast

    private var previewActive: Bool { developerMode && showingPreview }
    /// First day of every source: this Mac's history and the imported days, which can be older (R-265).
    /// The model owns the bound and the step, so the page cannot drop it (R272b-1).
    private var earliestDay: Date? {
        analytics.earliestDay(macDays: snapshotStore.snapshot.availableDays, preview: previewActive)
    }
    /// Disk full or unwritable: « Gérer le stockage… » in the top banner stays the only action.
    private var recordingInterrupted: Bool { !previewActive && runtimeStore.runtime.storageFailure != nil }
    private var shareBlockedReason: String? {
        guard !previewActive else { return nil }
        // Paused: nothing is read, so there is nothing to share yet (same grey button as an empty day).
        if analytics.paused { return "Tout le suivi en pause : rien à partager pour l’instant" }
        guard let payload = analytics.payload, selection.matches(payload, preview: false) else { return nil }
        return payload.current.observedSeconds > 0 ? nil : "Rien à partager ce jour-là"
    }
    private var selection: GoalongActivityNavigation { previewActive ? previewNavigation : navigation }
    private var selectionID: String { "\(selection.day.timeIntervalSince1970)|\(selection.period)|\(previewActive)" }
    private var loadRequest: GoalongAnalyticsLoadRequest {
        GoalongAnalyticsLoadRequest(day: selection.day, count: selection.period,
            revision: revision, preview: previewActive, dashboardIsVisible: runtimeStore.dashboardIsVisible)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The Apple sub-page is not driven by the period or the day: it keeps its own title and one way back (UI-17C, écran 15).
            if detail != .screenTime {
                GoalongActivityHeader(selection: selection, isPreview: previewActive, isRefreshing: analytics.busy,
                    shareBlockedReason: shareBlockedReason,
                    // R-265, UI-17A M3: one bound for the calendar, « précédent » and every period's step.
                    earliestDay: earliestDay,
                    onDay: { day in updateSelection { $0.selectDay(day) } },
                    onPeriod: { period in
                        GoalongSwitchTiming.begin("activite-\(period)j")
                        updateSelection { $0.selectPeriod(period) }
                    },
                    onStep: { direction in
                        updateSelection { analytics.step(&$0, direction, macDays: snapshotStore.snapshot.availableDays, preview: previewActive) }
                    },
                    onToday: { updateSelection { $0.today() } },
                    onReturn: { updateSelection { $0.restorePeriod() } },
                    onRefresh: refresh,
                    onShare: {
                        guard !previewActive else { return }
                        model.selectDay(selection.day)
                        navigationStore.showingWebsiteShare = true
                    })
                Rectangle().fill(LHTheme.separator).frame(height: 1)
            }
            ScrollViewReader { scroller in
                ScrollView {
                    // R14a: lazy, so a click builds and measures what the window shows, not the whole period.
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Color.clear.frame(height: 0).id("activity-top")
                        if !previewActive {
                            GoalongRecordingStateNotice(model: model)
                            ConcentrationActivityMarks(day: selection.day)
                        }
                        if developerMode && !previewActive { previewControl }
                        if previewActive { GoalongAnalyticsPreviewBanner(onExit: { showingPreview = false }) }
                        if analytics.paused {
                            // R-74 (R9C-39): the window's pause banner holds the title and the one resume button;
                            // the page only says what the pause means for these figures.
                            if analytics.payload == nil {
                                GoalongNote("Vos durées reviennent ici dès que le suivi reprend.", symbol: "pause.circle")
                                    .accessibilityIdentifier("activity-read-paused")
                            } else {
                                GoalongNote("Chiffres figés pendant la pause : ils seront actualisés dès la reprise.", symbol: "pause.circle")
                                    .accessibilityIdentifier("activity-read-paused")
                            }
                        } else if let error = analytics.error {
                            HStack(alignment: .center, spacing: 12) {
                                GoalongNote(error, tone: .warning)
                                Button("Réessayer", action: refresh).buttonStyle(LHSecondaryButtonStyle())
                            }
                        }
                        if detail != nil && !showsContent {
                            // While reading or after an error, a named view still offers its way back.
                            Button { detail = nil } label: { Label("Activité", systemImage: "chevron.left") }
                                .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                        }
                        if let payload = analytics.payload, selection.matches(payload, preview: previewActive) {
                            GoalongAnalyticsContent(payload: payload, focusMinutes: $focusMinutes,
                                lanes: lanes,
                                workStatus: previewActive ? .preview : workStatus,
                                recording: previewActive ? nil : recordingKind,
                                storageStop: previewActive ? nil : runtimeStore.runtime.storageFailure.map {
                                    GoalongActivityEmptyCopy.StorageStop(kind: $0, since: runtimeStore.runtime.storageInterruptedSince)
                                },
                                onDay: { day in updateSelection { $0.openDay(day) } },
                                onWork: { model.selectSection(.work) },
                                onReview: { task in if !previewActive { reviewRequest = GoalongWorkReviewRequest(day: selection.day, task: task) } },
                                onClassify: { agent.classify(day: GoalongWorkAgent.manualTarget(days: payload.current.days, fallback: selection.day)) },
                                onHistory: { openHistory(selection.day) },
                                onProjects: { if !previewActive { showingAnalysisChoice = true } },
                                onHistoryDay: openHistory,
                                onRecap: openRecap,
                                detail: $detail)
                                .id(selectionID)
                        } else if analytics.paused {
                            EmptyView()
                        } else if analytics.error == nil && !loadRequest.permitsLoading {
                            GoalongNote("Lecture en attente : cliquez dans cette fenêtre pour lire les observations de cette période. Les lectures privées restent suspendues lorsque vous utilisez une autre application.",
                                        symbol: "pause.circle")
                                .accessibilityIdentifier("activity-read-waiting-for-focus")
                        } else if analytics.error == nil {
                            GoalongPageLoadingView(title: "Lecture des observations locales…",
                                message: "Les durées sont calculées sur ce Mac, sans envoyer votre historique.")
                                .accessibilityIdentifier("analytics-primary-loading-motion")
                        }
                        if !previewActive {
                            // A choice of details, not an alert: after the hero, never in a named view (back link first).
                            GoalongRecordingCoverageNotice(model: model, dismissible: true,
                                hidden: recordingInterrupted || detail != nil
                                    || !GoalongRecordingCoverageNotice.showsOnActivity(recording: recordingKind, globallyPaused: analytics.paused))
                        }
                        if !previewActive && detail == .screenTime {
                            if selection.period == 1 {
                                GoalongActivityAppleCard(model: model, day: navigation.day,
                                    refreshRevision: manualRefreshRevision)
                                if let devices = lanes.otherDevices { GoalongOtherDevicesSection(value: devices) }
                            } else {
                                LHCard(padding: 16) {
                                    HStack(alignment: .center, spacing: 14) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("Temps d’écran Apple").font(.system(size: 13, weight: .semibold))
                                            Text("Source distincte, consultée par journée et jamais additionnée aux observations Goalong.")
                                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 8)
                                        Button("Consulter le \(navigation.day.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)))") {
                                            model.selectDay(navigation.day)
                                            model.selectSection(.screenTime)
                                        }.buttonStyle(LHSecondaryButtonStyle()).controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 1080, alignment: .leading)
                    // UI-9 (8): a named view starts 28 pt under the header, like other pages, not 56 pt: the
                    // top anchor above already adds one spacing of 24 pt. The summary starts 40 pt under the rule, not 48 (UI-14, écran 13/17).
                    .padding(.horizontal, LHTheme.pageInset).padding(.top, detail == nil ? 16 : 4).padding(.bottom, LHTheme.pageBottomInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: detail) { shown in
                    // A named view opens at its top; the summary comes back where its links are.
                    DispatchQueue.main.async {
                        scroller.scrollTo(shown == nil ? "activity-explore" : "activity-top", anchor: shown == nil ? .center : .top)
                    }
                }
            }
        }
        .background(LHTheme.pageBackground)
        .sheet(item: $reviewRequest) { request in GoalongWorkReviewSheet(request: request).goalongControls() }
        .sheet(isPresented: $showingDeveloperProjects) { GoalongDeveloperProjectsSheet().goalongControls() }
        .sheet(isPresented: $editingNote) {
            GoalongDayNoteSheet(day: selection.day, initial: systemValue?.note ?? "",
                                onSave: { try system.setNote($0, day: selection.day); laneRevision += 1 },
                                onDelete: { try system.deleteNote(day: selection.day); laneRevision += 1 })
                .goalongControls()
        }
        .sheet(isPresented: $importingHealth, onDismiss: { laneRevision += 1 }) { GoalongHealthImportSheet().goalongControls() }
        .confirmationDialog("Analyser la journée du \(GoalongUIFormat.day(navigation.day))",
                            isPresented: $showingAnalysisChoice, titleVisibility: .visible) {
            Button("Bilan quotidien et sources…") { openRecap(navigation.day) }
            Button("Projets et avancées…") {
                guard !previewActive else { return }
                model.profileStudio.show(localOnly: true, initialDay: navigation.day, earliestDay: snapshotStore.snapshot.availableDays.min())
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Choisissez le type d’analyse. Les sources et les autorisations restent à vérifier avant toute génération.")
        }
        .onAppearWhenShown {
            // The page is rebuilt on each section change: a day that turned while it was away counts too.
            followCalendarDay()
            model.selectDay(navigation.day)
        }
        .taskWhenShown(id: "\(revision)|\(laneRevision)") {
            // A Santé import or a new Temps d’écran day can move the first day back (R-265), read in the
            // model's own data folder, never AppPaths directly (R272b-2).
            await analytics.refreshImportedFirstDay()
        }
        .taskWhenShown(id: loadRequest) {
            let request = loadRequest
            guard request.permitsLoading else { return }
            let force = forceNextRead
            forceNextRead = false
            let started = ProcessInfo.processInfo.systemUptime
            await analytics.load(request, force: force, verdicts: work.verdicts)
            lastReadSeconds = ProcessInfo.processInfo.systemUptime - started
            if !Task.isCancelled, !request.isPreview {
                GoalongSwitchTiming.end("activite-\(request.count)j", stage: "data", last: true)
                // Overview shows this page too: its measure closes only on a read made for it (R13c).
                if navigationStore.selectedSection == .overview {
                    GoalongSwitchTiming.end(DashboardSection.overview.rawValue, stage: "data", last: true)
                }
            }
            // Contexts seen for the first time are classified in the background, at most
            // once per day shown (today: every 15 minutes), only with the user's consent.
            if !request.isPreview, let payload = analytics.payload, !Task.isCancelled {
                agent.classifyIfNeeded(payload.current.days)
            }
            // R13c: the other periods of this day are read once in the background, so that a first switch to them
            // is shown from memory too. A new selection cancels this task and the preload with it.
            if !request.isPreview, !Task.isCancelled, analytics.error == nil, !analytics.paused {
                await analytics.preloadOtherPeriods(day: request.day, count: request.count, verdicts: work.verdicts)
            }
        }
        .taskWhenShown(id: laneKey) {
            // Day-only sources, read beside the observations; never mixed into active time.
            guard loadRequest.permitsLoading, !previewActive, selection.period == 1,
                  consents.isEnabled(.aiConversations) || consents.isEnabled(.developerActivity) else { return }
            let day = selection.day, overview = model.agentActivityRuntime.overview
            await developer.refresh(day: day, agents: Calendar.current.isDate(overview.day, inSameDayAs: day) ? overview : nil)
        }
        .taskWhenShown(id: systemKey) {
            // Calls, agenda, other devices, Health and the note; the Mac's day gives its gaps.
            guard loadRequest.permitsLoading, let day = observedDay else { return }
            await system.refresh(day: day)
            guard !Task.isCancelled else { return }
            shownSystem = system.value.map { (day.date, $0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongDeveloperProjectsDidChange)) { _ in
            if !previewActive { laneRevision += 1 }
        }
        .onChange(of: developerMode) { enabled in
            if !enabled { showingPreview = false; previewNavigation = GoalongActivityNavigation() }
        }
        .onDisappear {
            showingPreview = false
            showingAnalysisChoice = false
            reviewRequest = nil
            previewNavigation = GoalongActivityNavigation()
        }
        .onChange(of: work.verdicts) { _ in
            // Re-applies the verdicts to cached days; no journal is read again.
            if !previewActive { revision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongProfileAnalysisDidSave)) { _ in
            if !previewActive { revision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in
            if !previewActive { revision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if runtimeStore.dashboardIsVisible && !previewActive { revision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
            followCalendarDay()
        }
        .onReceiveWhileShown(refreshTimer) { _ in
            // Also catches a missed day-change notification (sleep across midnight).
            followCalendarDay()
            // Visible-page refresh only. Completed days reuse the existing cache.
            guard runtimeStore.dashboardIsVisible, !previewActive, !analytics.busy,
                  GoalongToday.isToday(navigation.day),
                  Date().throttleElapsed(since: lastAutomaticRefresh) >= max(30, lastReadSeconds * 10) else { return }
            lastAutomaticRefresh = Date()
            revision += 1
        }
    }

    private var showsContent: Bool {
        analytics.payload.map { selection.matches($0, preview: previewActive) } ?? false
    }

    private var laneKey: String {
        [selection.day.timeIntervalSince1970.description, "\(selection.period)", "\(revision)", "\(laneRevision)",
         "\(previewActive)", "\(loadRequest.permitsLoading)", "\(consents.isEnabled(.aiConversations))",
         "\(consents.isEnabled(.developerActivity))"].joined(separator: "|")
    }

    /// The Mac's day on screen, once read: the system sources need its gaps.
    private var observedDay: GoalongLocalAnalytics.Day? {
        guard !previewActive, selection.period == 1, let day = analytics.payload?.current.days.first,
              Calendar.current.isDate(day.date, inSameDayAs: selection.day) else { return nil }
        return day
    }

    private var systemKey: String {
        [selection.day.timeIntervalSince1970.description, "\(laneRevision)", "\(manualRefreshRevision)",
         "\(loadRequest.permitsLoading)", observedDay.map { "\($0.segments.count)|\($0.lastObservation?.timeIntervalSince1970 ?? 0)" } ?? "-",
         "\(settingsStore.appliedSettings.captureCallPresence)", "\(consents.isEnabled(.calendar))",
         "\(consents.isEnabled(.localComputerHistory))", "\(consents.isEnabled(.appleScreenTime))"].joined(separator: "|")
    }

    private var systemValue: GoalongSystemSourcesDay? {
        guard selection.period == 1, let shown = shownSystem, Calendar.current.isDate(shown.day, inSameDayAs: selection.day) else { return nil }
        return shown.value
    }

    /// The sources of the day shown, each separate from the observations.
    private var lanes: GoalongActivityLanes {
        if previewActive { return GoalongAnalyticsPreview.lanes(day: selection.day) }
        let ai = consents.isEnabled(.aiConversations), followsProjects = consents.isEnabled(.developerActivity)
        var lanes = GoalongActivityLanes(editNote: { editingNote = true }, allowCalendar: allowCalendar,
                                         openSettings: { model.openRecordingSettings() },
                                         chooseProjects: { showingDeveloperProjects = true })
        if selection.period == 1, ai || followsProjects, let value = developer.value,
           Calendar.current.isDate(value.day, inSameDayAs: selection.day) {
            lanes.code = GoalongCodeDay(value)
        }
        if let value = systemValue {
            lanes.agenda = GoalongAgendaDay(calls: value.calls, calendar: value.calendar,
                                            calendarPermission: system.calendarPermission, remindersPermission: system.remindersPermission)
            lanes.sleep = GoalongSleepDay(value.health)
            lanes.otherDevices = GoalongOtherDevicesDay(value.otherDevices)
            lanes.note = value.note
            if case .failed = value.noteStatus {} else { lanes.noteAvailable = true }
        }
        lanes.sources = sourceRows(ai: ai, followsProjects: followsProjects)
        return lanes
    }

    /// Asks macOS once; after a refusal only System Settings can give the access back.
    private func allowCalendar() {
        guard !previewActive else { return }
        if [system.calendarPermission, system.remindersPermission].contains(.permissionDenied) {
            GoalongCalendarSettings.open()
        } else {
            Task { await system.requestCalendarPermissions(); laneRevision += 1 }
        }
    }

    private func sourceRows(ai: Bool, followsProjects: Bool) -> [GoalongSourceRow] {
        let settings = { model.openRecordingSettings() }
        let isDay = selection.period == 1
        let value = isDay ? developer.value.flatMap { Calendar.current.isDate($0.day, inSameDayAs: selection.day) ? $0 : nil } : nil
        let macState = GoalongSourceRow.macState(consentEnabled: consents.isEnabled(.localComputerHistory),
                                                 runtime: runtimeStore.runtime.state)
        var rows = [GoalongSourceRow(id: "mac", title: "Activité de ce Mac", state: macState,
                                     detail: "Applications, sites et saisie : la source du temps actif.",
                                     actionTitle: macState == .off ? "Activer…" : macState == .needsPermission ? "Autorisations…" : nil,
                                     action: macState == .off ? settings
                                        : { model.selectSection(.settings); navigationStore.settingsPane = .permissions })]
        rows += systemRows(settings: settings)
        if !ai {
            rows.append(.init(id: "agents", title: "Conversations d’agents", state: .off,
                              detail: GoalongAgentSourceCopy.off,
                              actionTitle: "Activer…", action: settings))
        } else {
            let conversations = value.map { $0.agents.projects.reduce(0) { $0 + $1.sessions } + $0.agents.unassignedSessions }
            rows.append(.init(id: "agents", title: "Conversations d’agents", state: .ready,
                              detail: conversations.map { GoalongCodeDay.count($0, "conversation", "conversations") + " ce jour-là." }
                                  ?? GoalongAgentSourceCopy.on))
            if !developer.t3Discovered {
                rows.append(.init(id: "t3", title: "T3 Code", state: .unavailable, detail: "T3 Code n’est pas installé sur ce Mac."))
            } else if let t3 = value?.t3 {
                let requests = t3.projects.reduce(0) { $0 + $1.requests }
                let detail: String
                switch t3.status {
                case .ready, .partial:
                    detail = GoalongCodeDay.count(requests, "demande", "demandes") + " ce jour-là, dans "
                        + GoalongCodeDay.count(t3.projects.count, "projet", "projets") + "."
                        + (t3.status == .partial ? " Lecture partielle : certaines activités T3 n’ont pas pu être lues en entier." : "")
                case .noData: detail = "Aucune demande ce jour-là."
                case .unsupported: detail = "Cette version de T3 Code n’est pas encore prise en charge. Mettez T3 Code à jour ou attendez la prochaine version de Goalong."
                case .failed(let reason): detail = reason
                default: detail = "Demandes et tours par projet, sans lire les messages."
                }
                rows.append(.init(id: "t3", title: "T3 Code", state: .init(t3.status), detail: detail))
            } else {
                rows.append(.init(id: "t3", title: "T3 Code", state: .ready, detail: "Demandes et tours par projet, lus pour une journée à la fois."))
            }
        }
        if !followsProjects {
            rows.append(.init(id: "projects", title: "Projets de développement", state: .off,
                              detail: "Commits et nombre de fichiers modifiés dans les projets que vous choisissez.",
                              actionTitle: "Activer…", action: settings))
        } else if developer.selectedProjects.isEmpty {
            rows.append(.init(id: "projects", title: "Projets de développement", state: .noData,
                              detail: "Aucun projet suivi.", actionTitle: "Choisir les projets…", action: { showingDeveloperProjects = true }))
        } else {
            let state = value.map { GoalongSourceRow.State($0.developerStatus) } ?? .ready
            var detail = GoalongCodeDay.count(developer.selectedProjects.count, "projet suivi", "projets suivis") + " : commits et fichiers modifiés."
            if case .failed(let reason)? = value?.developerStatus { detail = reason }
            if value?.developerStatus == .permissionDenied { detail = "Accès refusé à un dossier de projet." }
            rows.append(.init(id: "projects", title: "Projets de développement", state: state,
                              detail: detail, actionTitle: "Choisir les projets…", action: { showingDeveloperProjects = true }))
        }
        return rows
    }

    /// Calls, agenda, other devices and Health, each with its state and at most one action.
    private func systemRows(settings: @escaping () -> Void) -> [GoalongSourceRow] {
        let value = systemValue
        var rows: [GoalongSourceRow] = []
        let callsPurpose = "L’heure et l’app qui utilise le micro ou la caméra. Ni son, ni image."
        if !consents.isEnabled(.localComputerHistory) || !settingsStore.appliedSettings.captureCallPresence {
            rows.append(.init(id: "calls", title: "Appels", state: .off, detail: callsPurpose, actionTitle: "Activer…", action: settings))
        } else if let calls = value?.calls {
            let total = calls.unionSeconds >= 60 ? GoalongAnalyticsFormatting.duration(calls.unionSeconds) + " d’appels ce jour-là." : "Aucun appel enregistré ce jour-là."
            let detail: String
            switch calls.status {
            case .unsupported: detail = "Ce Mac ne permet pas de savoir quand le micro sert."
            case .failed(let reason): detail = reason
            case .partial: detail = total + " Lecture partielle : un micro ne dit pas quelle app l’utilise."
            default: detail = total
            }
            rows.append(.init(id: "calls", title: "Appels", state: .init(calls.status), detail: detail))
        } else {
            rows.append(.init(id: "calls", title: "Appels", state: .ready, detail: callsPurpose))
        }
        let agendaPurpose = "Événements et rappels terminés, lus sur ce Mac sans rien modifier."
        let permissions = [system.calendarPermission, system.remindersPermission]
        if !consents.isEnabled(.calendar) {
            rows.append(.init(id: "calendar", title: "Agenda et rappels", state: .off, detail: agendaPurpose, actionTitle: "Activer…", action: settings))
        } else if permissions.contains(where: { $0 != .ready }) {
            rows.append(.init(id: "calendar", title: "Agenda et rappels", state: .needsPermission,
                              detail: "macOS n’a pas donné l’accès à l’agenda ou aux rappels.",
                              actionTitle: permissions.contains(.permissionDenied) ? "Ouvrir Réglages Système…" : "Autoriser…", action: allowCalendar))
        } else if let calendar = value?.calendar {
            var detail = GoalongCodeDay.count(calendar.events.filter(\.isPlannedBusy).count, "événement prévu", "événements prévus")
                + " et " + GoalongCodeDay.count(calendar.completedReminders.count, "rappel terminé", "rappels terminés") + " ce jour-là."
            if case .failed(let reason) = calendar.status { detail = reason }
            rows.append(.init(id: "calendar", title: "Agenda et rappels", state: .init(calendar.status), detail: detail))
        } else {
            rows.append(.init(id: "calendar", title: "Agenda et rappels", state: .ready, detail: agendaPurpose))
        }
        let devicesPurpose = "iPhone et iPad, par Temps d’écran Apple : l’écran allumé pendant les trous du Mac."
        if !consents.isEnabled(.appleScreenTime) {
            rows.append(.init(id: "devices", title: "Autres appareils Apple", state: .off, detail: devicesPurpose, actionTitle: "Activer…", action: settings))
        } else if let lane = value?.otherDevices {
            let gaps = lane.devices.reduce(0) { $0 + $1.duringMacGapsSeconds }
            var detail = lane.devices.isEmpty ? "Aucun autre appareil pour cette date."
                : GoalongCodeDay.count(lane.devices.count, "appareil", "appareils")
                    + (gaps >= 60 ? ", \(GoalongAnalyticsFormatting.duration(gaps)) d’écran pendant les trous du Mac." : ".")
            if case .failed(let reason) = lane.status { detail = reason }
            rows.append(.init(id: "devices", title: "Autres appareils Apple", state: .init(lane.status), detail: detail))
        } else {
            rows.append(.init(id: "devices", title: "Autres appareils Apple", state: .ready, detail: devicesPurpose))
        }
        // An import is a snapshot by nature: it reads as ready once it exists.
        switch value?.health.status {
        case .ready?, .partial?:
            rows.append(.init(id: "health", title: "Apple Santé (import)", state: .ready,
                              detail: "Import pour cette date : sommeil, pas et séances.", actionTitle: "Importer…", action: { importingHealth = true }))
        case .failed(let reason)?:
            rows.append(.init(id: "health", title: "Apple Santé (import)", state: .failed, detail: reason,
                              actionTitle: "Importer…", action: { importingHealth = true }))
        default:
            rows.append(.init(id: "health", title: "Apple Santé (import)", state: .noData,
                              detail: "Aucun import pour cette date. Goalong ne lit pas Santé en continu.",
                              actionTitle: "Importer…", action: { importingHealth = true }))
        }
        return rows
    }

    private var workStatus: GoalongWorkStatus {
        GoalongWorkStatus(hasDefinition: !work.definition.isEmpty, isClassifying: agent.isRunning,
            progress: agent.progress, problem: agent.isRunning ? nil : (agent.lastError ?? (agent.readiness == .ready ? nil : agent.readiness.message)),
            classifiesOnOpen: work.automatic && agent.readiness == .ready)
    }

    /// The same reading as the recording banner, so the page body never contradicts it.
    private var recordingKind: GoalongRecordingStateNotice.Kind? {
        GoalongRecordingStateNotice.kind(localEnabled: consents.isEnabled(.localComputerHistory),
            globallyPaused: analytics.paused,
            dashboardVisible: runtimeStore.recordingStatusIsLive, runtime: runtimeStore.runtime.state,
            captureHealth: runtimeStore.runtime.captureHealth?.state)
    }

    /// UI-52: one way in; the preview banner has the one way out. The mode is a plain neutral mark, not a capsule
    /// that reads as a button.
    private var previewControl: some View {
        HStack(spacing: 12) {
            Button {
                showingAnalysisChoice = false
                previewNavigation = navigation
                showingPreview = true
            } label: {
                Label("Aperçu avec données fictives", systemImage: "testtube.2")
            }
            .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small).accessibilityIdentifier("analytics-preview-toggle")
            Spacer(minLength: 0)
            Label("Mode développeur", systemImage: "hammer")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .accessibilityIdentifier("analytics-developer-mode")
        }
    }

    /// A page left on today moves to the new today at midnight (same period); the day that just
    /// ended is read once more. A past day chosen by the user stays as it is.
    private func followCalendarDay(now: Date = GoalongToday.now) {
        let shown = navigation.day
        guard navigation.followToday(now: now) else { return }
        if !previewActive, navigation.day != shown { model.selectDay(navigation.day) }
        if !previewActive { revision += 1 }
    }

    private func updateSelection(_ change: (inout GoalongActivityNavigation) -> Void) {
        if previewActive { change(&previewNavigation); return }
        var next = latestSelection.base(navigation); change(&next)
        pendingSelection += 1
        let token = pendingSelection
        latestSelection.ask(next, token: token)
        guard analytics.hasSnapshot(day: next.day, count: next.period) else { commitSelection(next, token: token); return }
        // R14a: the last complete read of the new period is checked against its files off the main thread, then
        // goes on screen in the same turn as the new selection (one layout, never a stale figure); read again after.
        GoalongAnalyticsModel.selectionsPending += 1
        let verdicts = work.verdicts
        Task { @MainActor in
            defer { GoalongAnalyticsModel.selectionsPending -= 1 }
            let match = await analytics.verifySnapshot(day: next.day, count: next.period, verdicts: verdicts)
            guard token == pendingSelection else { return }  // a newer click won
            commitSelection(next, token: token)
            analytics.showVerified(day: next.day, count: next.period, match: match)
        }
    }
    private func commitSelection(_ next: GoalongActivityNavigation, token: Int) {
        latestSelection.committed(token: token)
        navigation = next; model.selectDay(next.day)
    }
    private func openHistory(_ day: Date) {
        guard !previewActive else { return }
        model.selectDay(day)
        model.selectSection(.history)
    }
    private func openRecap(_ day: Date) {
        guard !previewActive else { return }
        model.selectDay(day)
        model.selectSection(.chatGPTRecap)
    }
    private func refresh() {
        forceNextRead = true
        revision += 1
        if !previewActive {
            manualRefreshRevision += 1
            model.refreshEverything()
        }
    }
}

struct GoalongAnalyticsPreviewBanner: View {
    var onExit: () -> Void = {}
    var body: some View {
        LHCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Aperçu développeur, données fictives", systemImage: "testtube.2")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.text)
                    Spacer(minLength: 8)
                    Button("Quitter l’aperçu", action: onExit).buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("analytics-preview-exit")
                }
                Text("Aucune donnée personnelle n’est lue par cet aperçu. Rien n’est ajouté à l’historique ; le partage et l’analyse IA sont désactivés.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("analytics-preview-banner")
    }
}
#endif

/// Codex and Claude Code transcripts are read on this Mac (text of visible messages); T3 Code is read as metadata only.
enum GoalongAgentSourceCopy {
    static let off = "Codex, Claude Code et T3 Code : nombre de conversations et de demandes par projet. Les messages sont lus sur ce Mac et restent dans leurs fichiers."
    static let on = "Codex et Claude Code : nombre de conversations par projet. Les messages sont lus sur ce Mac et restent dans leurs fichiers."
}

/// R14a (N2): the selection a click asked for while its check runs off the main thread. The next click starts from it,
/// not from the selection still on screen, so two quick « jour suivant » give J+2. Cleared once the latest click is
/// committed.
final class GoalongSelectionChain {
    private(set) var asked: GoalongActivityNavigation?
    private var token = 0

    /// Where the next click starts: the selection asked for last, or the one on screen.
    func base(_ shown: GoalongActivityNavigation) -> GoalongActivityNavigation { asked ?? shown }

    func ask(_ next: GoalongActivityNavigation, token: Int) { asked = next; self.token = token }

    func committed(token: Int) { if token == self.token { asked = nil } }
}
