#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine
import LocalHistoryCore

/// Daily review and longer-term perspective share one window-local selection.
struct GoalongAnalyticsPage: View {
    @ObservedObject var model: DashboardViewModel
    @Binding var navigation: GoalongActivityNavigation
    @ObservedObject var analytics: GoalongAnalyticsModel
    @StateObject private var studio = GoalongProfileWindow()
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
    @State private var detail: GoalongActivityDetail?
    @AppStorage(GoalongDeveloperPreferences.enabledKey) private var developerMode = false
    @State private var showingPreview = false
    @State private var previewNavigation = GoalongActivityNavigation()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// Automatic refreshes of today wait at least ten times the last read duration, so a
    /// very busy day never keeps a core busy while the page is simply left open.
    @State private var lastReadSeconds: TimeInterval = 0
    @State private var lastAutomaticRefresh = Date.distantPast

    private var previewActive: Bool { developerMode && showingPreview }
    private var selection: GoalongActivityNavigation { previewActive ? previewNavigation : navigation }
    private var selectionID: String { "\(selection.day.timeIntervalSince1970)|\(selection.period)|\(previewActive)" }
    private var loadRequest: GoalongAnalyticsLoadRequest {
        GoalongAnalyticsLoadRequest(day: selection.day, count: selection.period,
            revision: revision, preview: previewActive, dashboardIsVisible: model.dashboardIsVisible)
    }

