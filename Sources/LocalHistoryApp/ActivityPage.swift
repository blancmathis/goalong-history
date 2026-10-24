#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    struct ActivityPage: View {
        @ObservedObject var model: DashboardViewModel
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
            self.showsHeader = showsHeader
        }

        var body: some View {
            SourceAccessGate(capability: .localComputerHistory) { pageBody }
        }

        private var pageBody: some View {
            VStack(alignment: .leading, spacing: 16) {
                if showsHeader {
                    header
                }

                Group {
                    if !consents.isEnabled(.localComputerHistory) {
                        ComputerHistoryActivationCard(model: model)
                    } else {
                        ComputerHistoryPage(
                            model: computerHistoryModel,
                            day: model.selectedDay,
                            snapshot: model.snapshot,
                            snapshotGeneration: model.snapshotGeneration,
                            isSnapshotLoading: model.isRefreshing,
                            fullContextEnabled: richContextEnabled,
                            openSourceJSON: model.revealTodayJSON,
                            deleteEpisode: { episode in
                                model.deleteComputerHistoryEpisode(
                                    episode,
                                    day: model.selectedDay
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.top, showsHeader ? 28 : 18)
            .padding(.bottom, 22)
            .background(LHTheme.pageBackground)
            .onAppear {
                refreshVisibleAnalysis(day: model.selectedDay)
            }
            .onChange(of: model.selectedDay) { day in
                computerHistoryModel.clearAnswer()
                refreshVisibleAnalysis(day: day)
            }
            .onChange(of: consents.document) { _ in
                refreshVisibleAnalysis(day: model.selectedDay)
            }
            .onChange(of: richContextEnabled) { _ in
                ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
            }
            .onChange(of: model.historyDeletionGeneration) { _ in
                refreshVisibleAnalysis(day: model.selectedDay, forceRebuild: true)
            }
        }

        var header: some View {
            PageHeader(
                title: "Historique de ce Mac",
                subtitle: "Consultez l’activité enregistrée par tranches de 10 minutes, sans résumé généré par IA."
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
                    .buttonStyle(LHSecondaryButtonStyle())
                    .disabled(analysesLoading)
                    .help("Actualiser l’activité enregistrée")
                    .accessibilityLabel("Actualiser")
                }
            }
        }

        private var analysesLoading: Bool {
            model.isRefreshing
                || computerHistoryModel.isLoading
        }

        private func refreshVisibleAnalysis(day: Date, forceRebuild: Bool = false) {
            guard consents.isEnabled(.localComputerHistory) else { return }
            computerHistoryModel.refresh(day: day, forceRebuild: forceRebuild)
        }
    }
#endif
