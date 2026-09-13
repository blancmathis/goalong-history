#if os(macOS)
    import Foundation
    import SwiftUI

    struct LocalHistoryDashboardView: View {
        @ObservedObject var model: DashboardViewModel

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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(LHTheme.pageBackground)
            .frame(minWidth: 1080, minHeight: 680)
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
            case .overview:
                OverviewPage(model: model)
            case .history:
                UnifiedHistoryPage(model: model)
            case .activity:
                ActivityPage(
                    model: model,
                    initialMode: .computerHistory,
                    showsModePicker: false
                )
            case .screenTime:
                GoalongScreenTimePage(model: model)
            case .agentActivity:
                AgentActivityPage(agents: model.agentActivityRuntime)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        SettingsBackBar { model.selectSection(.settings) }
                    }
            case .chatGPTRecap:
                ChatGPTRecapPage(model: model)
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
    }

    private struct DashboardSidebar: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var updates = SoftwareUpdateManager.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        private let primarySections: [DashboardSection] = [.overview, .history, .settings]

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
                        Color.primary.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 26, height: 18)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("Goalong logo")

                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductIdentity.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Private activity history")
                        .font(.system(size: 10))
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
                    symbol: section.symbol,
                    selected: model.selectedSection.sidebarParent == section
                )
            }
            .buttonStyle(LHNavigationButtonStyle(selected: model.selectedSection.sidebarParent == section))
            .accessibilityAddTraits(model.selectedSection.sidebarParent == section ? .isSelected : [])
        }

        private func navigationLabel(
            title: String,
            symbol: String,
            selected: Bool
        ) -> some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }

        private var statusRow: some View {
            Button {
                model.selectSection(!consents.isEnabled(.localComputerHistory) ? .settings : model.runtime.state == .permissionsMissing ? .privacy : .overview)
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTint : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTitle : "Recording off")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if model.runtime.state == .permissionsMissing || model.runtime.state == .inputTapUnavailable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
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
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(ProductIdentity.displayName) \(version)")
                            .font(.system(size: 9, weight: .medium))
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
                Text(ProductIdentity.displayName)
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
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
        }

        private static var version: String {
            let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return "v\(value ?? "0.6.0-dev")"
        }
    }

    extension DashboardSection {
        fileprivate var simpleTitle: String {
            switch self {
            case .overview: return "Today"
            case .history: return "History"
            case .activity: return "Computer History"
            case .screenTime: return "Screen Time"
            case .agentActivity: return "AI conversations"
            case .chatGPTRecap: return "Activity"
            case .share: return "Share"
            case .privacy: return "Privacy"
            case .cli: return "CLI"
            case .settings: return "Settings"
            }
        }

        fileprivate var sidebarParent: DashboardSection {
            switch self {
            case .overview, .chatGPTRecap, .share:
                return .overview
            case .history, .activity, .screenTime:
                return .history
            case .agentActivity, .privacy, .cli, .settings:
                return .settings
            }
        }
    }
#endif
