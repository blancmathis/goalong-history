#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import SwiftUI

    struct UnifiedHistoryPage: View {
        @ObservedObject private var model: DashboardViewModel
        @ObservedObject private var agents: AgentActivityRuntime
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @State private var source: HistorySource = .computer

        init(model: DashboardViewModel) {
            _model = ObservedObject(wrappedValue: model)
            _agents = ObservedObject(wrappedValue: model.agentActivityRuntime)
            _screenTime = StateObject(
                wrappedValue: AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: model.deviceID,
                    selectedDay: model.selectedDay,
                    accessEnabled: false
                )
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                Picker("History source", selection: $source) {
                    ForEach(HistorySource.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, LHTheme.pageInset)
                .padding(.bottom, 16)

                Divider()

                sourceView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                synchronizeSources(with: model.selectedDay)
                screenTime.setActive(model.dashboardIsVisible && source == .screenTime)
                if source == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
            .onDisappear {
                screenTime.setActive(false)
            }
            .onChange(of: model.dashboardIsVisible) { visible in
                screenTime.setActive(visible && source == .screenTime)
                if visible && source == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
            .onChange(of: model.selectedDay) { day in
                synchronizeSources(with: day)
            }
            .onChange(of: source) { next in
                screenTime.setActive(model.dashboardIsVisible && next == .screenTime)
                if next == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
        }

        private var header: some View {
            DayNavigationHeader(
                title: "Historique", day: model.selectedDay,
                isRefreshing: model.isRefreshing || agents.isScanning || screenTime.isBusy,
                onSelectDay: selectDay,
                onShare: { model.showingWebsiteShare = true },
                onRefresh: refresh
            )
        }

        @ViewBuilder private var sourceView: some View {
            switch source {
            case .computer:
                ActivityPage(
                    model: model,
                    initialMode: .computerHistory,
                    showsModePicker: false,
                    showsHeader: false
                )
            case .screenTime:
                GoalongScreenTimePage(
                    model: model,
                    screenTimeModel: screenTime,
                    showsHeader: false
                )
            case .conversations:
                AgentActivityPage(agents: agents, presentation: .history,
                    onManageSources: { model.selectSection(.agentActivity) })
            }
        }

        private func selectDay(_ day: Date) {
            model.selectDay(day)
            synchronizeSources(with: day)
        }

        private func synchronizeSources(with day: Date) {
            if screenTime.selectedDay != day {
                screenTime.selectDay(day)
            }
            if agents.selectedDay != day {
                agents.selectDay(day)
            }
        }

        private func refresh() {
            switch source {
            case .computer:
                model.refreshEverything()
            case .screenTime:
                model.refreshEverything()
                screenTime.refresh()
            case .conversations:
                agents.scanNow(analyzeSelectedDay: true)
            }
        }
    }

    private enum HistorySource: String, CaseIterable, Identifiable {
        case computer
        case screenTime
        case conversations

        var id: String { rawValue }

        var title: String {
            switch self {
            case .computer: return "Ce Mac"
            case .screenTime: return "Temps d’écran Apple"
            case .conversations: return "Conversations locales"
            }
        }
    }
#endif
