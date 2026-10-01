#if os(macOS)
import SwiftUI
import Foundation
import LocalHistoryCore

/// The dormant recorder stays off until consent. Every first-activation surface
/// uses this complete proposal instead of exposing the dormant defaults as choices.
enum GoalongRecordingSetup {
    static let preparedKey = "goalong.recordingProposal.v2"
    static let reviewedKey = "goalong.recordingChoicesReviewed.v3"
    static let explicitChoicesKey = "goalong.recordingExplicitChoices.v3"
    struct Proposal: Equatable {
        var settings: DashboardSettingsDraft
        var visibleText: Bool
    }
    static func proposed(from current: DashboardSettingsDraft) -> DashboardSettingsDraft {
        var next = current
        for signal in RecordingSignal.allCases { next[keyPath: signal.keyPath] = true }
        return next // Do not change private windows, exclusions, retention or sends.
    }
    static func hasReviewedChoices(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: reviewedKey) || defaults.bool(forKey: preparedKey)
            || defaults.bool(forKey: "goalongOnboardingPrivacyReviewedV1")
    }
    static func proposal(from current: DashboardSettingsDraft, visibleText: Bool,
                         complete: Bool = false, defaults: UserDefaults = .standard) -> Proposal {
        if !complete && hasReviewedChoices(defaults: defaults) {
            return Proposal(settings: current, visibleText: visibleText)
        }
        var result = Proposal(settings: proposed(from: current), visibleText: true)
        if !complete {
            let explicit = defaults.dictionary(forKey: explicitChoicesKey) ?? [:]
            for signal in RecordingSignal.allCases {
                if let value = explicit[signal.rawValue] as? Bool { result.settings[keyPath: signal.keyPath] = value }
            }
            if let value = explicit["visibleText"] as? Bool { result.visibleText = value }
        }
        return result
    }
    static func rememberChanges(from before: DashboardSettingsDraft, to after: DashboardSettingsDraft,
                                defaults: UserDefaults = .standard) {
        var choices = defaults.dictionary(forKey: explicitChoicesKey) ?? [:]
        for signal in RecordingSignal.allCases where before[keyPath: signal.keyPath] != after[keyPath: signal.keyPath] {
            choices[signal.rawValue] = after[keyPath: signal.keyPath]
        }
        defaults.set(choices, forKey: explicitChoicesKey)
    }
    static func rememberVisibleText(_ enabled: Bool, defaults: UserDefaults = .standard) {
        var choices = defaults.dictionary(forKey: explicitChoicesKey) ?? [:]
        choices["visibleText"] = enabled
        defaults.set(choices, forKey: explicitChoicesKey)
    }
    static func enabledCount(_ settings: DashboardSettingsDraft, visibleText: Bool) -> Int {
        RecordingSignal.allCases.filter { settings[keyPath: $0.keyPath] }.count + (visibleText ? 1 : 0)
    }
    static func profile(_ settings: DashboardSettingsDraft, visibleText: Bool) -> String {
        let count = enabledCount(settings, visibleText: visibleText)
        if count == 8 { return "Complet · 8/8" }
        if count == 0 { return "Applications seules" }
        return "Personnalisé · \(count)/8"
    }
}

private struct GoalongRecordingModelKey: EnvironmentKey {
    static let defaultValue: DashboardViewModel? = nil
}
extension EnvironmentValues {
    var goalongRecordingModel: DashboardViewModel? {
        get { self[GoalongRecordingModelKey.self] }
        set { self[GoalongRecordingModelKey.self] = newValue }
    }
}

struct GoalongVisibleTextChoice: View {
    @Binding var enabled: Bool
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Texte affiché").font(.system(size: 13, weight: .medium))
                Text("Peut contenir des messages et documents personnels.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer()
            Toggle("Texte affiché", isOn: $enabled).labelsHidden().toggleStyle(.goalongSwitchOnly)
                .accessibilityIdentifier("recording-visible-text-draft")
        }
    }
}

/// Used by initial activation AND by completion of an older partial profile.
/// Merely opening or cancelling this view never changes recording or sharing.
struct GoalongRecordingSetupSheet: View {
    @ObservedObject var model: DashboardViewModel
    var activating = false
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var proposal: GoalongRecordingSetup.Proposal
    @State private var error: String?
    init(model: DashboardViewModel, activating: Bool = false, complete: Bool = false,
         onSaved: @escaping () -> Void = {}) {
        self.model = model; self.activating = activating; self.onSaved = onSaved
        _proposal = State(initialValue: GoalongRecordingSetup.proposal(from: model.appliedSettings,
            visibleText: ActivityAnalysisPreferences.richContextEnabled, complete: complete))
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Votre enregistrement local").font(LHTheme.sheetTitleFont)
                Text("Tout est proposé. Décochez ce que vous ne souhaitez pas conserver.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LHCard {
                        VStack(spacing: 16) {
                            GoalongVisibleTextChoice(enabled: $proposal.visibleText)
                            Divider()
                            RecordingChoicesView(draft: $proposal.settings)
                        }
                    }
                    Text("Sur ce Mac uniquement. Les exclusions et la navigation privée gardent vos réglages. Aucun envoi n’est autorisé ici.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(LHTheme.warning) }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("recording-setup-cancel")
                Spacer()
                Button(activating ? "Valider et activer" : "Enregistrer mes choix") {
                    guard model.applyRecordingSetup(proposal) else {
                        error = model.alert?.message ?? "Les choix n’ont pas été enregistrés. Réessayez."
                        model.alert = nil; return
                    }
                    onSaved(); dismiss()
                    if !activating { GoalongToastCenter.shared.show("Choix d’enregistrement mis à jour") }
                }.buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("recording-setup-confirm")
            }.padding(20)
        }.frame(width: 700, height: 610).background(LHTheme.pageBackground)
    }
}

