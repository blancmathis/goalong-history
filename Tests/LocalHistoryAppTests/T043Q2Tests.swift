#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-043 lot Q2: the page's 7/28-day bound and the folder it lists.
@MainActor final class T043Q2Tests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func folder(healthDays: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t043q2-\(UUID().uuidString)", isDirectory: true)
        let health = root.appendingPathComponent("health", isDirectory: true)
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        for name in healthDays { try Data("{}".utf8).write(to: health.appendingPathComponent(name)) }
        return root
    }

    /// R272b-2: the imported days are listed in the data folder the model was given (gallery, tests), never in
    /// the real one. Two models, two folders, two answers.
    func testImportedFirstDayIsReadInTheModelsOwnFolder() async throws {
        let withImport = try folder(healthDays: ["2026-10-03.json"])
        let empty = try folder(healthDays: [])
        defer { for root in [withImport, empty] { try? FileManager.default.removeItem(at: root) } }
        let model = GoalongAnalyticsModel(reader: GoalongAnalyticsReader(root: withImport))
        XCTAssertNil(model.importedFirstDay, "nothing listed before the page asks")
        await model.refreshImportedFirstDay(calendar: calendar)
        XCTAssertEqual(model.importedFirstDay, date(3))
        let other = GoalongAnalyticsModel(root: empty)
        await other.refreshImportedFirstDay(calendar: calendar)
        XCTAssertNil(other.importedFirstDay, "an empty injected folder gives no imported day, whatever the real folder holds")
    }

    /// R272b-1: the page steps through the model, which always passes the bound. In 7 days the last step back
    /// ends on first day + 6; in 28 days on first day + 27; nothing earlier. The preview has no bound.
    func testPageStepStopsAtTheFirstDayOfEverySource() async throws {
        let root = try folder(healthDays: ["2026-10-03.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GoalongAnalyticsModel(root: root)
        await model.refreshImportedFirstDay(calendar: calendar)
        let mac = [date(12), date(10)]
        XCTAssertEqual(model.earliestDay(macDays: mac, preview: false, calendar: calendar), date(3))
        XCTAssertNil(model.earliestDay(macDays: mac, preview: true, calendar: calendar))

        let now = date(20, 12)
        var week = GoalongActivityNavigation(day: date(20), period: 1, now: now, calendar: calendar)
        week.selectPeriod(7)
        for _ in 0..<10 { model.step(&week, -1, macDays: mac, preview: false, now: now, calendar: calendar) }
        XCTAssertEqual(week.day, date(9), "last 7-day step back: 3–9 oct.")

        var month = GoalongActivityNavigation(day: date(20), period: 1, now: now, calendar: calendar)
        month.selectPeriod(28)
        for _ in 0..<3 { model.step(&month, -1, macDays: mac, preview: false, now: now, calendar: calendar) }
        XCTAssertEqual(month.day, date(20), "23 sept. – 20 oct. already starts before the 3rd: no step back")

        var preview = GoalongActivityNavigation(day: date(20), period: 1, now: now, calendar: calendar)
        preview.selectPeriod(7)
        for _ in 0..<3 { model.step(&preview, -1, macDays: mac, preview: true, now: now, calendar: calendar) }
        XCTAssertLessThan(preview.day, date(3), "the developer preview is not bounded by the real data")
    }

    /// R8-6: one announcement of the storage cause per screen. When the banner holds the storage slot, no string of the
    /// History page (note, empty title, empty message) says the cause; when the banner shows a stopped recording,
    /// the page keeps it.
    func testHistoryDoesNotRepeatTheCauseTheBannerNames() {
        let since = date(23, 9)
        let kinds: [CaptureStorageFailureKind] = [.diskFull, .permissionDenied, .unavailable]
        for kind in kinds {
            let cause = GoalongActivityEmptyCopy.storageCause(kind)
            let strings = [
                ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: kind, since: since, bannerNamesStorage: true),
                ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: kind, since: nil, bannerNamesStorage: true),
                ComputerHistoryPageCopy.storageEmptyTitle(since: since, bannerNamesStorage: true),
                ComputerHistoryPageCopy.storageEmptyMessage(failure: kind, bannerNamesStorage: true),
            ].compactMap { $0 }
            XCTAssertEqual(strings.count, 4)
            for text in strings {
                XCTAssertFalse(text.contains(cause), text)
                XCTAssertFalse(text.contains("disque est plein") || text.contains("interrompu"), text)
                XCTAssertFalse(text.contains("reprendra") || text.contains("reprise"), "the promise is the banner's: \(text)")
            }
            XCTAssertEqual(ComputerHistoryPageCopy.storageEmptyTitle(since: since, bannerNamesStorage: true),
                           "Aucune donnée depuis \(GoalongUIFormat.time(since))")
            // Another cause in the banner: the page is the only place that says the storage stop.
            XCTAssertEqual(ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: kind, since: since,
                                                                   bannerNamesStorage: false)?.contains(cause), true)
            XCTAssertTrue(ComputerHistoryPageCopy.storageEmptyMessage(failure: kind, bannerNamesStorage: false).contains(cause))
        }
        // The page reads the banner's own slot rule.
        typealias Banner = GoalongAttentionBanner
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: nil, recordingNoticeOnPage: false), .storage)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .input, recordingNoticeOnPage: false), .storage)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .off, recordingNoticeOnPage: false), .recordingCause)
    }

    /// Remarque 2 de R-276: the model publishes only when the value changes.
    func testImportedFirstDayPublishesOnlyOnChange() async throws {
        let root = try folder(healthDays: ["2026-10-03.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GoalongAnalyticsModel(reader: GoalongAnalyticsReader(root: root))
        var changes = 0
        let sub = model.objectWillChange.sink { changes += 1 }
        await model.refreshImportedFirstDay(calendar: calendar)
        XCTAssertEqual(changes, 1)
        await model.refreshImportedFirstDay(calendar: calendar)
        XCTAssertEqual(changes, 1, "same value: no publish")
        sub.cancel()
    }
}
#endif
