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
    @State private var focusMinutes = 25
    @State private var revision = 0
    @State private var manualRefreshRevision = 0
    @State private var forceNextRead = false
    @State private var showingAnalysisChoice = false
    @AppStorage(GoalongDeveloperPreferences.enabledKey) private var developerMode = false
    @State private var showingPreview = false
    @State private var previewNavigation = GoalongActivityNavigation()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var previewActive: Bool { developerMode && showingPreview }
    private var selection: GoalongActivityNavigation { previewActive ? previewNavigation : navigation }
    private var selectionID: String { "\(selection.day.timeIntervalSince1970)|\(selection.period)|\(previewActive)" }
    private var requestID: String { "\(selectionID)|\(revision)|\(model.dashboardIsVisible)" }

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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !previewActive { GoalongRecordingCoverageNotice(model: model) }
                    if developerMode { previewControl }
                    if previewActive { GoalongAnalyticsPreviewBanner(onExit: { showingPreview = false }) }
                    if let error = analytics.error {
                        LHCard(padding: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button("Réessayer", action: refresh).buttonStyle(.bordered)
                            }
                        }
                    }
                    if let payload = analytics.payload, selection.matches(payload, preview: previewActive) {
                        GoalongAnalyticsContent(payload: payload, focusMinutes: $focusMinutes,
                            onDay: { day in updateSelection { $0.openDay(day) } },
                            onHistory: { openHistory(selection.day) },
                            onProjects: { if !previewActive { showingAnalysisChoice = true } },
                            onHistoryDay: openHistory,
                            onRecap: openRecap)
                            .id(selectionID)
                    } else if analytics.error == nil {
                        GoalongPageLoadingView(title: "Lecture des observations locales…",
                            message: "Les durées sont calculées sur ce Mac, sans envoyer votre historique.")
                            .accessibilityIdentifier("analytics-primary-loading-motion")
                    }
                    if !previewActive {
                        if selection.period == 1 {
                            GoalongActivityAppleCard(model: model, day: navigation.day,
                                refreshRevision: manualRefreshRevision)
                        } else {
                            LHCard(padding: 16) {
                                HStack(alignment: .center, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Temps d’écran Apple").font(.system(size: 14, weight: .semibold))
                                        Text("Source distincte · consultation par journée, sans addition aux observations Goalong.")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 8)
                                    Button("Consulter le \(navigation.day.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)))") {
                                        model.selectDay(navigation.day)
                                        model.selectSection(.screenTime)
                                    }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 1100).padding(LHTheme.pageInset).frame(maxWidth: .infinity)
            }
        }
        .background(LHTheme.pageBackground)
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
        .task(id: requestID) {
            guard model.dashboardIsVisible else { return }
            let request = selection
            let preview = previewActive
            let force = forceNextRead
            forceNextRead = false
            await analytics.load(day: request.day, count: request.period, force: force, preview: preview)
        }
        .onChange(of: developerMode) { enabled in
            if !enabled { showingPreview = false; previewNavigation = GoalongActivityNavigation() }
        }
        .onDisappear {
            showingPreview = false
            showingAnalysisChoice = false
            previewNavigation = GoalongActivityNavigation()
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
                  Calendar.current.isDateInToday(navigation.day) else { return }
            revision += 1
        }
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
            .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("analytics-preview-toggle")
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
                    Label("Aperçu développeur · données fictives", systemImage: "testtube.2")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.warning)
                    Spacer(minLength: 8)
                    Button("Quitter l’aperçu", action: onExit).buttonStyle(.borderless)
                        .accessibilityIdentifier("analytics-preview-exit")
                }
                Text("Aucune donnée personnelle n’est lue par cet aperçu. Rien n’est ajouté à l’historique ; le partage et l’analyse IA sont désactivés.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("analytics-preview-banner")
    }
}
#endif
