#if os(macOS)
import Foundation
import LocalHistoryCore
import AppleScreenTime
import AgentActivity

extension ChatGPTRecapContextBuilder {
    static func buildGranular(day: Date, deviceID: String, includeScreenTime: Bool,
                              includeAgentActivity: Bool, selection: GoalongAnalysisSelection) throws -> ChatGPTRecapContext {
        let root = AppPaths.applicationSupportDirectory
        let pause = try GoalongGlobalPause.admit(in: root)
        let privacy = GoalongPrivacyPolicy.load(in: root)
        guard let scope = selection.scope, selection.isValid(for: privacy) else {
            throw CodexAppServerError.generationFailed("Vérifiez les données autorisées pour ChatGPT.")
        }
        try scope.validate()
        let consents = GoalongCapabilityConsentStore.shared
        var events: [HistoryEvent] = [], snapshots: [String: SemanticContextPayload] = [:]
        if selection.computer && consents.isEnabled(.localComputerHistory),
           let interval = Calendar.current.dateInterval(of: .day, for: day) {
            let evidence = HistoryLocalStoreReader(rootDirectory: root).loadComputerHistoryEvidence(
                start: interval.start, endExclusive: interval.end,
                includeSemanticText: scope.hasEventDetails,
                shouldContinue: { !GoalongGlobalPause.isPaused(in: root) && !Task.isCancelled })
            guard !evidence.metrics.sourceAccessWasIncomplete, !evidence.metrics.evidenceBudgetExceeded,
                  !evidence.metrics.wasCancelled, !evidence.metrics.sourceChangedDuringRead else {
                throw CodexAppServerError.generationFailed("La lecture locale est incomplète. Réessayez avant l’envoi.")
            }
            events = evidence.events; snapshots = evidence.semanticSnapshots
        }
        let apple = selection.screenTime && includeScreenTime && consents.isEnabled(.appleScreenTime)
            ? loadScreenTime(for: day, deviceID: deviceID) : nil
        let agents = selection.conversations && includeAgentActivity && consents.isEnabled(.aiConversations)
            ? loadAgentActivity(for: day, analyzeContent: scope.hasConversationText,
                                allowedFolderIDs: scope.conversationFolderIDs)
            : AgentActivityOverview(day: day)
        try Task.checkCancellation()
        try GoalongGlobalPause.revalidate(pause, in: root)
        guard GoalongPrivacyPolicy.load(in: root).revision == privacy.revision else {
            throw CodexAppServerError.generationFailed("Les exclusions ont changé pendant la préparation.")
        }
        return try granularContext(day: day, events: events, snapshots: snapshots,
                                   screenTime: apple, agents: agents, selection: selection, privacy: privacy)
    }

