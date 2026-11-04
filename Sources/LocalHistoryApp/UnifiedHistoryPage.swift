#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import SwiftUI

    struct UnifiedHistoryPage: View {
        private let model: DashboardViewModel
        @ObservedObject var deviceStore: DashboardDeviceState
        @ObservedObject var navigationStore: DashboardNavigation
        @ObservedObject var runtimeStore: DashboardRuntimeState
        @ObservedObject var snapshotStore: DashboardSnapshotStore
        @ObservedObject private var agents: AgentActivityRuntime
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @State private var source: HistorySource = .computer
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        init(model: DashboardViewModel) {
            let deviceStore = model.deviceStore, navigationStore = model.navigationStore
            self.model = model
            _deviceStore = ObservedObject(wrappedValue: deviceStore)
            _navigationStore = ObservedObject(wrappedValue: navigationStore)
            _runtimeStore = ObservedObject(wrappedValue: model.runtimeStore)
            _snapshotStore = ObservedObject(wrappedValue: model.snapshotStore)
            _agents = ObservedObject(wrappedValue: model.agentActivityRuntime)
            _screenTime = StateObject(
                wrappedValue: AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: deviceStore.deviceID,
                    selectedDay: navigationStore.selectedDay,
                    accessEnabled: false
                )
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                GoalongSegmentedControl("Source de l’historique", selection: $source,
                                        options: HistorySource.allCases) { $0.title }
                .padding(.horizontal, LHTheme.pageInset)
                .padding(.bottom, 16)

                Divider()

                sourceView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LHTheme.pageBackground)
            .onAppearWhenShown {
                synchronizeSources(with: navigationStore.selectedDay)
                screenTime.setActive(runtimeStore.dashboardIsVisible && source == .screenTime)
                if source == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
            .onDisappear {
                screenTime.setActive(false)
            }
            .onChange(of: runtimeStore.dashboardIsVisible) { visible in
                screenTime.setActive(visible && source == .screenTime)
                if visible && source == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
            .onChange(of: navigationStore.selectedDay) { day in
                synchronizeSources(with: day)
            }
            .onChange(of: source) { next in
                screenTime.setActive(runtimeStore.dashboardIsVisible && next == .screenTime)
                if next == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
        }

        private var header: some View {
            DayNavigationHeader(
                title: "Historique", day: navigationStore.selectedDay,
                isRefreshing: snapshotStore.isRefreshing || agents.isScanning || screenTime.isBusy,
                onSelectDay: selectDay,
                onShare: { navigationStore.showingWebsiteShare = true },
                onRefresh: refresh,
                // Same rule as Activité: an empty day greys the button instead of offering nothing.
                // History off: nothing is recorded, so there is nothing to share either (UI-17C, écran 22).
                sharingEnabled: historyEnabled && snapshotStore.snapshot.eventCount > 0,
                sharingDisabledReason: historyEnabled ? "Rien à partager ce jour-là" : "Enregistrement désactivé"
            )
        }

        private var historyEnabled: Bool { consents.isEnabled(.localComputerHistory) }

        @ViewBuilder private var sourceView: some View {
            switch source {
            case .computer:
                ActivityPage(
                    model: model,
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
