import XCTest
@testable import LocalHistoryCore

final class GoalongReadableErrorTests: XCTestCase {
    private enum Bare: Error { case unavailable, failed(code: Int) }
    private struct Described: Error, CustomStringConvertible { var description: String { "Already readable." } }

    private struct Row: Decodable { let day: String; let count: Int }

    private func decodingError(_ json: String) -> Error {
        do { _ = try JSONDecoder().decode(Row.self, from: Data(json.utf8)); return Bare.unavailable } catch { return error }
    }

    func testDecodingErrorsBecomeShortSentencesWithoutSwiftDumps() {
        for json in ["{\"count\":1}", "{\"day\":1,\"count\":1}", "not json", "{\"day\":null,\"count\":1}"] {
            let text = GoalongReadableError.message(decodingError(json))
            XCTAssertFalse(text.contains("Swift.DecodingError"), text)
            XCTAssertFalse(text.contains("CodingKeys"), text)
            XCTAssertTrue(text.hasPrefix("The data"), text)
        }
        XCTAssertEqual(GoalongReadableError.message(decodingError("{\"count\":1}")), "The data is missing the field \"day\".")
    }

    func testLocalizedAndDescribedErrorsKeepTheirOwnSentence() {
        XCTAssertEqual(GoalongReadableError.message(GoalongProofArchiveError.malformedZIP), "The Goalong proof package is malformed.")
        XCTAssertEqual(GoalongReadableError.message(Described()), "Already readable.")
    }

    func testSystemErrorsUseTheSystemSentenceAndBareCasesNameTheirType() {
        let missing = CocoaError(.fileNoSuchFile)
        XCTAssertEqual(GoalongReadableError.message(missing), missing.localizedDescription)
        XCTAssertEqual(GoalongReadableError.message(Bare.unavailable), "The operation failed (Bare: unavailable).")
        XCTAssertFalse(GoalongReadableError.message(Bare.failed(code: 7)).contains("code:"))
    }
}
