#if os(macOS)
    import SwiftUI

    struct LocalHistoryOnboardingView: View {
        @ObservedObject var model: DashboardViewModel
        @StateObject var launchAtLogin = LaunchAtLoginManager()
        @State var step: SetupStep = .welcome
        @State var askedForAccessibility = false
        @State var askedForInputMonitoring = false
        @State var launchAtLoginPreference = false
        @State var fullContextPreference = false
        @State var note: String?
        @ObservedObject var consents = GoalongCapabilityConsentStore.shared

        let permissions = PermissionManager()

        var body: some View {
            HStack(spacing: 0) {
                sidebar.frame(width: 242)
                VStack(spacing: 0) {
                    header
                    Divider()
                    page.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    footer
                }
                .background(LHTheme.pageBackground)
            }
            .frame(width: 920, height: 630)
            .onAppear {
                launchAtLogin.refresh()
                let defaults = UserDefaults.standard
                launchAtLoginPreference = consents.isEnabled(.launchAtLogin)
                fullContextPreference = defaults.object(
                    forKey: ActivityAnalysisPreferences.richContextEnabledKey
                ) == nil
                    ? false
                    : defaults.bool(
                        forKey: ActivityAnalysisPreferences.richContextEnabledKey
                    )
                model.refreshEverything()
            }
            .onChange(of: step) { newStep in
                note = nil
                model.refreshEverything()
                if newStep == .ready { launchAtLogin.refresh() }
            }
        }

        var sidebar: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.045, green: 0.052, blue: 0.075),
                        Color(red: 0.065, green: 0.075, blue: 0.115),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            LHTheme.accent,
                                            Color(red: 0.42, green: 0.31, blue: 0.94),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "clock.badge.checkmark.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProductIdentity.displayName)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("SETUP ASSISTANT")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(.white.opacity(0.46))
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(SetupStep.allCases) { progressRow($0) }
                    }
                    .padding(.top, 34)

                    Spacer()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Local and permissioned", systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(
                            "No screenshots, audio, clipboard, passwords, or reconstruction of raw typed characters."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(
                        .white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(24)
            }
        }

        func progressRow(_ item: SetupStep) -> some View {
            let current = item == step
            let complete = item.rawValue < step.rawValue
            return HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(
                            current
                                ? LHTheme.accent
                                : (complete ? LHTheme.success : .white.opacity(0.08))
                        )
                        if complete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(current ? .white : .white.opacity(0.48))
                        }
                    }
                    .frame(width: 24, height: 24)
                    if item != .ready {
                        Rectangle()
                            .fill(
                                complete
                                    ? LHTheme.success.opacity(0.58)
                                    : .white.opacity(0.1)
                            )
                            .frame(width: 1, height: 26)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sidebarTitle)
                        .font(.system(size: 11, weight: current ? .semibold : .medium))
                        .foregroundStyle(
                            current ? .white : .white.opacity(complete ? 0.72 : 0.45)
                        )
                    if current {
                        Text(item.sidebarDetail)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.44))
                            .lineLimit(2)
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .frame(minHeight: item == .ready ? 25 : 50, alignment: .top)
        }

        var header: some View {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.eyebrow.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(LHTheme.accent)
                    Text(step.navigationTitle)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                }
                Spacer()
                Text("\(step.rawValue + 1) of \(SetupStep.allCases.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            .padding(.horizontal, 28)
            .frame(height: 72)
        }

        var footer: some View {
            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back", action: goBack)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if step == .accessibility || step == .inputMonitoring || step == .protectedSources {
                    Button("Set up later", action: advance)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(step == .ready ? "Finish setup" : "Continue") {
                    step == .ready ? finishSetup() : advance()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
            }
            .padding(.horizontal, 28)
            .frame(height: 72)
        }

        var allPermissionsGranted: Bool {
            !consents.isEnabled(.localComputerHistory)
                || (model.runtime.accessibilityGranted && model.runtime.inputMonitoringGranted)
        }

        var canAdvance: Bool {
            switch step {
            case .accessibility:
                return !consents.isEnabled(.localComputerHistory)
                    || model.runtime.accessibilityGranted || askedForAccessibility
            case .inputMonitoring:
                return !consents.isEnabled(.localComputerHistory)
                    || model.runtime.inputMonitoringGranted || askedForInputMonitoring
            default:
                return true
            }
        }

        func requestAccessibility() {
            guard consents.isEnabled(.localComputerHistory) else {
                note = "Enable Computer History first. Goalong never requests Accessibility for a disabled capability."
                return
            }
            askedForAccessibility = true
            _ = permissions.requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                model.refreshEverything()
                if !model.runtime.accessibilityGranted {
                    permissions.openAccessibilitySettings()
                }
            }
        }

        func requestInputMonitoring() {
            guard consents.isEnabled(.localComputerHistory) else {
                note = "Enable Computer History first. Goalong never requests Input Monitoring for a disabled capability."
                return
            }
            askedForInputMonitoring = true
            _ = permissions.requestInputMonitoring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                model.refreshEverything()
                if !model.runtime.inputMonitoringGranted {
                    permissions.openInputMonitoringSettings()
                }
            }
        }

        func advance() {
            guard let next = SetupStep(rawValue: step.rawValue + 1) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
        }

        func goBack() {
            guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { step = previous }
        }

        func finishSetup() {
            UserDefaults.standard.set(
                launchAtLoginPreference,
                forKey: "launchAtLoginPreference"
            )
            UserDefaults.standard.set(
                fullContextPreference,
                forKey: ActivityAnalysisPreferences.richContextEnabledKey
            )
            ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
            do {
                try model.configureCaptureForOnboarding(
                    enabled: consents.isEnabled(.localComputerHistory)
                )
            } catch {
                note = "Capture settings could not be saved: \(error.localizedDescription)"
                return
            }
            guard consents.set(
                .launchAtLogin,
                enabled: launchAtLoginPreference,
                surface: .onboarding
            ) else {
                note = "The launch-at-login choice could not be saved."
                return
            }
            guard launchAtLogin.setEnabled(launchAtLoginPreference) else {
                note = launchAtLogin.message
                    ?? "macOS could not update the login-item setting."
                return
            }
            if launchAtLoginPreference && launchAtLogin.requiresApproval {
                note = "Allow \(ProductIdentity.displayName) in System Settings → General → Login Items, then click Finish setup again."
                launchAtLogin.openLoginItemsSettings()
                return
            }
            model.selectSection(allPermissionsGranted ? .overview : .privacy)
            model.dismissWelcome()
        }
    }

    enum SetupStep: Int, CaseIterable, Identifiable {
        case welcome, privacy, recording, accessibility, inputMonitoring, protectedSources, ready
        var id: Int { rawValue }

        var eyebrow: String {
            [
                "Welcome", "Privacy first", "Local capability",
                "Permission one", "Permission two", "Protected sources", "Final check",
            ][rawValue]
        }

        var navigationTitle: String {
            switch self {
            case .welcome:
                return "Meet \(ProductIdentity.displayName)"
            case .privacy:
                return "Understand the boundary"
            case .recording:
                return "Choose whether Goalong may record"
            case .accessibility:
                return "Add foreground context"
            case .inputMonitoring:
                return "Measure activity"
            case .protectedSources:
                return "Choose protected data sources"
            case .ready:
                return "Start your timeline"
            }
        }

        var sidebarTitle: String {
            [
                "Welcome", "Privacy", "Recording", "Accessibility",
                "Input Monitoring", "Full Disk Access", "Ready",
            ][rawValue]
        }

        var sidebarDetail: String {
            [
                "What the app does", "What stays private", "Off until you opt in",
                "Foreground context", "Activity signals", "Apple and agent sources", "Review and start",
            ][rawValue]
        }
    }
#endif
