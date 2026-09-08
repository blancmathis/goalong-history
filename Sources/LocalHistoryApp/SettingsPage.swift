#if os(macOS)
    import SwiftUI

    struct SettingsPage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var recapRuntime: ChatGPTRecapRuntime
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @State private var pane: SettingsPane = .home

        init(model: DashboardViewModel) {
            self.model = model
            _recapRuntime = ObservedObject(wrappedValue: ChatGPTRecapRuntime.shared)
        }

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        settingsHeader
                        paneContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LHTheme.pageInset)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if pane != .home || model.settingsHaveChanges {
                    saveBar
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if pane != .home {
                    SettingsBackBar { pane = .home }
                }
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                if GoalongBuildCapabilities.permitsRemoteAnalysis,
                    consents.isEnabled(.chatGPTAnalysis)
                {
                    recapRuntime.configure(deviceID: model.deviceID)
                    recapRuntime.activate()
                }
            }
            .alert(item: $recapRuntime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var settingsHeader: some View {
            PageHeader(
                eyebrow: pane == .home ? "Configuration" : "Settings",
                title: pane.title,
                subtitle: pane.subtitle
            ) {
                HStack(spacing: 10) {
                    if model.settingsHaveChanges {
                        Button("Save settings") {
                            model.saveSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: [.command])
                    }
                }
            }
        }

        @ViewBuilder private var paneContent: some View {
            switch pane {
            case .home:
                if GoalongBuildCapabilities.permitsRemoteAnalysis,
                    consents.isEnabled(.chatGPTAnalysis)
                {
                    ChatGPTAccountConnectionCard(runtime: recapRuntime)
                }
                capabilityConsentCard
                GoalongWebsiteConnectionCard()
                settingsNavigation
                Button("Review onboarding") { model.showWelcome = true }
                    .buttonStyle(.bordered)
            case .recording:
                captureCard
                privacyCard
            case .advanced:
                verificationCard
                monitoringScopeCard
                advancedCard
            }
        }

        private var capabilityConsentCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    title: "Optional capabilities",
                    subtitle: "Manage the sources Goalong uses. History checks existing access when you open a source and explains any missing permission."
                )
                LHCard {
                    VStack(alignment: .leading, spacing: 12) {
                        capabilityToggle(
                            .localComputerHistory,
                            message: "Observe foreground apps and coarse interaction signals; detailed events stay on this Mac."
                        )
                        Divider()
                        capabilityToggle(
                            .appleScreenTime,
                            message: "Read Apple’s protected Screen Time stores in place; Full Disk Access may be required."
                        )
                        Divider()
                        capabilityToggle(
                            .aiConversations,
                            message: "Index local provider metadata and read selected conversations directly from their original files."
                        )
                        Divider()
                        capabilityToggle(
                            .chatGPTAnalysis,
                            message: "Send only the bounded analysis context to the Codex/ChatGPT connection after you explicitly start or schedule a run."
                        )
                        if GoalongBuildCapabilities.permitsRemoteVerification {
                            Divider()
                            capabilityToggle(
                                .remoteVerification,
                                message: "Allow opaque signed commitments—not activity contents—to reach the configured verifier."
                            )
                        }
                        if GoalongBuildCapabilities.permitsAutomaticUpdates {
                            Divider()
                            capabilityToggle(
                                .automaticUpdates,
                                message: "Allow the signed updater to check the published release feed."
                            )
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private func capabilityToggle(_ capability: GoalongCapability, message: String) -> some View {
            let label = VStack(alignment: .leading, spacing: 3) {
                Text(capability.title).font(.system(size: 13, weight: .medium))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if [.localComputerHistory, .appleScreenTime, .aiConversations].contains(capability) {
                SourceActivationToggle(capability: capability, prepare: {
                    if capability == .localComputerHistory {
                        try model.configureCaptureForOnboarding(enabled: true)
                    }
                }) { label }
                .accessibilityHint(message).controlSize(.small)
            } else {
                Toggle(isOn: Binding(
                    get: { consents.isEnabled(capability) },
                    set: { _ = consents.set(capability, enabled: $0, surface: .settings) }
                )) { label }
                .toggleStyle(.switch).accessibilityLabel(capability.title)
                .accessibilityHint(message).controlSize(.small)
            }
        }

        private var settingsNavigation: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preferences")
                    .font(.system(size: 15, weight: .semibold))
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        settingsNavigationRow(
                            title: "Goalong CLI",
                            detail: "Use your local history from Terminal or give an agent one complete guide.",
                            symbol: "terminal"
                        ) {
                            model.selectSection(.cli)
                        }
                        Divider().padding(.leading, 52)
                        settingsNavigationRow(
                            title: "Recording",
                            detail: "Choose the local signals Goalong may record.",
                            symbol: "dot.radiowaves.left.and.right"
                        ) {
                            pane = .recording
                        }
                        Divider().padding(.leading, 52)
                        settingsNavigationRow(
                            title: "Sources",
                            detail: "Manage local AI conversation folders and integrations.",
                            symbol: "externaldrive.connected.to.line.below"
                        ) {
                            model.selectSection(.agentActivity)
                        }
                        Divider().padding(.leading, 52)
                        settingsNavigationRow(
                            title: "Privacy & permissions",
                            detail: "Review macOS access, local storage and deletion controls.",
                            symbol: "hand.raised"
                        ) {
                            model.selectSection(.privacy)
                        }
                        Divider().padding(.leading, 52)
                        settingsNavigationRow(
                            title: "Advanced",
                            detail: "Verification, inclusion rules and config.json.",
                            symbol: "slider.horizontal.3"
                        ) {
                            pane = .advanced
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }

        private func settingsNavigationRow(
            title: String,
            detail: String,
            symbol: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
            .help("Open \(title)")
        }

        private var captureCard: some View {
            settingsCard(
                symbol: "dot.radiowaves.left.and.right",
                title: "Activity capture",
                subtitle: "These signals help reconstruct understandable sessions without recording raw text"
            ) {
                settingsGrid {
                    settingToggle(
                        title: "Clicks",
                        message: "Button, position and accessible target",
                        isOn: $model.settingsDraft.captureClicks
                    )
                    settingToggle(
                        title: "Scrolling",
                        message: "Grouped scroll direction and event count",
                        isOn: $model.settingsDraft.captureScroll
                    )
                    settingToggle(
                        title: "Typing activity",
                        message: "Counts and duration only — never characters",
                        isOn: $model.settingsDraft.captureKeyboardActivity
                    )
                    settingToggle(
                        title: "Keyboard shortcuts",
                        message: "Command combinations such as ⌘C",
                        isOn: $model.settingsDraft.captureShortcuts
                    )
                    settingToggle(
                        title: "Window titles",
                        message: "Useful context that stays local by default",
                        isOn: $model.settingsDraft.captureWindowTitles
                    )
                    settingToggle(
                        title: "Interface labels",
                        message: "Accessible role and label of focused controls",
                        isOn: $model.settingsDraft.captureElementLabels
                    )
                    settingToggle(
                        title: "Browser URLs",
                        message: "Sanitized URL when the browser exposes it",
                        isOn: $model.settingsDraft.captureURLs
                    )
                }
            }
        }

        private var privacyCard: some View {
            settingsCard(
                symbol: "hand.raised.fill",
                title: "Privacy defaults",
                subtitle:
                    "Private browsing is excluded by default. Password managers, secure fields and your exclusions remain protected."
            ) {
                VStack(spacing: 14) {
                    settingToggle(
                        title: "Include private browsing",
                        message: "Record private windows using your activity capture settings. This can save their titles, URLs and visible context locally. Off by default; password fields and exclusions remain protected.",
                        isOn: $model.settingsDraft.capturePrivateBrowsing
                    )
                    Divider()
                    settingToggle(
                        title: "Redact every URL query value",
                        message: "Keeps parameter names but replaces all values before local storage",
                        isOn: $model.settingsDraft.redactAllURLQueryValues
                    )

                    Divider()

                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detailed history retention")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                model.settingsDraft.retentionDays == 0
                                    ? "Detailed JSONL events are kept until you delete them."
                                    : "Detailed JSONL events older than this are removed locally. Seals can remain."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(
                            value: $model.settingsDraft.retentionDays,
                            in: 0...3650,
                            step: 1
                        ) {
                            Text(
                                model.settingsDraft.retentionDays == 0
                                    ? "Indefinitely"
                                    : "\(model.settingsDraft.retentionDays) days"
                            )
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .frame(minWidth: 84, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                    .padding(13)
                    .background(
                        Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }

        private var verificationCard: some View {
            settingsCard(
                symbol: "checkmark.seal.fill",
                title: "Anti-tamper verification",
                subtitle: GoalongBuildCapabilities.permitsRemoteVerification
                    ? "When enabled, the server receives opaque signed commitments — never your detailed activity"
                    : "Local proofs remain available; this edition contains no uploader"
            ) {
                VStack(spacing: 15) {
                    settingToggle(
                        title: "Send opaque minute commitments",
                        message: GoalongBuildCapabilities.permitsRemoteVerification
                            ? "Allows later verification that a selectively shared day was not rewritten"
                            : "Unavailable because the Local target physically excludes the network uploader",
                        isOn: $model.settingsDraft.verificationEnabled
                    )
                    .disabled(!GoalongBuildCapabilities.permitsRemoteVerification)

                    if GoalongBuildCapabilities.permitsRemoteVerification,
                        model.settingsDraft.verificationEnabled
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Verification server")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("https://verify.example.com", text: $model.settingsDraft.verificationServerURL)
                                .textFieldStyle(.roundedBorder)
                            Text(
                                "HTTPS is required outside localhost. The server will see request metadata such as time and IP, but not app names, URLs or event contents."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(13)
                        .background(
                            Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                        settingToggle(
                            title: "Use Apple App Attest when available",
                            message: "Raises trust by proving commitments came from an eligible official app instance",
                            isOn: $model.settingsDraft.enableAppAttest
                        )
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(LHTheme.success)
                        Text(model.deviceProtectionSummary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(11)
                    .background(
                        LHTheme.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }

        private var monitoringScopeCard: some View {
            settingsCard(
                symbol: "eye.slash.fill",
                title: "Apps and websites",
                subtitle:
                    "Choose exclusions or switch to an include-only scope for future activity"
            ) {
                VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        exclusionEditor(
                            title: "Excluded website domains",
                            placeholder: "example.com\nprivate.company.com",
                            text: $model.settingsDraft.excludedDomainsText,
                            help:
                                "One host per line. Subdomains of a listed domain are also excluded by the recorder policy."
                        )
                        exclusionEditor(
                            title: "Excluded application bundle IDs",
                            placeholder: "com.example.privateapp",
                            text: $model.settingsDraft.excludedApplicationsText,
                            help: "One bundle identifier per line. Password managers are excluded by default."
                        )
                    }

                    Divider()

                    HStack(alignment: .top, spacing: 14) {
                        exclusionEditor(
                            title: "Include only website domains",
                            placeholder: "work.example.com",
                            text: $model.settingsDraft.includedDomainsText,
                            help:
                                "Leave empty to allow every non-excluded site. When populated, browser pages without a matching visible host fail closed."
                        )
                        exclusionEditor(
                            title: "Include only application bundle IDs",
                            placeholder: "com.apple.TextEdit",
                            text: $model.settingsDraft.includedApplicationsText,
                            help:
                                "Leave empty to allow every non-excluded app. When populated, apps without a matching bundle ID fail closed."
                        )
                    }
                }
            }
        }

        private var advancedCard: some View {
            LHCard {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(
                            LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced configuration")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "Polling intervals, browser markers and other expert settings remain available in config.json."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open config.json") {
                        model.openConfiguration()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        private var saveBar: some View {
            HStack(spacing: 12) {
                Image(systemName: model.settingsHaveChanges ? "pencil.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.settingsHaveChanges ? LHTheme.warning : LHTheme.success)
                Text(model.settingsHaveChanges ? "You have unsaved changes" : "Settings are up to date")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.settingsHaveChanges {
                    Button("Discard") {
                        model.discardSettingsChanges()
                    }
                    .buttonStyle(.bordered)
                    Button("Save settings") {
                        model.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 58)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle().fill(LHTheme.separator).frame(height: 1)
            }
        }

        private func settingsCard<Content: View>(
            symbol: String,
            title: String,
            subtitle: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LHTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(
                                LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content()
                }
            }
        }

        private func settingsGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                alignment: .leading,
                spacing: 10,
                content: content
            )
        }

        private func settingToggle(title: String, message: String, isOn: Binding<Bool>) -> some View {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityLabel(title)
            .accessibilityHint(message)
            .controlSize(.small)
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }

        private func exclusionEditor(
            title: String,
            placeholder: String,
            text: Binding<String>,
            help: String
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: text)
                        .accessibilityLabel(title)
                        .font(.system(size: 10, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .background(
                            Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 125)
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private enum SettingsPane {
        case home
        case recording
        case advanced

        var title: String {
            switch self {
            case .home: return "Settings"
            case .recording: return "Recording"
            case .advanced: return "Advanced settings"
            }
        }

        var subtitle: String {
            switch self {
            case .home:
                return "Your account and the few controls that usually matter."
            case .recording:
                return "Choose what Goalong observes locally. Safe defaults remain enabled."
            case .advanced:
                return "Verification and expert controls that rarely need changing."
            }
        }
    }
#endif
