#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongAnalyticsPreviewTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 9, day: 18))! }

    func testDeveloperModeIsOffByDefaultAndCanBeExplicitlyEnabledAndDisabled() throws {
        let suite = "analytics-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(GoalongDeveloperPreferences.isEnabled(in: defaults))
        XCTAssertNil(defaults.object(forKey: GoalongDeveloperPreferences.enabledKey))
        defaults.set(true, forKey: GoalongDeveloperPreferences.enabledKey)
        XCTAssertTrue(GoalongDeveloperPreferences.isEnabled(in: defaults))
        defaults.set(false, forKey: GoalongDeveloperPreferences.enabledKey)
        XCTAssertFalse(GoalongDeveloperPreferences.isEnabled(in: defaults))
        XCTAssertTrue(SettingsPane.matches("développeur").contains(.advanced))
        XCTAssertTrue(SettingsPane.matches("mocks").contains(.advanced))
    }
    func testPreviewCoversEveryPeriodAndProjectModuleWithConsistentTotals() {
        for count in [1, 7, 28] {
            let payload = GoalongAnalyticsPreview.make(ending: day, count: count, calendar: calendar, now: day)
            XCTAssertTrue(payload.isPreview)
            XCTAssertEqual(payload.current.days.count, count)
            XCTAssertEqual(payload.previous.days.count, count)
            XCTAssertEqual(payload.current.daysWithObservations, count)
            XCTAssertEqual(payload.current.incompleteDays, 0)
            XCTAssertEqual(payload.current.days.last?.date, day)
            XCTAssertGreaterThan(payload.current.activeSeconds, 0)
            XCTAssertGreaterThan(payload.current.contextChanges, 0)
            XCTAssertGreaterThan(payload.current.usage().count, 6)
            XCTAssertFalse(payload.current.usage(websites: true).isEmpty)
            XCTAssertEqual(payload.current.usage().reduce(0) { $0 + $1.seconds }, payload.current.activeSeconds)
            XCTAssertLessThanOrEqual(payload.current.usage(websites: true).reduce(0) { $0 + $1.seconds }, payload.current.activeSeconds)
            for threshold in [10, 25, 50] {
                XCTAssertGreaterThan(payload.current.focusSeconds(minimumMinutes: threshold), 0)
                XCTAssertLessThanOrEqual(payload.current.focusSeconds(minimumMinutes: threshold), payload.current.activeSeconds)
            }
            XCTAssertEqual(Set(payload.cards.map(\.module)), Set(GoalongProfileAnalysis.modules))
            XCTAssertTrue(payload.cards.allSatisfy { $0.caveat.contains("fictive") })
            for day in payload.current.days {
                XCTAssertEqual(day.segments.reduce(0) { $0 + $1.seconds }, day.end.timeIntervalSince(day.date))
            }
        }
    }
    func testPreviewDatesAreDeterministicAcrossPeriodChanges() {
        let daily = GoalongAnalyticsPreview.make(ending: day, count: 1, calendar: calendar, now: day)
        let weekly = GoalongAnalyticsPreview.make(ending: day, count: 7, calendar: calendar, now: day)
        let monthly = GoalongAnalyticsPreview.make(ending: day, count: 28, calendar: calendar, now: day)
        XCTAssertEqual(daily.current.days.last, weekly.current.days.last)
        XCTAssertEqual(weekly.current.days, Array(monthly.current.days.suffix(7)))
        XCTAssertEqual(daily.previous.days.last, weekly.current.days.dropLast().last)
        XCTAssertEqual(GoalongAnalyticsPreview.make(ending: day, count: 500, calendar: calendar).current.days.count, 7)
    }
    func testSparseChartScalesUseSecondsThenMinutesAndHours() {
        let seconds = GoalongAnalyticsChartScale(maximumSeconds: 7)
        XCTAssertEqual(seconds.unitSeconds, 1)
        XCTAssertEqual(seconds.unit, "s")
        XCTAssertGreaterThan(seconds.upperBound, 7)
        XCTAssertLessThan(seconds.upperBound, 12)
        XCTAssertEqual(GoalongAnalyticsChartScale(maximumSeconds: 300).unit, "min")
        XCTAssertEqual(GoalongAnalyticsChartScale(maximumSeconds: 7200).unit, "h")
        XCTAssertEqual(GoalongAnalyticsChartScale(maximumSeconds: 3600, hourly: true).upperBound, 60)
        XCTAssertGreaterThan(GoalongAnalyticsChartScale(maximumSeconds: 0).upperBound, 0)
        XCTAssertTrue(GoalongAnalyticsChartScale(maximumSeconds: .nan).upperBound.isFinite)
    }
    @MainActor func testPreviewNeverReadsOrCreatesAnArchiveAndReturningClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-no-store-" + UUID().uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let model = GoalongAnalyticsModel(root: root)
        await model.load(day: day, count: 7, preview: true)
        XCTAssertEqual(model.payload?.isPreview, true)
        XCTAssertGreaterThan(model.payload?.current.activeSeconds ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // A normal load is real by default and cannot fall back to fixture data.
        await model.load(day: day, count: 1)
        XCTAssertEqual(model.payload?.isPreview, false)
        XCTAssertEqual(model.payload?.current.activeSeconds, 0)
        XCTAssertTrue(model.payload?.cards.isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testRealSparseJournalAppearsInDailyWeeklyAndMonthlyViews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analytics-sparse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let localCalendar = Calendar.current
        let day = localCalendar.startOfDay(for: Date().addingTimeInterval(-86400))
        let directory = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.calendar = localCalendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = localCalendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let rows = [0, 9, 7].map { second in
            HistoryEvent(id: "fixture-\(second)", sessionID: "fixture", timestamp: day.addingTimeInterval(Double(3600 + second)),
                kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try rows.reduce(into: Data()) { data, row in data.append(try encoder.encode(row)); data.append(10) }
        let file = directory.appendingPathComponent(formatter.string(from: day) + ".jsonl")
        try bytes.write(to: file)
        let model = GoalongAnalyticsModel(root: root)
        for count in [1, 7, 28] {
            await model.load(day: day, count: count)
            XCTAssertEqual(model.payload?.current.activeSeconds, 9)
            XCTAssertEqual(model.payload?.current.daysWithObservations, 1)
            XCTAssertEqual(model.payload?.current.incompleteDays, 0)
            XCTAssertEqual(model.payload?.isPreview, false)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
#endif
