#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ActivityPage: View {
        let model: DashboardViewModel
        @ObservedObject var navigationStore: DashboardNavigation
        @ObservedObject var snapshotStore: DashboardSnapshotStore
        @Environment(\.accessibilityReduceMotion) var reduceMotion
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @StateObject var computerHistoryModel = ComputerHistoryPageModel()
        @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey)
        var richContextEnabled = false

        private let showsHeader: Bool

        init(
            model: DashboardViewModel,
            showsHeader: Bool = true
        ) {
            self.model = model
            _navigationStore = ObservedObject(wrappedValue: model.navigationStore)
            _snapshotStore = ObservedObject(wrappedValue: model.snapshotStore)
            self.showsHeader = showsHeader
        }

        var body: some View {
            if showsHeader {
                // One form for this history wherever it opens: « Historique », its tabs and Partager.
                UnifiedHistoryPage(model: model)
            } else {
                SourceAccessGate(capability: .localComputerHistory) { pageBody }
            }
        }

        private var pageBody: some View {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if !consents.isEnabled(.localComputerHistory) {
                        ComputerHistoryActivationCard(model: model)
                    } else {
                        ComputerHistoryPage(
                            model: computerHistoryModel,
                            day: navigationStore.selectedDay,
                            snapshot: snapshotStore.snapshot,
                            snapshotGeneration: snapshotStore.snapshotGeneration,
                            isSnapshotLoading: snapshotStore.isRefreshing,
                            fullContextEnabled: richContextEnabled,
                            openSourceJSON: model.revealTodayJSON,
                            runtimeStore: model.runtimeStore
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .background(LHTheme.pageBackground)
            .onAppearWhenShown {
                refreshVisibleAnalysis(day: navigationStore.selectedDay)
            }
            .onChange(of: navigationStore.selectedDay) { day in
                refreshVisibleAnalysis(day: day)
            }
            .onChange(of: consents.document) { _ in
                refreshVisibleAnalysis(day: navigationStore.selectedDay)
            }
            .onChange(of: richContextEnabled) { _ in
                ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
            }
            .onChange(of: snapshotStore.historyDeletionGeneration) { _ in
                refreshVisibleAnalysis(day: navigationStore.selectedDay, forceRebuild: true)
            }
        }

        private func refreshVisibleAnalysis(day: Date, forceRebuild: Bool = false) {
            guard consents.isEnabled(.localComputerHistory) else { return }
            computerHistoryModel.refresh(day: day, forceRebuild: forceRebuild)
        }
    }
#endif
