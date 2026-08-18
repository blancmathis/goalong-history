#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ActivityPage: View {
        @ObservedObject var model: DashboardViewModel
        @StateObject var analysisModel = ActivityAnalysisPageModel()
        @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey)
        var richContextEnabled = false
        @AppStorage(ActivityAnalysisPreferences.agentTokenBudgetKey)
        var agentTokenBudget = 1_600
        @State var expandedBlockID: String?
        @State var showRichContextConfirmation = false

        let metricColumns = [
            GridItem(.adaptive(minimum: 165, maximum: 250), spacing: 12)
        ]

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

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
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 30)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                analysisModel.refresh(day: model.selectedDay)
            }
            .onChange(of: model.selectedDay) { day in
                expandedBlockID = nil
                analysisModel.refresh(day: day)
            }
            .onChange(of: agentTokenBudget) { _ in
                analysisModel.refresh(day: model.selectedDay)
            }
            .alert("Enable Rich Context?", isPresented: $showRichContextConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Enable Rich Context") {
                    richContextEnabled = true
                }
            } message: {
                Text(
                    "LocalHistory will store selected and visible text exposed by macOS Accessibility for eligible foreground windows. It will not decode keystrokes and will still suppress private browsing, exclusions and secure fields. Turning it off later stops future snapshots; existing snapshots follow your normal local retention and deletion controls."
                )
            }
        }

        var header: some View {
            PageHeader(
                eyebrow: Calendar.current.isDateInToday(model.selectedDay) ? "Today" : "Daily history",
                title: "Day recap",
                subtitle:
                    "A compact, readable account of what you did — optimized for both you and a daily agent."
            ) {
                HStack(spacing: 10) {
                    DateSelectionControl(date: model.selectedDay, onChange: model.selectDay)
                    Button {
                        model.refreshEverything()
                        analysisModel.refresh(day: model.selectedDay)
                    } label: {
                        Image(systemName: analysisModel.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(analysisModel.isLoading)
                    .help("Rebuild the day analysis")
                }
            }
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
                                colors: [LHTheme.accent.opacity(0.14), LHTheme.privateTint.opacity(0.09)],
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
                            "\(analysis.coverage.sourceEventCount.formatted()) raw events were reduced to \(analysis.coverage.representativeMinuteCount.formatted()) meaningful minute records before analysis."
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
                    detail: "Coherent tasks, not every window change",
                    symbol: "rectangle.3.group.fill",
                    tint: LHTheme.accent
                )
                MetricCard(
                    title: "SITES / PAGES",
                    value: "\(analysis.sites.count) / \(analysis.sites.reduce(0) { $0 + $1.pageCount })",
                    detail: "Deduplicated web context",
                    symbol: "globe",
                    tint: LHTheme.privateTint
                )
                MetricCard(
                    title: "REQUESTS FOUND",
                    value: "\(analysis.requests.count)",
                    detail: analysis.coverage.semanticContextEnabledInData
                        ? "From opt-in accessible context"
                        : "Enable Rich Context for discussions",
                    symbol: "text.bubble.fill",
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
                    Text("Events are being deduplicated into representative minutes and focus blocks locally.")
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
                        ?? "Keep LocalHistory running. The recap and agent brief will be generated automatically as activity appears.",
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
#endif
