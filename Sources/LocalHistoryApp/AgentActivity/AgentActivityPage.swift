#if os(macOS)
    import AgentActivity
    import AppKit
    import SwiftUI

    enum AgentActivityPresentation {
        case history
        case management
    }

    enum AgentConversationListPresentation {
        static func date(for record: AgentCaptureRecord) -> Date {
            if record.availability != .available {
                return record.sourceModifiedAt ?? record.capturedAt
            }
            return record.summary.endedAt
                ?? record.index.conversationEndedAt
                ?? record.sourceModifiedAt
                ?? record.summary.startedAt
                ?? record.index.conversationStartedAt
                ?? record.capturedAt
        }

        static func newestFirst(_ records: [AgentCaptureRecord]) -> [AgentCaptureRecord] {
            records.sorted { left, right in
                let leftDate = date(for: left)
                let rightDate = date(for: right)
                if leftDate != rightDate { return leftDate > rightDate }
                return left.id < right.id
            }
        }

        static func compactTitle(_ title: String, maximumCharacters: Int = 120) -> String {
            guard title.count > maximumCharacters, maximumCharacters > 1 else { return title }
            let end = title.index(title.startIndex, offsetBy: maximumCharacters - 1)
            return title[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }

        static func visibleMessageCounts(for record: AgentCaptureRecord) -> (prompts: Int, replies: Int) {
            let visibleMessages = record.summary.visibleMessages
            guard !visibleMessages.isEmpty else {
                return (
                    max(record.summary.userMessageCount, 0),
                    max(record.summary.assistantMessageCount, 0)
                )
            }
            return (
                visibleMessages.filter { $0.role == .user }.count,
                visibleMessages.filter { $0.role == .assistantFinal }.count
            )
        }
    }

    struct AgentActivityPage: View {
        @ObservedObject var agents: AgentActivityRuntime
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @State private var search = ""
        @State private var providerFilter: AgentProvider?
        @State private var editingFolder: AgentWatchedFolder?
        private let presentation: AgentActivityPresentation

        init(
            agents: AgentActivityRuntime,
            presentation: AgentActivityPresentation = .management
        ) {
            self.agents = agents
            self.presentation = presentation
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceConsentCard
                    if !consents.isEnabled(.aiConversations) {
                        disabledSourceExplanation
                    } else if presentation == .history {
                        conversationHistoryList
                    } else {
                        PageHeader(
                            eyebrow: "Sources",
                            title: "AI conversation sources",
                            subtitle:
                                "Choose the original local sources Goalong may read. Conversation bodies are never copied into Goalong storage."
                        ) {
                            HStack(spacing: 9) {
                                DateSelectionControl(date: agents.selectedDay, onChange: agents.selectDay)
                                Button {
                                    agents.scanNow(
                                        forceFullDiscovery: true,
                                        analyzeSelectedDay: true
                                    )
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
                }
                .padding(.horizontal, 24)
                .padding(.top, presentation == .management ? 28 : 18)
                .padding(.bottom, 50)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                if consents.isEnabled(.aiConversations) {
                    agents.scanNow(
                        forceFullDiscovery: false,
                        analyzeSelectedDay: true
                    )
                }
            }
            .onChange(of: consents.document) { _ in
                if consents.isEnabled(.aiConversations) {
                    agents.scanNow(forceFullDiscovery: false, analyzeSelectedDay: true)
                }
            }
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

        private var sourceConsentCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(
                            LHTheme.accent.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(consents.isEnabled(.aiConversations) ? "Local conversation reading enabled" : "Local conversation reading is off")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "Goalong reads only sources you authorize, directly at their original location. It keeps a bounded metadata index and never stores a second copy of transcript bodies."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { consents.isEnabled(.aiConversations) },
                            set: {
                                _ = consents.set(.aiConversations, enabled: $0, surface: .settings)
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }

        private var disabledSourceExplanation: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No provider source is being scanned", systemImage: "pause.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Existing Goalong events and proofs stay available. Turn this source on only if you want the app to inspect Codex, Claude, OpenCode or another folder you explicitly add."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var conversationHistoryList: some View {
            let captures = filteredCaptures
            return VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            "\(agents.overview.captures.count) conversation\(agents.overview.captures.count == 1 ? "" : "s")"
                        )
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        HStack(spacing: 7) {
                            Text(conversationSummaryDetail)
                            Text("·")
                            if agents.isScanning {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Updating changed sources…")
                            } else {
                                Label("Original sources", systemImage: "internaldrive")
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availableProviders.count > 1 {
                        Picker("Provider", selection: $providerFilter) {
                            Text("All providers").tag(nil as AgentProvider?)
                            ForEach(availableProviders) { provider in
                                Text(provider.displayName).tag(provider as AgentProvider?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    TextField("Search conversations", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }

                LHCard(padding: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if captures.isEmpty {
                            EmptyStateView(
                                symbol: agents.isScanning
                                    ? "arrow.triangle.2.circlepath" : "bubble.left.and.bubble.right",
                                title: agents.isScanning ? "Reading conversations" : "No conversations for this day",
                                message: agents.isScanning
                                    ? "Goalong is checking changed original sources."
                                    : "Try another day or review AI conversation sources in Settings."
                            )
                            .frame(minHeight: 230)
                        } else {
                            ForEach(Array(captures.prefix(120).enumerated()), id: \.element.id) { index, record in
                                conversationRow(record)
                                if index < min(captures.count, 120) - 1 {
                                    Divider().padding(.leading, 66)
                                }
                            }
                            if captures.count > 120 {
                                Text("Showing the 120 newest matching conversations")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                }
            }
        }

        private func conversationRow(_ record: AgentCaptureRecord) -> some View {
            let title = conversationTitle(record)
            return HStack(alignment: .center, spacing: 14) {
                providerIcon(record.provider)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AgentConversationListPresentation.compactTitle(title))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .help(title)
                    HStack(spacing: 6) {
                        Text(Self.timeFormatter.string(from: AgentConversationListPresentation.date(for: record)))
                            .monospacedDigit()
                        Text("·")
                        Text(conversationDetail(record))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 16)

                if record.availability != .available {
                    Label(record.availability.displayName, systemImage: statusSymbol(record.availability))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                } else if !record.projectionIsComplete {
                    Label("Partial day", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                        .help("The selected day exceeded the bounded direct-read limit; older messages from that day may be absent.")
                }

                Menu {
                    Button("Reveal original source") { agents.openOriginal(record) }
                    Button("Verify original SHA-256") { agents.verify(record) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("Conversation actions")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }

        private var conversationSummaryDetail: String {
            let prompts = agents.overview.captures.reduce(0) { count, record in
                count + AgentConversationListPresentation.visibleMessageCounts(for: record).prompts
            }
            let replies = agents.overview.captures.reduce(0) { count, record in
                count + AgentConversationListPresentation.visibleMessageCounts(for: record).replies
            }
            var parts = [
                "\(prompts) prompt\(prompts == 1 ? "" : "s")",
                "\(replies) final repl\(replies == 1 ? "y" : "ies")",
            ]
            parts.append(contentsOf: availableProviders.map(\.displayName))
            return parts.joined(separator: " · ")
        }

        private func conversationTitle(_ record: AgentCaptureRecord) -> String {
            let title = record.summary.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "\(record.provider.displayName) conversation" : title
        }

        private func conversationDetail(_ record: AgentCaptureRecord) -> String {
            guard record.availability == .available else {
                return record.provider.displayName
            }
            let counts = AgentConversationListPresentation.visibleMessageCounts(for: record)
            guard counts.prompts + counts.replies > 0 else {
                return record.provider.displayName
            }
            return
                "\(record.provider.displayName) · \(counts.prompts) prompt\(counts.prompts == 1 ? "" : "s") · \(counts.replies) repl\(counts.replies == 1 ? "y" : "ies")"
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateFormat = "HH:mm"
            return formatter
        }()

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
                    Text("Direct source analysis")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Conversation bodies are read in place from Codex, Claude Code, OpenCode and configured folders. The local index contains only provider, stable ID, source reference, timestamps, size, offsets and SHA-256."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "No blob, snapshot, materialized copy or hook payload is stored by Goalong History."
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LHTheme.privateTint)
                    if agents.lastScanResult.capacityLimitedFolderCount > 0 {
                        Text(
                            "A source exceeded the lightweight index ceiling; Goalong retained its newest bounded metadata projection without retrying an eviction loop."
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LHTheme.warning)
                    }
                }
                Spacer(minLength: 18)
                if agents.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                StatusPill(
                    title: agents.indexIsValid ? "Lightweight index valid" : "Index needs attention",
                    symbol: agents.indexIsValid ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    tint: agents.indexIsValid ? LHTheme.success : LHTheme.danger
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
                    title: "Indexed sources",
                    value: String(agents.overview.captures.count),
                    detail: formatBytes(agents.overview.indexBytes) + " total index",
                    symbol: "list.bullet.rectangle.fill",
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
                                "Optional hooks only wake incremental discovery. Their stdin is discarded and never added to the index."
                        )
                        Spacer()
                        Button("Open rescan signals") {
                            agents.openSignalsFolder()
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
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
                        ? "Folder active"
                        : agents.configuration.watchedFolders.contains(where: {
                            $0.provider == .codex && !$0.isManaged
                        }) ? "Detected — off" : "Not detected",
                    symbol: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
                        ? "checkmark.circle.fill" : "folder.badge.questionmark",
                    tint: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
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
                    title: status.isInstalled ? "Rescan signal installed" : "Periodic discovery",
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
                                "Stopped default sources stay stopped after relaunch. Detect or add one explicitly to allow it again. Goalong stores only lightweight references."
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
                            title: "Indexed original conversations",
                            subtitle:
                                "One replaceable index entry per stable conversation. Selecting or analyzing it reads the provider’s original source directly."
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
                            title: agents.isScanning ? "Checking agent sources" : "No matching indexed source",
                            message: agents.isScanning
                                ? "Known sources are checked incrementally; changed originals are re-read in place."
                                : "Launch an agent, install an optional rescan signal, or add its original history folder."
                        )
                        .frame(minHeight: 210)
                    } else {
                        ForEach(Array(filteredCaptures.prefix(120).enumerated()), id: \.element.id) { index, record in
                            captureRow(record)
                            if index < min(filteredCaptures.count, 120) - 1 { Divider() }
                        }
                        if filteredCaptures.count > 120 {
                            Text("Showing the 120 newest matching source references.")
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
                    Text(DashboardFormatters.fullTimestamp.string(from: record.sourceModifiedAt ?? record.capturedAt))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        compactPill("\(record.summary.messageCount) msg", symbol: "bubble.left")
                        compactPill("\(record.summary.toolCallCount) tools", symbol: "wrench")
                        compactPill(record.availability.displayName, symbol: statusSymbol(record.availability))
                        compactPill(formatBytes(record.byteCount), symbol: "doc")
                    }
                }
                Menu {
                    Button("Reveal original source") { agents.openOriginal(record) }
                    Divider()
                    Button("Verify original SHA-256") { agents.verify(record) }
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
                            title: "Lightweight source index",
                            subtitle:
                                "Only bounded source metadata is stored in Goalong History’s private Application Support folder."
                        )
                        detailLine("Agent Activity total", value: formatBytes(agents.storageBytes))
                        detailLine("Index file", value: formatBytes(agents.overview.indexBytes))
                        detailLine("Original bytes read today", value: formatBytes(agents.overview.sourceBytes))
                        detailLine("Index structure", value: agents.indexIsValid ? "Valid" : "Invalid")
                        Button("Open Agent Activity metadata") {
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
                                "Provider-independent analysis without becoming another transcript repository."
                        )
                        privacyBullet("Conversation bodies stay exclusively in each provider’s original storage.")
                        privacyBullet("A changed source replaces its prior fingerprint instead of creating a version.")
                        privacyBullet("Missing and unreadable originals remain explicit index states.")
                        privacyBullet("Hooks overwrite one tiny signal per provider and discard their stdin.")
                        privacyBullet(
                            "Full discovery is periodic; ordinary checks use the known index and provider metadata."
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var filteredCaptures: [AgentCaptureRecord] {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let effectiveProviderFilter = availableProviders.count > 1 ? providerFilter : nil
            return AgentConversationListPresentation.newestFirst(
                agents.overview.captures.filter { record in
                    let providerMatches = effectiveProviderFilter == nil || record.provider == effectiveProviderFilter
                    let searchMatches = query.isEmpty || record.searchableText.contains(query)
                    return providerMatches && searchMatches
                })
        }

        private var availableProviders: [AgentProvider] {
            var seen = Set<String>()
            return agents.overview.captures.compactMap { record in
                seen.insert(record.provider.rawValue).inserted ? record.provider : nil
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            case .gemini: return "sparkles"
            case .copilot: return "chevron.left.forwardslash.chevron.right"
            case .custom: return "cpu.fill"
            }
        }

        private func statusSymbol(_ status: AgentSourceAvailability) -> String {
            switch status {
            case .available: return "checkmark.circle"
            case .missing: return "questionmark.folder"
            case .inaccessible: return "lock.slash"
            }
        }

        private func providerTint(_ provider: AgentProvider) -> Color {
            switch provider {
            case .codex: return LHTheme.success
            case .claudeCode: return LHTheme.warning
            case .cursor: return LHTheme.accent
            case .openCode: return LHTheme.teal
            case .gemini: return LHTheme.warning
            case .copilot: return LHTheme.success
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
                        ? "Every supported regular file is indexed in place except common credential stores, cookies, private keys and caches."
                        : "Goalong directly reads common transcript, chat, log, trace and state formats without copying them."
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
