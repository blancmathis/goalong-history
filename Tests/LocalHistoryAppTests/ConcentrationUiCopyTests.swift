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
        // A saved review can be edited down to nothing.
        XCTAssertTrue(Sheet.hasAnswer(choices: [id: .unset], tomorrowFirst: "", note: "", commit: false, existing: true))
    }

    /// H31 L4: « Sans fin » cannot lock, so the start button shows no padlock.
    func testOpenSessionDraftShowsNoPadlock() {
        var draft = FocusComposerDraft(); draft.lock = true
        XCTAssertTrue(draft.locks(hasLists: true))
        draft.kind = .free; draft.free = .open
        XCTAssertFalse(draft.locks(hasLists: true))
        XCTAssertFalse(FocusComposerDraft().locks(hasLists: true))
    }

    /// H31 L6: the last end-of-day weekday stays on and says why.
    func testLastEndOfDayWeekdayStaysAndExplains() {
        var settings = FocusSettings(); settings.limits.endMinute = 18 * 60; settings.limits.weekdays = [2]
        let refused = FocusLimitsEditing.toggled(settings, day: 2)
        XCTAssertEqual(refused.settings, settings); XCTAssertEqual(refused.error, "Gardez au moins un jour.")
        let added = FocusLimitsEditing.toggled(settings, day: 3)
        XCTAssertEqual(added.settings.limits.weekdays, [2, 3]); XCTAssertNil(added.error)
        XCTAssertEqual(FocusLimitsEditing.toggled(added.settings, day: 2).settings.limits.weekdays, [3])
    }

    /// H31 L7: the end of the day is a word, not 23:59.
    func testDeadlineSpeaksTheEndOfTheDay() {
        XCTAssertEqual(FocusCommitmentFormat.deadline("23:59"), "la fin de la journée")
        XCTAssertEqual(FocusCommitmentFormat.deadline("12:00"), "12:00")
    }
}
#endif
