#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct PrivacyChoicesOverview: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @State private var showingSharing = false
    @State private var showingRetention = false
    @State private var retentionSummary = ""
    @State private var retentionEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Your applied choices", systemImage: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                    Text("This summary shows saved settings, not an unsaved recording draft. Source consent, macOS access and actual data availability are separate.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    ForEach([GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]) { capability in
                        HStack {
                            Text(capability.title).font(.system(size: 13))
                            Spacer()
                            Text(consents.isEnabled(capability) ? "Source enabled" : "Source off")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Divider()
                    Text(model.appliedSettings.recordingSummary).font(.system(size: 13))
                    Text(model.appliedSettings.capturePrivateBrowsing
                         ? "Detected private windows: included by your saved choice."
                         : "Detected private windows: excluded. Detection depends on the browser; Pause is the safest control for a sensitive activity.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Change recording details & exclusions") { model.openRecordingSettings() }.buttonStyle(LHPrimaryButtonStyle())
                        Button("Manage sources") { model.selectSection(.settings) }.buttonStyle(.bordered)
                    }
                    Text("Recording filters apply to Computer History, not to Apple's Screen Time data or original AI conversations. Each source and each outgoing share has its own controls.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    Label("What can leave this Mac", systemImage: "arrow.up.doc")
                        .font(.system(size: 16, weight: .semibold))
                    Text(sender.enabled ? "Daily website sync is enabled." : "Daily website sync is off or paused.")
                        .font(.system(size: 13, weight: .semibold))
                    if sender.savedConfiguration != nil {
                        Text(sender.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(consents.isEnabled(.chatGPTAnalysis)
                         ? "ChatGPT analysis is enabled. Runs you start or schedule may send their selected context to the connected provider."
                         : "ChatGPT analysis is off. Turning it on is a separate choice from local recording.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("A website upload and sharing with other people are different actions. The website's active audience rules apply after upload. A local export creates a file; anyone you give it to can keep a copy.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Review website sharing…") { showingSharing = true }.buttonStyle(.bordered)
                        if sender.enabled {
                            Button("Pause daily sync") { sender.stop() }.buttonStyle(.bordered)
                        }
                    }
                    Text("Pausing, disconnecting or deleting locally does not erase data already received. A transfer already in progress may finish. Manage recipients and remove remote data on the website or provider. Update checks can contact the update service without sending activity contents.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            LHCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Retention is a separate choice", systemImage: "calendar.badge.clock")
                        .font(.system(size: 16, weight: .semibold))
                    Text(retentionEnabled ? "Automatic cleanup is enabled for the rules below." : "Automatic cleanup is off. Local data stays until explicit deletion.")
                        .font(.system(size: 13, weight: .medium))
                    if retentionEnabled { Text(retentionSummary).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Button("Choose retention by data type…") { showingRetention = true }.buttonStyle(.bordered)
                    Text("Activity files are readable to your macOS account; file permissions are not app-level encryption. Retention does not cover every store: Apple data, AI originals, ChatGPT recap/run history, exports, backups and remote copies need their own controls.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refreshRetention() }
        .onReceive(NotificationCenter.default.publisher(for: .goalongRetentionPolicyDidChange)) { _ in refreshRetention() }
        .sheet(isPresented: $showingSharing) { GoalongWebsiteSharingSheet() }
        .sheet(isPresented: $showingRetention, onDismiss: refreshRetention) { HistoryRetentionSettingsSheet() }
    }
    private func refreshRetention() {
        let store = HistoryRetentionStore(legacyRetentionDays: model.appliedSettings.retentionDays)
        retentionEnabled = store.isAutomaticCleanupEnabled
        retentionSummary = store.policy.retentionDescription
    }
}
#endif
