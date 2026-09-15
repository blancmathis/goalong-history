#if os(macOS)
import SwiftUI
import AppKit
import LocalHistoryCore

extension Notification.Name {
    static let goalongRecordingChoicesDidChange = Notification.Name("goalong.recording.choices.changed")
    static let goalongAnalysisSelectionDidChange = Notification.Name("goalong.analysis.selection.changed")
}

struct GoalongHelpButton: View {
    let text: String
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: { Image(systemName: "info.circle").frame(width: 28, height: 28) }
            .buttonStyle(.borderless).accessibilityLabel("En savoir plus")
            .popover(isPresented: $presented) {
                Text(text).font(.system(size: 13)).padding(18).frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
    }
}

struct GoalongSettingsLink: View {
    let title: String
    let value: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(LHTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(LHTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 12)
                Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
            .accessibilityElement(children: .combine)
    }
}

struct GoalongSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
            LHCard { VStack(alignment: .leading, spacing: 16, content: content) }
        }
    }
}

@MainActor struct GoalongDataStatus: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @ObservedObject private var analysis = ChatGPTRecapRuntime.shared
    @State private var globalPause = GoalongGlobalPause.load()
    var body: some View {
        VStack(spacing: 12) {
            row("Enregistrement local", value: !consents.isEnabled(.localComputerHistory) ? "Désactivé" : model.runtime.state == .paused ? "En pause" : model.runtime.displayTitle,
                symbol: "internaldrive", pane: .recording)
            row("Envoi à Goalong", value: sender.enabled ? "Chaque jour" : "Automatique désactivé", symbol: "arrow.up.circle", pane: .connections)
            row("Analyse ChatGPT", value: !consents.isEnabled(.chatGPTAnalysis) ? "Désactivée" : !GoalongAnalysisSelection.load().isValid(for: GoalongExclusionStore.shared.policy) ? "À configurer" : analysis.automaticRecapsEnabled ? "Automatique" : "À la demande",
                symbol: "sparkles", pane: .connections)
        }.onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in globalPause = .load() }
    }
    private func row(_ title: String, value: String, symbol: String, pane: SettingsPane) -> some View {
        Button { model.selectSection(.settings); model.settingsPane = pane } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(globalPause.blocksActivity ? "Suspendu" : value).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}

@MainActor struct GoalongPermissionRow: View {
    let capability: GoalongCapability
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @StateObject private var validation = SourceAccessValidation()
    @State private var showing = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capability == .appleScreenTime ? "hourglass" : capability == .aiConversations ? "folder" : "accessibility")
                .frame(width: 24).foregroundStyle(LHTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.title).font(.system(size: 14, weight: .medium))
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if consents.isEnabled(capability) {
                if validation.checking { ProgressView().controlSize(.small) }
                else if validation.result == .ready { Label("Autorisé", systemImage: "checkmark.circle").font(.system(size: 12)) }
                else { Button("Configurer") { showing = true }.buttonStyle(.bordered) }
            }
        }
        .onAppear { check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
        .onDisappear { validation.cancel() }
        .sheet(isPresented: $showing, onDismiss: check) {
            SourceActivationSheet(capability: capability, surface: .settings, prepare: {}, check: SourceAccessService.check)
        }
    }
    private var status: String {
        guard consents.isEnabled(capability) else { return "Fonction désactivée · aucun accès demandé" }
        guard let result = validation.result else { return "Vérification…" }
        switch result {
        case .ready: return "L’accès nécessaire est disponible"
        case .accessibility: return "Accessibilité requise"
        case .inputMonitoring: return "Surveillance de l’entrée requise"
        case .fullDiskAccess: return "Accès complet au disque requis"
        case .screenTimeSetup: return "Aucune donnée Apple disponible"
        case .unavailable: return "Source indisponible"
        }
    }
    private func check() { validation.validate(capability, check: SourceAccessService.check) }
}
#endif