struct GoalongCompleteRecordingButton: View {
    @ObservedObject var model: DashboardViewModel
    @State private var showing = false
    var body: some View {
        Button("Configurer le suivi complet") { showing = true }
            .buttonStyle(LHSecondaryButtonStyle())
            .accessibilityIdentifier("recording-complete-setup")
            .sheet(isPresented: $showing) { GoalongRecordingSetupSheet(model: model, complete: true).goalongControls() }
    }
}

/// Says on the landing page why no new activity arrives, with the one useful action.
/// The global privacy stop and storage failures keep their own banners.
struct GoalongRecordingStateNotice: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @State private var globalPause = GoalongGlobalPause.load()

    enum Kind: Equatable { case off, paused, permissions }

    static func kind(localEnabled: Bool, globallyPaused: Bool, dashboardVisible: Bool,
                     runtime: RuntimeStateKind) -> Kind? {
        guard !globallyPaused else { return nil }
        guard localEnabled else { return .off }
        // The runtime is only refreshed while the window is visible; never alarm on a stale value.
        guard dashboardVisible else { return nil }
        switch runtime {
        case .paused, .suppressed(.manualPause): return .paused
        case .permissionsMissing: return .permissions
        default: return nil
        }
    }

    private var kind: Kind? {
        Self.kind(localEnabled: consents.isEnabled(.localComputerHistory),
                  globallyPaused: globalPause.blocksActivity,
                  dashboardVisible: model.dashboardIsVisible, runtime: model.runtime.state)
    }

    var body: some View {
        Group {
            if let kind {
                LHCard(padding: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: symbol(kind)).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(kind == .permissions ? LHTheme.warning : LHTheme.secondaryText)
                            .frame(width: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(kind)).font(.system(size: 13, weight: .semibold))
                            Text(detail(kind)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button(actionTitle(kind)) { perform(kind) }
                            .buttonStyle(LHPrimaryButtonStyle())
                            .accessibilityIdentifier("activity-recording-action")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("activity-recording-state")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in globalPause = .load() }
    }

    private func symbol(_ kind: Kind) -> String {
        switch kind {
        case .off: return "record.circle"
        case .paused: return "pause.circle"
        case .permissions: return "exclamationmark.triangle"
        }
    }
    private func title(_ kind: Kind) -> String {
        switch kind {
        case .off: return "L’enregistrement de ce Mac est désactivé"
        case .paused: return "Enregistrement en pause"
        case .permissions: return "Autorisation macOS à rétablir"
        }
    }
    private func detail(_ kind: Kind) -> String {
        switch kind {
        case .off: return "Activez-le pour voir ici votre temps actif, vos blocs de travail et vos apps et sites. Tout reste sur ce Mac."
        case .paused: return "Aucune nouvelle activité n’est enregistrée. L’historique existant reste consultable."
        case .permissions: return "Rien n’est enregistré tant que l’accès n’est pas rétabli. Goalong vous guide pas à pas."
        }
    }
    private func actionTitle(_ kind: Kind) -> String {
        switch kind {
        case .off: return "Activer…"
        case .paused: return "Reprendre"
        case .permissions: return "Rétablir l’accès…"
        }
    }
    private func perform(_ kind: Kind) {
        switch kind {
        case .off: model.openRecordingSettings()
        case .paused: model.togglePause()
        case .permissions: model.selectSection(.settings); model.settingsPane = .permissions
        }
    }
}

struct GoalongRecordingCoverageNotice: View {
    static let dismissedProfileKey = "goalong.activity.coverageNoticeDismissedProfile"
    @ObservedObject var model: DashboardViewModel
    /// On Activité a deliberate custom profile can be acknowledged once; Settings always shows it.
    var dismissible = false
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var visibleText = false
    @AppStorage(GoalongRecordingCoverageNotice.dismissedProfileKey) private var dismissedProfile = ""
    private var count: Int { GoalongRecordingSetup.enabledCount(model.appliedSettings, visibleText: visibleText) }
    private var profile: String { GoalongRecordingSetup.profile(model.appliedSettings, visibleText: visibleText) }
    var body: some View {
        if consents.isEnabled(.localComputerHistory) && count < 8 && !(dismissible && dismissedProfile == profile) {
            LHCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(count == 0 ? "Seules les applications sont enregistrées" : "Suivi personnalisé · \(count)/8 types de détails")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Certains clics, interactions ou textes ne sont pas enregistrés selon vos choix. Vos durées et vos apps restent mesurées.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    GoalongCompleteRecordingButton(model: model)
                    if dismissible {
                        Button { dismissedProfile = profile } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(LHQuietButtonStyle())
                        .help("Garder mes choix et masquer ce message")
                        .accessibilityLabel("Garder mes choix et masquer ce message")
                        .accessibilityIdentifier("recording-incomplete-dismiss")
                    }
                }
            }.accessibilityIdentifier("recording-incomplete-notice")
        }
    }
}
#endif
