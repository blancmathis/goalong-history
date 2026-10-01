#if os(macOS)
    import Foundation
    import SwiftUI

    struct LocalHistoryDashboardView: View {
        @ObservedObject var model: DashboardViewModel
        @State private var activityNavigation = GoalongActivityNavigation()

        var body: some View {
            Group {
                if model.showWelcome {
                    LocalHistoryOnboardingView(model: model)
                } else {
                    HStack(spacing: 0) {
                        DashboardSidebar(model: model)
                            .frame(width: 208)
                        Rectangle()
                            .fill(LHTheme.separator)
                            .frame(width: 1)
                        page
                            .safeAreaInset(edge: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    GoalongGlobalPauseBanner(model: model)
                                    GoalongAttentionBanner(model: model)
                                }
                            }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if model.settingsHaveChanges && model.selectedSection != .settings {
                                    HStack(spacing: 12) {
                                        Label("Modifications d’enregistrement non appliquées", systemImage: "pencil.circle")
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Button("Abandonner") { model.discardSettingsChanges() }
                                        Button("Vérifier les modifications") { model.openRecordingSettings() }
                                            .buttonStyle(LHPrimaryButtonStyle())
                                    }.padding(14).background(LHTheme.cardBackground)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .environment(\.goalongRecordingModel, model)
            .sheet(isPresented: $model.showingWebsiteShare) { GoalongWebsiteSharingSheet(initialDay: model.selectedDay) }
            .background(LHTheme.pageBackground)
            .foregroundStyle(LHTheme.text)
            .tint(LHTheme.accent)
            .accentColor(LHTheme.accent)
            .frame(minWidth: 900, minHeight: 620)
            .alert(item: $model.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        @ViewBuilder private var page: some View {
            switch model.selectedSection {
            case .overview, .analytics:
                GoalongAnalyticsPage(model: model, navigation: $activityNavigation)
            case .work:
                GoalongWorkPage(model: model)
            case .history:
                UnifiedHistoryPage(model: model)
            case .monitoring:
                JevMonitoringPage(onOpenRecording: { model.openRecordingSettings() },
                                  onOpenWork: { model.selectSection(.work) })
            case .activity:
                ActivityPage(
                    model: model,
                    initialMode: .computerHistory,
                    showsModePicker: false
                )
            case .screenTime:
                GoalongScreenTimePage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .agentActivity:
                AgentActivityPage(agents: model.agentActivityRuntime)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .chatGPTRecap:
                ChatGPTRecapPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .share:
                SharePage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .privacy:
                PrivacyPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .cli:
                CLIHelpPage {
                    model.returnFromSecondaryPage()
                }
            case .settings:
                SettingsPage(model: model)
            }
        }

        /// Returns to the page (and Settings pane) the secondary page was opened from.
        private var secondaryReturnBar: some View {
            SettingsBackBar(title: model.secondaryReturnTitle) { model.returnFromSecondaryPage() }
        }
    }

    private struct DashboardSidebar: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var updates = SoftwareUpdateManager.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @ObservedObject private var monitor = JevMonitor.shared

        private let primarySections = DashboardSection.primarySections

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                brand
                    .padding(.horizontal, 18)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                VStack(spacing: 5) {
                    ForEach(primarySections) { section in
                        navigationButton(section)
                    }
                }
                .padding(.horizontal, 10)

                if let version = updates.availableVersion {
                    updateButton(version: version)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                Spacer(minLength: 20)

                // Reminder breaks only mean something once real-time monitoring is on.
                if consents.isEnabled(.jevMonitoring) || monitor.timedBreak != nil {
                    JevQuickPauseControl()
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }

                statusRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                footer
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            .background(LHTheme.sidebarBackground)
            .onAppear {
                updates.refreshAvailableUpdate()
            }
        }

        private var brand: some View {
            HStack(spacing: 11) {
                GoalongMark()
                    .stroke(
                        LHTheme.accent,
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 30, height: 21)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Logo Goalong")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Goalong")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.6)
                    Text("Historique sur ce Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func navigationButton(_ section: DashboardSection) -> some View {
            Button {
                model.selectSection(section)
            } label: {
                navigationLabel(
                    title: section.simpleTitle,
                    symbol: section == .overview ? "chart.bar.xaxis" : section.symbol,
                    selected: model.highlightedSidebarSection == section,
                    wraps: section == .monitoring
                )
            }
            .buttonStyle(LHNavigationButtonStyle(selected: model.highlightedSidebarSection == section))
            .accessibilityIdentifier("sidebar-\(section.rawValue)")
            .accessibilityLabel(section.simpleTitle)
            .accessibilityAddTraits(model.highlightedSidebarSection == section ? .isSelected : [])
        }

        private func navigationLabel(
            title: String,
            symbol: String,
            selected: Bool,
            wraps: Bool = false
        ) -> some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(wraps ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? LHTheme.text : LHTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: wraps ? 48 : 38)
            .contentShape(Rectangle())
        }

        private var statusRow: some View {
            Button {
                if !consents.isEnabled(.localComputerHistory) {
                    model.openRecordingSettings()
                } else if model.runtime.state == .permissionsMissing || model.runtime.state == .inputTapUnavailable {
                    model.selectSection(.settings); model.settingsPane = .permissions
                } else if model.runtime.storageFailure != nil {
                    model.selectSection(.settings); model.settingsPane = .storage
                } else { model.selectSection(.overview) }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTint : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTitle : "Suivi désactivé")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer()
                    if model.runtime.needsAttention {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(LHTheme.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(LHNavigationButtonStyle())
        }

        private func updateButton(version: String) -> some View {
            Button {
                updates.showAvailableUpdate()
            } label: {
                HStack(spacing: 9) {
                    if updates.isPreparingAvailableUpdate {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updates.isPreparingAvailableUpdate ? "Préparation…" : "Mise à jour disponible")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Version \(version) · installer")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.76)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(LHTheme.accent)
                .padding(.horizontal, 11)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LHTheme.accent.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .disabled(updates.isPreparingAvailableUpdate)
        }

        private var footer: some View {
            HStack {
                Button {
                    updates.checkForUpdates()
                } label: {
                    if updates.isPreparingAvailableUpdate {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text("Version \(Self.version.dropFirst())")
                    }
                }
                .buttonStyle(.plain)
                .disabled(!updates.isConfigured || updates.isPreparingAvailableUpdate)
                .help(
                    updates.isConfigured
                        ? "Rechercher les mises à jour"
                        : "Mises à jour désactivées dans cette version compilée localement"
                )
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LHTheme.secondaryText)
        }

        private static var version: String {
            let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return "v\(value ?? "0.6.0-dev")"
        }
    }

    extension DashboardSection {
        static let primarySections: [DashboardSection] = [.overview, .work, .history, .monitoring, .settings]

        var simpleTitle: String {
            switch self {
            case .overview, .analytics: return "Activité"
            case .work: return "Mon travail"
            case .history: return "Historique"
            case .monitoring: return "Surveillance temps réel"
            case .activity: return "Historique de ce Mac"
            case .screenTime: return "Temps d’écran"
            case .agentActivity: return "Conversations IA"
            case .chatGPTRecap: return "Activité"
            case .share: return "Partager"
            case .privacy: return "Confidentialité"
            case .cli: return "Terminal"
            case .settings: return "Réglages"
            }
        }

        var sidebarParent: DashboardSection {
            switch self {
            case .overview, .analytics, .chatGPTRecap, .share:
                return .overview
            case .monitoring:
                return .monitoring
            case .work:
                return .work
            case .history, .activity, .screenTime:
                return .history
            case .agentActivity, .privacy, .cli, .settings:
                return .settings
            }
        }
    }
#endif
