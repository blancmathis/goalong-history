#if os(macOS)
    import SwiftUI

    extension LocalHistoryOnboardingView {
        @ViewBuilder var page: some View {
            switch step {
            case .welcome: welcomePage
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
                        introduction("Your activity stays on this Mac", symbol: "internaldrive",
                            detail: "Local history is stored on your Mac. Connecting ChatGPT analysis is a separate choice in Settings.")
                        Divider()
                        introduction("Only the access you need", symbol: "hand.raised",
                            detail: "Goalong checks existing permissions first. If a source needs access, you will see why and how to grant it.")
                        Divider()
                        introduction("No screenshots or typed characters", symbol: "lock",
                            detail: "Computer History uses foreground context and activity counts. Private browsing is excluded by default. Secure fields stay protected.")
                    }
                }
            }
        }

        var sourcesPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("What would you like to see in Goalong?")
                    .font(.system(size: 22, weight: .semibold))
                Text("Choose what to include. If access is missing, Goalong explains why it is needed and helps you grant it.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                sourceChoice(.localComputerHistory, symbol: "macwindow",
                    detail: "Apps, windows and activity counts in one timeline. Requires Accessibility.",
                    prepare: prepareComputerHistory)
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
                Text("Enabled sources are ready to use. New Computer History activity appears as you use your Mac; existing Apple and AI history loads when you open it.")
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
