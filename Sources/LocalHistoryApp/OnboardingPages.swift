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
                    case .accessibility:
                        permissionPage(
                            symbol: "accessibility",
                            tint: LHTheme.accent,
                            title: "Let \(ProductIdentity.displayName) understand the foreground context",
                            subtitle: "Accessibility lets the app read permitted information about the active app, window, browser URL, and clicked interface element.",
                            granted: model.runtime.accessibilityGranted,
                            bullets: [
                                "Used only to observe foreground context",
                                "Never used to control your Mac",
                                "Private windows and secure fields are suppressed",
                            ],
                            actionTitle: "Allow Accessibility",
                            action: requestAccessibility,
                            settingsAction: permissions.openAccessibilitySettings
                        )
                    case .inputMonitoring:
                        permissionPage(
                            symbol: "keyboard",
                            tint: LHTheme.privateTint,
                            title: "Measure activity without reading what you type",
                            subtitle: "Accessibility already includes event-listening access on macOS. A direct Input Monitoring grant is requested only when the current Mac still needs it.",
                            granted: model.runtime.inputMonitoringGranted,
                            bullets: [
                                "Characters and words are never stored",
                                "Accessibility may complete this step automatically",
                                "Passwords and secure input are excluded",
                                "You can pause capture instantly from the menu bar",
                            ],
                            actionTitle: "Allow Input Monitoring",
                            action: requestInputMonitoring,
                            settingsAction: permissions.openInputMonitoringSettings
                        )
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
                                    colors: [LHTheme.accent.opacity(0.18), LHTheme.privateTint.opacity(0.13)],
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
                        Text("\(ProductIdentity.displayName) creates a clear timeline on this Mac, seals it minute by minute, and lets you share only the parts you choose.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    featureCard(symbol: "macwindow", title: "Local first", detail: "Detailed activity stays in your private Application Support folder.")
                    featureCard(symbol: "checkmark.shield", title: "Tamper-evident", detail: "Cryptographic seals make later rewriting or omission detectable.")
                    featureCard(symbol: "eye.slash", title: "Selective sharing", detail: "Reveal details, an app or category, or keep a period private.")
                }

                callout(
                    symbol: "hand.raised.fill",
                    tint: LHTheme.success,
                    title: "You stay in control",
                    detail: "Every permission is explained before macOS asks for it. Nothing is enabled silently."
                )
            }
        }

        var privacyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("A useful record needs context. It does not need your content.")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Detailed activity remains local unless you create a selective share package.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 14) {
                    boundaryCard(
                        symbol: "externaldrive.fill",
                        tint: LHTheme.accent,
                        title: "Stored locally",
                        items: [
                            "Active app and permitted window context",
                            "Cleaned browser URL when available",
                            "Clicks, scrolling, shortcuts, and typing duration",
                            "Pause, lock, sleep, and private states",
                        ]
                    )
                    boundaryCard(
                        symbol: "nosign",
                        tint: LHTheme.danger,
                        title: "Never captured",
                        items: [
                            "Screenshots, camera, or screen video",
                            "Microphone or system audio",
                            "Clipboard contents or passwords",
                            "Typed characters or reconstructed text",
                        ]
                    )
                }

                callout(
                    symbol: "eye.slash.fill",
                    tint: LHTheme.privateTint,
                    title: "Private browsing fails closed",
                    detail: "Only a generic private period is stored — not the URL, title, clicks, or keyboard activity."
                )
            }
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
                        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))

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
                Text("The guide stays visible beside System Settings and refreshes automatically. macOS may ask you to quit and reopen \(ProductIdentity.displayName).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }

        var readyPage: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle().fill((allPermissionsGranted ? LHTheme.success : LHTheme.warning).opacity(0.12))
                        Image(systemName: allPermissionsGranted ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(allPermissionsGranted ? LHTheme.success : LHTheme.warning)
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(allPermissionsGranted ? "\(ProductIdentity.displayName) is ready" : "You can finish and grant access later")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(allPermissionsGranted
                            ? "Your private timeline begins as soon as setup closes."
                            : "The app will open Privacy & Security for the remaining permission.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    finalCheckRow(
                        symbol: "accessibility",
                        title: "Accessibility",
                        detail: model.runtime.accessibilityGranted ? "Foreground context available" : "Still needs approval",
                        complete: model.runtime.accessibilityGranted
                    )
                    Divider().padding(.leading, 48)
                    finalCheckRow(
                        symbol: "keyboard",
                        title: "Activity monitoring",
                        detail: model.runtime.inputMonitoringGranted ? "Activity signals available" : "Still needs approval",
                        complete: model.runtime.inputMonitoringGranted
                    )
                }
                .padding(.horizontal, 16)
                .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))

                Toggle(isOn: $launchAtLoginPreference) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start \(ProductIdentity.displayName) when I log in")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Recommended to avoid accidental gaps. You can change this later.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(17)
                .background(LHTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let note {
                    callout(symbol: "info.circle.fill", tint: LHTheme.warning, title: "One more step", detail: note)
                }
            }
        }
    }
#endif
