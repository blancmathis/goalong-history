#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// R11 « textes » (O6–O9): each assertion fails on the text it replaced.
final class R11TextesTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// O6 (R9A-15): the sleep note is two short sentences, not one long line.
    func testSleepNoteIsTwoShortSentences() {
        let label = GoalongHealthLane(status: .partial).sleepLabel
        XCTAssertFalse(label.contains("coupé à minuit dans le fuseau"))
        let sentences = label.split(separator: ".").map(String.init)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences.allSatisfy { $0.count <= 60 }, label)
        XCTAssertTrue(label.contains("minuit"))
    }

    /// O7 (R9A-49): the note help reads as two short sentences.
    func testReviewNoteHelpIsTwoShortSentences() throws {
        XCTAssertEqual(ConcentrationReviewSheet.noteHelp, "Facultative. 500 caractères au plus.")
        XCTAssertFalse(try source("Sources/LocalHistoryApp/Concentration/ConcentrationPanelViews.swift").contains("Facultative, jusqu’à"))
    }

    /// O8 (R9A-52): the « values as is » note is in the header, so every state has it; no footer copy is left.
    func testHealthValuesNoteIsInTheHeaderOnly() throws {
        XCTAssertTrue(GoalongHealthImportSheet.subtitle.contains("telles quelles"))
        XCTAssertFalse(try source("Sources/LocalHistoryApp/GoalongHealthImportSheet.swift").contains("sans note."))
    }

    /// O9 (R9A-53): the slowdown views no longer show a bare « Ralenti » status; « Renoncer » stays.
    func testSlowDownViewsHaveNoBareRalentiStatus() throws {
        XCTAssertNotEqual(SlowDownText.siteStatus, "Ralenti")
        XCTAssertEqual(SlowDownText.appOccurrence(1), "1ʳᵉ ouverture aujourd’hui")
        XCTAssertEqual(SlowDownText.appOccurrence(3), "3ᵉ ouverture aujourd’hui")
        let views = try source("Sources/LocalHistoryApp/Blocking/SlowDownViews.swift")
        XCTAssertFalse(views.contains("Label(\"Ralenti\""))
        XCTAssertFalse(views.contains("\"Ralenti pour la"))
        XCTAssertTrue(views.contains("Renoncer"))
        var slow = BlockList(name: "L"); slow.action = .slowDown
        XCTAssertEqual(BlockingFormat.verb([slow]), "Ralenti")
    }
}
#endif
