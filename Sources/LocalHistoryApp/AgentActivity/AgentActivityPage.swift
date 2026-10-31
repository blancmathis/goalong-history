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

        /// The picker is hidden with fewer than two providers, and a filter outside the
        /// available providers must never show another provider's rows.
        static func effectiveProviderFilter(
            _ filter: AgentProvider?,
            availableProviders: [AgentProvider]
        ) -> AgentProvider? {
            guard let filter, availableProviders.count > 1, availableProviders.contains(filter)
            else { return nil }
            return filter
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

        /// The kit menu, same height and surface as the search field beside it.
        private var providerOptions: [(AgentProvider?, String)] {
            [(nil, "Tous les outils")] + availableProviders.map { (Optional($0), $0.frenchName) }
        }
        @State private var editingFolder: AgentWatchedFolder?
        private let presentation: AgentActivityPresentation
        private let onManageSources: (() -> Void)?
        /// The dashboard's day when this page is a dashboard route: the page follows it and writes back to it.
        private let dashboardDay: Date?
        private let onSelectDashboardDay: ((Date) -> Void)?

        init(
            agents: AgentActivityRuntime,
            presentation: AgentActivityPresentation = .management,
            onManageSources: (() -> Void)? = nil,
            dashboardDay: Date? = nil,
            onSelectDashboardDay: ((Date) -> Void)? = nil
        ) {
            self.agents = agents
            self.presentation = presentation
            self.onManageSources = onManageSources
            self.dashboardDay = dashboardDay
            self.onSelectDashboardDay = onSelectDashboardDay
        }

        private func selectDay(_ day: Date) {
            onSelectDashboardDay?(day)
            agents.selectDay(day)
        }

        private func followDashboardDay() {
            if let dashboardDay, agents.selectedDay != dashboardDay { agents.selectDay(dashboardDay) }
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
                        conversationHistoryList
                        // The token figures come after the list they describe, and not at all when no source is readable.
                        if !sourcesUnreadable {
                            AgentTokenUsageCard(usage: agents.tokenUsageSnapshot, scanning: agents.isScanning, analyzedAt: agents.tokenUsageAnalyzedAt)
                        }
                        GoalongDisclosureGroup("Source et confidentialité") {
                            sourceConsentCard.padding(.top, 12)
                        }
                        .font(.system(size: 12))
                    } else {
                        metrics
                        integrationCard
                        watchedFoldersCard
                        captureHistoryCard
                        storageAndPrivacyCard
                    }
                }
                // Sources is a settings page: reading width (DESIGN §7). The history list keeps the full width.
                .frame(maxWidth: presentation == .management ? LHTheme.readableWidth : .infinity, alignment: .leading)
                .padding(.horizontal, LHTheme.pageInset)
                .padding(.top, presentation == .management ? 28 : 18)
                .padding(.bottom, 50)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                followDashboardDay()
                if consents.isEnabled(.aiConversations) {
                    agents.scanNow(
                        forceFullDiscovery: false,
                        analyzeSelectedDay: true
                    )
                }
            }
            .onChange(of: dashboardDay) { _ in followDashboardDay() }
            .onChange(of: availableProviders) { providers in
                // Drop a stale provider filter (for example after a day change) so the picker,
                // the list and the empty state agree.
                if providerFilter != nil,
                    AgentConversationListPresentation.effectiveProviderFilter(
                        providerFilter, availableProviders: providers) == nil
                {
                    providerFilter = nil
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
                        DateSelectionControl(date: agents.selectedDay, onChange: selectDay)
                        Button {
                            agents.scanNow(
                                forceFullDiscovery: true,
                                analyzeSelectedDay: true
                            )
                        } label: {
                            Label(agents.isScanning ? "Analyse…" : "Analyser maintenant", systemImage: "arrow.clockwise")
                        }
                        // One lime action per page: here once a folder exists, in the folder empty state before.
                        .modifier(AgentHeaderActionStyle(primary: !agents.userWatchedFolders.isEmpty))
                        .disabled(agents.isScanning)
                    }
                }
            }
        }

        private var sourceConsentCard: some View {
            GoalongPlainBlock {
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
                            .foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        private var disabledSourceExplanation: some View {
            GoalongPlainBlock {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Aucune source n’est analysée", systemImage: "pause.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Les événements et preuves existants restent disponibles. Activez cette source seulement si vous voulez que Goalong lise Codex, Claude, OpenCode ou un dossier que vous ajoutez."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var sourceHealth: AgentConversationSourceHealth {
            AgentConversationSourceHealth(indexIsValid: agents.indexIsValid, scan: agents.lastScanResult)
        }

        private var hasSourceIssue: Bool { sourceHealth.hasReadFailure }

        /// No source could be read and nothing is listed: the page says it once, in the empty state.
        private var sourcesUnreadable: Bool {
            hasSourceIssue && agents.overview.captures.isEmpty && !agents.isScanning
        }

        private var conversationHistoryList: some View {
            let captures = filteredCaptures
            return VStack(alignment: .leading, spacing: 12) {
                if sourcesUnreadable {
                    unreadableSourcesState
                } else {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(GoalongUIFormat.count(agents.overview.captures.count, "conversation"))
                            .font(.system(size: 20, weight: .semibold))
                            HStack(spacing: 7) {
                                if agents.isScanning {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Mise à jour des sources modifiées…")
                                } else {
                                    Text(conversationSummaryDetail + ".")
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
                        }
                        Spacer()
                        if availableProviders.count > 1 {
                            GoalongMenuPicker("Outil", selection: $providerFilter, options: providerOptions)
                                .frame(width: 150)
                        }
                        GoalongSearchField("Rechercher dans les conversations", text: $search)
                            .frame(width: 280)
                    }

                    if sourceHealth != .ready {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: sourceHealth.symbol).foregroundStyle(LHTheme.warning)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sourceHealth.title).font(.system(size: 13, weight: .semibold))
                                Text(sourceHealth.message)
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let title = sourceHealth.actionTitle {
                                Button(title) { agents.scanNow(analyzeSelectedDay: true) }
                                    .buttonStyle(LHSecondaryButtonStyle()).disabled(agents.isScanning)
                            }
                            if let onManageSources {
                                Button("Vérifier les sources", action: onManageSources).buttonStyle(LHSecondaryButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("conversation-source-health")
                    }

                    if captures.isEmpty {
                        // An empty state sits on the page, not in a card (DESIGN §8).
                        VStack(spacing: 0) {
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
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        LHCard(padding: 0) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(captures.prefix(120).enumerated()), id: \.element.id) { index, record in
                                        conversationRow(record)
                                        if index < min(captures.count, 120) - 1 {
                                            Divider().padding(.leading, 66)
                                        }
                                    }
                                    if captures.count > 120 {
                                        Text("Affichage des 120 conversations les plus récentes")
                                            .font(.system(size: 12))
                                            .foregroundStyle(LHTheme.secondaryText)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                    }
                            }
                        }
                    }
                }
            }
        }

        /// One message for one problem: what failed, what to do (no count, no token line, no card).
        private var unreadableSourcesState: some View {
            VStack(spacing: 16) {
                EmptyStateView(
                    symbol: sourceHealth.symbol,
                    title: sourceHealth.title,
                    message: sourceHealth.message
                )
                HStack(spacing: 10) {
                    if let onManageSources {
                        Button("Vérifier les sources", action: onManageSources)
                            .buttonStyle(LHSecondaryButtonStyle())
                    }
                    if let title = sourceHealth.actionTitle {
                        Button(title) { agents.scanNow(analyzeSelectedDay: true) }
                            .buttonStyle(LHSecondaryButtonStyle())
                            .disabled(agents.isScanning)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .accessibilityIdentifier("conversation-source-health")
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
                        Text(GoalongUIFormat.time(AgentConversationListPresentation.date(for: record)) + ",")
                            .monospacedDigit()
                        Text(conversationDetail(record))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                    .lineLimit(1)
                }

                Spacer(minLength: 16)

                if record.availability != .available {
                    Label(record.availability.frenchName, systemImage: statusSymbol(record.availability))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                } else if !record.projectionIsComplete {
                    Label("Journée partielle", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                        .help("Ce jour dépasse la limite de lecture directe ; les messages les plus anciens peuvent manquer.")
                }

                Menu {
                    Button("Afficher la source d’origine") { agents.openOriginal(record) }
                    Button("Vérifier que la source est intacte") { agents.verify(record) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(LHTheme.secondaryText)
                .foregroundStyle(LHTheme.secondaryText)
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
            return parts.joined(separator: ", ")
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
                "\(record.provider.frenchName), \(counts.prompts) demande\(counts.prompts > 1 ? "s" : ""), \(counts.replies) réponse\(counts.replies > 1 ? "s" : "")"
        }

        /// One hero figure (conversations followed that day); the other counts are one sentence below it,
        /// the source state is one pill, and the technical detail waits in « En savoir plus » (DESIGN §6).
        private var metrics: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(GoalongUIFormat.number(agents.overview.captures.count))
                        .font(LHTheme.heroFont)
                        .tracking(-1.8)
                    Text(agents.overview.captures.count > 1 ? "conversations suivies" : "conversation suivie")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 18)
                    if agents.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    StatusPill(
                        title: agents.indexIsValid ? "Sources lisibles" : "Sources à vérifier",
                        symbol: agents.indexIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        tint: agents.indexIsValid ? LHTheme.success : LHTheme.danger
                    )
                }
                .accessibilityElement(children: .combine)
                Text(metricsDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if agents.overview.errorCount > 0 {
                    Text(GoalongUIFormat.count(Int(agents.overview.errorCount), "action en erreur", plural: "actions en erreur") + ".")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.warning)
                }
                if agents.lastScanResult.capacityLimitedFolderCount > 0 {
                    Text(
                        "Une source est trop grande pour l’index : Goalong garde ses informations les plus récentes et ne la relit pas en boucle."
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LHTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                GoalongDisclosureGroup("En savoir plus") {
                    Text(
                        "Goalong lit Codex, Claude Code, OpenCode et les dossiers que vous ajoutez, là où ils sont, sans copier les conversations. Pour chacune, il garde une courte fiche : l’outil, l’identifiant, l’emplacement, les heures, la taille et une empreinte SHA-256 qui montre si le fichier a changé. Index local : \(formatBytes(agents.overview.indexBytes))."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// « Le 23 octobre 2026 : 12 sessions, 340 messages et 85 actions des agents. »
        private var metricsDetail: String {
            let day = DashboardFormatters.dayTitle.string(from: agents.selectedDay)
            let sessions = GoalongUIFormat.count(Int(agents.overview.sessionCount), "session")
            let messages = GoalongUIFormat.count(Int(agents.overview.messageCount), "message")
            let actions = GoalongUIFormat.count(Int(agents.overview.toolCallCount), "action des agents", plural: "actions des agents")
            return "\(day) : \(sessions), \(messages) et \(actions)."
        }

        private var integrationCard: some View {
            GoalongPlainBlock {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top) {
                        sectionHeader(
                            symbol: "point.3.connected.trianglepath.dotted",
                            tint: LHTheme.secondaryText,
                            title: "Détection immédiate (facultatif)",
                            subtitle:
                                "Sans elle, Goalong regarde vos dossiers de temps en temps. Avec elle, l’outil prévient Goalong dès qu’une conversation change, sans lui envoyer son contenu."
                        )
                        Spacer()
                        Button("Afficher le dossier") {
                            agents.openSignalsFolder()
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                    }

                    providerDirectoryRow
                    ForEach(AgentIntegrationKind.allCases) { kind in
                        Divider()
                        integrationRow(kind)
                    }
                    GoalongDisclosureGroup("En savoir plus") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex est lu dans ~/.codex. La détection immédiate modifie seulement ces fichiers de réglages :")
                            ForEach(AgentIntegrationKind.allCases) { kind in
                                Text("\(kind.frenchName) : \(configurationPathLabel(agents.status(for: kind).configurationPath))")
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    }
                    .font(.system(size: 12))
                }
            }
        }

        private var providerDirectoryRow: some View {
            HStack(spacing: 12) {
                providerIcon(.codex)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Historique local de Codex")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Goalong suit les sessions et l’historique de Codex quand Codex est installé sur ce Mac."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
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

        private func configurationPathLabel(_ path: String) -> String {
            AgentActivityPathLabel.abbreviated(path)
        }

        private func integrationRow(_ kind: AgentIntegrationKind) -> some View {
            let status = agents.status(for: kind)
            return HStack(spacing: 12) {
                providerIcon(kind.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.frenchName)
                        .font(.system(size: 12, weight: .semibold))
                    // The file path is developer detail: on hover, and listed in « En savoir plus » below.
                    Text(status.isInstalled ? "Prévient Goalong dès qu’une conversation change." : "Goalong regarde les dossiers de temps en temps.")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(1)
                        .help(configurationPathLabel(status.configurationPath))
                    if let otherPath = status.otherExecutablePath {
                        Text(
                            status.otherExecutableExists
                                ? "Installé pour une autre copie : \(otherPath)"
                                : "Cassé : copie introuvable (\(otherPath))"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(status.otherExecutableExists ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    }
                }
                Spacer()
                StatusPill(
                    title: status.isInstalled
                        ? "Détection immédiate"
                        : (status.otherExecutablePath != nil
                            ? (status.otherExecutableExists ? "Installé pour une autre copie" : "Intégration cassée")
                            : "Non installée"),
                    symbol: status.isInstalled ? "bolt.shield.fill" : "bolt.slash",
                    tint: status.isInstalled ? LHTheme.success : Color.secondary
                )
                if status.isInstalled {
                    Button("Retirer") {
                        agents.uninstallIntegration(kind)
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                } else if status.otherExecutablePath != nil {
                    Button("Retirer") {
                        agents.uninstallIntegration(kind)
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                    Button("Réinstaller pour cette copie") {
                        agents.installIntegration(kind)
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                } else {
                    Button("Installer") {
                        agents.installIntegration(kind)
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                }
            }
            // Goalong Dev: the hooks are shared with the installed Goalong (read-only here).
            .disabled(!agents.allowsHookChanges)
        }

        private var watchedFoldersCard: some View {
            GoalongPlainBlock {
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
                        // With no folder yet, the empty state below carries the one primary action.
                        // The page header carries the one primary action; the empty state below has its own.
                        Button { agents.chooseFolder() } label: { Label("Ajouter un dossier", systemImage: "plus") }
                            .buttonStyle(LHSecondaryButtonStyle())
                    }

                    if agents.userWatchedFolders.isEmpty {
                        EmptyStateView(
                            symbol: "folder.badge.plus",
                            title: "Aucun dossier suivi pour l’instant",
                            message:
                                "Choisissez un dossier contenant des conversations locales. La lecture ne commence qu’une fois la source activée.",
                            // Source off: no lime action that cannot read anything yet.
                            buttonTitle: consents.isEnabled(.aiConversations) ? "Choisir un dossier" : nil,
                            action: consents.isEnabled(.aiConversations) ? agents.chooseFolder : nil
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
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(folder.captureMode.frenchName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LHTheme.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                    }
                    Text(folder.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LHTheme.secondaryText)
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
                .accessibilityLabel("Ouvrir le dossier \(folder.displayName)")
                Button {
                    editingFolder = folder
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .help("Modifier le suivi")
                .accessibilityLabel("Modifier le suivi de \(folder.displayName)")
                Button(role: .destructive) {
                    agents.removeFolder(id: folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .help("Arrêter de suivre ce dossier")
                .accessibilityLabel("Arrêter de suivre \(folder.displayName)")
            }
            .padding(.vertical, 4)
        }

        private var captureHistoryCard: some View {
            GoalongPlainBlock {
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
                        if availableProviders.count > 1 {
                            GoalongMenuPicker("Outil", selection: $providerFilter, options: providerOptions)
                                .frame(width: 165)
                        }
                        GoalongSearchField("Rechercher sessions, fichiers, modèles ou outils", text: $search)
                            .frame(width: 285)
                    }

                    if filteredCaptures.isEmpty {
                        EmptyStateView(
                            symbol: agents.isScanning ? "arrow.triangle.2.circlepath" : "cpu",
                            title: agents.isScanning ? "Vérification des sources" : "Aucune source indexée correspondante",
                            message: agents.isScanning
                                ? "Les sources connues sont vérifiées progressivement ; les originaux modifiés sont relus sur place."
                                : "Lancez un agent, activez la détection immédiate ou ajoutez son dossier d’historique."
                        )
                        .frame(minHeight: 210)
                    } else {
                        ForEach(Array(filteredCaptures.prefix(120).enumerated()), id: \.element.id) { index, record in
                            captureRow(record)
                            if index < min(filteredCaptures.count, 120) - 1 { Divider() }
                        }
                        if filteredCaptures.count > 120 {
                            Text("Affichage des 120 références les plus récentes.")
                                .font(.system(size: 12))
                                .foregroundStyle(LHTheme.secondaryText)
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
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(record.provider.frenchName), \(record.watchedFolderName), \(record.relativePath)")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let excerpt = record.summary.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(DashboardFormatters.fullTimestamp.string(from: record.sourceModifiedAt ?? record.capturedAt))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText)
                    HStack(spacing: 5) {
                        compactPill("\(record.summary.messageCount) msg", symbol: "bubble.left")
                        compactPill(GoalongUIFormat.count(record.summary.toolCallCount, "outil"), symbol: "wrench")
                        compactPill(record.availability.frenchName, symbol: statusSymbol(record.availability))
                        compactPill(formatBytes(record.byteCount), symbol: "doc")
                    }
                }
                Menu {
                    Button("Afficher la source d’origine") { agents.openOriginal(record) }
                    Divider()
                    Button("Vérifier que la source est intacte") { agents.verify(record) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(LHTheme.secondaryText)
                .foregroundStyle(LHTheme.secondaryText)
                .frame(width: 30)
                .accessibilityLabel("Plus d’actions")
                .help("Afficher la source ou vérifier l’empreinte")
            }
            .padding(.vertical, 5)
        }

        private var storageAndPrivacyCard: some View {
            HStack(alignment: .top, spacing: 14) {
                GoalongPlainBlock {
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
                        detailLine("Taille des sources de la journée", value: formatBytes(agents.overview.sourceBytes))
                        detailLine("Structure de l’index", value: agents.indexIsValid ? "Valide" : "Invalide")
                        Button("Ouvrir le dossier de l’index") {
                            agents.openRootFolder()
                        }
                        .buttonStyle(LHSecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)

                GoalongPlainBlock {
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
                        privacyBullet("La détection immédiate ne transmet qu’un signal, jamais le contenu.")
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
            let effectiveProviderFilter = AgentConversationListPresentation.effectiveProviderFilter(
                providerFilter,
                availableProviders: availableProviders
            )
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
                .foregroundStyle(LHTheme.secondaryText)
                .frame(width: 34, height: 34)
        }

        private func compactPill(_ title: String, symbol: String) -> some View {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LHTheme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.045), in: Capsule())
        }

        private func detailLine(_ title: String, value: String) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
            }
        }

        private func privacyBullet(_ text: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LHTheme.success)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func sectionHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
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

        private func formatBytes(_ bytes: Int64) -> String {
            DashboardFormatters.byteCount.string(fromByteCount: bytes)
        }
    }

    private struct AgentHeaderActionStyle: ViewModifier {
        let primary: Bool

        @ViewBuilder func body(content: Content) -> some View {
            if primary {
                content.buttonStyle(LHPrimaryButtonStyle())
            } else {
                content.buttonStyle(LHSecondaryButtonStyle())
            }
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
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LHTheme.secondaryText)
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
                .font(.system(size: 12))
                .foregroundStyle(LHTheme.secondaryText)
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
