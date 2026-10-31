#if os(macOS)
import Foundation
import SwiftUI
import AgentActivity
@testable import AgentActivity
@testable import LocalHistoryApp

/// Conversations IA with content: the list of Historique › Conversations locales, and the sources page, fed through
/// the runtime's DEBUG seam (`galleryInstall`) with the records a scan would produce. No tool folder is read.
extension GalleryCatalog {
    enum Conversations { case filled, loading, unreadable, partial, projects }

    private static func conversation(_ n: Int, _ provider: AgentProvider, _ title: String, _ hour: Int, _ minute: Int,
                                     prompts: Int, replies: Int, availability: AgentSourceAvailability = .available,
                                     complete: Bool = true, project: String? = nil,
                                     tokens: [(String, Int64, Int64)] = []) -> AgentCaptureRecord {
        let folder = provider == .codex ? ".codex/sessions" : ".claude/projects"
        let relative = "2026/10/23/\(provider == .codex ? "rollout" : "session")-\(n).jsonl"
        let at = GalleryClock.at(hour, minute)
        let index = AgentSourceIndexEntry(
            id: "galerie-\(n)", stableConversationID: "galerie-conversation-\(n)",
            watchedFolderID: provider == .codex ? "galerie-codex" : "galerie-claude",
            watchedFolderName: provider == .codex ? "Codex" : "Claude Code", provider: provider,
            reference: AgentSourceReference(kind: .file, path: "/galerie/\(folder)/\(relative)"), relativePath: relative,
            sourceCreatedAt: GalleryClock.at(hour - 1, minute), sourceModifiedAt: at, firstIndexedAt: at,
            lastObservedAt: at, byteCount: Int64(40_000 * n), sha256: String(repeating: String(n), count: 64),
            availability: availability)
        var usage = AgentTokenUsage()
        usage.events = tokens.enumerated().map { offset, token in
            .init(id: "galerie-\(n)-\(offset)", date: at, model: token.0, input: token.1, output: token.2,
                  cacheRead: token.1 / 2, cacheWrite: 0, reasoning: nil, total: token.1 + token.2)
        }
        var summary = AgentDocumentSummary(
            format: .jsonLines, sessionID: "session-\(n)", title: title, startedAt: GalleryClock.at(hour - 1, minute),
            endedAt: at, messageCount: prompts + replies, userMessageCount: prompts, assistantMessageCount: replies,
            models: tokens.map(\.0),
            visibleMessages: (0..<(prompts + replies)).map { offset in
                .init(role: offset.isMultiple(of: 2) ? .user : .assistantFinal,
                      text: offset.isMultiple(of: 2) ? (title.isEmpty ? "Question sans titre" : title) : "Voici une proposition.",
                      timestamp: GalleryClock.calendar.date(byAdding: .minute, value: offset % 10, to: GalleryClock.at(hour - 1, minute))!)
            })
        summary.tokenUsage = usage
        summary.projectPath = project
        return AgentCaptureRecord(index: index, summary: summary, isAnalyzed: availability == .available,
                                  projectionIsComplete: complete)
    }

    private static func conversationRecords(_ state: Conversations) -> [AgentCaptureRecord] {
        switch state {
        case .loading, .unreadable: return []
        case .filled:
            return [
                conversation(1, .codex, "Planifier la migration du module Atlas", 9, 12, prompts: 7, replies: 7,
                             tokens: [("gpt-5.5", 182_400, 21_300)]),
                conversation(2, .claudeCode, "Relire la maquette de l’onboarding", 8, 47, prompts: 4, replies: 4,
                             tokens: [("claude-opus-5-5", 96_200, 12_800)]),
                conversation(3, .codex, "Corriger les tests du lecteur de calendrier", 8, 20, prompts: 12, replies: 11,
                             tokens: [("gpt-5.5", 241_000, 30_100)]),
                conversation(4, .claudeCode, "Un titre de conversation très long pour vérifier la coupe de la ligne quand le titre dépasse la largeur disponible dans la liste", 7, 55,
                             prompts: 1, replies: 1, tokens: [("claude-sonnet-5-5", 14_500, 2_100)]),
                conversation(5, .codex, "", 7, 10, prompts: 1, replies: 1, tokens: [("gpt-5.5", 8_200, 900)]),
            ]
        case .projects:
            // The same day, with the folder each conversation ran in: « Agents et code » groups them by project. A scan
            // of a finished day reads each file for that day (`analysisInterval`); without it the figures show as partial.
            let day = GalleryClock.calendar.dateInterval(of: .day, for: GalleryClock.today)
            return [
                conversation(1, .codex, "Planifier la migration du module Atlas", 9, 12, prompts: 7, replies: 7,
                             project: "/galerie/projets/atlas", tokens: [("gpt-5.5", 182_400, 21_300)]),
                conversation(2, .claudeCode, "Relire la maquette de l’onboarding", 8, 47, prompts: 4, replies: 4,
                             project: "/galerie/projets/onboarding", tokens: [("claude-opus-5-5", 96_200, 12_800)]),
                conversation(3, .codex, "Corriger les tests du lecteur de calendrier", 8, 20, prompts: 12, replies: 11,
                             project: "/galerie/projets/atlas", tokens: [("gpt-5.5", 241_000, 30_100)]),
                conversation(4, .claudeCode, "Préparer la note de version", 7, 40, prompts: 3, replies: 3,
                             project: "/galerie/projets/atlas", tokens: [("claude-sonnet-5-5", 14_500, 2_100)]),
                conversation(5, .codex, "Vérifier une idée sans dossier de projet", 7, 10, prompts: 1, replies: 1,
                             tokens: [("gpt-5.5", 8_200, 900)]),
            ].map { record in var scoped = record; scoped.analysisInterval = day; return scoped }
        case .partial:
            return [
                conversation(1, .codex, "Planifier la migration du module Atlas", 9, 12, prompts: 7, replies: 7, complete: false,
                             tokens: [("gpt-5.5", 182_400, 21_300)]),
                conversation(2, .claudeCode, "Relire la maquette de l’onboarding", 8, 47, prompts: 4, replies: 4,
                             availability: .missing),
                conversation(3, .codex, "Corriger les tests du lecteur de calendrier", 8, 20, prompts: 12, replies: 11,
                             availability: .inaccessible),
            ]
        }
    }

