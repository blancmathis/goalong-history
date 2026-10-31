#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Activité › Bilan ChatGPT (`ChatGPTRecapPage`): the day being read, a read that failed, and a saved report. The page
/// gets a runtime whose sources are replaced (no Codex, no account check, no real clock); its state goes through the
/// app's own code: the day reader, the recap files in the app's folder, the consent store.
extension GalleryCatalog {
    private static var recapOverview: ChatGPTRecapDayOverview {
        typealias Usage = ChatGPTRecapDayOverview.Usage
        return ChatGPTRecapDayOverview(
            day: GalleryClock.today, activeSeconds: 5_280, workSeconds: 4_020, sourceEventCount: 312, privateMinutes: 0,
            focusBlockCount: 2,
            computerApplications: [Usage(id: "xcode", name: "Xcode", seconds: 2_400, detail: nil),
                                   Usage(id: "safari", name: "Safari", seconds: 1_500, detail: nil),
                                   Usage(id: "notes", name: "Notes", seconds: 780, detail: nil)],
            screenTimeSeconds: 0, screenTimeDevices: [], screenTimeApplications: [],
            agentSessions: 0, agentMessages: 0, agentToolCalls: 0, agentErrors: 0, analyzedAgentSessions: 0)
    }

    /// A saved report of the gallery day, written like the app writes one (an old report without signature: schema 2).
    private static func saveRecap() throws {
        let lines = ["Matinée concentrée sur Atlas : 1 h 07 de travail réel entre 08:12 et 09:40.",
                     "Xcode domine la journée, Safari sert surtout à la documentation.",
                     "Deux blocs de concentration, séparés par une courte pause.",
                     "Peu de distractions : Messages et YouTube restent sous dix minutes.",
                     "Prochaine étape : finir la vue Planning avant le point de midi."]
        let counts = ChatGPTRecapSourceCounts(localEvents: 312, activeMinutes: 88, semanticSnapshots: 0, screenTimeDevices: 0,
                                              screenTimeApplications: 0, agentCaptures: 0, agentMessages: 0,
                                              importedChatMessages: 0, computerHistoryEpisodes: nil,
                                              computerHistoryResources: nil, workflowSuggestions: nil)
        let recap = ChatGPTDailyRecap(day: GalleryClock.today, generatedAt: GalleryClock.at(9, 30), planType: "plus",
                                      contextDigest: String(repeating: "ab", count: 32), sourceCounts: counts,
                                      markdown: lines.joined(separator: "\n"), model: CodexDailyAssessmentContract.model,
                                      reasoningEffort: CodexDailyAssessmentContract.reasoningEffort,
                                      productivityScore: 74, confidenceScore: 82, summaryLines: lines)
        // The store refuses a path with a link in it, and `/tmp` is one (`resolvingSymlinksInPath` puts it back).
        let folder = AppPaths.chatGPTRecapsDirectory
        guard let real = realpath(folder.path, nil) else { throw GalleryError.fixture("dossier des bilans introuvable") }
        defer { free(real) }
        try ChatGPTRecapPersistence.write(recap, to: URL(fileURLWithPath: String(cString: real), isDirectory: true))
    }

    private struct RecapReadFailure: LocalizedError {
        var errorDescription: String? { "La lecture des sources locales a été interrompue." }
    }

    /// One state of the page. `reader` replaces the day's local read; `ready` says the state is on screen.
    private static func recapEntry(_ id: String, saved: Bool = false, note: String,
                                   reader: @escaping (GalleryContext) -> (Date) throws -> ChatGPTRecapDayOverview,
                                   ready: @escaping (ChatGPTRecapRuntime) -> Bool) -> GalleryEntry {
        var runtime: ChatGPTRecapRuntime?
        var model: DashboardViewModel?
        // UI-13C (34): inside the real window, like bilan/non-connecte, so every state has the sidebar and the return bar.
        return GalleryEntry(id, sizes: [.window], clock: .injected, dashboardWindow: true, note: note,
                            section: .chatGPTRecap,
                            ready: { ctx in
                                guard let model, GalleryFixtures.dashboardReady(model)(ctx) else { return false }
                                return runtime.map(ready) ?? false
                            }) { ctx in
            ctx.environment.usedBytes = GalleryFixtureHome.usedBytes(.recordingOn)
            try GalleryFixtureHome.install(.recordingOn)
            GoalongCapabilityConsentStore.shared.set(.chatGPTAnalysis, enabled: true, surface: .settings)
            if saved { try saveRecap() }
            let read = reader(ctx)
            let built = ChatGPTRecapRuntime(
                executableLocator: { nil }, directoryOpener: { _ in }, fileRevealer: { _ in },
                delayedAutomaticScheduler: { _ in }, automaticRetryScheduler: { _, _ in },
                automaticBoundaryFallbackScheduler: { _, _ in }, analysisConsentProvider: { true },
                analysisSelectionProvider: { GoalongAnalysisSelection.load() },
                dayOverviewReader: { try read($0) }, defaults: ctx.defaults)
            runtime = built
            ctx.keep(built)
            ChatGPTRecapPage.galleryRuntime = built
            ctx.cleanups.append { ChatGPTRecapPage.galleryRuntime = nil; built.stop() }
            let dashboard = try GalleryFixtures.dashboardModel(ctx, .init(section: .chatGPTRecap))
            model = dashboard
            return AnyView(LocalHistoryDashboardView(model: dashboard))
        }
    }

    static var recapEntries: [GalleryEntry] {
        [
            // The read of the day has not returned: it waits until the entry is captured, then the cleanup frees it.
            recapEntry("bilan/chargement", note: "lecture de la journée en cours",
                       reader: { ctx in
                           let gate = DispatchSemaphore(value: 0)
                           ctx.cleanups.append { gate.signal() }
                           return { _ in gate.wait(); return recapOverview }
                       }, ready: { $0.isLoadingDayOverview }),
            recapEntry("bilan/erreur", note: "la lecture de la journée a échoué",
                       reader: { _ in { _ in throw RecapReadFailure() } },
                       ready: { $0.dayOverviewError != nil }),
            recapEntry("bilan/rapport", saved: true, note: "rapport enregistré (ancien format, non signé) et mesures du jour",
                       reader: { _ in { _ in recapOverview } },
                       ready: { $0.dayOverview != nil && $0.recap != nil }),
        ]
    }
}
#endif
