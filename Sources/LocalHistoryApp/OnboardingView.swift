#if os(macOS)
    import SwiftUI

    struct LocalHistoryOnboardingView: View {
        @ObservedObject var model: DashboardViewModel
        @StateObject var launchAtLogin = LaunchAtLoginManager()
        @ObservedObject var consents = GoalongCapabilityConsentStore.shared
        @AppStorage("goalongOnboardingStep") var step: SetupStep = .welcome
        @State var launchAtLoginPreference = false
        @State var note: String?
        @State var checkingSources: Set<GoalongCapability> = []

        var body: some View {
            HStack(spacing: 0) {
                sidebar.frame(width: 218)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(step.navigationTitle).font(.system(size: 20, weight: .semibold))
                        Spacer()
                        Text("\(step.rawValue + 1) of \(SetupStep.allCases.count)")
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
                launchAtLogin.refresh()
                launchAtLoginPreference = consents.isEnabled(.launchAtLogin)
            }
        }

        var sidebar: some View {
            VStack(alignment: .leading, spacing: 28) {
                Label(ProductIdentity.displayName, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
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
                    Label("Your sources, your choice", systemImage: "lock")
                        .font(.system(size: 12, weight: .medium))
                    Text("You can change these choices in Settings at any time.")
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
                if step != .welcome {
                    Button("Back") { note = nil; step = SetupStep(rawValue: step.rawValue - 1)! }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if !checkingSources.isEmpty { ProgressView("Checking access…").controlSize(.small) }
                Button(step == .ready ? "Open Goalong" : step == .welcome ? "Choose sources" : "Review setup") {
                    if step == .ready { finishSetup() }
                    else { note = nil; step = SetupStep(rawValue: step.rawValue + 1)! }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!checkingSources.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 28).frame(height: 72)
        }

        func prepareComputerHistory() throws {
            guard consents.document.consent(for: .localComputerHistory).changedAt == nil,
                  !UserDefaults.standard.bool(forKey: "didShowLocalHistoryConsentOnboardingV5") else { return }
            try model.configureCaptureForOnboarding(enabled: true)
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
            step = .welcome
        }
    }

    enum SetupStep: Int, CaseIterable, Identifiable {
        case welcome, sources, ready
        var id: Int { rawValue }
        var navigationTitle: String {
            switch self {
            case .welcome: return "Welcome"
            case .sources: return "Your sources"
            case .ready: return "Ready to start"
            }
        }
    }
#endif
