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
        // The sentence the member reads: the view adds the full stop, so none may be doubled.
        let shown = GoalongSleepDay.note(label: label)
        XCTAssertFalse(shown.contains(".."), shown)
        XCTAssertTrue(shown.contains("l’import. Données importées"), shown)
        XCTAssertFalse(label.hasSuffix("."))
    }

    /// O6 (review 1, point 2): the developer preview shows the same sleep note as a real import.
    func testDeveloperPreviewUsesTheSleepNote() throws {
        XCTAssertFalse(try source("Sources/LocalHistoryApp/GoalongAnalyticsPreview.swift").contains("réparti à minuit"))
        XCTAssertTrue(try source("Sources/LocalHistoryApp/GoalongAnalyticsPreview.swift").contains("GoalongHealthLane(status: .partial).sleepLabel"))
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
        XCTAssertNotEqual(SlowDownText.siteStatus(ready: false), "Ralenti")
        XCTAssertEqual(SlowDownText.siteStatus(ready: false), "Prenez un instant")
        XCTAssertEqual(SlowDownText.siteStatus(ready: true), "Attente terminée")
        XCTAssertEqual(SlowDownText.attempt(1), "1ʳᵉ tentative d’ouverture aujourd’hui")
        XCTAssertEqual(SlowDownText.attempt(3), "3ᵉ tentative d’ouverture aujourd’hui")
        var feedback = BlockingListFeedback(listID: UUID(), reason: nil, attemptsToday: 2, earnedMinutesToday: 0)
        XCTAssertEqual(feedback.attemptLine, SlowDownText.attempt(2))
        feedback.attemptsToday = 1
        XCTAssertNil(feedback.attemptLine)
        let views = try source("Sources/LocalHistoryApp/Blocking/SlowDownViews.swift")
        XCTAssertFalse(views.contains("Label(\"Ralenti\""))
        XCTAssertFalse(views.contains("\"Ralenti pour la"))
        XCTAssertTrue(views.contains("Renoncer"))
        var slow = BlockList(name: "L"); slow.action = .slowDown
        XCTAssertEqual(BlockingFormat.verb([slow]), "Ralenti")
    }
}
#endif
