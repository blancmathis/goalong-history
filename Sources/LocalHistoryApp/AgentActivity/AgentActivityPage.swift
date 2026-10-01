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
        private let onManageSources: (() -> Void)?

        init(
            agents: AgentActivityRuntime,
            presentation: AgentActivityPresentation = .management,
            onManageSources: (() -> Void)? = nil
        ) {
            self.agents = agents
            self.presentation = presentation
            self.onManageSources = onManageSources
        }

        var body: some View {
            SourceAccessGate(capability: .aiConversations) { pageBody }
        }

        private var pageBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if presentation == .management {
                        managementHeader
                    }
                    if presentation == .management || !consents.isEnabled(.aiConversations) {
                        sourceConsentCard
                    }
                    if !consents.isEnabled(.aiConversations) {
                        disabledSourceExplanation
                        if presentation == .management { watchedFoldersCard }
                    } else if presentation == .history {
                        AgentTokenUsageCard(usage: agents.tokenUsageSnapshot ?? AgentDailyTokenUsage(records: [], day: agents.selectedDay), scanning: agents.isScanning, analyzedAt: agents.tokenUsageAnalyzedAt)
                        conversationHistoryList
                        GoalongDisclosureGroup("Source et confidentialité") {
                            sourceConsentCard.padding(.top, 12)
                        }
                        .font(.system(size: 12))
                    } else {
                        localStatusBanner
                        metrics
                        integrationCard
                        watchedFoldersCard
                        captureHistoryCard
                        storageAndPrivacyCard
                    }
                }
                .padding(.horizontal, LHTheme.pageInset)
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
                .goalongControls()
            }
        }

        private var managementHeader: some View {
            PageHeader(
                title: "Sources des conversations IA",
                subtitle:
                    "Choisissez les sources locales que Goalong peut lire. Le contenu des conversations n’est jamais copié dans Goalong."
            ) {
                if consents.isEnabled(.aiConversations) {
                    HStack(spacing: 9) {
                        DateSelectionControl(date: agents.selectedDay, onChange: agents.selectDay)
                        Button {
                            agents.scanNow(
                                forceFullDiscovery: true,
                                analyzeSelectedDay: true
                            )
                        } label: {
                            Label(agents.isScanning ? "Analyse…" : "Analyser maintenant", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .disabled(agents.isScanning)

                        Button {
                            agents.chooseFolder()
                        } label: {
                            Label("Ajouter un dossier", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                    }
                }
            }
        }

        private var sourceConsentCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText)
                        .frame(width: 22).accessibilityHidden(true)
                    SourceActivationToggle(capability: .aiConversations) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(consents.isEnabled(.aiConversations) ? "Lecture des conversations locales activée" : "Lecture des conversations locales désactivée")
                                .font(.system(size: 13, weight: .semibold))
                            Text(
                                "Goalong lit seulement les sources que vous autorisez, à leur emplacement d’origine. Il garde un index léger de métadonnées et ne copie jamais le contenu des conversations."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        private var disabledSourceExplanation: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Aucune source n’est analysée", systemImage: "pause.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Les événements et preuves existants restent disponibles. Activez cette source seulement si vous voulez que Goalong lise Codex, Claude, OpenCode ou un dossier que vous ajoutez."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var sourceHealth: AgentConversationSourceHealth {
            AgentConversationSourceHealth(indexIsValid: agents.indexIsValid, scan: agents.lastScanResult)
        }

        private var hasSourceIssue: Bool { sourceHealth.hasReadFailure }

        private var conversationHistoryList: some View {
            let captures = filteredCaptures
            return VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            "\(agents.overview.captures.count) conversation\(agents.overview.captures.count == 1 ? "" : "s")"
                        )
                        .font(.system(size: 20, weight: .semibold))
                        HStack(spacing: 7) {
                            Text(conversationSummaryDetail)
                            Text("·")
                            if agents.isScanning {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Mise à jour des sources modifiées…")
                            } else {
                                Label("Sources d’origine", systemImage: "internaldrive")
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availableProviders.count > 1 {
                        Picker("Outil", selection: $providerFilter) {
                            Text("Tous les outils").tag(nil as AgentProvider?)
                            ForEach(availableProviders) { provider in
                                Text(provider.frenchName).tag(provider as AgentProvider?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    GoalongSearchField("Rechercher dans les conversations", text: $search)
                        .frame(width: 240)
                }

                if sourceHealth != .ready {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: sourceHealth.symbol).foregroundStyle(LHTheme.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceHealth.title).font(.system(size: 13, weight: .semibold))
                            Text(sourceHealth.message)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let title = sourceHealth.actionTitle {
                            Button(title) { agents.scanNow(analyzeSelectedDay: true) }.disabled(agents.isScanning)
                        }
                        if let onManageSources { Button("Vérifier les sources", action: onManageSources) }
                    }.padding(14)
                    .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("conversation-source-health")
                }

                LHCard(padding: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if captures.isEmpty {
                            EmptyStateView(
                                symbol: agents.isScanning
                                    ? "arrow.triangle.2.circlepath" : "bubble.left.and.bubble.right",
                                title: agents.isScanning ? "Lecture des conversations"
                                    : (!search.isEmpty || providerFilter != nil) ? "Aucune conversation correspondante"
                                    : hasSourceIssue ? "Conversations indisponibles" : "Aucune conversation ce jour-là",
                                message: agents.isScanning
                                    ? "Goalong vérifie les sources modifiées."
                                    : (!search.isEmpty || providerFilter != nil)
                                        ? "Effacez la recherche ou choisissez un autre outil."
                                        : hasSourceIssue ? "Vérifiez l’état des sources ci-dessus pour rétablir l’accès." : "Essayez un autre jour ou vérifiez vos dossiers de conversations."
                            )
                            .frame(minHeight: 190)
                            if search.isEmpty, providerFilter == nil, !hasSourceIssue, let onManageSources {
                                Button("Vérifier les sources", action: onManageSources)
                                    .buttonStyle(LHSecondaryButtonStyle()).frame(maxWidth: .infinity).padding(.bottom, 20)
                            }
                            if !search.isEmpty || providerFilter != nil {
                                Button("Effacer les filtres") { search = ""; providerFilter = nil }
                                    .buttonStyle(LHSecondaryButtonStyle())
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, 20)
                            }
                        } else {
                            ForEach(Array(captures.prefix(120).enumerated()), id: \.element.id) { index, record in
                                conversationRow(record)
                                if index < min(captures.count, 120) - 1 {
                                    Divider().padding(.leading, 66)
                                }
                            }
                            if captures.count > 120 {
                                Text("Affichage des 120 conversations les plus récentes")
                                    .font(.system(size: 12))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 16)

                if record.availability != .available {
                    Label(record.availability.frenchName, systemImage: statusSymbol(record.availability))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                } else if !record.projectionIsComplete {
                    Label("Journée partielle", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                        .help("Ce jour dépasse la limite de lecture directe ; les messages les plus anciens peuvent manquer.")
                }

                Menu {
                    Button("Afficher la source d’origine") { agents.openOriginal(record) }
                    Button("Vérifier l’empreinte SHA-256") { agents.verify(record) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("Actions sur la conversation")
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
                "\(prompts) demande\(prompts > 1 ? "s" : "")",
                "\(replies) réponse\(replies > 1 ? "s" : "") finale\(replies > 1 ? "s" : "")",
            ]
            parts.append(contentsOf: availableProviders.map(\.frenchName))
            return parts.joined(separator: " · ")
        }

        private func conversationTitle(_ record: AgentCaptureRecord) -> String {
            let title = record.summary.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Conversation \(record.provider.frenchName)" : title
        }

        private func conversationDetail(_ record: AgentCaptureRecord) -> String {
            guard record.availability == .available else {
                return record.provider.frenchName
            }
            let counts = AgentConversationListPresentation.visibleMessageCounts(for: record)
            guard counts.prompts + counts.replies > 0 else {
                return record.provider.frenchName
            }
            return
                "\(record.provider.frenchName) · \(counts.prompts) demande\(counts.prompts > 1 ? "s" : "") · \(counts.replies) réponse\(counts.replies > 1 ? "s" : "")"
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
                    Text("Lecture directe des sources")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Le contenu des conversations est lu sur place dans Codex, Claude Code, OpenCode et les dossiers configurés. L’index local ne contient que l’outil, l’identifiant, la référence de la source, les horodatages, la taille, les positions et l’empreinte SHA-256."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Goalong ne conserve aucune copie, aucun instantané ni contenu transmis par les hooks."
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LHTheme.privateTint)
                    if agents.lastScanResult.capacityLimitedFolderCount > 0 {
                        Text(
                            "Une source dépasse la taille maximale de l’index léger : Goalong garde ses métadonnées les plus récentes, sans relancer de lecture en boucle."
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LHTheme.warning)
                    }
                }
                Spacer(minLength: 18)
                if agents.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                StatusPill(
                    title: agents.indexIsValid ? "Index léger valide" : "Index à vérifier",
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
                    title: "Sessions d’agents",
                    value: String(agents.overview.sessionCount),
                    detail: DashboardFormatters.dayTitle.string(from: agents.selectedDay),
                    symbol: "cpu",
                    tint: LHTheme.accent
                )
                MetricCard(
                    title: "Messages",
                    value: String(agents.overview.messageCount),
                    detail: "Messages utilisateur, assistant et système",
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: LHTheme.teal
                )
                MetricCard(
                    title: "Appels d’outils",
                    value: String(agents.overview.toolCallCount),
                    detail: agents.overview.errorCount == 0
                        ? "Aucun message d’erreur observé"
                        : "\(agents.overview.errorCount) message\(agents.overview.errorCount > 1 ? "s" : "") d’erreur observé\(agents.overview.errorCount > 1 ? "s" : "")",
                    symbol: "wrench.and.screwdriver.fill",
                    tint: agents.overview.errorCount == 0 ? LHTheme.success : LHTheme.warning
                )
                MetricCard(
                    title: "Sources indexées",
                    value: String(agents.overview.captures.count),
                    detail: "Index : " + formatBytes(agents.overview.indexBytes),
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
                            title: "Signaux de relance des agents",
                            subtitle:
                                "Les hooks facultatifs ne font que relancer la détection. Leur contenu est ignoré et jamais ajouté à l’index."
                        )
                        Spacer()
                        Button("Ouvrir les signaux de relance") {
                            agents.openSignalsFolder()
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
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
                    Text("Historique local de Codex")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        "Goalong suit les sessions, l’historique et les journaux de Codex dans `~/.codex` lorsque ce dossier existe."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
                        ? "Dossier actif"
                        : agents.configuration.watchedFolders.contains(where: {
                            $0.provider == .codex && !$0.isManaged
                        }) ? "Détecté — désactivé" : "Non détecté",
                    symbol: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
                        ? "checkmark.circle.fill" : "folder.badge.questionmark",
                    tint: agents.configuration.watchedFolders.contains(where: {
                        $0.provider == .codex && !$0.isManaged && $0.isEnabled
                    })
                        ? LHTheme.success : Color.secondary
                )
                Button("Détecter") {
                    agents.detectCommonSources()
                }
                .buttonStyle(LHSecondaryButtonStyle())
            }
        }

        private func integrationRow(_ kind: AgentIntegrationKind) -> some View {
            let status = agents.status(for: kind)
            return HStack(spacing: 12) {
                providerIcon(kind.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.frenchName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(status.configurationPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                StatusPill(
                    title: status.isInstalled ? "Signal de relance installé" : "Détection périodique",
                    symbol: status.isInstalled ? "bolt.shield.fill" : "bolt.slash",
                    tint: status.isInstalled ? LHTheme.success : Color.secondary
                )
                if status.isInstalled {
                    Button("Retirer") {
                        agents.uninstallIntegration(kind)
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                } else {
                    Button("Installer") {
                        agents.installIntegration(kind)
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
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
                            title: "Dossiers de conversations",
                            subtitle:
                                "Une source arrêtée le reste après un redémarrage ; ajoutez-la de nouveau pour l’autoriser. Goalong ne conserve que des références légères."
                        )
                        Spacer()
                        Button("Détecter les dossiers courants") {
                            agents.detectCommonSources()
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .disabled(!consents.isEnabled(.aiConversations))
                        Button {
                            agents.chooseFolder()
                        } label: {
                            Label("Ajouter un dossier", systemImage: "plus")
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                    }

                    if agents.userWatchedFolders.isEmpty {
                        EmptyStateView(
                            symbol: "folder.badge.plus",
                            title: "Aucun dossier suivi pour l’instant",
                            message:
                                "Choisissez un dossier contenant des conversations locales. La lecture ne commence qu’une fois la source activée.",
                            buttonTitle: "Choisir un dossier",
                            action: agents.chooseFolder
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
                        Text(folder.captureMode.frenchName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(providerTint(folder.provider))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(providerTint(folder.provider).opacity(0.10), in: Capsule())
                    }
                    Text(folder.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 14)
                Toggle(
                    "Suivre ce dossier",
                    isOn: Binding(
                        get: { folder.isEnabled },
                        set: { agents.setFolderEnabled($0, id: folder.id) }
                    )
                )
                .toggleStyle(.goalongSwitchInline)
                .controlSize(.small)
                .labelsHidden()
                Button {
                    agents.openFolder(folder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .help("Ouvrir le dossier source")
                Button {
                    editingFolder = folder
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .help("Modifier le suivi")
                Button(role: .destructive) {
                    agents.removeFolder(id: folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .help("Arrêter de suivre ce dossier")
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
                            title: "Conversations d’origine indexées",
                            subtitle:
                                "Une entrée d’index par conversation. L’ouvrir ou l’analyser lit directement la source d’origine."
                        )
                        Spacer()
                        Picker("Outil", selection: $providerFilter) {
                            Text("Tous les outils").tag(nil as AgentProvider?)
                            ForEach(AgentProvider.allCases) { provider in
                                Text(provider.frenchName).tag(provider as AgentProvider?)
                            }
                        }
                        .frame(width: 165)
                        GoalongSearchField("Rechercher sessions, fichiers, modèles ou outils", text: $search)
                            .frame(width: 285)
                    }

                    if filteredCaptures.isEmpty {
                        EmptyStateView(
                            symbol: agents.isScanning ? "arrow.triangle.2.circlepath" : "cpu",
                            title: agents.isScanning ? "Vérification des sources" : "Aucune source indexée correspondante",
                            message: agents.isScanning
                                ? "Les sources connues sont vérifiées progressivement ; les originaux modifiés sont relus sur place."
                                : "Lancez un agent, installez un signal de relance facultatif ou ajoutez son dossier d’historique."
                        )
                        .frame(minHeight: 210)
                    } else {
                        ForEach(Array(filteredCaptures.prefix(120).enumerated()), id: \.element.id) { index, record in
                            captureRow(record)
                            if index < min(filteredCaptures.count, 120) - 1 { Divider() }
                        }
                        if filteredCaptures.count > 120 {
                            Text("Affichage des 120 références les plus récentes.")
                                .font(.system(size: 11))
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
                    Text("\(record.provider.frenchName) · \(record.watchedFolderName) · \(record.relativePath)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let excerpt = record.summary.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(DashboardFormatters.fullTimestamp.string(from: record.sourceModifiedAt ?? record.capturedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        compactPill("\(record.summary.messageCount) msg", symbol: "bubble.left")
                        compactPill("\(record.summary.toolCallCount) outils", symbol: "wrench")
                        compactPill(record.availability.frenchName, symbol: statusSymbol(record.availability))
                        compactPill(formatBytes(record.byteCount), symbol: "doc")
                    }
                }
                Menu {
                    Button("Afficher la source d’origine") { agents.openOriginal(record) }
                    Divider()
                    Button("Vérifier l’empreinte SHA-256") { agents.verify(record) }
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
                            title: "Index léger des sources",
                            subtitle:
                                "Seules des métadonnées limitées sont conservées dans le dossier privé de Goalong History."
                        )
                        detailLine("Espace total utilisé", value: formatBytes(agents.storageBytes))
                        detailLine("Fichier d’index", value: formatBytes(agents.overview.indexBytes))
                        detailLine("Octets d’origine lus aujourd’hui", value: formatBytes(agents.overview.sourceBytes))
                        detailLine("Structure de l’index", value: agents.indexIsValid ? "Valide" : "Invalide")
                        Button("Ouvrir le dossier de l’index") {
                            agents.openRootFolder()
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)

                LHCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(
                            symbol: "checkmark.shield.fill",
                            tint: LHTheme.privateTint,
                            title: "Ce que Goalong ajoute",
                            subtitle:
                                "Une analyse indépendante de l’outil, sans créer une copie de plus des conversations."
                        )
                        privacyBullet("Le contenu des conversations reste uniquement dans le stockage d’origine de chaque outil.")
                        privacyBullet("Une source modifiée remplace son empreinte précédente au lieu de créer une version.")
                        privacyBullet("Les originaux absents ou illisibles restent signalés comme tels dans l’index.")
                        privacyBullet("Les hooks réécrivent un petit signal par outil et ignorent leur contenu.")
                        privacyBullet(
                            "La recherche complète des sources est périodique ; les vérifications courantes utilisent l’index connu."
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.045), in: Capsule())
        }

        private func detailLine(_ title: String, value: String) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
            }
        }

        private func privacyBullet(_ text: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LHTheme.success)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 11))
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
                        .font(.system(size: 11))
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
                    Text("Modifier le dossier suivi")
                        .font(.system(size: 20, weight: .bold))
                    Text(draft.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Form {
                    TextField("Nom affiché", text: $draft.displayName)
                    Picker("Outil", selection: $draft.provider) {
                        ForEach(AgentProvider.allCases) { provider in
                            Text(provider.frenchName).tag(provider)
                        }
                    }
                    Picker("Lecture", selection: $draft.captureMode) {
                        ForEach(AgentCaptureMode.allCases) { mode in
                            Text(mode.frenchName).tag(mode)
                        }
                    }
                    Toggle("Suivre ce dossier", isOn: $draft.isEnabled)
                    Toggle("Inclure les sous-dossiers", isOn: $draft.includeSubdirectories)
                }
                .formStyle(.grouped)

                Text(
                    draft.captureMode == .everyFile
                        ? "Chaque fichier pris en charge est indexé sur place, sauf les coffres d’identifiants, cookies, clés privées et caches."
                        : "Goalong lit directement les formats courants de conversations, journaux et traces, sans les copier."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Annuler", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Enregistrer") {
                        onSave(draft)
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 560, height: 410)
        }
    }
#endif
