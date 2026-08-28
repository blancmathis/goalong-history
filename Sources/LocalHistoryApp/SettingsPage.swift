#if os(macOS)
    import SwiftUI

    struct SettingsPage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var recapRuntime: ChatGPTRecapRuntime
        @State private var pane: SettingsPane = .home

        init(model: DashboardViewModel) {
            self.model = model
            _recapRuntime = ObservedObject(wrappedValue: ChatGPTRecapRuntime.shared)
        }

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsHeader
                        paneContent
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 90)
                }

                if pane != .home {
                    saveBar
                }
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                recapRuntime.configure(deviceID: model.deviceID)
                recapRuntime.activate()
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
                    if pane != .home {
                        Button {
                            pane = .home
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                    }
                    if pane != .home, model.settingsHaveChanges {
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
                ChatGPTAccountConnectionCard(runtime: recapRuntime)
                settingsNavigation
            case .recording:
                captureCard
                privacyCard
            case .advanced:
                verificationCard
                monitoringScopeCard
                advancedCard
            }
        }

        private var settingsNavigation: some View {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    settingsNavigationRow(
                        title: "Recording",
                        detail: "Choose the local signals Goalong may record.",
                        symbol: "dot.radiowaves.left.and.right"
                    ) {
                        pane = .recording
                    }
                    Divider().padding(.leading, 62)
                    settingsNavigationRow(
                        title: "Sources",
                        detail: "Manage Computer History, Screen Time and AI conversations.",
                        symbol: "externaldrive.connected.to.line.below"
                    ) {
                        model.selectSection(.history)
                    }
                    Divider().padding(.leading, 62)
                    settingsNavigationRow(
                        title: "Privacy & permissions",
                        detail: "Review macOS access, local storage and deletion controls.",
                        symbol: "hand.raised"
                    ) {
                        model.selectSection(.privacy)
                    }
                    Divider().padding(.leading, 62)
                    settingsNavigationRow(
                        title: "Advanced",
                        detail: "Verification, inclusion rules and config.json.",
                        symbol: "slider.horizontal.3"
                    ) {
                        pane = .advanced
                    }
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(
                            LHTheme.accent.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    "Private browsing, password managers and secure text fields remain protected regardless of these options"
            ) {
                VStack(spacing: 14) {
                    settingToggle(
                        title: "Redact every URL query value",
                        message: "Keeps parameter names but replaces all values before local storage",
                        isOn: $model.settingsDraft.redactAllURLQueryValues
                    )

                    Divider()

                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detailed history retention")
                                .font(.system(size: 11, weight: .semibold))
                            Text(
                                model.settingsDraft.retentionDays == 0
                                    ? "Detailed JSONL events are kept until you delete them."
                                    : "Detailed JSONL events older than this are removed locally. Seals can remain."
                            )
                            .font(.system(size: 9))
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
                subtitle: "When enabled, the server receives opaque signed commitments — never your detailed activity"
            ) {
                VStack(spacing: 15) {
                    settingToggle(
                        title: "Send opaque minute commitments",
                        message: "Allows later verification that a selectively shared day was not rewritten",
                        isOn: $model.settingsDraft.verificationEnabled
                    )

                    if model.settingsDraft.verificationEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Verification server")
                                .font(.system(size: 10, weight: .semibold))
                            TextField("https://verify.example.com", text: $model.settingsDraft.verificationServerURL)
                                .textFieldStyle(.roundedBorder)
                            Text(
                                "HTTPS is required outside localhost. The server will see request metadata such as time and IP, but not app names, URLs or event contents."
                            )
                            .font(.system(size: 9))
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
                        .font(.system(size: 9))
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
                    .font(.system(size: 10, weight: .semibold))
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
                                .font(.system(size: 10))
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
                        .font(.system(size: 11, weight: .semibold))
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
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
                    .font(.system(size: 10, weight: .semibold))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: text)
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
                    .font(.system(size: 9))
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
