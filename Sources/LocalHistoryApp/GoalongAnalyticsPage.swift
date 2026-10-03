#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine

/// Daily review and longer-term perspective share one window-local selection.
struct GoalongAnalyticsPage: View {
    @ObservedObject var model: DashboardViewModel
    @Binding var navigation: GoalongActivityNavigation
    @StateObject private var analytics = GoalongAnalyticsModel()
    @StateObject private var studio = GoalongProfileWindow()
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @State private var focusMinutes = 25
    @State private var revision = 0
    @State private var manualRefreshRevision = 0
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
