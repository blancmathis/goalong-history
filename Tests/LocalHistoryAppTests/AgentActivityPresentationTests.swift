#if os(macOS)
    import AgentActivity
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AgentActivityPresentationTests: XCTestCase {
        func testScanFailureAlertsOnlyForNewFailures() {
            let first = ["/a: unreadable"]
            // First scan: alert.
            XCTAssertEqual(
                AgentActivityRuntime.newScanFailures(previous: [], current: first), first)
            // Same failure on the next timer scan: no new alert.
            XCTAssertEqual(
                AgentActivityRuntime.newScanFailures(previous: Set(first), current: first), [])
            // A different failure: alert for it only.
            XCTAssertEqual(
                AgentActivityRuntime.newScanFailures(
                    previous: Set(first), current: first + ["/b: unreadable"]),
                ["/b: unreadable"])
            // Sequence [F], [], [F] as produced by retry backoff: the alert shows once.
            var reported = Set<String>()
            var alerts = 0
            for scan in [first, [], first, [], first] {
                if !AgentActivityRuntime.newScanFailures(previous: reported, current: scan).isEmpty {
                    alerts += 1
                }
                reported.formUnion(scan)
            }
            XCTAssertEqual(alerts, 1)
        }

        func testProviderFilterNeverShowsOtherProvidersRows() {
            XCTAssertNil(
                AgentConversationListPresentation.effectiveProviderFilter(
                    .custom, availableProviders: [.codex]))
            XCTAssertNil(
                AgentConversationListPresentation.effectiveProviderFilter(
                    .custom, availableProviders: [.codex, .claudeCode]))
            XCTAssertEqual(
                AgentConversationListPresentation.effectiveProviderFilter(
                    .codex, availableProviders: [.codex, .claudeCode]), .codex)
            XCTAssertNil(
                AgentConversationListPresentation.effectiveProviderFilter(
                    nil, availableProviders: [.codex, .claudeCode]))
        }

        func testTokenCardShowsFrenchProviderNamesNotRawValues() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let card = try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/LocalHistoryApp/AgentActivity/AgentTokenUsageCard.swift"),
                encoding: .utf8)
            XCTAssertFalse(card.contains("provider.rawValue"))
            XCTAssertTrue(card.contains("provider.frenchName"))
            XCTAssertEqual(AgentProvider.claudeCode.frenchName, "Claude Code")
        }
    }
#endif