    /// Installs the state in the page's runtime and gives the consent the page needs to show conversations.
    static func installConversations(_ state: Conversations, _ model: DashboardViewModel) {
        installConversations(state, runtime: model.agentActivityRuntime)
    }

    /// The same state on a runtime alone (unit tests that render the page without a dashboard model).
    static func installConversations(_ state: Conversations, runtime: AgentActivityRuntime) {
        GoalongCapabilityConsentStore.shared.set(.aiConversations, enabled: true, surface: .settings)
        let records = conversationRecords(state)
        let overview = AgentActivityOverview(
            day: GalleryClock.today, captures: records, sessionCount: records.count, analyzedSessionCount: records.count,
            messageCount: records.reduce(0) { $0 + $1.summary.messageCount },
            visibleMessageCount: records.reduce(0) { $0 + $1.summary.visibleMessages.count },
            sourceBytes: records.reduce(0) { $0 + $1.byteCount }, indexBytes: 4_096,
            lastCaptureAt: records.first?.capturedAt)
        var scan = AgentScanResult(scannedSourceCount: records.count)
        var usage: AgentDailyTokenUsage?
        switch state {
        case .filled, .projects:
            usage = AgentDailyTokenUsage(records: records, day: GalleryClock.today, calendar: GalleryClock.calendar)
        case .partial:
            scan.analysisIncomplete = true
            usage = AgentDailyTokenUsage(records: records, day: GalleryClock.today, calendar: GalleryClock.calendar)
        case .unreadable:
            scan.failures = [".codex/sessions/2026/10/23/rollout-1.jsonl : lecture refusée",
                             ".claude/projects/atlas/session-2.jsonl : lecture refusée"]
        case .loading: break
        }
        runtime.galleryInstall(
            overview: overview, tokenUsage: usage, analyzedAt: usage == nil ? nil : GalleryClock.at(9, 40), scan: scan,
            isScanning: state == .loading,
            codexFolder: state == .filled
                ? AgentWatchedFolder(displayName: ".codex", path: "/Users/demo/.codex", provider: .codex) : nil)
    }

    /// Historique › Conversations locales, in the dashboard window.
    private static func conversationsHistory(_ id: String, _ state: Conversations, note: String) -> GalleryEntry {
        GalleryEntry(id, sizes: [.fixed(1100, 900)], clock: .injected, note: note) { ctx in
            try GalleryFixtureHome.install(.recordingOn)
            let model = try GalleryFixtures.dashboardModel(ctx, .init(section: .history))
            installConversations(state, model)
            return AnyView(AgentActivityPage(agents: model.agentActivityRuntime, presentation: .history, onManageSources: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(LHTheme.pageBackground))
        }
    }

    static var conversationEntries: [GalleryEntry] {
        [
            conversationsHistory("conversations-ia/liste-remplie", .filled,
                                 note: "Historique › Conversations locales : cinq conversations, usage de l’IA, un titre très long, une sans titre"),
            conversationsHistory("conversations-ia/lecture-en-cours", .loading,
                                 note: "analyse du jour en cours : liste vide « Lecture des conversations »"),
            conversationsHistory("conversations-ia/sources-illisibles", .unreadable,
                                 note: "deux sources refusent la lecture : avertissement et « Conversations indisponibles »"),
            conversationsHistory("conversations-ia/analyse-partielle", .partial,
                                 note: "journée partielle, source absente, source inaccessible, analyse à reprendre"),
            dashboard("conversations-ia/gestion-remplie", section: .agentActivity, fixture: .recordingOn,
                      note: "page des sources avec conversations lues",
                      configure: { model, _ in installConversations(.filled, model) }),
        ]
    }
}
#endif
