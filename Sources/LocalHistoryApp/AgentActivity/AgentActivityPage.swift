#if os(macOS)
    import AgentActivity
    import AppKit
    import SwiftUI

    struct AgentActivityPage: View {
        @ObservedObject var agents: AgentActivityRuntime
        @State private var search = ""
        @State private var providerFilter: AgentProvider?
        @State private var editingFolder: AgentWatchedFolder?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Local agent memory",
                        title: "Agentic work",
                        subtitle:
                            "Capture available local agent conversations, provider events, tool activity and changing files. Everything is processed and stored on this Mac unless you explicitly export it."
                    ) {
                        HStack(spacing: 9) {
                            DateSelectionControl(date: agents.selectedDay, onChange: agents.selectDay)
                            Button {
                                agents.scanNow()
                            } label: {
                                Label(agents.isScanning ? "Scanning…" : "Scan now", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(agents.isScanning)

                            Button {
                                agents.chooseFolder()
                            } label: {
                                Label("Add folder", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    localStatusBanner
                    metrics
                    integrationCard
                    watchedFoldersCard
                    captureHistoryCard
                    storageAndPrivacyCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 50)
            }
            .background(LHTheme.pageBackground)
            .onAppear { agents.scanNow() }
            .alert(item: $agents.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $editingFolder) { folder in
                AgentFolderEditorSheet(folder: folder) { updated in
                    agents.applyFolder(updated)
                    editingFolder = nil
                } onCancel: {
                    editingFolder = nil
                }
            }
        }

        private var localStatusBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LHTheme.success.opacity(0.12))
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LHTheme.success)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Full local capture")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Raw transcripts and hook payloads are copied into an immutable local vault. No agent content uses the network path reserved for opaque Goalong commitments."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Common standalone credential stores, cookies and private-key files are excluded by filename. Secrets echoed inside a transcript or tool result remain part of that local capture."
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LHTheme.privateTint)
                }
                Spacer(minLength: 18)
                if agents.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                StatusPill(
                    title: agents.chainIsValid ? "Hash chain intact" : "Chain needs attention",
                    symbol: agents.chainIsValid ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    tint: agents.chainIsValid ? LHTheme.success : LHTheme.danger
                )
            }
            .padding(14)
            .background(LHTheme.success.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.success.opacity(0.14), lineWidth: 1)
            )
        }

        private var metrics: some View {
            HStack(spacing: 12) {
                MetricCard(
                    title: "Agent sessions",
                    value: String(agents.overview.sessionCount),
                    detail: DashboardFormatters.dayTitle.string(from: agents.selectedDay),
                    symbol: "cpu",
                    tint: LHTheme.accent
                )
                MetricCard(
                    title: "Messages",
                    value: String(agents.overview.messageCount),
                    detail: "User, assistant and system turns",
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: LHTheme.teal
                )
                MetricCard(
                    title: "Tool calls",
                    value: String(agents.overview.toolCallCount),
                    detail: agents.overview.errorCount == 0
                        ? "No parsed failures"
                        : "\(agents.overview.errorCount) parsed failure(s)",
                    symbol: "wrench.and.screwdriver.fill",
                    tint: agents.overview.errorCount == 0 ? LHTheme.success : LHTheme.warning
                )
                MetricCard(
                    title: "New versions",
                    value: String(agents.overview.captures.count),
                    detail: formatBytes(agents.overview.storedBytes) + " stored today",
                    symbol: "doc.on.doc.fill",
                    tint: LHTheme.privateTint
                )
            }
        }

        private var integrationCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top) {
                        sectionHeader(
                            symbol: "point.3.connected.trianglepath.dotted",
                            tint: LHTheme.accent,
                            title: "Live agent integrations",
                            subtitle:
                                "Install lightweight local hooks in addition to folder monitoring. Goalong preserves the JSON event payloads exposed by each provider as they happen."
                        )
                        Spacer()
                        Button("Open hook inbox") {
                            agents.openHookInbox()
                        }
                        .buttonStyle(.bordered)
                    }

                    providerDirectoryRow
                    Divider()
                    ForEach(AgentIntegrationKind.allCases) { kind in
                        Divider()
                        integrationRow(kind)
                    }
                }
            }
        }

        private var providerDirectoryRow: some View {
            HStack(spacing: 12) {
                providerIcon(.codex)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex local history")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        "Goalong monitors Codex sessions, history and logs under `~/.codex` when that directory exists."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged
                    })
                        ? "Folder active" : "Not detected",
                    symbol: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged
                    })
                        ? "checkmark.circle.fill" : "folder.badge.questionmark",
                    tint: agents.configuration.watchedFolders.contains(where: { $0.provider == .codex && !$0.isManaged }
                    )
                        ? LHTheme.success : Color.secondary
                )
                Button("Detect") {
                    agents.detectCommonSources()
                }
                .buttonStyle(.bordered)
            }
        }

        private func integrationRow(_ kind: AgentIntegrationKind) -> some View {
            let status = agents.status(for: kind)
            return HStack(spacing: 12) {
                providerIcon(kind.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(status.configurationPath)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                StatusPill(
                    title: status.isInstalled ? "Live capture installed" : "Folder capture only",
                    symbol: status.isInstalled ? "bolt.shield.fill" : "bolt.slash",
                    tint: status.isInstalled ? LHTheme.success : Color.secondary
                )
                if status.isInstalled {
                    Button("Remove") {
                        agents.uninstallIntegration(kind)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Install") {
                        agents.installIntegration(kind)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }

        private var watchedFoldersCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top) {
                        sectionHeader(
                            symbol: "folder.badge.gearshape",
                            tint: LHTheme.teal,
                            title: "Folders monitored",
                            subtitle:
                                "Add any transcript, agent-state or project folder. Provider, recursion and capture breadth can be changed at any time."
                        )
                        Spacer()
                        Button("Detect common folders") {
                            agents.detectCommonSources()
                        }
                        .buttonStyle(.bordered)
                        Button {
                            agents.chooseFolder()
                        } label: {
                            Label("Add folder", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if agents.userWatchedFolders.isEmpty {
                        EmptyStateView(
                            symbol: "folder.badge.plus",
                            title: "No agent folders are monitored yet",
                            message:
                                "Detect the standard Codex, Claude Code, Cursor and OpenCode folders, or choose any directory manually.",
                            buttonTitle: "Detect common folders",
                            action: agents.detectCommonSources
                        )
                        .frame(minHeight: 190)
                    } else {
                        ForEach(Array(agents.userWatchedFolders.enumerated()), id: \.element.id) { index, folder in
                            folderRow(folder)
                            if index < agents.userWatchedFolders.count - 1 { Divider() }
                        }
                    }
                }
            }
        }

        private func folderRow(_ folder: AgentWatchedFolder) -> some View {
            HStack(spacing: 12) {
                providerIcon(folder.provider)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(folder.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(folder.captureMode.displayName)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(providerTint(folder.provider))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(providerTint(folder.provider).opacity(0.10), in: Capsule())
                    }
                    Text(folder.path)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 14)
                Toggle(
                    "Active",
                    isOn: Binding(
                        get: { folder.isEnabled },
                        set: { agents.setFolderEnabled($0, id: folder.id) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                Button {
                    agents.openFolder(folder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("Open source folder")
                Button {
                    editingFolder = folder
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .help("Edit monitoring settings")
                Button(role: .destructive) {
                    agents.removeFolder(id: folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Stop monitoring this folder")
            }
            .padding(.vertical, 4)
        }

        private var captureHistoryCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        sectionHeader(
                            symbol: "clock.arrow.circlepath",
                            tint: LHTheme.privateTint,
                            title: "Captured agent history",
                            subtitle:
                                "Every changed version is content-addressed and linked to the previous manifest. Append-only transcripts use lossless deltas."
                        )
                        Spacer()
                        Picker("Provider", selection: $providerFilter) {
                            Text("All providers").tag(nil as AgentProvider?)
                            ForEach(AgentProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider as AgentProvider?)
                            }
                        }
                        .frame(width: 165)
                        TextField("Search sessions, files, models or tools", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 285)
                    }

                    if filteredCaptures.isEmpty {
                        EmptyStateView(
                            symbol: agents.isScanning ? "arrow.triangle.2.circlepath" : "cpu",
                            title: agents.isScanning ? "Scanning agent folders" : "No matching agent capture",
                            message: agents.isScanning
                                ? "New and changed local files are being hashed and stored."
                                : "Launch an agent, install a live integration, or add the folder where it stores its history."
                        )
                        .frame(minHeight: 210)
                    } else {
                        ForEach(Array(filteredCaptures.prefix(120).enumerated()), id: \.element.id) { index, record in
                            captureRow(record)
                            if index < min(filteredCaptures.count, 120) - 1 { Divider() }
                        }
                        if filteredCaptures.count > 120 {
                            Text("Showing the 120 newest matching versions.")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 5)
                        }
                    }
                }
            }
        }

        private func captureRow(_ record: AgentCaptureRecord) -> some View {
            HStack(spacing: 12) {
                providerIcon(record.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.summary.title ?? URL(fileURLWithPath: record.relativePath).lastPathComponent)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("\(record.provider.displayName) · \(record.watchedFolderName) · \(record.relativePath)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let excerpt = record.summary.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(DashboardFormatters.fullTimestamp.string(from: record.capturedAt))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        compactPill("\(record.summary.messageCount) msg", symbol: "bubble.left")
                        compactPill("\(record.summary.toolCallCount) tools", symbol: "wrench")
                        compactPill("v\(record.version)", symbol: "doc.on.doc")
                        compactPill(formatBytes(record.storedByteCount), symbol: "internaldrive")
                    }
                }
                Menu {
                    Button("Open immutable copy") { agents.openCapturedCopy(record) }
                    Button("Reveal original") { agents.openOriginal(record) }
                    Divider()
                    Button("Verify SHA-256") { agents.verify(record) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
            .padding(.vertical, 5)
        }

        private var storageAndPrivacyCard: some View {
            HStack(alignment: .top, spacing: 14) {
                LHCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(
                            symbol: "lock.square.stack.fill",
                            tint: LHTheme.success,
                            title: "Private agent vault",
                            subtitle:
                                "Raw content remains in Goalong History’s private Application Support folder with user-only permissions."
                        )
                        detailLine("Vault size", value: formatBytes(agents.storageBytes))
                        detailLine("Stored today", value: formatBytes(agents.overview.storedBytes))
                        detailLine("Original bytes represented", value: formatBytes(agents.overview.capturedBytes))
                        detailLine("Manifest chain", value: agents.chainIsValid ? "Valid" : "Invalid")
                        Button("Open local agent vault") {
                            agents.openRootFolder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)

                LHCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(
                            symbol: "checkmark.shield.fill",
                            tint: LHTheme.privateTint,
                            title: "What Goalong adds",
                            subtitle:
                                "A provider-independent history that can later be selectively disclosed and verified."
                        )
                        privacyBullet("Full raw bytes are retained locally, not only a summary.")
                        privacyBullet("Changed files are hashed and chained immediately after capture.")
                        privacyBullet("Append-only histories store exact deltas without losing earlier states.")
                        privacyBullet("Live hook integrations only append to the local inbox and cannot upload.")
                        privacyBullet(
                            "Common standalone credential files are hard-excluded; transcript and tool-result contents are preserved as-is."
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var filteredCaptures: [AgentCaptureRecord] {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return agents.overview.captures.filter { record in
                let providerMatches = providerFilter == nil || record.provider == providerFilter
                let searchMatches = query.isEmpty || record.searchableText.contains(query)
                return providerMatches && searchMatches
            }
        }

        private func providerIcon(_ provider: AgentProvider) -> some View {
            Image(systemName: providerSymbol(provider))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(providerTint(provider))
                .frame(width: 34, height: 34)
                .background(
                    providerTint(provider).opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private func compactPill(_ title: String, symbol: String) -> some View {
            Label(title, systemImage: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.045), in: Capsule())
        }

        private func detailLine(_ title: String, value: String) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
        }

        private func privacyBullet(_ text: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(LHTheme.success)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func sectionHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func providerSymbol(_ provider: AgentProvider) -> String {
            switch provider {
            case .codex: return "terminal.fill"
            case .claudeCode: return "brain.head.profile"
            case .cursor: return "cursorarrow.rays"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
            case .custom: return "cpu.fill"
            }
        }

        private func providerTint(_ provider: AgentProvider) -> Color {
            switch provider {
            case .codex: return LHTheme.success
            case .claudeCode: return LHTheme.warning
            case .cursor: return LHTheme.accent
            case .openCode: return LHTheme.teal
            case .custom: return LHTheme.privateTint
            }
        }

        private func formatBytes(_ bytes: Int64) -> String {
            DashboardFormatters.byteCount.string(fromByteCount: bytes)
        }
    }

    private struct AgentFolderEditorSheet: View {
        @State private var draft: AgentWatchedFolder
        let onSave: (AgentWatchedFolder) -> Void
        let onCancel: () -> Void

        init(
            folder: AgentWatchedFolder,
            onSave: @escaping (AgentWatchedFolder) -> Void,
            onCancel: @escaping () -> Void
        ) {
            _draft = State(initialValue: folder)
            self.onSave = onSave
            self.onCancel = onCancel
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit monitored folder")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(draft.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Form {
                    TextField("Display name", text: $draft.displayName)
                    Picker("Agent provider", selection: $draft.provider) {
                        ForEach(AgentProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    Picker("Capture", selection: $draft.captureMode) {
                        ForEach(AgentCaptureMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Toggle("Monitor this folder", isOn: $draft.isEnabled)
                    Toggle("Include subfolders", isOn: $draft.includeSubdirectories)
                }
                .formStyle(.grouped)

                Text(
                    draft.captureMode == .everyFile
                        ? "Every regular file is copied except common standalone credential stores, cookies, private keys, caches and Goalong’s own vault."
                        : "Goalong captures common transcript, chat, log, trace, state and database formats."
                )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        onSave(draft)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 560, height: 410)
        }
    }
#endif
