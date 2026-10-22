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

    func testDiagnosticLabelsAreFrenchForEveryCase() {
        let all = SuppressionReason.privateBrowserWindow.frenchLabel + SuppressionReason.manualPause.frenchLabel
        XCTAssertFalse(all.contains("private") || all.contains("manualPause"))
        for kind in CaptureEventTapLifecycle.allCases { XCTAssertNotEqual(kind.frenchLabel, kind.rawValue) }
        for kind in BuildSignatureKind.allCases { XCTAssertFalse(kind.frenchLabel.isEmpty) }
    }
}
#endif
