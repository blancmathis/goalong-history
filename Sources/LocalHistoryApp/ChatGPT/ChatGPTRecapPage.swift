#if os(macOS)
    import SwiftUI

    struct ChatGPTRecapPage: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var recapRuntime: ChatGPTRecapRuntime

        init(model: DashboardViewModel) {
            self.model = model
            _recapRuntime = ObservedObject(wrappedValue: ChatGPTRecapRuntime.shared)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "ChatGPT-powered local synthesis",
                        title: "AI daily recap",
                        subtitle:
                            "Combine Goalong activity, document context, Apple Screen Time, local agent transcripts and an optional ChatGPT export into one evidence-aware recap."
                    ) {
                        HStack(spacing: 10) {
                            DateSelectionControl(date: recapRuntime.selectedDay, onChange: recapRuntime.selectDay)
                            Button {
                                recapRuntime.revealRecapFiles()
                            } label: {
                                Label("Files", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                recapRuntime.generateRecap()
                            } label: {
                                Label(
                                    recapRuntime.isGenerating ? "Generating…" : "Generate recap",
                                    systemImage: "sparkles"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canGenerate || recapRuntime.isGenerating)
                        }
                    }

                    accountCard
                    sourceCard
                    historyImportCard
                    automaticCard
                    recapCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 60)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                recapRuntime.configure(deviceID: model.deviceID)
                recapRuntime.selectDay(model.selectedDay)
            }
            .onChange(of: model.selectedDay) { next in
                recapRuntime.selectDay(next)
            }
            .alert(item: $recapRuntime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var accountCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: connectionSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(connectionTint)
                        .frame(width: 42, height: 42)
                        .background(
                            connectionTint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(connectionTitle)
                            .font(.system(size: 14, weight: .semibold))
                        Text(connectionMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "Goalong never reads or copies OAuth token values. Codex stores and refreshes them inside Goalong’s isolated private Codex directory. API-key credentials are deliberately rejected to avoid accidental usage-based billing."
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    VStack(alignment: .trailing, spacing: 10) {
                        StatusPill(
                            title: connectionPill,
                            symbol: connectionSymbol,
                            tint: connectionTint
                        )
                        accountActions
                    }
                }
            }
        }

        @ViewBuilder private var accountActions: some View {
            switch recapRuntime.connectionState {
            case .codexUnavailable:
                Button("Install Codex") {
                    recapRuntime.openCodexInstallGuide()
                }
                .buttonStyle(.borderedProminent)
            case .connected:
                HStack(spacing: 8) {
                    Button {
                        recapRuntime.refreshAccount()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(recapRuntime.isCheckingAccount)
                    Button("Disconnect") {
                        recapRuntime.disconnectChatGPT()
                    }
                    .buttonStyle(.bordered)
                }
            case .checking:
                ProgressView()
                    .controlSize(.small)
            default:
                HStack(spacing: 8) {
                    Button {
                        recapRuntime.refreshAccount()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(recapRuntime.isCheckingAccount)
                    Button(recapRuntime.isConnecting ? "Connecting…" : "Connect ChatGPT") {
                        recapRuntime.connectChatGPT()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recapRuntime.isConnecting)
                }
            }
        }

        private var sourceCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Context assembled for the recap agent")
                                .font(.system(size: 13, weight: .semibold))
                            Text(
                                "Goalong sends a bounded, sanitized synthesis for the chosen day—not the raw event database or your whole disk."
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(LHTheme.success)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                        spacing: 10
                    ) {
                        sourceTile(
                            symbol: "macbook",
                            title: "Computer activity",
                            value: sourceCounts.map { "\($0.activeMinutes) active min" } ?? "Built locally",
                            detail: "Apps, focus blocks, pages and accessible document context"
                        )
                        sourceTile(
                            symbol: "macbook.and.iphone",
                            title: "Apple Screen Time",
                            value: sourceCounts.map { "\($0.screenTimeDevices) device(s)" } ?? "Optional source",
                            detail: "Per-device totals and top applications"
                        )
                        sourceTile(
                            symbol: "cpu",
                            title: "Agent chats",
                            value: sourceCounts.map { "\($0.agentMessages) message(s)" } ?? "Local vault",
                            detail: "Codex, Claude Code, Cursor, OpenCode and watched folders"
                        )
                        sourceTile(
                            symbol: "bubble.left.and.bubble.right",
                            title: "ChatGPT history",
                            value: sourceCounts.map { "\($0.importedChatMessages) message(s)" }
                                ?? (recapRuntime.importSummary.map { "\($0.messageCount) imported" } ?? "Not imported"),
                            detail: "Selected-day messages from conversations.json"
                        )
                    }
                }
            }
        }

        private var historyImportCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(
                            LHTheme.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Existing ChatGPT conversations")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "Connecting the account authorizes Codex usage; it does not expose your existing ChatGPT chats. Import conversations.json from a ChatGPT data export to include that history. Common credential patterns are redacted before the normalized local copy is stored."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        if let summary = recapRuntime.importSummary {
                            Text(
                                "\(summary.conversationCount) conversations · \(summary.messageCount) messages · imported \(summary.importedAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LHTheme.success)
                        }
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        if recapRuntime.importSummary != nil {
                            Button("Delete import") {
                                recapRuntime.clearImportedChatGPTHistory()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(recapRuntime.isImporting ? "Importing…" : "Import conversations.json") {
                            recapRuntime.importChatGPTHistory()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recapRuntime.isImporting)
                    }
                }
            }
        }

        private var automaticCard: some View {
            LHCard {
                Toggle(isOn: $recapRuntime.automaticRecapsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic recap refresh")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "When explicitly enabled, Goalong refreshes today’s recap at most once every four hours while the app is running and ChatGPT remains connected."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }

        private var recapCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recapRuntime.isGenerating ? "Recap agent is working" : "Generated recap")
                                .font(.system(size: 13, weight: .semibold))
                            if let recap = recapRuntime.recap {
                                Text(
                                    "Generated \(recap.generatedAt.formatted(date: .abbreviated, time: .shortened)) · context \(recap.contextDigest.prefix(10))…"
                                )
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                            } else {
                                Text("No recap has been generated for this day yet.")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if recapRuntime.isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Divider()

                    if recapRuntime.isGenerating {
                        if recapRuntime.streamedMarkdown.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Assembling the local context and starting an isolated, network-disabled Codex thread…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                        } else {
                            markdownText(recapRuntime.streamedMarkdown)
                        }
                    } else if let recap = recapRuntime.recap {
                        markdownText(recap.markdown)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(LHTheme.accent.opacity(0.75))
                            Text("Connect ChatGPT, then generate the first evidence-aware recap.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 190)
                    }
                }
            }
        }

        private func sourceTile(symbol: String, title: String, value: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: symbol)
                        .foregroundStyle(LHTheme.accent)
                    Spacer()
                    Text(value)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }

        private func markdownText(_ markdown: String) -> some View {
            Text(.init(markdown))
                .font(.system(size: 11))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }

        private var sourceCounts: ChatGPTRecapSourceCounts? {
            recapRuntime.recap?.sourceCounts
        }

        private var canGenerate: Bool {
            if case .connected = recapRuntime.connectionState { return true }
            return false
        }

        private var connectionTitle: String {
            switch recapRuntime.connectionState {
            case .checking: return "Checking ChatGPT connection"
            case .codexUnavailable: return "Codex is not installed"
            case .signedOut: return "Connect your ChatGPT account"
            case .connected(let email, let plan):
                return [email, plan.map { "ChatGPT \($0)" }].compactMap { $0 }.joined(separator: " · ")
            case .unsupportedCredentialMode: return "A non-ChatGPT Codex credential is active"
            case .failed: return "ChatGPT connection needs attention"
            }
        }

        private var connectionMessage: String {
            switch recapRuntime.connectionState {
            case .checking:
                return "Goalong is asking the local Codex app-server for its account state."
            case .codexUnavailable:
                return "Install the official Codex CLI once. A future signed release can bundle the reviewed helper so normal users do not need a developer toolchain."
            case .signedOut:
                return "The browser flow uses your ChatGPT plan’s included Codex usage instead of an OpenAI API key."
            case .connected:
                return "Ready to launch ephemeral in-memory recap threads. They are not written to Codex conversation history."
            case .unsupportedCredentialMode(let mode):
                return "Codex currently reports “\(mode)”. Goalong refuses to run recaps with it so API-billed credentials are never used by surprise."
            case .failed(let message):
                return message
            }
        }

        private var connectionPill: String {
            switch recapRuntime.connectionState {
            case .checking: return "Checking"
            case .codexUnavailable: return "Codex required"
            case .signedOut: return "Not connected"
            case .connected(_, let plan): return plan.map { "ChatGPT \($0)" } ?? "Connected"
            case .unsupportedCredentialMode: return "Blocked"
            case .failed: return "Error"
            }
        }

        private var connectionSymbol: String {
            switch recapRuntime.connectionState {
            case .connected: return "checkmark.seal.fill"
            case .checking: return "arrow.triangle.2.circlepath"
            case .codexUnavailable: return "terminal.fill"
            case .signedOut: return "person.crop.circle.badge.plus"
            case .unsupportedCredentialMode: return "exclamationmark.shield.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        private var connectionTint: Color {
            switch recapRuntime.connectionState {
            case .connected: return LHTheme.success
            case .checking: return LHTheme.accent
            case .signedOut, .codexUnavailable: return LHTheme.warning
            case .unsupportedCredentialMode, .failed: return LHTheme.danger
            }
        }
    }
#endif
