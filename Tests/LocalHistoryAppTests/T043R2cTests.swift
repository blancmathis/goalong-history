#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-043 R2c: displayed texts and the two logic fixes (Health range, 12/24 h cache).
@MainActor
final class T043R2cTests: XCTestCase {
    /// R2c-11: the shown text names « l'enregistrement », not the source's old name; the matched key stays.
    func testComputerHistoryOffMessageUsesTheRecordingWord() {
        struct Failure: Error, CustomStringConvertible { let description = "Computer History is off" }
        let text = GoalongWebsiteSharingModel.readableError(Failure())
        XCTAssertEqual(text, "Activez l’enregistrement pour inclure les sites, ou désactivez Sites web.")
        XCTAssertFalse(text.contains("historique de ce Mac"))
    }

    /// R2c-1: no internal name in the Jev text.
    func testJevInterventionTextHasNoSurveillanceWord() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp/JevInterventionControls.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("la surveillance ne reçoit"))
        XCTAssertTrue(source.contains("Si Jev ne reçoit plus de résultat"))
    }

    /// R2c-9: the login-item hint for « Autorisation requise » (LaunchAtLoginManager.swift:69).
    func testLoginItemApprovalHintNamesTheListEntry() {
        let saved = LaunchAtLoginManager.galleryState
        defer { LaunchAtLoginManager.galleryState = saved }
        LaunchAtLoginManager.galleryState = .requiresApproval
        let hint = LaunchAtLoginManager().statusDetail
        XCTAssertEqual(hint, "Autorisez \(PermissionSetupCopy.macOSListName()) dans \(LoginItemsPanel.path).")
    }

    /// R2c-10: the proposed range ends today, so the day the page shows is inside it. Red on the old code
    /// (through = the day before « today »).
    func testHealthImportDefaultRangeContainsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 20))!
        let range = GoalongHealthImportSheet.defaultRange(now: now, calendar: calendar)
        XCTAssertTrue(calendar.isDate(range.through, inSameDayAs: now))
        XCTAssertEqual(calendar.dateComponents([.day], from: calendar.startOfDay(for: range.from),
                                               to: calendar.startOfDay(for: range.through)).day, 6)
    }

    /// R2c-8: the locale observer clears the cache on the main queue even when the notification is posted from
    /// another thread. Red with `queue: nil` (the closure then runs on the posting thread).
    func testLocaleObserverRunsOnTheMainQueue() {
        let center = NotificationCenter()
        let cleared = expectation(description: "cleared")
        var onMain: Bool?
        let token = GoalongUIFormat.observeLocaleChange(center: center) {
            onMain = Thread.isMainThread
            cleared.fulfill()
        }
        defer { center.removeObserver(token) }
        DispatchQueue.global().async { center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil) }
        wait(for: [cleared], timeout: 5)
        XCTAssertEqual(onMain, true)
    }
}
#endif
