#if os(macOS)
    import Foundation
    import SwiftUI

    struct LocalHistoryDashboardView: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            HStack(spacing: 0) {
                DashboardSidebar(model: model)
                    .frame(width: 238)
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
                ScreenTimePage(model: model)
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

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                brand
                    .padding(.horizontal, 18)
                    .padding(.top, 24)
                    .padding(.bottom, 18)

                runtimeCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)

                VStack(spacing: 5) {
                    ForEach(DashboardSection.allCases) { section in
                        Button {
                            model.selectSection(section)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 20)
                                Text(section.title)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                if section == .share, model.snapshot.sealedMinutes > 0 {
                                    Text("\(model.snapshot.sealedMinutes)")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                            }
                            .foregroundStyle(
                                model.selectedSection == section ? LHTheme.accent : Color.primary.opacity(0.78)
                            )
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(model.selectedSection == section ? LHTheme.accent.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)

                if let version = updates.availableVersion {
                    updateButton(version: version)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                } else if updates.requiresSignedBuild {
                    enableUpdatesButton
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                Spacer(minLength: 20)

                trustCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)

                HStack {
                    Text(ProductIdentity.displayName)
                    Spacer()
                    Button(Self.version) {
                        if updates.isConfigured {
                            updates.checkForUpdates()
                        } else {
                            updates.installUpdateEnabledBuild()
                        }
                    }
                    .buttonStyle(.plain)
                    .help(
                        updates.isConfigured
                            ? "Check for updates"
                            : "Install the release build to enable in-app updates"
                    )
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
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
                    Image(systemName: "clock.badge.checkmark.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductIdentity.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Private, verifiable activity")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var runtimeCard: some View {
            Button {
                model.selectSection(model.runtime.state == .permissionsMissing ? .privacy : .overview)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.runtime.displayTint)
                        .frame(width: 8, height: 8)
                        .shadow(color: model.runtime.displayTint.opacity(0.45), radius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.runtime.displayTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(model.runtime.verificationEnabled ? "Verification enabled" : "Local-only mode")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }

        private func updateButton(version: String) -> some View {
            Button {
                updates.showAvailableUpdate()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(LHTheme.accent.opacity(0.18), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Review and install \(ProductIdentity.displayName) \(version)")
        }

        private var enableUpdatesButton: some View {
            Button {
                updates.installUpdateEnabledBuild()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Enable app updates")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Install the release build once")
                            .font(.system(size: 9, weight: .medium))
                            .opacity(0.76)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(LHTheme.accent)
                .padding(.horizontal, 11)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LHTheme.accent.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(LHTheme.accent.opacity(0.18), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Download the latest release build. Your history and settings are preserved.")
        }

        private var trustCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Device identity", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LHTheme.success)
                    Spacer()
                }
                Text(model.deviceProtectionTitle)
                    .font(.system(size: 10, weight: .medium))
                Text("Device \(model.deviceID.prefix(10))…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LHTheme.success.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(LHTheme.success.opacity(0.15), lineWidth: 1)
                    )
            )
        }

        private static var version: String {
            let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return "v\(value ?? "0.5.1-dev")"
        }
    }
#endif
