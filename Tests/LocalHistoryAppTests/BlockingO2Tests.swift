#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-043 O2: blocking day chips, monogram letters, « Ensuite » folding.
final class BlockingO2Tests: XCTestCase {
    private let social = UUID(), video = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func block(_ lists: [UUID], lock: BlockLock, endIn minutes: Double) -> BlockingActiveBlock {
        BlockingActiveBlock(id: UUID(), listIDs: lists, start: now.addingTimeInterval(-600),
                            end: now.addingTimeInterval(minutes * 60), lock: lock, origin: .manual)
    }

    // HL-31: day chips read like every French summary (« Sam, dim »), never « Sa Di ».
    func testDayChipsUseTheFrenchAbbreviationsOfTheSummaries() {
        XCTAssertEqual(BlockingFormat.weekdayLetters, ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"])
        XCTAssertEqual(BlockingFormat.weekdayLetters, BlockingFormat.weekdayShort)
        XCTAssertEqual(BlockingFormat.weekdays([6, 7]), "Sam, dim")
    }

    // HL-TUILES: the monogram letter never falls under 11 pt, even on the smallest tiles.
    func testMonogramLetterIsAtLeastElevenPoints() {
        for side: CGFloat in [16, 18, 22, 24] {
            XCTAssertGreaterThanOrEqual(WebsiteIconView.letterSize(for: side), 11, "side \(side)")
        }
        XCTAssertEqual(WebsiteIconView.letterSize(for: 36), 18)
    }

    // R-266 (moyen), case B: fewer lists than the leading block → its own row, not « Ensuite ».
    func testBlockWithFewerListsIsNotFolded() {
        let leading = block([social, video], lock: .locked, endIn: 60)
        let other = block([social], lock: .free, endIn: 120)
        XCTAssertFalse(BlockingStateHero.folds(other, into: leading))
    }

    // R-266 (moyen), case A: a stricter block is never hidden nor folded, with its actions.
    func testStricterBlockIsNotFolded() {
        let leading = block([social], lock: .free, endIn: 120)
        let other = block([social], lock: .password, endIn: 30)
        XCTAssertFalse(BlockingStateHero.folds(other, into: leading))
    }

    func testSameListsAndNoStricterLockFold() {
        let leading = block([social, video], lock: .password, endIn: 60)
        XCTAssertTrue(BlockingStateHero.folds(block([video, social], lock: .free, endIn: 120), into: leading))
        XCTAssertTrue(BlockingStateHero.folds(block([social, video], lock: .password, endIn: 30), into: leading))
    }

    // R-266 (mineur): VoiceOver names the lists of the « Ensuite » line.
    func testContinuationLabelNamesItsLists() {
        XCTAssertEqual(BlockingStateHero.continuationAccessibilityLabel(lists: ["Réseaux sociaux", "Vidéo"],
                                                                        state: "Bloqué jusqu’à 18:00"),
                       "Ensuite, Réseaux sociaux, Vidéo : bloqué jusqu’à 18:00")
    }
}
#endif
