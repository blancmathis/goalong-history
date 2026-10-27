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

    func testGoalongNSErrorsKeepTheirFrenchSentence() {
        let limit = NSError(domain: "GoalongAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Limite : 4 000 caractères de consignes."])
        XCTAssertEqual(GoalongUserFacingError.message(limit), "Limite : 4 000 caractères de consignes.")
        XCTAssertEqual(GoalongUserFacingError.message(NSError(domain: "GoalongPrivacy", code: 3)), GoalongUserFacingError.genericMessage)
    }

    @MainActor func testComputerHistoryFallbackNeverShowsSystemEnglishForCustomErrors() {
        struct Other: Error {}
        XCTAssertEqual(ComputerHistoryPageModel.displayMessage(for: Other()), GoalongUserFacingError.genericMessage)
    }

    @MainActor func testUpdateSummaryHasNoBareCode() {
        let unknown = SoftwareUpdateManager.unknownErrorSummary
        XCTAssertEqual(SoftwareUpdateManager.errorSummary(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)), "problème de réseau ; réessayez plus tard")
        XCTAssertEqual(SoftwareUpdateManager.errorSummary(NSError(domain: "Other", code: 7)), unknown)
        XCTAssertFalse(unknown.contains(where: \.isNumber))
    }

    /// C13-13 (T-044 r13). A full disk while Sparkle downloads, unpacks or makes its temporary folder:
    /// the sentence speaks of the disk, not of the network and not « erreur inconnue ».
    @MainActor func testUpdateFailureOnAFullDiskNamesTheDisk() {
        let sparkle = "SUSparkleErrorDomain"
        let cases: [(String, NSError, String)] = [
            ("download -3003", NSError(domain: sparkle, code: 2001, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile)]), SoftwareUpdateManager.cannotWriteSummary),
            ("url -3000", NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotCreateFile), SoftwareUpdateManager.cannotWriteSummary),
            ("unarchive ENOSPC", NSError(domain: sparkle, code: 3000, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]), SoftwareUpdateManager.diskFullSummary),
            ("temp dir out of space", NSError(domain: sparkle, code: 2000, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)]), SoftwareUpdateManager.diskFullSummary),
        ]
        for (name, error, expected) in cases {
            let text = SoftwareUpdateManager.errorSummary(error)
            XCTAssertEqual(text, expected, name)
            XCTAssertTrue(text.contains("disque"), "\(name): \(text)")
        }
    }
}
#endif
