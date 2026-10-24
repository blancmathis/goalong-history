import XCTest
@testable import LocalHistoryCore

final class FrenchCountTests: XCTestCase {
    func testZeroAndOneAreSingularTwoAndMoreArePlural() {
        XCTAssertEqual(FrenchCount.count(0, "journée", "journées"), "0 journée")
        XCTAssertEqual(FrenchCount.count(1, "journée", "journées"), "1 journée")
        XCTAssertEqual(FrenchCount.count(2, "journée", "journées"), "2 journées")
        XCTAssertEqual(FrenchCount.count(12, "élément local", "éléments locaux"), "12 éléments locaux")
    }

    func testAgreeingWordsFollowTheSameRule() {
        XCTAssertEqual(FrenchCount.word(1, "conservée", "conservées"), "conservée")
        XCTAssertEqual(FrenchCount.word(3, "conservée", "conservées"), "conservées")
        XCTAssertEqual(FrenchCount.word(0, "supprimé", "supprimés"), "supprimé")
    }
}
