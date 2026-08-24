#if os(macOS)
    import SwiftUI

    struct PrivacyPage: View {
        @ObservedObject var model: DashboardViewModel
        @State private var deletionScope: DeletionScope?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Local-first by design",
                        title: "Privacy & security",
                        subtitle: "Understand exactly what is captured, what is hidden and what can leave your Mac."
                    ) {
                        HStack(spacing: 10) {
                            Button("Open data folder") {
                                model.openDataFolder()
                            }
                            .buttonStyle(.bordered)
                            Button {
                                model.refreshEverything()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    dataFlowCard
                    permissionsCard
                    protectionGrid

                    HStack(alignment: .top, spacing: 14) {
                        storageCard
                            .frame(maxWidth: .infinity)
                        identityCard
                            .frame(maxWidth: .infinity)
                    }

                    deletionCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 30)
            }
            .background(LHTheme.pageBackground)
            .alert(item: $deletionScope) { scope in
                Alert(
                    title: Text(scope.title),
                    message: Text(scope.message),
                    primaryButton: .destructive(Text("Delete")) {
                        model.deleteDetails(since: scope.cutoff)
                    },
                    secondaryButton: .cancel()
                )
            }
        }

        private var dataFlowCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle(
                        title: "What happens to your data",
                        subtitle: "The detailed record and the cryptographic proof follow separate paths"
                    )

                    HStack(alignment: .center, spacing: 12) {
                        flowNode(
                            symbol: "macwindow",
                            title: "1. Observe",
                            message: "Apps, windows, clicks and non-content input activity"
                        )
                        flowArrow
                        flowNode(
                            symbol: "internaldrive.fill",
                            title: "2. Keep local",
                            message: "Detailed JSONL events and private commitment salts"
                        )
                        flowArrow
                        flowNode(
                            symbol: "number.square.fill",
                            title: "3. Anchor",
                            message: model.runtime.verificationEnabled
                                ? "Opaque signed commitments only"
                                : "Stored locally until verification is enabled"
                        )
                        flowArrow
                        flowNode(
                            symbol: "eye.slash.fill",
                            title: "4. Share selectively",
                            message: "Only fields you explicitly reveal with their proofs"
                        )
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(LHTheme.accent)
                        Text(
                            "An opaque commitment does not contain the application, URL, window title, clicks or category. Your server necessarily sees connection metadata such as arrival time and IP when commitments are enabled."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .background(
                        LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }

        private var permissionsCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    SectionTitle(
                        title: "macOS permissions",
                        subtitle: "macOS switches, functional AX access and real input callbacks are measured separately."
                    )

                    captureHealthPanel

                    HStack(spacing: 12) {
                        permissionRow(
                            title: "Accessibility",
                            message: "Reads the active app, window and accessible UI context.",
                            granted: model.runtime.accessibilityGranted,
                            grantedLabel: "Granted",
                            buttonTitle: "Guided setup",
                            action: model.openAccessibilitySettings
                        )
                        permissionRow(
                            title: "Activity input",
                            message: "Reports the direct Input Monitoring switch. A real event callback is still required before capture is called healthy.",
                            granted: model.runtime.inputMonitoringGranted,
                            grantedLabel: "Available",
                            buttonTitle: "Guided setup",
                            action: model.openInputMonitoringSettings
                        )
                    }

                    if let health = model.runtime.captureHealth,
                        [.permissionRequired, .permissionAppearsEnabledButStaleForBuild,
                         .accessibilityContextUnavailable].contains(health.state)
                    {
                        HStack {
                            Label(health.detail, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LHTheme.warning)
                            Spacer()
                            Button("Open guided setup") { model.requestPermissions() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if model.runtime.captureHealth?.captureProven != true {
                        HStack {
                            Label(
                                "The switches or tap object may exist, but this process has not received a real input callback yet.",
                                systemImage: "waveform.path.ecg"
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LHTheme.warning)
                            Spacer()
                            Button("Validate input") { model.beginCaptureValidation() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LHTheme.success)
                            Text("A real input callback and Accessibility context have been observed for this running process.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private var captureHealthPanel: some View {
            let assessment = model.runtime.captureHealth
            let snapshot = model.runtime.captureHealthSnapshot
            return VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: assessment?.captureProven == true ? "checkmark.shield.fill" : "waveform.path.ecg")
                        .foregroundStyle(assessment?.captureProven == true ? LHTheme.success : LHTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(assessment?.state.title ?? "Capture health unavailable")
                            .font(.system(size: 12, weight: .semibold))
                        Text(assessment?.detail ?? "No persisted capture-health evidence is available yet.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Validate input now") { model.beginCaptureValidation() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let snapshot {
                    Text(
                        "Last input: \(snapshot.lastInputEventAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · click: \(snapshot.lastClickAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · typing: \(snapshot.lastTypingBurstAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · scroll: \(snapshot.lastScrollAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · shortcut: \(snapshot.lastShortcutAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never")"
                    )
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "AX: \(snapshot.lastAXContextSuccessAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · URL: \(snapshot.lastURLDetectedAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never") · suppression: \(snapshot.lastSuppressionReason?.rawValue ?? "none") at \(snapshot.lastSuppressionAt.map { DashboardFormatters.shortTime.string(from: $0) } ?? "never")"
                    )
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "Permissions: AX switch \(snapshot.permissions.accessibilityPreflight ? "on" : "off") · AX probe \(snapshot.permissions.accessibilityFunctionalProbe ? "works" : "fails") · Input Monitoring switch \(snapshot.permissions.inputMonitoringPreflight ? "on" : "off") · tap \(snapshot.eventTapLifecycle.rawValue)"
                    )
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "Build: \(snapshot.build.signatureKind.rawValue) · \(snapshot.build.codeDirectoryHash.map { String($0.prefix(14)) } ?? "no CDHash") · 5 min input events: \(snapshot.recentCounters.inputEventCount)"
                    )
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    if snapshot.build.signatureKind == .adHoc {
                        Text("Ad-hoc updates can change the app identity recognized by TCC and may require approval again. Existing history remains readable.")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LHTheme.warning)
                    }
                }
            }
            .padding(13)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var protectionGrid: some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                protectionCard(
                    symbol: "person.fill.questionmark",
                    title: "Private browsing",
                    message:
                        "No URL, title, click detail or keyboard activity is stored from detected private windows.",
                    tint: LHTheme.privateTint
                )
                protectionCard(
                    symbol: "key.fill",
                    title: "Passwords and secure fields",
                    message: "Password managers are excluded and secure text input suppresses keyboard activity.",
                    tint: LHTheme.success
                )
                protectionCard(
                    symbol: "keyboard.badge.ellipsis",
                    title: "No raw typed text",
                    message: "\(ProductIdentity.displayName) stores typing counts and duration, never reconstructed characters.",
                    tint: LHTheme.teal
                )
                protectionCard(
                    symbol: "link.badge.plus",
                    title: "Sanitized URLs",
                    message: model.settingsDraft.redactAllURLQueryValues
                        ? "URL query values and fragments are removed before local storage."
                        : "Sensitive query names are redacted; full-query redaction is currently disabled.",
                    tint: LHTheme.accent
                )
            }
        }

        private var storageCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Local storage",
                        subtitle: "Readable files protected by your macOS user account"
                    )

                    infoRow(
                        symbol: "externaldrive.fill",
                        title: "Current size",
                        value: DashboardFormatters.byteCount.string(fromByteCount: model.snapshot.storageBytes)
                    )
                    infoRow(
                        symbol: "calendar",
                        title: "Detailed retention",
                        value: model.settingsDraft.retentionDays == 0
                            ? "Keep indefinitely"
                            : "\(model.settingsDraft.retentionDays) days"
                    )
                    infoRow(
                        symbol: "doc.text",
                        title: "Available days",
                        value: "\(model.snapshot.availableDays.count)"
                    )
                    infoRow(
                        symbol: "lock.fill",
                        title: "File permissions",
                        value: "Folders 0700 · files 0600"
                    )

                    HStack {
                        Button("Open folder") { model.openDataFolder() }
                            .buttonStyle(.bordered)
                        Button("Open JSONL") { model.openTodayJSON() }
                            .buttonStyle(.bordered)
                        Button("Diagnostics") { model.openDiagnostics() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }

        private var identityCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(
                        title: "Verification identity",
                        subtitle: "Used to sign minute commitments without exposing activity"
                    )

                    HStack(spacing: 13) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                            .frame(width: 48, height: 48)
                            .background(
                                LHTheme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.deviceProtectionTitle)
                                .font(.system(size: 13, weight: .semibold))
                            Text(model.deviceAlgorithm)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("DEVICE ID")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(model.deviceID)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(11)
                    .background(
                        Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        StatusPill(
                            title: model.runtime.verificationEnabled ? "Verification enabled" : "Local-only mode",
                            symbol: model.runtime.verificationEnabled ? "checkmark.seal.fill" : "internaldrive",
                            tint: model.runtime.verificationEnabled ? LHTheme.accent : Color.secondary
                        )
                        Spacer()
                    }
                }
            }
        }

        private var deletionCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Delete local activity and derived memories")
                            .font(.system(size: 14, weight: .semibold))
                        Text(
                            "Deleting activity also removes its local semantic context, Activity Analysis, Activity Memory and Computer History projections. Agent Activity's source index, Screen Time, minute commitments and server receipts remain."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 20)
                    Menu {
                        Button("Last 10 minutes", role: .destructive) {
                            deletionScope = .lastTenMinutes
                        }
                        Button("Last hour", role: .destructive) {
                            deletionScope = .lastHour
                        }
                        Divider()
                        Button("All local activity and memories", role: .destructive) {
                            deletionScope = .all
                        }
                    } label: {
                        Label("Delete details…", systemImage: "trash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }

        private func flowNode(symbol: String, title: String, message: String) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var flowArrow: some View {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
        }

        private func permissionRow(
            title: String,
            message: String,
            granted: Bool,
            grantedLabel: String,
            buttonTitle: String,
            action: @escaping () -> Void
        ) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(granted ? LHTheme.success : LHTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Text(grantedLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LHTheme.success)
                } else {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func protectionCard(symbol: String, title: String, message: String, tint: Color) -> some View {
            LHCard(padding: 15) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        private func infoRow(symbol: String, title: String, value: String) -> some View {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
    }

    private enum DeletionScope: Identifiable {
        case lastTenMinutes
        case lastHour
        case all

        var id: String {
            switch self {
            case .lastTenMinutes: return "ten"
            case .lastHour: return "hour"
            case .all: return "all"
            }
        }

        var cutoff: Date? {
            switch self {
            case .lastTenMinutes: return Date().addingTimeInterval(-10 * 60)
            case .lastHour: return Date().addingTimeInterval(-60 * 60)
            case .all: return nil
            }
        }

        var title: String {
            switch self {
            case .lastTenMinutes: return "Delete the last 10 minutes?"
            case .lastHour: return "Delete the last hour?"
            case .all: return "Delete all local activity and derived memories?"
            }
        }

        var message: String {
            "This permanently removes the selected JSONL events, semantic context and the Activity Analysis, Activity Memory and Computer History files derived from them, including Goalong's Codex mirror. Agent Activity's metadata-only source index, Screen Time, cryptographic seals and receipts remain."
        }
    }
#endif
