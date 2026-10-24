import XCTest

@testable import LocalHistoryApp

final class GoalongFrenchErrorTextTests: XCTestCase {
    private func assertFrench(_ errors: [Error], file: StaticString = #filePath, line: UInt = #line) {
        for error in errors {
            let text = GoalongUserFacingError.message(error)
            XCTAssertFalse(text.isEmpty, file: file, line: line)
            XCTAssertFalse(text.contains("The "), text, file: file, line: line)
            XCTAssertFalse(text.contains("Could not"), text, file: file, line: line)
            XCTAssertFalse(text.contains("No "), text, file: file, line: line)
            XCTAssertNotEqual(text, (error as? LocalizedError)?.errorDescription, file: file, line: line)
        }
    }

    func testChatGPTHistoryStoreErrorsAreFrench() {
        assertFrench([
            ChatGPTHistoryStoreError.fileTooLarge(1), .sourceIsSymbolicLink, .sourceIsNotRegularFile,
            .sourceChangedDuringRead, .sourceReadFailed("x"), .invalidRoot, .noMessages, .tooManyMessages,
            .importsDisabled,
        ])
    }

    func testAnalysisProofAndCapsuleErrorsAreFrench() {
        assertFrench([
            AnalysisProofStoreError.invalidIdentity, AnalysisProofStoreError.invalidManifest,
            AnalysisProofStoreError.invalidProof, AnalysisProofStoreError.tooManySources,
            AnalysisProofStoreError.randomFailure(1), AnalysisProofStoreError.destinationExists,
        ])
        assertFrench([
            AnalysisEvidenceCapsuleError.invalidExecutionID, AnalysisEvidenceCapsuleError.randomFailure(1),
            AnalysisEvidenceCapsuleError.keychainFailure(1), AnalysisEvidenceCapsuleError.malformedCapsule,
            AnalysisEvidenceCapsuleError.integrityFailure,
        ])
    }
}
