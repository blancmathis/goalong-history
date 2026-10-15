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

    func testExamplesDefinitionNoteAndTasksFollowTodaysChoices() throws {
        var reviewed = GoalongAnalysisSelection()
        reviewed.reviewed = true
        reviewed.replacements = [GoalongTextReplacement(search: "Acme", replacement: "Client A")]
        let mail = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "com.apple.mail", host: nil, title: "Relevé Acme")
        let corrections = [
            GoalongWorkStore.Correction(key: docs.key, label: docs, verdict: .work, task: "Lancement Acme"),
            GoalongWorkStore.Correction(key: mail.key, label: mail, verdict: .other, task: nil),
        ]
        let filter = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: reviewed)
        let examples = try filter.examples(corrections)
        XCTAssertEqual(examples.map(\.title), ["Client A — plan de lancement", "Relevé Client A"])
        XCTAssertEqual(examples.first?.site, "docs.Client A.example")
        XCTAssertEqual(examples.first?.task, "Lancement Client A")

        var policy = GoalongPrivacyPolicy(); policy.applications = ["com.apple.mail": "Mail"]
        XCTAssertEqual(try GoalongWorkSharingFilter(policy: policy, selection: reviewed).examples(corrections).map(\.application),
                       ["Safari"], "A correction on a context excluded later is no longer sent")
        var scoped = reviewed
        scoped.scope = GoalongAnalysisScope(applicationIDs: ["com.apple.safari"], detailApplicationIDs: ["com.apple.safari"],
                                            websiteDomains: true)
        let scopedExamples = try GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: scoped).examples(corrections)
        XCTAssertEqual(scopedExamples.count, 1)
        XCTAssertNil(scopedExamples.first?.title, "Window titles follow « Données pour ChatGPT » in examples too")

        let definition = try filter.definition(GoalongWorkDefinition(goals: "Projet Acme", notWork: "Mails perso Acme"))
        XCTAssertEqual(definition.goals, "Projet Client A")
        XCTAssertEqual(definition.notWork, "Mails perso Client A")
        XCTAssertEqual(try filter.text("Appel Acme"), "Appel Client A")
        var cache: [String: String] = [:]
        let verdicts = try filter.verdicts(GoalongWorkVerdicts([docs.key: .init(verdict: .work, task: "Acme")]), cache: &cache)
        XCTAssertEqual(verdicts.contexts[docs.key]?.task, "Client A")

        var broken = reviewed
        broken.replacements = Array(repeating: GoalongTextReplacement(search: "x", replacement: "y"), count: 101)
        XCTAssertThrowsError(try GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: broken).text("Acme"),
                             "Without valid replacements nothing free-form is sent")
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
        XCTAssertTrue(source.contains("filter.examples(store.corrections)"), "Examples go through the privacy filter")
        XCTAssertTrue(source.contains("prompt(request, definition: sharedDefinition)"), "The prompt reads the masked definition")
    }
}
#endif
