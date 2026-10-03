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
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
            .buttonStyle(LHNavigationButtonStyle(cornerRadius: 6)).accessibilityLabel("En savoir plus")
            .popover(isPresented: $presented) {
                Text(text).font(.system(size: 13)).padding(18).frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
    }
}

/// A row that leads somewhere: neutral glyph, name, current value, chevron.
struct GoalongSettingsLink: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(value).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                GoalongRowChevron()
            }.padding(.horizontal, LHTheme.cardInset).frame(minHeight: detail == nil ? 44 : 56).contentShape(Rectangle())
        }.buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
            .accessibilityElement(children: .combine)
    }
}

/// Hairline between two rows of a group, aligned on the text column.
struct GoalongRowDivider: View {
    var inset: CGFloat = LHTheme.cardInset + 34
    var body: some View {
        Rectangle().fill(LHTheme.separator).frame(height: 1).padding(.leading, inset)
    }
}

struct GoalongSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            LHCard { VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// A titled list of full-width rows (links, switches) with hairlines between them.
struct GoalongSettingsList<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            LHCard(padding: 0) { VStack(spacing: 0, content: content) }
        }
    }
}

@MainActor struct GoalongDataStatus: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @ObservedObject private var analysis = ChatGPTRecapRuntime.shared
    @ObservedObject private var work = GoalongWorkStore.shared
    @State private var pause = GoalongGlobalPause.load()
    @State private var analysisSelection = GoalongAnalysisSelection.load()
    @ObservedObject private var exclusions = GoalongExclusionStore.shared
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var visibleText = false
    var body: some View {
        LHCard(padding: 0) {
            VStack(spacing: 0) {
                row("Enregistrement local", status: !consents.isEnabled(.localComputerHistory) ? "Désactivé" : model.runtime.state == .paused ? "En pause" : GoalongRecordingSetup.profile(model.appliedSettings, visibleText: visibleText),
                    detail: "Ce que Goalong conserve sur ce Mac", symbol: "internaldrive", pane: .recording)
                GoalongRowDivider()
                row("Envoi à Goalong", status: sender.enabled ? "Chaque jour" : "À la demande",
                    detail: "Compte, données et fréquence des envois", symbol: "arrow.up.circle", pane: .website)
                GoalongRowDivider()
                row("Analyse ChatGPT", status: chatGPTStatus,
                    detail: "Applications, textes, noms masqués et consignes", symbol: "sparkles", pane: .chatGPT)
            }
        }.onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
            .onReceive(NotificationCenter.default.publisher(for: .goalongAnalysisSelectionDidChange)) { _ in analysisSelection = .load() }
    }
    /// Two automations run through ChatGPT: classifying time when Activité opens, and daily
    /// reports. The status names the ones that really run, not only the report schedule.
    private var chatGPTStatus: String {
        guard consents.isEnabled(.chatGPTAnalysis), analysisSelection.isValid(for: exclusions.policy) else { return "À configurer" }
        switch analysis.connectionState {
        case .signedOut, .codexUnavailable, .unsupportedCredentialMode, .failed: return "Non connecté"
        case .checking, .connected: break
        }
        switch (work.automatic && !work.definition.isEmpty, analysis.automaticRecapsEnabled) {
        case (true, true): return "Automatique"
        case (true, false): return "Classement automatique"
        case (false, true): return "Bilans automatiques"
        case (false, false): return "À la demande"
        }
    }
    private func row(_ title: String, status: String, detail: String, symbol: String, pane: SettingsPane) -> some View {
        // A disabled or unconfigured service is not "suspended": the global pause changes nothing for it.
        GoalongSettingsLink(title: title, value: pause.blocksActivity && !["Désactivé", "À configurer", "Non connecté"].contains(status) ? "Suspendu" : status,
                            symbol: symbol, detail: detail) {
            model.selectSection(.settings); model.settingsPane = pane
        }
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
                .font(.system(size: 14, weight: .medium)).frame(width: 22).foregroundStyle(LHTheme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title).font(.system(size: 13, weight: .medium))
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if consents.isEnabled(capability) {
                if validation.checking { ProgressView().controlSize(.small) }
                else if validation.result == .ready {
                    Label("Autorisé", systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.success)
                }
                else { Button("Configurer") { showing = true }.buttonStyle(LHSecondaryButtonStyle()) }
            }
        }
        .onAppear { check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
        .onDisappear { validation.cancel() }
        .sheet(isPresented: $showing, onDismiss: check) {
            SourceActivationSheet(capability: capability, surface: .settings, prepare: {}, check: SourceAccessService.check)
                .goalongControls()
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