    /// Build every outgoing field explicitly. No cached narrative or raw metadata is
    /// reused because it could describe an application or field the user excluded.
    static func granularContext(day: Date, events: [HistoryEvent], snapshots: [String: SemanticContextPayload],
                                screenTime: AppleScreenTimeDaySummary?, agents: AgentActivityOverview,
                                selection: GoalongAnalysisSelection, privacy: GoalongPrivacyPolicy) throws -> ChatGPTRecapContext {
        guard let scope = selection.scope else { throw CodexAppServerError.generationFailed("Sélection détaillée manquante.") }
        let transformer = try GoalongTextTransformer(selection.replacements ?? [])
        // Transform before truncation: a sensitive name crossing a field limit must
        // not be transmitted as an unmatched prefix. Each value is transformed once.
        func text(_ value: String, limit: Int = 16_000) throws -> String {
            let transformed = try transformer.apply(value, maximumCharacters: 170_000)
            return String((ActivitySemanticTextSanitizer.redact(transformed) ?? "").prefix(limit))
        }
        let browsers = Set(RecorderConfig.default.browserBundleIdentifiers.map { $0.lowercased() })
        func allowed(_ event: HistoryEvent) -> Bool {
            guard selection.computer, event.suppressionReason == nil, event.element?.isSecure != true,
                  let app = event.app, scope.allows(id: app.bundleIdentifier, name: app.name),
                  privacy.permits(event), scope.allows(domain: event.url?.host) else { return false }
            if !privacy.domains.isEmpty || !scope.excludedDomains.isEmpty {
                if browsers.contains(app.bundleIdentifier?.lowercased() ?? ""), event.url?.host == nil { return false }
            }
            return true
        }
        let filtered = events.map { event in
            allowed(event) ? event : HistoryEvent(sessionID: event.sessionID, timestamp: event.timestamp,
                kind: .heartbeat, suppressionReason: .excludedApplication)
        }
        let activity = ActivityAnalysisEngine.analyze(events: filtered, day: day)
        let usage = activity.applications.filter { scope.allows(id: $0.bundleIdentifier, name: $0.name) && !privacy.excludes(appID: $0.bundleIdentifier, name: $0.name) }
        var document: [String: Any] = [
            "date": ActivityAnalysisPaths.dayString(day),
            "lecture": "Les sources absentes ou exclues sont des lacunes, pas de l’inactivité. Les durées de plusieurs sources peuvent se chevaucher."
        ]
        if selection.computer {
            document["applications_sur_ce_Mac"] = try usage.map { ["application": try text($0.name, limit: 512), "secondes_actives": $0.activeSeconds] as [String: Any] }
        }
        var details: [[String: Any]] = [], detailKeys = Set<String>(), detailCharacters = 0
        var omitted = 0, semanticCount = 0
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "HH:mm:ss"
        for event in events where allowed(event) {
            guard let app = event.app else { continue }
            func includes(_ field: GoalongAnalysisField) -> Bool { scope.allows(field, id: app.bundleIdentifier, name: app.name) }
            var row: [String: Any] = ["application": try text(app.name, limit: 512)]
            if includes(.windowTitles), let title = event.window?.title, !title.isEmpty { row["titre"] = try text(title, limit: 1600) }
            if includes(.fullURLs), let address = event.url?.value { row["adresse"] = try text(address, limit: 2000) }
            else if includes(.websiteDomains), let domain = event.url?.host { row["site"] = try text(domain, limit: 512) }
            if includes(.interfaceLabels) {
                if let label = event.element?.label ?? event.element?.title, !label.isEmpty { row["libelle"] = try text(label, limit: 600) }
            }
            let sameSnapshotSource: Bool
            if let reference = event.semanticContext, let payload = snapshots[reference.snapshotID] {
                sameSnapshotSource = payload.application.bundleIdentifier == app.bundleIdentifier
                    && payload.application.name == app.name && payload.capturedAt == reference.capturedAt
            } else { sameSnapshotSource = true }
            if includes(.visibleText), sameSnapshotSource,
               let content = SemanticContextResolver.text(for: event, semanticSnapshots: snapshots) {
                row["texte_affiche"] = try text(content, limit: 5000)
            }
            let action: String?
            switch event.kind {
            case .mouseClick: action = includes(.clicks) ? "clic" : nil
            case .scrollBurst: action = includes(.scrolling) ? "défilement" : nil
            case .typingBurst: action = includes(.typing) ? "frappe (sans caractères)" : nil
            case .keyboardShortcut: action = includes(.shortcuts) ? "raccourci (sans touches)" : nil
            default: action = nil
            }
            if let action { row["action"] = action }
            if includes(.timestamps) { row["heure"] = clock.string(from: event.timestamp) }
            guard row.count > 1 else { continue }
            let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let key = SHA256Digest.hashHex(raw)
            guard detailKeys.insert(key).inserted else { continue }
            guard details.count < 800, detailCharacters + raw.count < 105_000 else { omitted += 1; continue }
            detailCharacters += raw.count; details.append(row)
            if row["texte_affiche"] != nil { semanticCount += 1 }
        }
        if !details.isEmpty { document["details_autorises"] = details }
        var appleRows: [[String: Any]] = [], appleCount = 0
        if selection.screenTime, let screenTime {
            for device in screenTime.deviceSummaries where scope.deviceIDs?.contains(device.device.id) ?? true {
                let apps = device.applications.filter { app in
                    guard scope.allows(id: app.bundleIdentifier ?? app.id, name: app.resolvedName),
                          !privacy.excludes(appID: app.bundleIdentifier ?? app.id, name: app.resolvedName) else { return false }
                    // A browser's opaque total cannot safely remove a chosen domain.
                    if !privacy.domains.isEmpty || !scope.excludedDomains.isEmpty {
                        return !browsers.contains((app.bundleIdentifier ?? app.id).lowercased())
                    }
                    return true
                }
                guard !apps.isEmpty else { continue }
                appleCount += apps.count
                appleRows.append(["appareil": "Appareil \(appleRows.count + 1)", "applications": try apps.map {
                    ["application": try text($0.resolvedName, limit: 512), "secondes": max(0, Int($0.duration))] as [String: Any]
                }])
            }
            document["temps_ecran_Apple"] = appleRows
        }
        var dialogues: [[String: Any]] = [], conversationCharacters = 0, messageCount = 0
        if selection.conversations {
            for capture in agents.captures where scope.conversationFolderIDs?.contains(capture.watchedFolderID) ?? true {
                // Provider files lack app/domain provenance. Global exclusions retain their conservative protection.
                if privacy.hasExclusions && scope.hasConversationText { continue }
                var row: [String: Any] = ["outil": try text(capture.provider.displayName, limit: 512)]
                if scope.conversationCounts { row["messages"] = capture.summary.messageCount }
                if scope.conversationTitles, let title = capture.summary.title { row["titre"] = try text(title, limit: 1000) }
                var messages: [[String: String]] = []
                for message in capture.summary.visibleMessages {
                    guard message.role == .user ? scope.conversationUserMessages : scope.conversationAssistantMessages else { continue }
                    guard messageCount < 512, conversationCharacters < 50_000 else { omitted += 1; continue }
                    let protected = try text(message.text, limit: min(8000, 50_000 - conversationCharacters))
                    conversationCharacters += protected.count; messageCount += 1
                    messages.append(["auteur": message.role == .user ? "vous" : "assistant", "texte": protected])
                }
                if !messages.isEmpty { row["conversation"] = messages }
                if row.count > 1 { dialogues.append(row) }
                if dialogues.count >= 128 { omitted += 1; break }
            }
            document["conversations_choisies"] = dialogues
        }
        if omitted > 0 { document["limite"] = "\(omitted) éléments omis : aperçu partiel, ne pas extrapoler." }
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // JSON escapes keep observations from closing the prompt's context marker.
        let rendered = String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        guard rendered.count <= 169_000 else {
            throw CodexAppServerError.protocolLimitExceeded("Le contexte autorisé dépasse la limite. Réduisez les textes ou les applications.")
        }
        let safeActivity = ActivityDayAnalysis(schemaVersion: activity.schemaVersion, dayStart: activity.dayStart,
            dayEnd: activity.dayEnd, generatedAt: activity.generatedAt, headline: "Données choisies pour ChatGPT",
            activeSeconds: usage.reduce(0) { $0 + $1.activeSeconds }, workSeconds: 0, focusBlocks: [], sites: [], applications: usage,
            requests: [], contextHighlights: [], coverage: activity.coverage, agentMarkdown: "", estimatedAgentTokens: 0)
        let counts = ChatGPTRecapSourceCounts(localEvents: filtered.filter { $0.suppressionReason == nil }.count,
            activeMinutes: safeActivity.activeSeconds / 60, semanticSnapshots: semanticCount,
            screenTimeDevices: appleRows.count, screenTimeApplications: appleCount, agentCaptures: dialogues.count,
            agentMessages: messageCount, visibleAgentMessages: messageCount, analyzedAgentCaptures: dialogues.count,
            importedChatMessages: 0, computerHistoryEpisodes: nil, computerHistoryResources: nil, workflowSuggestions: nil)
        return ChatGPTRecapContext(day: day, activity: safeActivity, computerHistory: nil, screenTime: nil,
            agentActivity: AgentActivityOverview(day: day), importedChats: [], localJournalSourceAbsent: events.isEmpty,
            renderedData: rendered, sourceCounts: counts, digest: SHA256Digest.hashHex(rendered))
    }
}
#endif
