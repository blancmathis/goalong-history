#if os(macOS)
@testable import LocalHistoryApp
@testable import LocalHistoryQueryCLI
import LocalHistoryCore
import XCTest

/// T-045 H10: website pairing texts follow the « connexion » wording (T46) and send the user back to the site.
final class T045H10Tests: XCTestCase {
    func testPairingConfirmationSaysConnexionNotLiaison() {
        let text = GoalongWebsitePairingCoordinator.confirmationText(origin: "https://goalong.example", notice: "")
        XCTAssertFalse(text.lowercased().contains("liaison"), text)
        XCTAssertTrue(text.contains("connexion"), text)
        XCTAssertTrue(text.hasPrefix("Site : https://goalong.example"), text)
    }

    /// Pairing always starts on the website (« Relier mon Mac »): the app cannot start it again.
    func testRejectedPairingLinkSendsTheUserBackToTheSite() {
        for status in [400, 404, 410, 200, 0] {
            let text = PairingResponse.failureMessage(status: status, transportError: nil)
            XCTAssertFalse(text.contains("depuis Goalong"), text)
            XCTAssertTrue(text.contains("depuis le site"), text)
        }
    }
    /// Several folders picked at once: a failure on one must stay shown even when a later one is added.
    @MainActor func testProjectsSheetKeepsTheFirstFailureOfAMultipleChoice() {
        var added = 0
        let changes: [() throws -> Void] = [
            { throw GoalongDeveloperFileIO.Failure.invalid },
            { added += 1 },
        ]
        let problem = GoalongDeveloperProjectsSheet.outcome(changes)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(problem, "Ce dossier n’est pas un dépôt Git.")
        XCTAssertNil(GoalongDeveloperProjectsSheet.outcome([{ added += 1 }]))
    }
}
#endif
