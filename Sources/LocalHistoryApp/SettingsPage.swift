#if os(macOS)
    import SwiftUI

    struct SettingsPage: View {
        @ObservedObject var model: DashboardViewModel

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(
                            eyebrow: "Configuration",
                            title: "Settings",
                            subtitle:
                                "Choose what Goalong History observes and how verification behaves. Safe defaults are already enabled."
                        ) {
                            HStack(spacing: 10) {
                                if model.settingsHaveChanges {
                                    StatusPill(
                                        title: "Unsaved changes",
                                        symbol: "circle.fill",
                                        tint: LHTheme.warning
                                    )
                                }
                                Button("Discard") {
                                    model.discardSettingsChanges()
                                }
                                .buttonStyle(.bordered)
                                .disabled(!model.settingsHaveChanges)
                                Button("Save settings") {
                                    model.saveSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.settingsHaveChanges)
                                .keyboardShortcut("s", modifiers: [.command])
                            }
                        }

                        captureCard
                        privacyCard
                        verificationCard
                        exclusionsCard
                        advancedCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 90)
                }

                saveBar
            }
            .background(LHTheme.pageBackground)
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

        private var exclusionsCard: some View {
            settingsCard(
                symbol: "eye.slash.fill",
                title: "Exclusions",
                subtitle:
                    "Excluded contexts remain visible only as coverage gaps; their detailed contents are not stored"
            ) {
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
#endif
