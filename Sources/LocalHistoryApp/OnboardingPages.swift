#if os(macOS)
    import SwiftUI

    extension LocalHistoryOnboardingView {
        @ViewBuilder var page: some View {
            ScrollView {
                Group {
                    switch step {
                    case .welcome:
                        welcomePage
                    case .privacy:
                        privacyPage
                    case .recording:
                        recordingConsentPage
                    case .accessibility:
                        permissionPage(
                            symbol: "accessibility",
                            tint: LHTheme.accent,
                            title: "Let \(ProductIdentity.displayName) understand the foreground context",
                            subtitle: "Accessibility lets the app read permitted information about the active app, window, browser URL, clicked interface element, and — when full context is enabled — bounded visible text.",
                            granted: model.runtime.accessibilityGranted,
                            bullets: [
                                "Used only to observe foreground context",
                                "Never used to control your Mac",
                                "Private windows and secure fields are suppressed",
                                "Full-context text follows the separate choice you just made",
                            ],
                            actionTitle: "Allow Accessibility",
                            action: requestAccessibility,
                            settingsAction: permissions.openAccessibilitySettings
                        )
                    case .inputMonitoring:
                        permissionPage(
                            symbol: "keyboard",
                            tint: LHTheme.privateTint,
                            title: "Measure activity without reconstructing what you type",
                            subtitle: "Accessibility already includes event-listening access on macOS. A direct Input Monitoring grant is requested only when the current Mac still needs it.",
                            granted: model.runtime.inputMonitoringGranted,
                            bullets: [
                                "Raw keyboard characters are never decoded or stored",
                                "Typing is grouped into duration and count signals",
                                "Passwords and secure input are excluded",
                                "You can pause capture instantly from the menu bar",
                            ],
                            actionTitle: "Allow Input Monitoring",
                            action: requestInputMonitoring,
                            settingsAction: permissions.openInputMonitoringSettings
                        )
                    case .protectedSources:
                        protectedSourcesPage
                    case .ready:
                        readyPage
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }

        var welcomePage: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LHTheme.accent.opacity(0.18),
                                        LHTheme.privateTint.opacity(0.13),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "clock.badge.checkmark.fill")
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(LHTheme.accent)
                    }
                    .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Your activity, made useful — without giving it away.")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "\(ProductIdentity.displayName) reconstructs what you worked on, where the source lives, what changed, and where to resume — entirely from this Mac unless you explicitly share."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    featureCard(
                        symbol: "macwindow",
                        title: "Local first",
                        detail: "Detailed activity and causal memories stay in your private Application Support folder."
                    )
                    featureCard(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Understands sequences",
                        detail: "Actions are linked as before → action → after, not flattened into screen-time totals."
                    )
                    featureCard(
                        symbol: "doc.text.magnifyingglass",
                        title: "Find and resume",
                        detail: "Ask for a recent file, conversation, task status, or where you left off."
                    )
                }

                callout(
                    symbol: "hand.raised.fill",
                    tint: LHTheme.success,
                    title: "You choose the analysis depth",
                    detail: "The next pages explain metadata-only and full-context analysis before either is saved."
                )
            }
        }

        var privacyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Useful context, with a hard privacy boundary.")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(
                    "The single Goalong app keeps detailed activity local. It contains no Sparkle updater or first-party HTTP uploader. A selective share is created only when you export one; ChatGPT receives a bounded context only after you separately enable and run analysis."
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 14) {
                    boundaryCard(
                        symbol: "externaldrive.fill",
                        tint: LHTheme.accent,
                        title: "May be stored locally",
                        items: [
                            "Active app, window, page, and clicked control",
                            "Cleaned browser URL or local file path when available",
                            "Clicks, scrolling, generic shortcut/navigation activity, and grouped typing",
                            "Bounded selected and visible text only with full-context consent",
                        ]
                    )
                    boundaryCard(
                        symbol: "nosign",
                        tint: LHTheme.danger,
                        title: "Never captured",
                        items: [
                            "Screenshots, camera, or screen video",
                            "Microphone or system audio",
                            "Clipboard contents or secure-field values",
                            "Characters reconstructed from keyboard keycodes",
                        ]
                    )
                }

                callout(
                    symbol: "eye.slash.fill",
                    tint: LHTheme.privateTint,
                    title: "Private and secure periods fail closed",
                    detail: "Only a generic coverage gap is stored — not the URL, title, visible text, clicks, or keyboard activity."
                )
            }
        }

        var recordingConsentPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(LHTheme.privateTint)
                        .frame(width: 76, height: 76)
                        .background(
                            LHTheme.privateTint.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Computer History starts off")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(
                            "Goalong will not observe apps, windows, clicks or keyboard activity unless you explicitly enable this capability. macOS permissions alone never start it."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 12) {
                    analysisChoice(
                        selected: !consents.isEnabled(.localComputerHistory),
                        symbol: "pause.circle.fill",
                        title: "Keep Computer History off",
                        badge: "DEFAULT",
                        detail: "No foreground context or interaction events are collected. Existing local history remains readable.",
                        action: {
                            _ = consents.set(
                                .localComputerHistory,
                                enabled: false,
                                surface: .onboarding
                            )
                            fullContextPreference = false
                        }
                    )
                    analysisChoice(
                        selected: consents.isEnabled(.localComputerHistory),
                        symbol: "clock.arrow.circlepath",
                        title: "Enable local Computer History",
                        badge: nil,
                        detail: "Stores app and window context, sanitized websites, clicks, scrolling and grouped typing signals. It never stores typed characters, screenshots, audio, clipboard data or secure-field values.",
                        action: {
                            _ = consents.set(
                                .localComputerHistory,
                                enabled: true,
                                surface: .onboarding
                            )
                        }
                    )
                }

                if consents.isEnabled(.localComputerHistory) {
                    Toggle(isOn: $fullContextPreference) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Use bounded visible context")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "Adds selected or visible text exposed by Accessibility after private and secure contexts are suppressed. This is off by default."
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(15)
                    .background(
                        LHTheme.cardBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(LHTheme.success)
                    Text(
                        "Full context still excludes private browsing, configured exclusions, Secure Input, protected controls, screenshots, audio, clipboard data, and raw character decoding. Common credential patterns are redacted before persistence."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
                .background(
                    LHTheme.success.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }

        var protectedSourcesPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 76, height: 76)
                        .background(
                            LHTheme.accent.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Choose each protected source separately")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(
                            "Full Disk Access is a broad macOS permission. Goalong still keeps Apple Screen Time and AI-conversation reading off until you select them here."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                protectedSourceToggle(
                    .appleScreenTime,
                    symbol: "macbook.and.iphone",
                    detail: "Reads Apple’s local Screen Time and iCloud-synced device stores only for the active day, then keeps one compact local daily record. Apple databases themselves are never copied."
                )
                protectedSourceToggle(
                    .aiConversations,
                    symbol: "cpu",
                    detail: "Discovers Codex, Claude, OpenCode and folders you add. Only a bounded metadata index is stored; transcript bodies stay at the provider source."
                )

                HStack(spacing: 12) {
                    Button("Open Full Disk Access") {
                        permissions.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        !consents.isEnabled(.appleScreenTime)
                            && !consents.isEnabled(.aiConversations)
                    )
                    Text("You may skip this. Denied sources report a clear unavailable state without affecting Goalong’s other local data.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                callout(
                    symbol: "lock.shield.fill",
                    tint: LHTheme.success,
                    title: "Read at the original location",
                    detail: "Goalong uses provider-specific read-only adapters, fixed discovery roots, no-follow checks and bounded parsing. It never recreates the old transcript blob vault."
                )
            }
        }

        func protectedSourceToggle(
            _ capability: GoalongCapability,
            symbol: String,
            detail: String
        ) -> some View {
            Toggle(
                isOn: Binding(
                    get: { consents.isEnabled(capability) },
                    set: {
                        _ = consents.set(capability, enabled: $0, surface: .onboarding)
                    }
                )
            ) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            LHTheme.accent.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(capability.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .padding(15)
            .background(
                LHTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            )
        }

        func analysisChoice(
            selected: Bool,
            symbol: String,
            title: String,
            badge: String?,
            detail: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(
                                selected ? LHTheme.accent : Color.secondary.opacity(0.35),
                                lineWidth: 2
                            )
                        if selected {
                            Circle()
                                .fill(LHTheme.accent)
                                .padding(4)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .padding(.top, 2)

                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? LHTheme.accent : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(
                            (selected ? LHTheme.accent : Color.secondary).opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                            if let badge {
                                Text(badge)
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .tracking(0.5)
                                    .foregroundStyle(LHTheme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(LHTheme.accent.opacity(0.1), in: Capsule())
                            }
                        }
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? LHTheme.accent.opacity(0.075) : LHTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            selected ? LHTheme.accent.opacity(0.55) : Color.primary.opacity(0.07),
                            lineWidth: selected ? 1.5 : 1
                        )
                )
            }
            .buttonStyle(.plain)
        }

        func permissionPage(
            symbol: String,
            tint: Color,
            title: String,
            subtitle: String,
            granted: Bool,
            bullets: [String],
            actionTitle: String,
            action: @escaping () -> Void,
            settingsAction: @escaping () -> Void
        ) -> some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 76, height: 76)
                        .background(
                            tint.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(title)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Spacer()
                            statusPill(granted: granted)
                        }
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 13) {
                    ForEach(bullets, id: \.self) { bullet in
                        Label(bullet, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.82))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LHTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.07))
                )

                HStack(spacing: 12) {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(granted)
                    Button("Open guided setup", action: settingsAction)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button("Check again", action: model.refreshEverything)
                        .buttonStyle(.plain)
                        .foregroundStyle(LHTheme.accent)
                }
                Text(
                    "The guide stays visible beside System Settings and refreshes automatically. macOS may ask you to quit and reopen \(ProductIdentity.displayName)."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }

        var readyPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle().fill(
                            (allPermissionsGranted ? LHTheme.success : LHTheme.warning)
                                .opacity(0.12)
                        )
                        Image(
                            systemName: allPermissionsGranted
                                ? "checkmark.seal.fill"
                                : "exclamationmark.shield.fill"
                        )
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(
                            allPermissionsGranted ? LHTheme.success : LHTheme.warning
                        )
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            allPermissionsGranted
                                ? "\(ProductIdentity.displayName) is ready"
                                : "You can finish and grant access later"
                        )
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(
                            allPermissionsGranted
                                ? "Your private causal timeline begins as soon as setup closes."
                                : "The app will guide you back to Privacy & Security for the remaining permission."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    finalCheckRow(
                        symbol: "clock.arrow.circlepath",
                        title: "Computer History",
                        detail: consents.isEnabled(.localComputerHistory)
                            ? (fullContextPreference
                                ? "Enabled with bounded visible context"
                                : "Enabled without visible-text context")
                            : "Off — no local activity capture",
                        complete: true
                    )
                    Divider().padding(.leading, 48)
                    finalCheckRow(
                        symbol: "accessibility",
                        title: "Accessibility",
                        detail: model.runtime.accessibilityGranted
                            ? "Foreground context available"
                            : (consents.isEnabled(.localComputerHistory)
                                ? "Still needs approval" : "Not requested"),
                        complete: !consents.isEnabled(.localComputerHistory)
                            || model.runtime.accessibilityGranted
                    )
                    Divider().padding(.leading, 48)
                    finalCheckRow(
                        symbol: "keyboard",
                        title: "Activity monitoring",
                        detail: model.runtime.inputMonitoringGranted
                            ? "Activity signals available"
                            : (consents.isEnabled(.localComputerHistory)
                                ? "Still needs approval" : "Not requested"),
                        complete: !consents.isEnabled(.localComputerHistory)
                            || model.runtime.inputMonitoringGranted
                    )
                    Divider().padding(.leading, 48)
                    finalCheckRow(
                        symbol: "externaldrive.fill",
                        title: "Protected sources",
                        detail: [
                            consents.isEnabled(.appleScreenTime) ? "Screen Time" : nil,
                            consents.isEnabled(.aiConversations) ? "AI conversations" : nil,
                        ].compactMap { $0 }.joined(separator: " + ").isEmpty
                            ? "Off — Full Disk Access is not needed by Goalong"
                            : [
                                consents.isEnabled(.appleScreenTime) ? "Screen Time" : nil,
                                consents.isEnabled(.aiConversations) ? "AI conversations" : nil,
                            ].compactMap { $0 }.joined(separator: " + "),
                        complete: true
                    )
                }
                .padding(.horizontal, 16)
                .background(
                    LHTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.07))
                )

                Toggle(isOn: $launchAtLoginPreference) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start \(ProductIdentity.displayName) when I log in")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "Off by default. Enable only if you want Goalong to start automatically."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(17)
                .background(
                    LHTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                if let note {
                    callout(
                        symbol: "info.circle.fill",
                        tint: LHTheme.warning,
                        title: "One more step",
                        detail: note
                    )
                }
            }
        }
    }
#endif
