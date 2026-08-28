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
                    selectedDay: model.selectedDay
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
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
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
            PageHeader(
                eyebrow: Calendar.current.isDateInToday(model.selectedDay) ? "Today" : "Daily history",
                title: "History",
                subtitle: "Computer activity, Apple Screen Time and AI conversations in one place."
            ) {
                HStack(spacing: 10) {
                    DateSelectionControl(date: model.selectedDay, onChange: selectDay)
                    Button {
                        model.selectSection(.share)
                    } label: {
                        Label("Share day", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshing || agents.isScanning || screenTime.isBusy)
                    .help("Refresh the selected day")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 18)
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
                GoalongScreenTimePage(model: model, showsHeader: false)
            case .conversations:
                AgentActivityPage(agents: agents, presentation: .history)
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
            case .computer: return "Computer History"
            case .screenTime: return "Screen Time"
            case .conversations: return "AI conversations"
            }
        }
    }
#endif
