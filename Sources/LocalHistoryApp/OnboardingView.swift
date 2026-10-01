#if os(macOS)
    import SwiftUI

    struct LocalHistoryOnboardingView: View {
        @Environment(\.colorSchemeContrast) var contrast
        @Environment(\.accessibilityReduceMotion) var reduceMotion
        @ObservedObject var model: DashboardViewModel
        @StateObject var launchAtLogin = LaunchAtLoginManager()
        @ObservedObject var consents = GoalongCapabilityConsentStore.shared
        @AppStorage("goalongOnboardingStep") var step: SetupStep = .privacy
        @State var launchAtLoginPreference = true
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
                sidebar.frame(width: 208)
                Rectangle().fill(LHTheme.separator).frame(width: 1)
                VStack(spacing: 0) {
                    ScrollView {
                        page
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, LHTheme.pageInset).padding(.top, 40).padding(.bottom, 32)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Rectangle().fill(LHTheme.separator).frame(height: 1)
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
                    .goalongControls()
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
                launchAtLoginPreference = launchAtLogin.suggestedOnboardingPreference
            }
        }

        var sidebar: some View {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 11) {
                    GoalongMark()
                        .stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 28, height: 20)
                        .accessibilityHidden(true)
                    Text("Goalong")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.5)
                }
                .accessibilityLabel(ProductIdentity.displayName)
                // The steps hang on one thread: walked in lime, still to come as a hairline.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SetupStep.allCases) { item in
                        let done = item.position < step.position, current = item == step
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(done || current ? LHTheme.accent : LHTheme.sidebarBackground)
                                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .strokeBorder(done || current ? .clear : LHTheme.tertiaryText, lineWidth: 1.5))
                                .frame(width: 9, height: 9)
                            Text(item.navigationTitle)
                                .font(.system(size: 13, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? LHTheme.text : LHTheme.secondaryText)
                        }
                        .frame(height: 20)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.navigationTitle), étape \(item.position) sur \(SetupStep.allCases.count)\(current ? ", en cours" : done ? ", terminée" : "")")
                        if item != SetupStep.allCases.last {
                            Rectangle().fill(done ? LHTheme.accent : LHTheme.separator)
                                .frame(width: done ? 2 : 1, height: 18)
                                .frame(width: 9)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .animation(reduceMotion ? nil : LHTheme.settle, value: step)
                Spacer()
                Text("Tout reste sur ce Mac. Chaque choix se modifie ensuite dans Réglages.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LHTheme.sidebarBackground)
        }

        var footer: some View {
            HStack(spacing: 14) {
                if step != .privacy {
                    Button("Retour") { note = nil; step = step.previous ?? .privacy }
                        .buttonStyle(LHSecondaryButtonStyle())
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
            .padding(.horizontal, LHTheme.pageInset).frame(height: 68)
        }

        func finishSetup() {
            // Source activation already saved the user's choices. Do not reset their
            // recording, privacy or analysis preferences when setup is revisited.
            guard launchAtLogin.setUserPreference(launchAtLoginPreference, surface: .onboarding) else {
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
