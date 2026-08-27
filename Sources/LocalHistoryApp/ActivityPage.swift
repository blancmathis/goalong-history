#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ActivityPage: View {
        @ObservedObject var model: DashboardViewModel
        @StateObject var analysisModel = ActivityAnalysisPageModel()
        @StateObject var computerHistoryModel = ComputerHistoryPageModel()
        @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey)
        var richContextEnabled = false
        @AppStorage(ActivityAnalysisPreferences.agentTokenBudgetKey)
        var agentTokenBudget = 1_600
        @State var expandedBlockID: String?
        @State var showRichContextConfirmation = false
        @State var mode: ActivityMode = .appsAndSites

        let metricColumns = [
            GridItem(.adaptive(minimum: 165, maximum: 250), spacing: 12)
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                header

                Picker("Activity view", selection: $mode) {
                    ForEach(ActivityMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 590)

                Group {
                    switch mode {
                    case .appsAndSites:
                        MonitoringRulesList(model: model)
                    case .computerHistory:
                        ComputerHistoryPage(
                            model: computerHistoryModel,
                            day: model.selectedDay,
                            snapshot: model.snapshot,
                            snapshotGeneration: model.snapshotGeneration,
                            fullContextEnabled: richContextEnabled,
                            openSourceJSON: model.revealTodayJSON,
                            deleteEpisode: { episode in
                                model.deleteComputerHistoryEpisode(
                                    episode,
                                    day: model.selectedDay
                                )
                            }
                        )
                    case .dayRecap:
                        recapBody
                    case .timeline:
                        ActivityTimelineExplorer(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 22)
            .background(LHTheme.pageBackground)
            .onAppear {
                refreshVisibleAnalysis(day: model.selectedDay)
            }
            .onChange(of: model.selectedDay) { day in
                expandedBlockID = nil
                computerHistoryModel.clearAnswer()
                refreshVisibleAnalysis(day: day)
            }
            .onChange(of: mode) { _ in
                refreshVisibleAnalysis(day: model.selectedDay)
            }
            .onChange(of: agentTokenBudget) { _ in
                if mode == .dayRecap {
                    analysisModel.refresh(day: model.selectedDay, forceRebuild: true)
                }
            }
            .onChange(of: richContextEnabled) { _ in
                ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
                if mode == .dayRecap {
                    analysisModel.refresh(day: model.selectedDay, forceRebuild: true)
                }
            }
            .onChange(of: model.historyDeletionGeneration) { _ in
                refreshVisibleAnalysis(day: model.selectedDay, forceRebuild: true)
            }
            .alert("Enable Rich Context?", isPresented: $showRichContextConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Enable Rich Context") {
                    richContextEnabled = true
                }
            } message: {
                Text(
                    "\(ProductIdentity.displayName) will store selected and visible text exposed by macOS Accessibility for eligible foreground windows. It will not decode keystrokes and will still suppress private browsing, exclusions and secure fields. Turning it off later stops future snapshots; existing snapshots follow your normal local retention and deletion controls."
                )
            }
        }

        var recapBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let analysis = analysisModel.analysis {
                        headlineCard(analysis)
                        metrics(analysis)

                        HStack(alignment: .top, spacing: 14) {
                            focusBlocksCard(analysis)
                                .frame(minWidth: 500, maxWidth: .infinity)
                            VStack(spacing: 14) {
                                sitesCard(analysis)
                                requestsCard(analysis)
                            }
                            .frame(minWidth: 330, idealWidth: 370, maxWidth: 430)
                        }

                        agentBriefCard(analysis)
                        richContextCard(analysis)
                        evidenceCard
                    } else if analysisModel.isLoading {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .padding(.bottom, 8)
            }
        }

        var header: some View {
            PageHeader(
                eyebrow: Calendar.current.isDateInToday(model.selectedDay)
                    ? "Today"
                    : "Daily history",
                title: mode == .computerHistory ? "Computer History" : "Activity",
                subtitle: headerSubtitle
            ) {
                HStack(spacing: 10) {
                    DateSelectionControl(
                        date: model.selectedDay,
                        onChange: model.selectDay
                    )
                    Button {
                        model.refreshEverything()
                        refreshVisibleAnalysis(day: model.selectedDay, forceRebuild: true)
                    } label: {
                        Image(
                            systemName: analysesLoading
                                ? "arrow.triangle.2.circlepath"
                                : "arrow.clockwise"
                        )
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(analysesLoading)
                    .help(refreshHelp)
                }
            }
        }

        private var analysesLoading: Bool {
            model.isRefreshing || (mode == .dayRecap && analysisModel.isLoading)
        }

        private var refreshHelp: String {
            mode == .dayRecap
                ? "Refresh activity and rebuild the day recap"
                : "Refresh recorded activity"
        }

        private var headerSubtitle: String {
            switch mode {
            case .appsAndSites:
                return "See every observed app and website, then choose what Goalong may monitor in future."
            case .computerHistory:
                return "Review recorded activity in factual 15-minute windows, without an AI-generated summary."
            case .dayRecap:
                return "Review the compact daily digest used by recap agents alongside full causal history."
            case .timeline:
                return "Inspect the exact chronological source events, gaps, classifications, and integrity signals."
            }
        }

        private func refreshVisibleAnalysis(day: Date, forceRebuild: Bool = false) {
            guard mode == .dayRecap else { return }
            analysisModel.refresh(day: day, forceRebuild: forceRebuild)
        }

        func headlineCard(_ analysis: ActivityDayAnalysis) -> some View {
            LHCard(padding: 20) {
                HStack(alignment: .center, spacing: 17) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 58, height: 58)
                        .background(
                            LinearGradient(
                                colors: [
                                    LHTheme.accent.opacity(0.14),
                                    LHTheme.privateTint.opacity(0.09),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text(analysis.headline)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "\(analysis.coverage.sourceEventCount.formatted()) raw events were reduced to \(analysis.coverage.representativeMinuteCount.formatted()) meaningful minute records for the compact digest. Full causal history remains available in its own tab."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    StatusPill(
                        title: "~\(analysis.estimatedAgentTokens.formatted()) agent tokens",
                        symbol: "leaf.fill",
                        tint: LHTheme.success
                    )
                }
            }
        }

        func metrics(_ analysis: ActivityDayAnalysis) -> some View {
            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                MetricCard(
                    title: "ACTIVE",
                    value: duration(analysis.activeSeconds),
                    detail: "Representative foreground minutes",
                    symbol: "clock.fill",
                    tint: LHTheme.teal
                )
                MetricCard(
                    title: "FOCUS BLOCKS",
                    value: "\(analysis.focusBlocks.count)",
                    detail: "Compact task digest",
                    symbol: "rectangle.3.group.fill",
                    tint: LHTheme.accent
                )
                MetricCard(
                    title: "SITES / PAGES",
                    value: "\(analysis.sites.count) / \(analysis.sites.reduce(0) { $0 + $1.pageCount })",
                    detail: "Every detected site and sanitized page",
                    symbol: "globe",
                    tint: LHTheme.privateTint
                )
                MetricCard(
                    title: "WEB CLICKS",
                    value: "\(analysis.sites.reduce(0) { $0 + $1.clickCount })",
                    detail: "Accessible targets plus unlabelled positions",
                    symbol: "cursorarrow.click",
                    tint: LHTheme.warning
                )
            }
        }

        var loadingState: some View {
            LHCard {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Building the compact day analysis…")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Events are being deduplicated into representative minutes, sites, pages and focus blocks locally."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }

        var emptyState: some View {
            LHCard {
                EmptyStateView(
                    symbol: "sparkles.rectangle.stack",
                    title: "No analyzable activity yet",
                    message: analysisModel.errorMessage
                        ?? "Keep Goalong running. The recap and agent brief will be generated automatically as activity appears.",
                    buttonTitle: "Try again",
                    action: { analysisModel.refresh(day: model.selectedDay) }
                )
                .frame(minHeight: 320)
            }
        }

        func compactEmpty(symbol: String, title: String) -> some View {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(11)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }

        func duration(_ seconds: Int) -> String {
            DashboardFormatters.duration(seconds: TimeInterval(seconds))
        }
    }

    enum ActivityMode: String, CaseIterable, Identifiable {
        case appsAndSites
        case computerHistory
        case dayRecap
        case timeline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appsAndSites: return "Apps & websites"
            case .computerHistory: return "Computer History"
            case .dayRecap: return "Day recap"
            case .timeline: return "Raw timeline"
            }
        }
    }
#endif
