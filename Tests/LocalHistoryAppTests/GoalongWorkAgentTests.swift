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

    @MainActor func testSlowSessionBuildKeepsTheMainActorFreeAndStaleRunsCloseIt() async throws {
        final class Box: @unchecked Sendable { var closed = 0 }
        let box = Box()
        var mainRan = false
        let build = Task { @MainActor in
            try await GoalongWorkAgent.makeOffMain({ Thread.sleep(forTimeInterval: 0.6); return 7 }, isStale: { false }, close: { _ in box.closed += 1 })
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        mainRan = true
        let built = try await build.value; XCTAssertEqual(built, 7)
        XCTAssertTrue(mainRan)
        XCTAssertEqual(box.closed, 0)
        let stale = try await GoalongWorkAgent.makeOffMain({ 8 }, isStale: { true }, close: { _ in box.closed += 1 })
        XCTAssertNil(stale)
        XCTAssertEqual(box.closed, 1, "A stale run closes the session it built")
        let cancelled = Task { @MainActor in
            try await GoalongWorkAgent.makeOffMain({ Thread.sleep(forTimeInterval: 0.3); return 9 }, isStale: { false }, close: { _ in box.closed += 1 })
        }
        cancelled.cancel()
        let none = try await cancelled.value; XCTAssertNil(none)
        XCTAssertEqual(box.closed, 2)
    }

    func testCancellingTheParentStopsTheDetachedScan() async throws {
        final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0; var stopped = false
            func tick(_ live: Bool) { lock.lock(); n += 1; if !live { stopped = true }; lock.unlock() } }
        let counter = Counter()
        let parent = Task {
            await GoalongWorkAgent.detachedForwardingCancellation(priority: .utility) {
                for _ in 0..<2_000 {
                    counter.tick(!Task.isCancelled)
                    if Task.isCancelled { return false }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return true
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        parent.cancel()
        let finished = await parent.value
        XCTAssertFalse(finished)
        XCTAssertTrue(counter.stopped)
        XCTAssertLessThan(counter.n, 1_000)
    }

    func testAgentNeverRunsOnATimerAndOnlyWithConsent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/GoalongWorkAgent.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Timer."), "Classification is triggered by Activité or the user, never by a timer")
        XCTAssertTrue(source.contains("consents.isEnabled(.chatGPTAnalysis)"))
        XCTAssertTrue(source.contains("siteAnalysisOnly: true"), "The strict tool-less, network-less profile")
        XCTAssertTrue(source.contains("filter.label(label)"), "Every label goes through the privacy filter")
        XCTAssertTrue(source.contains("filter.examples(store.corrections)"), "Examples go through the privacy filter")
        XCTAssertTrue(source.contains("GoalongAnalysisSelection.load(root: root).revision == selectionRevision"),
                      "A changed « Données pour ChatGPT » choice stops the run before the next batch")
        XCTAssertTrue(source.contains("selectionRevision: selectionRevision"), "The client rechecks the choice before sending")
        XCTAssertTrue(source.contains("if !userInitiated { rerunRequested = true }"), "A new definition during a run is classified afterwards")
        XCTAssertTrue(source.contains("classified += applied.count"), "Only stored verdicts are reported as classified")
        XCTAssertTrue(source.contains("prompt(request, definition: sharedDefinition)"), "The prompt reads the masked definition")
    }

    func testHomeBusyIsRecognisedAsRetryLater() {
        XCTAssertTrue(GoalongWorkAgent.isHomeBusy(CodexAppServerError.homeBusy))
        XCTAssertFalse(GoalongWorkAgent.isHomeBusy(CodexAppServerError.executableUnavailable))
    }

    func testBusyGuardAndEscapeBindingsInSource() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let agent = try src("Sources/LocalHistoryApp/GoalongWorkAgent.swift")
        XCTAssertTrue(agent.contains("if !userInitiated, ChatGPTRecapRuntime.shared.isBusyWithCodex {"), "Automatic runs defer while Codex is busy")
        XCTAssertTrue(agent.contains("if !userInitiated, Self.isHomeBusy(error) {"), "An automatic homeBusy is not a failure")
        XCTAssertTrue(agent.contains("guard rerunRequested, !isRunning, !ChatGPTRecapRuntime.shared.isBusyWithCodex"), "The rerun waits for Codex, not only the recap")
        for path in ["Sources/LocalHistoryApp/GoalongWorkPage.swift",
                     "Sources/LocalHistoryApp/DeveloperActivity/GoalongDeveloperProjectsSheet.swift",
                     "Sources/LocalHistoryApp/Blocking/BlockingPageLists.swift",
                     "Sources/LocalHistoryApp/GoalongRetentionSheet.swift"] {
            XCTAssertTrue(try src(path).contains(".keyboardShortcut(.cancelAction)"), "\(path) closes with Escape")
        }
    }
}
#endif
