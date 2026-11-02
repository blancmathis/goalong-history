#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-043 R2, tour 2: the two blockers of the PR #284 review.
@MainActor
final class T043R2Tour2Tests: XCTestCase {
    override func tearDown() { GoalongUIFormat.twelveHourOverride = nil; super.tearDown() }

    /// « Fin de journée » is filled with the system short time; with the 12 h clock it reads « 6:30 PM »
    /// and must be read back, else no limit can be saved any more.
    func testEndOfDayTypedInTwelveHourClockIsReadBack() {
        GoalongUIFormat.twelveHourOverride = true
        let shown = BlockingFormat.minuteOfDay(18 * 60 + 30)
        XCTAssertEqual(shown, "6:30 PM")
        XCTAssertEqual(FocusUIFormat.minute(shown), 18 * 60 + 30)
        XCTAssertEqual(FocusUIFormat.minute("6:30pm"), 18 * 60 + 30)
        XCTAssertEqual(FocusUIFormat.minute("6 PM"), 18 * 60)
        XCTAssertEqual(FocusUIFormat.minute("12:15 AM"), 15)
        XCTAssertEqual(FocusUIFormat.minute("12:15 PM"), 12 * 60 + 15)
        XCTAssertNil(FocusUIFormat.minute("13:00 PM"))
        XCTAssertNil(FocusUIFormat.minute("0:30 AM"))
        // 24 h entries still work whatever the clock.
        XCTAssertEqual(FocusUIFormat.minute("18:30"), 18 * 60 + 30)
        XCTAssertEqual(FocusUIFormat.minute("18h30"), 18 * 60 + 30)
    }

    /// The whole save path: the field filled in 12 h, then committed, saves the end of day and the other limits.
    func testLimitsSaveWhenTheEndOfDayFieldIsInTwelveHourClock() {
        GoalongUIFormat.twelveHourOverride = true
        let shown = BlockingFormat.minuteOfDay(18 * 60)
        guard case .save(let saved) = FocusLimitsEditing.committed(FocusSettings(), daily: "8", weekly: "40", end: shown) else {
            return XCTFail("« \(shown) » not saved")
        }
        XCTAssertEqual(saved.limits.endMinute, 18 * 60)
        XCTAssertEqual(saved.limits.dailyHours, 8)
        XCTAssertEqual(saved.limits.weeklyHours, 40)
        XCTAssertEqual(FocusLimitsEditing.committed(FocusSettings(), daily: "", weekly: "", end: "25:00 PM"),
                       .error("Fin de journée : écrivez l’heure au format 6:30 PM."))
    }

    /// Health import: numbers go through the French formatter (« 8 100 », never « 8100 »).
    func testHealthCountsAreGrouped() {
        XCTAssertEqual(GoalongHealthImportSheet.formatted(["value": 8100.0, "unit": "count"]), "8\u{202F}100")
    }

    /// Glossary § 0: when the text sends the user to a macOS list, it names the app as that list shows it.
    func testPermissionMessagesNameTheMacOSListEntry() {
        let listName = PermissionSetupCopy.macOSListName()
        XCTAssertNotEqual(listName, "Goalong")
        for status in [SourceAccessStatus.accessibility, .inputMonitoring, .fullDiskAccess] {
            XCTAssertTrue(status.message.contains("Autorisez \(listName) dans"), "\(status): \(status.message)")
        }
        var guardWaiting = BlockingProtectionState(); guardWaiting.guardian = .awaitingApproval
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(guardWaiting),
                       "Autorisez \(listName) dans \(LoginItemsPanel.path).")
    }
}
#endif
