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
            .onAppear {
                if step == .welcome || !privacyReviewed { step = .privacy }
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
                if !checkingSources.isEmpty { ProgressView("Checking access…").controlSize(.small) }
                Button(step.actionTitle) {
                    note = nil
                    if step == .ready { finishSetup() }
                    else {
                        if step == .privacy {
                            guard model.saveOnboardingRecordingChoices() else {
                                note = model.alert?.message ?? "Your choices could not be saved. Try again."
                                model.alert = nil
                                return
                            }
                            privacyReviewed = true
                        }
                        step = step.next ?? .ready
                    }
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!checkingSources.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 28).frame(height: 72)
        }

        func finishSetup() {
            // Source activation already saved the user's choices. Do not reset their
            // recording, privacy or analysis preferences when setup is revisited.
            guard consents.set(.launchAtLogin, enabled: launchAtLoginPreference, surface: .onboarding) else {
                note = "Your startup preference could not be saved. Please try again."
                return
            }
            guard launchAtLogin.setEnabled(launchAtLoginPreference) else {
                note = launchAtLogin.message ?? "macOS could not save the startup preference. Try again or turn it off."
                return
            }
            if launchAtLoginPreference && launchAtLogin.requiresApproval {
                note = "macOS needs approval for automatic startup. You can open Login Items below, or turn off automatic startup and continue."
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
            case .privacy: return "Continuer"
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
