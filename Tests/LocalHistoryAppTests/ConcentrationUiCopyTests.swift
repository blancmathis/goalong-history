#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// Plan row figures, empty commitment cards and the evening review gate (UI batch u02).
final class ConcentrationUiCopyTests: XCTestCase {
    func testPlanMeasureLineGivesEveryFigureItsUnit() {
        XCTAssertEqual(FocusPlanMeasureText.line(measured: 95.4, estimate: 90), "mesuré 95 min · prévu 90 min")
        XCTAssertEqual(FocusPlanMeasureText.line(measured: nil, estimate: 30), "prévu 30 min")
        XCTAssertEqual(FocusPlanMeasureText.line(measured: 21, estimate: nil), "mesuré 21 min")
    }

    @MainActor func testEmptyCommitmentCardsDifferByPeriod() {
        let day = FocusCommitmentCardView.emptyText(for: .day), week = FocusCommitmentCardView.emptyText(for: .week)
        XCTAssertNotEqual(day, week)
        XCTAssertTrue(day.contains("aujourd’hui")); XCTAssertTrue(week.contains("semaine"))
    }

    @MainActor func testReviewCannotBeSavedWithoutAnyAnswer() {
        typealias Sheet = ConcentrationReviewSheet
        let id = UUID()
        XCTAssertFalse(Sheet.hasAnswer(choices: [id: .unset], tomorrowFirst: "  ", note: "\n", commit: false))
        XCTAssertTrue(Sheet.hasAnswer(choices: [id: .partly], tomorrowFirst: "", note: "", commit: false))
        XCTAssertTrue(Sheet.hasAnswer(choices: [id: .unset], tomorrowFirst: "Relire", note: "", commit: false))
        XCTAssertTrue(Sheet.hasAnswer(choices: [:], tomorrowFirst: "", note: "Bien", commit: false))
        XCTAssertTrue(Sheet.hasAnswer(choices: [id: .unset], tomorrowFirst: "", note: "", commit: true))
    }
}
#endif