    var body: some View {
        VStack(spacing: 0) {
            GoalongActivityHeader(selection: selection, isPreview: previewActive, isRefreshing: analytics.busy,
                onDay: { day in updateSelection { $0.selectDay(day) } },
                onPeriod: { period in updateSelection { $0.selectPeriod(period) } },
                onStep: { direction in updateSelection { $0.step(direction) } },
                onToday: { updateSelection { $0.today() } },
                onReturn: { updateSelection { $0.restorePeriod() } },
                onRefresh: refresh,
                onShare: {
                    guard !previewActive else { return }
                    model.selectDay(selection.day)
                    model.showingWebsiteShare = true
                })
            Rectangle().fill(LHTheme.separator).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Color.clear.frame(height: 0).id("activity-top")
                        if !previewActive {
                            GoalongRecordingStateNotice(model: model)
                            GoalongRecordingCoverageNotice(model: model, dismissible: true)
                        }
                        if developerMode { previewControl }
                        if previewActive { GoalongAnalyticsPreviewBanner(onExit: { showingPreview = false }) }
                        if let error = analytics.error {
                            HStack(alignment: .center, spacing: 12) {
                                GoalongNote(error, tone: .warning)
                                Button("Réessayer", action: refresh).buttonStyle(LHSecondaryButtonStyle())
                            }
                        }
                        if detail != nil && !showsContent {
                            // While reading or after an error, a named view still offers its way back.
                            Button { detail = nil } label: { Label("Synthèse", systemImage: "chevron.left") }
                                .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                        }
                        if let payload = analytics.payload, selection.matches(payload, preview: previewActive) {
                            GoalongAnalyticsContent(payload: payload, focusMinutes: $focusMinutes,
                                lanes: lanes,
                                workStatus: previewActive ? .preview : workStatus,
                                onDay: { day in updateSelection { $0.openDay(day) } },
                                onWork: { model.selectSection(.work) },
                                onReview: { task in if !previewActive { reviewRequest = GoalongWorkReviewRequest(day: selection.day, task: task) } },
                                onClassify: { agent.classify(day: selection.day) },
                                onHistory: { openHistory(selection.day) },
                                onProjects: { if !previewActive { showingAnalysisChoice = true } },
                                onHistoryDay: openHistory,
                                onRecap: openRecap,
                                detail: $detail)
                                .id(selectionID)
                        } else if analytics.error == nil && !loadRequest.permitsLoading {
                            GoalongNote("Lecture en attente : cliquez dans cette fenêtre pour lire les observations de cette période. Les lectures privées restent suspendues lorsque vous utilisez une autre application.",
                                        symbol: "pause.circle")
                                .accessibilityIdentifier("activity-read-waiting-for-focus")
                        } else if analytics.error == nil {
                            GoalongPageLoadingView(title: "Lecture des observations locales…",
                                message: "Les durées sont calculées sur ce Mac, sans envoyer votre historique.")
                                .accessibilityIdentifier("analytics-primary-loading-motion")
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
                    .padding(.horizontal, LHTheme.pageInset).padding(.top, 24).padding(.bottom, 40)
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
                studio.show(localOnly: true, initialDay: navigation.day, onSend: { _ in })
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Choisissez le type d’analyse. Les sources et les autorisations restent à vérifier avant toute génération.")
        }
        .onAppear { model.selectDay(navigation.day) }
        .task(id: loadRequest) {
            let request = loadRequest
            guard request.permitsLoading else { return }
            let force = forceNextRead
            forceNextRead = false
            let started = ProcessInfo.processInfo.systemUptime
            await analytics.load(request, force: force, verdicts: work.verdicts)
            lastReadSeconds = ProcessInfo.processInfo.systemUptime - started
            // Contexts seen for the first time are classified in the background, at most
            // once per day shown (today: every 15 minutes), only with the user's consent.
            if !request.isPreview, let payload = analytics.payload, !Task.isCancelled {
                agent.classifyIfNeeded(payload.current.days)
            }
        }
        .task(id: laneKey) {
            // Day-only sources, read beside the observations; never mixed into active time.
            guard loadRequest.permitsLoading, !previewActive, selection.period == 1,
                  consents.isEnabled(.aiConversations) || consents.isEnabled(.developerActivity) else { return }
            let day = selection.day, overview = model.agentActivityRuntime.overview
            await developer.refresh(day: day, agents: Calendar.current.isDate(overview.day, inSameDayAs: day) ? overview : nil)
        }
        .task(id: systemKey) {
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.dashboardIsVisible && !previewActive { revision += 1 }
        }
        .onReceive(refreshTimer) { _ in
            // Visible-page refresh only. Completed days reuse the existing cache.
            guard model.dashboardIsVisible, !previewActive, !analytics.busy,
                  Calendar.current.isDateInToday(navigation.day),
                  Date().timeIntervalSince(lastAutomaticRefresh) >= max(30, lastReadSeconds * 10) else { return }
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
         "\(model.appliedSettings.captureCallPresence)", "\(consents.isEnabled(.calendar))",
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
        var rows = [GoalongSourceRow(id: "mac", title: "Activité de ce Mac", state: .ready,
                                     detail: "Applications, sites et saisie : la source du temps actif.")]
        rows += systemRows(settings: settings)
        if !ai {
            rows.append(.init(id: "agents", title: "Conversations d’agents", state: .off,
                              detail: "Codex, Claude Code et T3 Code : nombre de conversations et de demandes par projet, sans lire les messages.",
                              actionTitle: "Activer…", action: settings))
        } else {
            let conversations = value.map { $0.agents.projects.reduce(0) { $0 + $1.sessions } + $0.agents.unassignedSessions }
            rows.append(.init(id: "agents", title: "Conversations d’agents", state: .ready,
                              detail: conversations.map { GoalongCodeDay.count($0, "conversation", "conversations") + " ce jour-là." }
                                  ?? "Codex et Claude Code : nombre de conversations par projet, sans lire les messages."))
            if !developer.t3Discovered {
                rows.append(.init(id: "t3", title: "T3 Code", state: .unavailable, detail: "T3 Code n’est pas installé sur ce Mac."))
            } else if let t3 = value?.t3 {
                let requests = t3.projects.reduce(0) { $0 + $1.requests }
                let detail: String
                switch t3.status {
                case .ready, .partial:
                    detail = GoalongCodeDay.count(requests, "demande", "demandes") + " ce jour-là, dans "
                        + GoalongCodeDay.count(t3.projects.count, "projet", "projets") + "."
                        + (t3.status == .partial ? " Lecture partielle : la base dépasse les limites de lecture." : "")
                case .noData: detail = "Aucune demande ce jour-là."
                case .unsupported: detail = "Cette version de T3 Code n’est pas encore prise en charge."
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
        if !consents.isEnabled(.localComputerHistory) || !model.appliedSettings.captureCallPresence {
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
                              actionTitle: permissions.contains(.permissionDenied) ? "Ouvrir…" : "Autoriser…", action: allowCalendar))
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

    private var previewControl: some View {
        HStack(spacing: 12) {
            Button {
                showingAnalysisChoice = false
                if !showingPreview { previewNavigation = navigation }
                showingPreview.toggle()
            } label: {
                Label(previewActive ? "Revenir à mes données" : "Aperçu avec données fictives",
                      systemImage: previewActive ? "arrow.uturn.backward" : "testtube.2")
            }
            .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small).accessibilityIdentifier("analytics-preview-toggle")
            Spacer(minLength: 0)
            Text("Mode développeur").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func updateSelection(_ change: (inout GoalongActivityNavigation) -> Void) {
        if previewActive { change(&previewNavigation) }
        else { change(&navigation); model.selectDay(navigation.day) }
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
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.warning)
                    Spacer(minLength: 8)
                    Button("Quitter l’aperçu", action: onExit).buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("analytics-preview-exit")
                }
                Text("Aucune donnée personnelle n’est lue par cet aperçu. Rien n’est ajouté à l’historique ; le partage et l’analyse IA sont désactivés.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("analytics-preview-banner")
    }
}
#endif
