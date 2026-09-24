#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Never runs in CI/default tests. Sends synthetic fixtures only, using the owner's existing key
/// only when GOALONG_JEV_LIVE_EVALUATION=1 was explicitly supplied for a local semantic audit.
final class JevSemanticEvaluationTests: XCTestCase {
    @MainActor func testExplicitSyntheticSemanticEvaluation() async throws {
        guard ProcessInfo.processInfo.environment["GOALONG_JEV_LIVE_EVALUATION"] == "1" else {
            throw XCTSkip("Opt-in paid API evaluation with synthetic data only")
        }
        guard let data = try JevLocalFiles.read("api-key"), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw XCTSkip("No local API key available; never infer semantic accuracy from mocked transport")
        }
        let work = try JevWorkContext(summary: "Goalong History: macOS SwiftUI app + website; code, design, work tracking, launch communication.")
        let cases: [(String, String, String, String, JevVerdict)] = [
            ("relevant-search-en", "google.com", "search", "SwiftUI NSWindow keep Sparkle update window in front", .productive),
            ("unrelated-search-fr", "google.com", "search", "Résultat du match de football Marseille Paris ce soir", .procrastination),
            ("unrelated-research", "wikipedia.org", "other", "History of the Roman Empire", .procrastination),
            ("unrelated-code", "Xcode", "other", "space-invaders-game - enemyMovement.swift", .procrastination),
            ("relevant-code", "Xcode", "other", "Goalong History - SoftwareUpdateManager.swift", .productive),
            ("relevant-docs-no-project-name", "developer.apple.com", "other", "NSWindow addChildWindow ordered: API documentation", .productive),
            ("tutorial-is-consumption", "youtube.com", "video", "SwiftUI tutorial for productivity apps - YouTube", .procrastination),
            ("social-feed", "x.com", "social-feed", "For you - X", .procrastination),
            ("unknown-title", "Safari", "other", "", .unknown),
            ("off-goal-with-project-keyword", "google.com", "search", "Goalong whisky price and tasting review", .procrastination),
            ("related-composition", "x.com", "composing", "Announcing Goalong History work monitoring launch", .productive),
            ("unrelated-composition", "x.com", "composing", "My favourite football team won tonight", .procrastination)
        ]
        let negativeWork = try JevWorkContext(summary: work.summary,
            applications: "Xcode for Goalong; X for launch announcements.",
            content: "Swift courses and Swift documentation are allowed.",
            procrastination: "Watching Swift video tutorials about logo design. Scrolling the For you feed on X.")
        let negativeCases: [(String, String, String, String, JevVerdict)] = [
            ("negative-overrides-broad-media-rule", "youtube.com", "video", "Swift course: design an animated logo for your app", .procrastination),
            ("unlisted-shopping-still-distracts", "google.com", "search", "Compare sneaker prices for my holidays", .procrastination),
            ("specific-use-not-whole-site-ban", "x.com", "composing", "Announcing Goalong History app launch", .productive),
            ("explicit-negative-feed", "x.com", "social-feed", "For you - X", .procrastination),
            ("allowed-media-not-all-banned", "youtube.com", "video", "Swift course: NSWindow window ordering API", .productive),
            ("negative-context-no-evidence", "Safari", "other", "", .unknown)
        ]
        let allCases = cases.map { ($0, work) } + negativeCases.map { ($0, negativeWork) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (item, context) in allCases {
            let (id, site, mode, topic, expected) = item
            let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
                .init(date: now, resource: site, title: topic, action: mode == "composing" || mode == "search" || site == "Xcode" ? "typing" : "scroll", surface: mode, isActivity: true)
            ])
            let body = try JevPayload.build(window, work: context)
            let decision = try await JevTransport().classify(body: body, key: key)
            let verdict = JevWorkContextStore.reviewedVerdict(decision.verdict, work: context, window: window)
            print("SYNTHETIC_SEMANTIC_CASE \(id) expected=\(expected.rawValue) actual=\(verdict.rawValue) raw=\(decision.verdict.rawValue) probability=\(decision.probability) bytes=\(body.count) tokens=\(decision.inputTokens)")
            XCTAssertEqual(verdict, expected, id)
            XCTAssertLessThan(decision.inputTokens, 1000)
        }
    }
}
#endif
