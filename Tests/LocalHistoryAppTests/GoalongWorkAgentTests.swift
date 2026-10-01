#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// What the classification agent may send, and how the daily report uses the definition.
final class GoalongWorkAgentTests: XCTestCase {
    private let docs = GoalongWorkContext.Label(application: "Safari", bundleIdentifier: "com.apple.Safari",
                                                host: "docs.acme.example", title: "Acme — plan de lancement")

    func testFilterAppliesExclusionsSelectionAndNameMasking() throws {
        var reviewed = GoalongAnalysisSelection()
        reviewed.reviewed = true
        reviewed.replacements = [GoalongTextReplacement(search: "Acme", replacement: "Client A")]
        let masked = try XCTUnwrap(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: reviewed).label(docs))
        XCTAssertEqual(masked.title, "Client A — plan de lancement")
        XCTAssertEqual(masked.host, "docs.Client A.example")

        var policy = GoalongPrivacyPolicy()
        policy.domains = ["acme.example"]
        XCTAssertNil(GoalongWorkSharingFilter(policy: policy, selection: reviewed).label(docs), "Excluded sites never leave")
        policy = GoalongPrivacyPolicy(); policy.applications = ["com.apple.Safari": "Safari"]
        XCTAssertNil(GoalongWorkSharingFilter(policy: policy, selection: reviewed).label(docs), "Excluded apps never leave")

        var scoped = reviewed
        scoped.scope = GoalongAnalysisScope(applicationIDs: ["com.apple.safari"], detailApplicationIDs: ["com.apple.safari"],
                                            websiteDomains: true)
        let withoutTitles = try XCTUnwrap(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: scoped).label(docs))
        XCTAssertNil(withoutTitles.title, "Window titles follow « Données pour ChatGPT »")
        XCTAssertNotNil(withoutTitles.host)
        XCTAssertTrue(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: scoped).withholdsTitles)
        scoped.scope?.applicationIDs = ["com.apple.mail"]
        XCTAssertNil(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: scoped).label(docs),
                     "Applications removed from the selection stay on the Mac")
    }

    func testDailyReportJudgesAgainstTheUsersDefinition() {
        let text = ChatGPTRecapContextBuilder.workDefinitionText(
            GoalongWorkDefinition(goals: "Goalong", applications: "YouTube pour le cours Swift", notWork: "Scroller X"))
        XCTAssertEqual(text, "Projects and goals: Goalong\nApplications and sites used for work, and what for: YouTube pour le cours Swift\nWhat is not work: Scroller X")
        XCTAssertEqual(ChatGPTRecapContextBuilder.workDefinitionText(nil), "")
        XCTAssertEqual(ChatGPTRecapContextBuilder.workDefinitionText(GoalongWorkDefinition()), "")
    }

    func testAgentNeverRunsOnATimerAndOnlyWithConsent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/GoalongWorkAgent.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Timer."), "Classification is triggered by Activité or the user, never by a timer")
        XCTAssertTrue(source.contains("consents.isEnabled(.chatGPTAnalysis)"))
        XCTAssertTrue(source.contains("siteAnalysisOnly: true"), "The strict tool-less, network-less profile")
        XCTAssertTrue(source.contains("filter.label(label)"), "Every label goes through the privacy filter")
    }
}
#endif
