#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class OnboardingPermissionsB04Tests: XCTestCase {
    func testTypedSiteIsAddedToTheDraftAndInvalidTextThrows() throws {
        var draft = DashboardSettingsDraft(config: .default)
        try GoalongOnboardingExclusionEdit.addDomains("banque.fr", to: &draft)
        XCTAssertTrue(GoalongOnboardingExclusionEdit.lines(draft.excludedDomainsText).contains("banque.fr"))
        XCTAssertThrowsError(try GoalongOnboardingExclusionEdit.addDomains("pas un site !", to: &draft))
    }

    func testExclusionCanBeRemovedAndMergeDeduplicates() {
        let text = GoalongOnboardingExclusionEdit.merged("a.fr\nb.fr", adding: ["b.fr", "c.fr", ""])
        XCTAssertEqual(text, "a.fr\nb.fr\nc.fr")
        XCTAssertEqual(GoalongOnboardingExclusionEdit.removing("b.fr", from: text), "a.fr\nc.fr")
    }

    func testPendingWebsiteValidation() {
        var draft = DashboardSettingsDraft(config: .default)
        var pending = "banque.fr"
        XCTAssertEqual(GoalongOnboardingExclusionEdit.commitPendingWebsite(&pending, to: &draft), .added)
        XCTAssertEqual(pending, "")
        XCTAssertTrue(GoalongOnboardingExclusionEdit.lines(draft.excludedDomainsText).contains("banque.fr"))
        pending = "pas un site !"
        XCTAssertEqual(GoalongOnboardingExclusionEdit.commitPendingWebsite(&pending, to: &draft), .invalid)
        XCTAssertEqual(pending, "pas un site !")
        pending = "  "
        XCTAssertEqual(GoalongOnboardingExclusionEdit.commitPendingWebsite(&pending, to: &draft), .nothingPending)
    }

    func testDefaultExclusionsAreNotListedAsAdditions() {
        let defaults = DashboardSettingsDraft(config: .default)
        var draft = defaults
        XCTAssertTrue(GoalongOnboardingExclusionEdit.added(current: draft.excludedApplicationsText, baseline: defaults.excludedApplicationsText).isEmpty)
        draft.excludedApplicationsText = GoalongOnboardingExclusionEdit.merged(draft.excludedApplicationsText, adding: ["com.slack"])
        XCTAssertEqual(GoalongOnboardingExclusionEdit.added(current: draft.excludedApplicationsText, baseline: defaults.excludedApplicationsText), ["com.slack"])
    }

    func testDiagnosticLabelsAreFrenchForEveryCase() {
        let all = SuppressionReason.privateBrowserWindow.frenchLabel + SuppressionReason.manualPause.frenchLabel
        XCTAssertFalse(all.contains("private") || all.contains("manualPause"))
        for kind in CaptureEventTapLifecycle.allCases { XCTAssertNotEqual(kind.frenchLabel, kind.rawValue) }
        for kind in BuildSignatureKind.allCases { XCTAssertFalse(kind.frenchLabel.isEmpty) }
    }
}
#endif
