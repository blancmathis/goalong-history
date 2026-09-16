#if os(macOS)
    import SwiftUI

    struct LocalHistoryOnboardingView: View {
        @Environment(\.colorSchemeContrast) var contrast
        @ObservedObject var model: DashboardViewModel
        @StateObject var launchAtLogin = LaunchAtLoginManager()
        @ObservedObject var consents = GoalongCapabilityConsentStore.shared
        @AppStorage("goalongOnboardingStep") var step: SetupStep = .privacy
        @State var launchAtLoginPreference = false
        @State var note: String?
        @State var visibleTextDraft = true
        @State var localRecordingDraft = true
        @State private var showingLocalActivation = false
        @Environment(\.sourceAccessCheck) private var checkAccess
        @State private var loadedProposal = false
        @State var showingRetention = false
        @AppStorage("goalongOnboardingPrivacyReviewedV1") var privacyReviewed = false
        @State var checkingSources: Set<GoalongCapability> = []

        var body: some View {
            HStack(spacing: 0) {
                sidebar.frame(width: 218)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(step.navigationTitle).font(.system(size: 20, weight: .semibold))
                        Spacer()
                        Text("\(step.position) / \(SetupStep.allCases.count)")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28).frame(height: 72)
                    Divider()
                    ScrollView {
                        page
                            .frame(maxWidth: 780, alignment: .leading)
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    Divider()
                    footer
                }
                .background(LHTheme.pageBackground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.goalongRecordingModel, model)
            .sheet(isPresented: $showingLocalActivation) {
                SourceActivationSheet(capability: .localComputerHistory, surface: .onboarding,
                    prepare: {}, check: checkAccess)
                    .environment(\.goalongRecordingModel, model)
            }
            .onAppear {
                if step == .welcome || !privacyReviewed { step = .privacy }
                if !loadedProposal {
                    let previouslyReviewed = GoalongRecordingSetup.hasReviewedChoices()
                    let proposed = GoalongRecordingSetup.proposal(from: model.appliedSettings,
                        visibleText: ActivityAnalysisPreferences.richContextEnabled)
                    model.settingsDraft = proposed.settings
                    visibleTextDraft = proposed.visibleText
                    localRecordingDraft = previouslyReviewed ? consents.isEnabled(.localComputerHistory) : true
                    loadedProposal = true
                }
                launchAtLogin.refresh()
                launchAtLoginPreference = consents.isEnabled(.launchAtLogin)
            }
        }

        var sidebar: some View {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    GoalongMark()
                        .stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                        .frame(width: 29, height: 21)
                        .accessibilityHidden(true)
                    Text("Goalong")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.6)
                }
                .accessibilityLabel(ProductIdentity.displayName)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(SetupStep.allCases) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item == step ? "circle.inset.filled" : "circle")
                                .foregroundStyle(item == step ? LHTheme.accent : .secondary)
                            Text(item.navigationTitle)
                                .font(.system(size: 13, weight: item == step ? .semibold : .regular))
                        }
                        .foregroundStyle(item == step ? .primary : .secondary)
                        .accessibilityLabel("\(item.navigationTitle)\(item == step ? ", current step" : "")")
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sur ce Mac", systemImage: "lock")
                        .font(.system(size: 12, weight: .medium))
                    Text("Tous ces choix restent modifiables.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(LHTheme.sidebarBackground)
        }

        var footer: some View {
            HStack(spacing: 14) {
                if step != .privacy {
                    Button("Retour") { note = nil; step = step.previous ?? .privacy }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if !checkingSources.isEmpty { ProgressView("Vérification des accès…").controlSize(.small) }
                Button(step == .privacy && localRecordingDraft && !consents.isEnabled(.localComputerHistory)
                       ? "Valider et démarrer" : step.actionTitle) {
                    note = nil
                    if step == .ready { finishSetup() }
                    else {
                        if step == .privacy {
                            let choices = GoalongRecordingSetup.Proposal(settings: model.settingsDraft,
                                visibleText: visibleTextDraft)
                            guard model.applyRecordingSetup(choices) else {
                                note = model.alert?.message ?? "Les choix n’ont pas pu être enregistrés. Réessayez."
                                model.alert = nil; return
                            }
                            privacyReviewed = true
                            if !localRecordingDraft && consents.isEnabled(.localComputerHistory) {
                                guard consents.set(.localComputerHistory, enabled: false, surface: .onboarding) else {
                                    note = "L’arrêt du suivi n’a pas pu être enregistré."; return
                                }
                            }
                            step = .sources
                            if localRecordingDraft && !consents.isEnabled(.localComputerHistory) {
                                showingLocalActivation = true
                            }
                            return
                        }
                        step = step.next ?? .ready
                    }
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-continue")
                .disabled(!checkingSources.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 28).frame(height: 72)
        }

        func finishSetup() {
            // Source activation already saved the user's choices. Do not reset their
            // recording, privacy or analysis preferences when setup is revisited.
            guard consents.set(.launchAtLogin, enabled: launchAtLoginPreference, surface: .onboarding) else {
                note = "Le choix de démarrage n’a pas pu être enregistré. Réessayez."
                return
            }
            guard launchAtLogin.setEnabled(launchAtLoginPreference) else {
                note = launchAtLogin.message ?? "macOS n’a pas enregistré ce choix. Réessayez ou désactivez le démarrage automatique."
                return
            }
            if launchAtLoginPreference && launchAtLogin.requiresApproval {
                note = "Autorisez le démarrage dans les réglages macOS, ou désactivez cette option pour continuer."
                return
            }
            UserDefaults.standard.set(launchAtLoginPreference, forKey: "launchAtLoginPreference")
            model.selectSection(.overview)
            model.dismissWelcome()
            step = .privacy
        }
    }

    enum SetupStep: Int, CaseIterable, Identifiable {
        // Preserve the raw values used by previous installations.
        case welcome = 0, sources = 1, ready = 2, privacy = 3
        static let allCases: [SetupStep] = [.privacy, .sources, .ready]
        var id: Int { rawValue }
        var position: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
        var previous: SetupStep? { position > 1 ? Self.allCases[position - 2] : nil }
        var next: SetupStep? { self == .welcome ? .privacy : position < Self.allCases.count ? Self.allCases[position] : nil }
        var actionTitle: String {
            switch self {
            case .welcome: return "Commencer"
            case .privacy: return "Valider mes choix"
            case .sources: return "Continuer"
            case .ready: return "Ouvrir Goalong"
            }
        }
        var navigationTitle: String {
            switch self {
            case .welcome: return "Vos données"
            case .privacy: return "Vos données"
            case .sources: return "Vos sources"
            case .ready: return "Prêt"
            }
        }
    }
#endif
