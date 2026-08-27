#if os(macOS)
    import Foundation
    import SwiftUI

    struct LocalHistoryDashboardView: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            HStack(spacing: 0) {
                DashboardSidebar(model: model)
                    .frame(width: 220)
                Rectangle()
                    .fill(LHTheme.separator)
                    .frame(width: 1)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LHTheme.pageBackground)
            .frame(minWidth: 1080, minHeight: 680)
            .sheet(isPresented: $model.showWelcome) {
                LocalHistoryOnboardingView(model: model)
                    .interactiveDismissDisabled()
            }
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
            case .activity:
                ActivityPage(model: model)
            case .screenTime:
                GoalongScreenTimePage(model: model)
            case .agentActivity:
                AgentActivityPage(agents: model.agentActivityRuntime)
            case .chatGPTRecap:
                ChatGPTRecapPage(model: model)
            case .share:
                SharePage(model: model)
            case .privacy:
                PrivacyPage(model: model)
            case .settings:
                SettingsPage(model: model)
            }
        }
    }

    private struct DashboardSidebar: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var updates = SoftwareUpdateManager.shared

        private let primarySections: [DashboardSection] = [.overview, .activity, .share]
        private let sourceSections: [DashboardSection] = [.screenTime, .agentActivity, .chatGPTRecap]
        private let utilitySections: [DashboardSection] = [.privacy, .settings]

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

                    navigationDivider

                    ForEach(sourceSections) { section in
                        navigationButton(section)
                    }

                    navigationDivider

                    ForEach(utilitySections) { section in
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
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [LHTheme.accent, Color(red: 0.34, green: 0.34, blue: 0.94)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    GoalongMark()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 2.35, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 25, height: 17)
                }
                .frame(width: 38, height: 38)
                .accessibilityLabel("Goalong logo")

                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductIdentity.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Private activity history")
                        .font(.system(size: 9, weight: .medium))
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
                    selected: model.selectedSection == section
                )
            }
            .buttonStyle(.plain)
        }

        private func navigationLabel(
            title: String,
            symbol: String,
            selected: Bool
        ) -> some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if title == DashboardSection.share.simpleTitle, model.snapshot.sealedMinutes > 0 {
                    Text("\(model.snapshot.sealedMinutes)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .foregroundStyle(selected ? LHTheme.accent : Color.primary.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? LHTheme.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }

        private var navigationDivider: some View {
            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
        }

        private var statusRow: some View {
            Button {
                model.selectSection(model.runtime.state == .permissionsMissing ? .privacy : .overview)
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(model.runtime.displayTint)
                        .frame(width: 7, height: 7)
                    Text(model.runtime.displayTitle)
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
            return "v\(value ?? "0.5.1-dev")"
        }
    }

    private extension DashboardSection {
        var simpleTitle: String {
            switch self {
            case .overview: return "Overview"
            case .activity: return "History"
            case .screenTime: return "Screen Time"
            case .agentActivity: return "AI conversations"
            case .chatGPTRecap: return "AI recap settings"
            case .share: return "Share"
            case .privacy: return "Privacy"
            case .settings: return "Settings"
            }
        }
    }
#endif
