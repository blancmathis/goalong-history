#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class BlockingProgramUIU04Tests: XCTestCase {
    func testWeekdayLettersAreUniqueAndSevenLong() {
        let letters = BlockingFormat.weekdayLetters
        XCTAssertEqual(letters.count, 7)
        XCTAssertEqual(Set(letters).count, 7, "Tuesday and Wednesday must not both read M")
    }

    func testListSheetTitleNamesTheLock() {
        XCTAssertEqual(BlockListSheet.title(locked: true), "Liste verrouillée")
        XCTAssertEqual(BlockListSheet.title(locked: false), "Modifier la liste")
    }
}
#endif
