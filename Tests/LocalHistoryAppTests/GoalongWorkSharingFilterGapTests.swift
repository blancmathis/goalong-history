#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Visible text and the readiness messages of the work agent: gaps left by `GoalongWorkAgentTests`.
final class GoalongWorkSharingFilterGapTests: XCTestCase {
    private let label = GoalongWorkContext.Label(application: "Safari", bundleIdentifier: "com.apple.Safari",
                                                 host: "docs.acme.example", title: "Plan")

    private func selection(visibleText: Bool, reviewed: Bool = true) -> GoalongAnalysisSelection {
        var selection = GoalongAnalysisSelection()
        selection.reviewed = reviewed
        selection.replacements = [GoalongTextReplacement(search: "Acme", replacement: "Client A")]
        var scope = GoalongAnalysisScope(applicationIDs: ["com.apple.safari"], detailApplicationIDs: ["com.apple.safari"])
        scope.visibleText = visibleText
        selection.scope = scope
        return selection
    }

    func testVisibleTextLeavesOnlyWhenTheOwnerAllowedItAndIsMaskedAndShortened() throws {
        let allowed = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection(visibleText: true))
        XCTAssertTrue(allowed.permitsVisibleContext(label))
        let long = "Acme " + String(repeating: "x", count: 500)
        let excerpt = try XCTUnwrap(allowed.excerpt(long, label: label))
        XCTAssertEqual(excerpt.count, 240, "An excerpt is cut to 240 characters")
        XCTAssertTrue(excerpt.hasPrefix("Client A "), "Name replacements apply to visible text")
        XCTAssertFalse(excerpt.contains("Acme"))

        let denied = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection(visibleText: false))
        XCTAssertFalse(denied.permitsVisibleContext(label))
        XCTAssertNil(denied.excerpt("secret", label: label), "Visible text stays on the Mac when not allowed")

        let unreviewed = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection(visibleText: true, reviewed: false))
        XCTAssertNil(unreviewed.excerpt("secret", label: label), "No reviewed selection, no visible text")

        var policy = GoalongPrivacyPolicy()
        policy.applications = ["com.apple.Safari": "Safari"]
        XCTAssertNil(GoalongWorkSharingFilter(policy: policy, selection: selection(visibleText: true))
            .excerpt("secret", label: label), "A globally excluded app never sends text")
    }

    func testTitlesAreNotWithheldWhenNoScopeIsReviewed() {
        XCTAssertFalse(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection(visibleText: false, reviewed: false)).withholdsTitles)
        XCTAssertTrue(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection(visibleText: false)).withholdsTitles)
    }

    func testReadinessMessagesAreFrenchAndOnlyReadyIsEmpty() {
        let all: [GoalongWorkAgent.Readiness] = [.ready, .noDefinition, .historyOff, .noConsent, .notConnected, .paused]
        for state in all {
            XCTAssertEqual(state.message.isEmpty, state == .ready, "\(state)")
        }
        XCTAssertEqual(Set(all.map(\.message)).count, all.count, "Each state says something different")
    }
}
#endif
