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
            LHCard { VStack(alignment: .leading, spacing: 16, content: content).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

@MainActor struct GoalongDataStatus: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @ObservedObject private var analysis = ChatGPTRecapRuntime.shared
    @State private var pause = GoalongGlobalPause.load()
    @State private var analysisSelection = GoalongAnalysisSelection.load()
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var visibleText = false
    var body: some View {
        VStack(spacing: 12) {
            card("Enregistrement local", status: !consents.isEnabled(.localComputerHistory) ? "Désactivé" : model.runtime.state == .paused ? "En pause" : GoalongRecordingSetup.profile(model.appliedSettings, visibleText: visibleText),
                 detail: "Ce que Goalong conserve sur ce Mac", symbol: "internaldrive", pane: .recording)
            card("Envoi à Goalong", status: sender.enabled ? "Chaque jour" : "À la demande",
                 detail: "Compte, données et fréquence des envois", symbol: "arrow.up.circle", pane: .website)
            card("Analyse ChatGPT", status: !consents.isEnabled(.chatGPTAnalysis) || !analysisSelection.isValid(for: exclusions.policy) ? "À configurer" : analysis.automaticRecapsEnabled ? "Automatique" : "À la demande",
                 detail: "Applications, textes, noms masqués et consignes", symbol: "sparkles", pane: .chatGPT)
        }.onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
            .onReceive(NotificationCenter.default.publisher(for: .goalongAnalysisSelectionDidChange)) { _ in analysisSelection = .load() }
    }
    private func card(_ title: String, status: String, detail: String, symbol: String, pane: SettingsPane) -> some View {
        Button { model.selectSection(.settings); model.settingsPane = pane } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 23)).foregroundStyle(LHTheme.accent)
                    .frame(width: 48, height: 48).background(LHTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(pause.blocksActivity ? "Suspendu" : status).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(LHNavigationButtonStyle(cornerRadius: 14))
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LHTheme.separator))
            .accessibilityIdentifier("settings-\(pane)")
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
