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
                            .safeAreaInset(edge: .top, spacing: 0) { GoalongGlobalPauseBanner(model: model) }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if model.settingsHaveChanges && model.selectedSection != .settings {
                                    HStack(spacing: 12) {
                                        Label("Recording changes are not saved", systemImage: "pencil.circle")
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Button("Discard draft") { model.discardSettingsChanges() }
                                        Button("Review changes") { model.openRecordingSettings() }
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
            case .history:
                UnifiedHistoryPage(model: model)
            case .monitoring:
                JevMonitoringPage(onOpenRecording: { model.openRecordingSettings() })
            case .activity:
                ActivityPage(
                    model: model,
                    initialMode: .computerHistory,
                    showsModePicker: false
                )
            case .screenTime:
                GoalongScreenTimePage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { activityReturnBar }
            case .agentActivity:
                AgentActivityPage(agents: model.agentActivityRuntime)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        SettingsBackBar { model.selectSection(.settings) }
                    }
            case .chatGPTRecap:
                ChatGPTRecapPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { activityReturnBar }
            case .share:
                SharePage(model: model)
            case .privacy:
                PrivacyPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        SettingsBackBar { model.selectSection(.settings) }
                    }
            case .cli:
                CLIHelpPage {
                    model.selectSection(.settings)
                }
            case .settings:
                SettingsPage(model: model)
            }
        }

        private var activityReturnBar: some View {
            HStack {
                Button { model.selectSection(.overview) } label: {
                    Label("Retour à Activité", systemImage: "chevron.left")
                }.buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                Spacer()
            }.padding(.horizontal, LHTheme.pageInset).padding(.vertical, 10)
                .background(LHTheme.pageBackground)
        }
    }

    private struct DashboardSidebar: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var updates = SoftwareUpdateManager.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

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

                JevQuickPauseControl()
                    .padding(.horizontal, 16).padding(.bottom, 12)

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
                    .accessibilityLabel("Goalong logo")

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
                    selected: model.selectedSection.sidebarParent == section,
                    wraps: section == .monitoring
                )
            }
            .buttonStyle(LHNavigationButtonStyle(selected: model.selectedSection.sidebarParent == section))
            .accessibilityIdentifier("sidebar-\(section.rawValue)")
            .accessibilityLabel(section.simpleTitle)
            .accessibilityAddTraits(model.selectedSection.sidebarParent == section ? .isSelected : [])
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
                } else { model.selectSection(.overview) }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTint : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTitle : "Enregistrement désactivé")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if model.runtime.state == .permissionsMissing || model.runtime.state == .inputTapUnavailable {
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
                        Text(updates.isPreparingAvailableUpdate ? "Preparing update…" : "Update available")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(ProductIdentity.displayName) \(version)")
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
                Text("Historique")
                    .help(ProductIdentity.displayName)
                Spacer()
                Button {
                    updates.checkForUpdates()
                } label: {
                    if updates.isPreparingAvailableUpdate {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(Self.version)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!updates.isConfigured || updates.isPreparingAvailableUpdate)
                .help(
                    updates.isConfigured
                        ? "Check for updates"
                        : "Updates are disabled in this privacy-audited source build"
                )
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
        static let primarySections: [DashboardSection] = [.overview, .history, .monitoring, .settings]

        var simpleTitle: String {
            switch self {
            case .overview, .analytics: return "Activité"
            case .history: return "Historique"
            case .monitoring: return "Surveillance temps réel"
            case .activity: return "Computer History"
            case .screenTime: return "Screen Time"
            case .agentActivity: return "AI conversations"
            case .chatGPTRecap: return "Activity"
            case .share: return "Share"
            case .privacy: return "Privacy"
            case .cli: return "CLI"
            case .settings: return "Réglages"
            }
        }

        var sidebarParent: DashboardSection {
            switch self {
            case .overview, .analytics, .chatGPTRecap, .share:
                return .overview
            case .monitoring:
                return .monitoring
            case .history, .activity, .screenTime:
                return .history
            case .agentActivity, .privacy, .cli, .settings:
                return .settings
            }
        }
    }
#endif
