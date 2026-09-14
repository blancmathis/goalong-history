#if os(macOS)
    import SwiftUI

    extension LocalHistoryOnboardingView {
        @ViewBuilder var page: some View {
            switch step {
            case .welcome: welcomePage
            case .privacy: privacyPage
            case .sources: sourcesPage
            case .ready: readyPage
            }
        }

        var welcomePage: some View {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(LHTheme.accent)
                Text("Find your way back to what you were doing.")
                    .font(.system(size: 28, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Bring together your activity, screen time and local AI conversations. Choose the sources you want; you can add the rest later.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LHCard {
                    VStack(alignment: .leading, spacing: 16) {
                        introduction("Local first. Sharing is a separate choice", symbol: "internaldrive",
                            detail: "Recording stays on your Mac. ChatGPT analysis and sharing to the Goalong website require separate choices. You can use the app without either.")
                        Divider()
                        introduction("Only the access you need", symbol: "hand.raised",
                            detail: "Goalong checks existing permissions first. If a source needs access, you will see why and how to grant it.")
                        Divider()
                        introduction("No screenshots or keystroke decoding", symbol: "lock",
                            detail: "Computer History uses foreground context and activity counts. Optional visible-text capture has its own consent. Detected private windows are excluded by default.")
                    }
                }
            }
        }

        var privacyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose what stays on this Mac").font(.system(size: 24, weight: .semibold))
                Text("Start with an app timeline or add specific details. Nothing is enabled by viewing this page. Changes apply only after Save choices below.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LHCard { RecordingChoicesView(draft: $model.settingsDraft) }
                VisibleContextControl()
                LHCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Include private browsing", isOn: $model.settingsDraft.capturePrivateBrowsing).toggleStyle(.switch)
                        Text("Off by default. Enabling can retain sensitive titles, URLs and visible context according to the choices above. Detection depends on the browser; use Pause for activity you do not want observed.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Toggle("Redact every URL query value", isOn: $model.settingsDraft.redactAllURLQueryValues).toggleStyle(.switch)
                        DisclosureGroup("Exclude apps or websites before recording") {
                            VStack(alignment: .leading, spacing: 10) {
                                scopeInput("Excluded websites", text: $model.settingsDraft.excludedDomainsText)
                                scopeInput("Excluded application bundle identifiers", text: $model.settingsDraft.excludedApplicationsText)
                                scopeInput("Include only these websites (optional)", text: $model.settingsDraft.includedDomainsText)
                                scopeInput("Include only these application bundle identifiers (optional)", text: $model.settingsDraft.includedApplicationsText)
                                Text("One domain, website URL or bundle identifier per line. Website paths are discarded; subdomains are included. Exclusions take priority. Empty include-only lists allow all non-excluded apps or sites.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(.top, 12)
                        }
                        Button("Choose how long to keep local data…") { showingRetention = true }.buttonStyle(.bordered)
                        Text("Recording settings do not authorize deletion. Retention has its own confirmation and separate choices for details, derived memories and proofs.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if let note { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(LHTheme.warning) }
            }
            .sheet(isPresented: $showingRetention) { HistoryRetentionSettingsSheet() }
        }

        private func scopeInput(_ title: String, text: Binding<String>) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                    .frame(height: 80).padding(6).background(Color.primary.opacity(0.035))
                    .accessibilityLabel(title)
            }
        }

        var sourcesPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("What would you like to see in Goalong?")
                    .font(.system(size: 22, weight: .semibold))
                Text("Sources start when you enable them. macOS access alone is not consent; opening History never turns a source on. You can skip every source.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                sourceChoice(.localComputerHistory, symbol: "macwindow",
                    detail: "A local app timeline, with only the additional details you saved. Requires Accessibility.")
                sourceChoice(.appleScreenTime, symbol: "macbook.and.iphone",
                    detail: "App usage from this Mac and synced devices. May require Full Disk Access.")
                sourceChoice(.aiConversations, symbol: "bubble.left.and.bubble.right",
                    detail: "Find conversations in local provider folders. Original files stay in place.")
                Text("You can continue with any selection and add more sources later.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        func sourceChoice(_ capability: GoalongCapability, symbol: String, detail: String,
                          prepare: @escaping () throws -> Void = {}) -> some View {
            LHCard {
                SourceActivationToggle(capability: capability, surface: .onboarding, prepare: prepare,
                    onCheckingChanged: { checking in
                        if checking { checkingSources.insert(capability) }
                        else { checkingSources.remove(capability) }
                    }) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: symbol).font(.system(size: 20))
                            .foregroundStyle(LHTheme.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(capability.title).font(.system(size: 14, weight: .semibold))
                            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 54, alignment: .leading)
                }
            }
        }

        var readyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your setup, at a glance")
                    .font(.system(size: 24, weight: .semibold))
                Text("Your choices are saved. Enabled is not a guarantee of available data: missing permission or history is shown separately. Computer History starts with new activity; it cannot reconstruct the past.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LHCard {
                    VStack(spacing: 15) {
                        ForEach([GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations]) { capability in
                            HStack {
                                Text(capability.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Label(consents.isEnabled(capability) ? "Enabled" : "Set up later",
                                      systemImage: consents.isEnabled(capability) ? "checkmark.circle.fill" : "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(consents.isEnabled(capability) ? LHTheme.success : .secondary)
                            }
                        }
                    }
                }
                LHCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your saved recording scope").font(.system(size: 13, weight: .semibold))
                        Text(model.appliedSettings.recordingSummary + (ActivityAnalysisPreferences.richContextEnabled ? " Visible-text capture is separately enabled." : " Visible-text capture is off.")).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(model.appliedSettings.capturePrivateBrowsing ? "Private browsing included by your choice." : "Detected private windows excluded.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Cloud analysis and website sharing are managed separately in Settings. Turning a source off does not delete stored or previously shared data.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Start Goalong when I log in", isOn: $launchAtLoginPreference)
                    .toggleStyle(.switch)
                Text("Optional. Your source choices stay the same on the next launch.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if launchAtLoginPreference && launchAtLogin.requiresApproval {
                        Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
            }
        }

        func introduction(_ title: String, symbol: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
#endif
