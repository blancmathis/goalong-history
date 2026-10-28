import XCTest
@testable import LocalHistoryApp

final class GoalongH18CopyTests: XCTestCase {
    func testAgentSourceTextsNeverClaimMessagesAreNotRead() {
        for text in [GoalongAgentSourceCopy.off, GoalongAgentSourceCopy.on] {
            XCTAssertFalse(text.contains("sans lire les messages"))
            XCTAssertTrue(text.contains("Les messages sont lus sur ce Mac et restent dans leurs fichiers."))
        }
    }

    func testSavedAnalysesNoticeSeparatesLimitAndUnreadableFiles() {
        XCTAssertNil(GoalongAnalyticsReader.savedAnalysesNotice(truncated: false, rejected: 0))
        XCTAssertEqual(GoalongAnalyticsReader.savedAnalysesNotice(truncated: true, rejected: 0),
                       "Seules les 64 analyses enregistrées les plus récentes sont lues.")
        let one = GoalongAnalyticsReader.savedAnalysesNotice(truncated: false, rejected: 1)
        XCTAssertEqual(one, "1 analyse enregistrée illisible n’est pas affichée.")
        XCTAssertFalse(one?.contains("64") ?? true)
        XCTAssertTrue(GoalongAnalyticsReader.savedAnalysesNotice(truncated: true, rejected: 2)?.hasSuffix("2 analyses enregistrées illisibles ne sont pas affichées.") ?? false)
    }
}
