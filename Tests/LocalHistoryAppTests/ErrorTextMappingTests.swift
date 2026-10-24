#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// R56: a person never reads a case name, a Swift debug dump or a bare error code.
final class ErrorTextMappingTests: XCTestCase {
    private let fallback = "L’action n’a pas abouti. Réessayez."

    func testFocusFallbackHidesCaseNamesAndDumps() {
        XCTAssertEqual(FocusUIError.message(raw: "unsafePath"), fallback)
        XCTAssertEqual(FocusUIError.message(raw: "keyNotFound(CodingKeys(stringValue: \"day\"), Context())"), fallback)
        XCTAssertEqual(FocusUIError.message(raw: "The operation couldn’t be completed. (X error 1.)"), fallback)
        XCTAssertEqual(FocusUIError.message(raw: String(repeating: "Mot ", count: 40)), fallback)
    }

    func testFocusFallbackKeepsFrenchSentencesFromTheController() {
        for sentence in ["Le plan de demain compte déjà dix tâches.", "Donnez le nom de la tâche de demain."] {
            XCTAssertEqual(FocusUIError.message(raw: sentence), sentence)
        }
        XCTAssertEqual(FocusUIError.message(raw: "locked"), FocusUIError.message(FocusFailure.locked))
    }

    func testDecodingErrorGetsAFrenchSentence() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(GoalongUserFacingError.message(error), GoalongUserFacingError.unreadableFileMessage)
        XCTAssertFalse(GoalongUserFacingError.message(error).contains("Decoding"))
    }

    @MainActor func testComputerHistoryFallbackNeverShowsSystemEnglishForCustomErrors() {
        struct Other: Error {}
        XCTAssertEqual(ComputerHistoryPageModel.displayMessage(for: Other()), GoalongUserFacingError.genericMessage)
    }

    @MainActor func testUpdateSummaryHasNoBareCode() {
        let unknown = SoftwareUpdateManager.unknownErrorSummary
        XCTAssertEqual(SoftwareUpdateManager.errorSummary(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)), unknown)
        XCTAssertEqual(SoftwareUpdateManager.errorSummary(NSError(domain: "Other", code: 7)), unknown)
        XCTAssertFalse(unknown.contains(where: \.isNumber))
    }
}
#endif
