#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongLiveProfileAnalysisTests: XCTestCase {
    /// Opt-in acceptance uses only fictional inline evidence and Goalong's own connection.
    func testRealConnectedProfileAnalysisWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_LIVE_PROFILE_ANALYSIS"] == "1" else {
            throw XCTSkip("Enable only for an explicitly authorized real-agent acceptance run with synthetic data.")
        }
        let folder = URL(fileURLWithPath: "/private/tmp/goalong-live-profile-acceptance", isDirectory: true)
        try ChatGPTSecureStorage.prepareDirectory(folder)
        let executable = try XCTUnwrap(CodexExecutableLocator.locate())
        let session = try CodexAppServerSession(executableURL: executable,
            codexHomeURL: AppPaths.chatGPTDirectory.appendingPathComponent("site-analysis-codex-home"), siteAnalysisOnly: true)
        defer { session.close() }
        let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        typealias A = GoalongProfileAnalysis
        let request = try A.prepare(date: "2026-09-12", timezone: "Europe/Paris", evidence: [
            .init(id: "past", start: "2026-09-10T08:01:02.345Z", end: "2026-09-10T08:01:02.345Z", kind: "ai", application: "Agent de test", text: "Utilisateur : pour Atlas, je choisis un export local à relire avant partage. Je souhaite finir le prototype le 12 septembre."),
            .init(id: "proposal", start: "2026-09-10T08:02:03.456Z", end: "2026-09-10T08:02:03.456Z", kind: "ai", application: "Agent de test", text: "Réponse finale de l’IA : proposition de tester les exclusions avant de connecter l’envoi. Ce message est une proposition, pas une tâche accomplie."),
            .init(id: "today", start: "2026-09-12T09:30:00.123Z", end: "2026-09-12T09:30:00.123Z", application: "Éditeur de test", text: "Fixture fictive : prototype Atlas modifié ; quatre tests de masquage passent. Aucun déploiement ni achèvement global observé. Étape ouverte : relire l’aperçu d’export."),
            .init(id: "switch", start: "2026-09-12T09:35:00.789Z", end: "2026-09-12T09:35:00.789Z", application: "Navigateur de test", text: "Fixture fictive : consultation de la documentation JSON pour le même export Atlas. Le changement d’outil concerne le même projet."),
            .init(id: "measure", start: "2026-09-12T08:00:00Z", end: "2026-09-12T10:00:00Z", kind: "measurement", application: "Mesure fictive", text: "Source de test uniquement, fenêtre 08:00–10:00 UTC : total observé 7200 secondes, productif 5400 secondes, procrastination 0 seconde, non classé 1800 secondes. Pas de mesure de l’attention, aucune donnée sur le reste de la journée."),
            .init(id: "excluded", start: "2026-09-12T10:00:00Z", end: "2026-09-12T10:00:00Z", application: "SecretClient", text: "Donnée synthétique qui doit être retirée avant l’agent.")
        ], policy: .init(excluded_terms: ["SecretClient"], replacements: [.init(term: "Atlas", replacement: "Projet confidentiel")], additional_instructions: "Ne recommande pas de travailler la nuit."), selected: A.modules, includeConversations: true)
        XCTAssertFalse(try request.prompt().contains("SecretClient"))
        XCTAssertFalse(try request.prompt().contains("Atlas"))
        let result = try A.apply(session.generateProfileAnalysis(request: request, workingDirectory: directory), to: request)
        XCTAssertEqual(Set(result.items.map(\.module)), Set(A.modules))
        XCTAssertTrue(result.items.allSatisfy { $0.status == "unknown" || !$0.evidence_refs.isEmpty })
        try ChatGPTSecureStorage.writeFileAtomically(try request.encoded(), to: folder.appendingPathComponent("request.json"))
        try ChatGPTSecureStorage.writeFileAtomically(try GoalongContextualRhythm.encode(result), to: folder.appendingPathComponent("result.json"))
        try ChatGPTSecureStorage.writeFileAtomically(try GoalongContextualRhythm.encode(A.Archive(request: request, result: result)), to: folder.appendingPathComponent("analysis.json"))
        let ids = Set(result.items.filter { ["projects", "methods"].contains($0.module) }.map(\.id))
        let projection = try A.siteImport(.init(request: request, result: result), selectedIDs: ids)
        try ChatGPTSecureStorage.writeFileAtomically(projection, to: folder.appendingPathComponent("selected-cards.json"))
        let shared = String(decoding: projection, as: UTF8.self)
        for privateValue in ["Atlas", "SecretClient", "evidence_refs", "context_json", "09:30:00.123"] { XCTAssertFalse(shared.contains(privateValue)) }
    }
}
#endif
