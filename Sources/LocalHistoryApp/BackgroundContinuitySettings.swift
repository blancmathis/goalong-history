#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    struct BackgroundContinuitySettings: View {
        @AppStorage(BackgroundContinuityPreferences.keepRunningKey) private var keepRunning = true
        @StateObject private var login = LaunchAtLoginManager()
        @ObservedObject private var continuity = BackgroundContinuityController.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Background recording", subtitle: "Keep Goalong available without leaving its window open.")
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Keep Goalong running in the background", isOn: $keepRunning)
                            .toggleStyle(.switch)
                        Text("On by default. Closing the window keeps your enabled sources running; Quit asks before stopping. Turn this off to quit when the last window closes. No extra service is installed, and your Mac can still sleep.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Start Goalong when I log in", isOn: Binding(
                            get: { login.isRegistered },
                            set: { _ = login.setUserPreference($0, surface: .settings) }
                        )).toggleStyle(.switch).disabled(login.isChanging)
                        Text(login.statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        if consents.isEnabled(.launchAtLogin) && !login.isEnabled {
                            Text("Automatic startup needs attention. Goalong will not override a change made in macOS Settings.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if login.requiresApproval || login.state == .unavailable {
                            Button("Open Login Items") { login.openLoginItemsSettings() }
                                .buttonStyle(.bordered)
                        }
                        if let message = login.message {
                            Text(message).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                        }
                        if let notice = continuity.interruptionNotice {
                            Divider()
                            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                            Button("Dismiss notice") { continuity.dismissInterruptionNotice() }
                                .buttonStyle(.bordered)
                        }
                        Text("Startup and background options do not enable additional data sources or resume a pause. A complete crash or Force Quit still requires reopening Goalong.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { login.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login.refresh()
            }
        }
    }
#endif
