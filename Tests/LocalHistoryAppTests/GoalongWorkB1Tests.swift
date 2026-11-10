#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// Lot B1 (T-049): the classification contract, the new consent and the stored rules.
    final class GoalongWorkB1Tests: XCTestCase {
        func testClassificationUsesLunaLowAndLeavesTheDailyContractUnchanged() {
            XCTAssertEqual(CodexWorkClassificationContract.model, "gpt-5.6-luna")
            XCTAssertEqual(CodexWorkClassificationContract.reasoningEffort, "low")
            XCTAssertEqual(CodexDailyAssessmentContract.model, "gpt-5.6-luna")
            XCTAssertEqual(CodexDailyAssessmentContract.reasoningEffort, "high", "The daily recap contract does not change")
        }

        func testClientChecksTheContractAndMeasuresTokens() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/ChatGPT/CodexAppServerClient.swift"), encoding: .utf8)
            XCTAssertTrue(source.contains("try requireModel(model, reasoningEffort: reasoningEffort)"), "model/list checks the effort used")
            XCTAssertTrue(source.contains("started[\"reasoningEffort\"] as? String == reasoningEffort"), "Codex confirms the effort")
            XCTAssertTrue(source.contains("case \"thread/tokenUsage/updated\":"), "Real tokens are read when exposed")
            XCTAssertTrue(source.contains("\"account/rateLimits/read\""), "Account limits are read without inference")
            XCTAssertTrue(source.contains("if let baseInstructions { threadParams[\"baseInstructions\"] = baseInstructions }"),
                          "Short base instructions only where asked")
        }

        func testBackgroundConsentTextStatesRhythmCapAndData() {
            let text = GoalongWorkPage.backgroundConsentText
            for part in ["2 envois par jour", "12 h 30", "18 h 30", "40 groupes", "24", "jetons", "titre de la fenêtre", "Jamais vos frappes au clavier"] {
                XCTAssertTrue(text.contains(part), part)
            }
        }

        @MainActor func testRulesAndConsentPersistAndAnOldFileStillLoads() throws {
            let root = URL(fileURLWithPath: "/private/tmp/t049b1-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("work.json")
            func make() -> GoalongWorkStore {
                GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }, committedTasks: { [] },
                                 renamedTask: { _, _ in [] })
            }
            let store = make()
            XCTAssertFalse(store.backgroundConsent, "Unchecked by default; the old automatic switch does not count")
            store.automatic = true
            XCTAssertFalse(store.backgroundConsent)
            store.setRule(scope: .site, target: "www.Docs.example.org", label: "docs", verdict: .work, task: "Spec", day: "2026-09-10")
            store.setRule(scope: .context, target: "k", label: "x", verdict: .work, day: "2026-09-10")
            store.backgroundConsent = true
            store.recordUsage(day: "2026-09-10", at: Date(), tokens: 4_200, estimated: true, background: true, weeklyBefore: 3, weeklyAfter: 4)
            let reloaded = make()
            XCTAssertEqual(reloaded.rules.map(\.target), ["docs.example.org"], "Only app and site rules are stored as rules")
            XCTAssertTrue(reloaded.backgroundConsent)
            XCTAssertEqual(reloaded.usage.day("2026-09-10").tokens, 4_200)
            XCTAssertTrue(reloaded.verdicts.rules.match(application: "Browser", bundleIdentifier: nil, host: "docs.example.org") != nil)

            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            for key in ["rules", "groups", "backgroundConsent"] { json.removeValue(forKey: key) }
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let old = make()
            XCTAssertTrue(old.rules.isEmpty)
            XCTAssertFalse(old.backgroundConsent)
            XCTAssertEqual(old.definition.goals, "Goalong")
        }
    }
#endif
