#if os(macOS)
import Foundation
import Combine
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongActivityTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Paris")!
        return value
    }
    private func date(_ day: Int, month: Int = 9, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func day(_ date: Date, end: Date? = nil, state: GoalongLocalAnalytics.State = .ready,
                     classification: Bool = true, versions: Set<String> = ["fixture"]) -> GoalongLocalAnalytics.Day {
        let start = calendar.startOfDay(for: date)
        let base = start.addingTimeInterval(9 * 3600)
        let activeKind: GoalongLocalAnalytics.Kind = classification ? .work : .unclassified
        let segments: [GoalongLocalAnalytics.Segment] = [
            .init(start: base, end: base.addingTimeInterval(60), kind: activeKind,
                  application: "Navigateur", bundleIdentifier: "fixture.browser", host: "a.example.org"),
            .init(start: base.addingTimeInterval(60), end: base.addingTimeInterval(120), kind: activeKind,
                  application: "Navigateur", bundleIdentifier: "fixture.browser", host: "b.example.org"),
            .init(start: base.addingTimeInterval(120), end: base.addingTimeInterval(150), kind: activeKind,
                  application: "Navigateur", bundleIdentifier: "fixture.browser", host: nil),
            .init(start: base.addingTimeInterval(150), end: base.addingTimeInterval(240), kind: activeKind,
                  application: "Éditeur", bundleIdentifier: "fixture.editor", host: nil),
            .init(start: base.addingTimeInterval(240), end: base.addingTimeInterval(360), kind: .idle,
                  application: nil, bundleIdentifier: nil, host: nil),
            .init(start: base.addingTimeInterval(360), end: base.addingTimeInterval(480), kind: .concealed,
                  application: nil, bundleIdentifier: nil, host: nil)
        ]
        return .init(date: start, end: end ?? calendar.date(byAdding: .day, value: 1, to: start)!,
                     state: state, segments: segments, eventCount: 10, classifierVersions: versions)
    }

    func testNavigationHasOnlyOneActivityDestination() {
        XCTAssertEqual(DashboardSection.primarySections, [.overview, .history, .settings])
        XCTAssertEqual(DashboardSection.overview.simpleTitle, "Activité")
        XCTAssertEqual(DashboardSection.analytics.sidebarParent, .overview)
        XCTAssertEqual(DashboardSection.analytics.simpleTitle, "Activité")
    }

    func testDefaultPeriodIsDay() {
        XCTAssertEqual(GoalongActivityNavigation(day: date(20), calendar: calendar).period, 1)
        XCTAssertEqual(GoalongActivityNavigation(day: date(20), period: 999, calendar: calendar).period, 1)
    }

    func testDayDrillDownRestoresExactPeriodAndAnchor() {
        let original = GoalongActivityNavigation(day: date(20), period: 28, calendar: calendar)
        var selection = original
        selection.openDay(date(12), now: date(20), calendar: calendar)
        XCTAssertEqual(selection.day, date(12))
        XCTAssertEqual(selection.period, 1)
        XCTAssertEqual(selection.returnContext?.period, 28)
        selection.restorePeriod()
        XCTAssertEqual(selection, original)
    }

    func testManualDateOrPeriodSelectionClearsDrillDownReturn() {
        var selection = GoalongActivityNavigation(day: date(20), period: 7, calendar: calendar)
        selection.openDay(date(18), now: date(20), calendar: calendar)
        selection.selectDay(date(17), now: date(20), calendar: calendar)
        XCTAssertNil(selection.returnContext)
        selection.selectPeriod(28)
        selection.openDay(date(12), now: date(20), calendar: calendar)
        selection.selectPeriod(7)
        XCTAssertNil(selection.returnContext)
    }

    func testPeriodArrowsUseCalendarDaysAcrossDaylightSavingTime() {
        var selection = GoalongActivityNavigation(day: date(31, month: 3), period: 7, calendar: calendar)
        let original = selection.day
        selection.step(-1, now: date(20), calendar: calendar)
        XCTAssertEqual(selection.day, date(24, month: 3))
        XCTAssertEqual(original.timeIntervalSince(selection.day), 7 * 86400 - 3600, accuracy: 0.001)
        let interval = GoalongActivityNavigation(day: date(31, month: 3), period: 7, calendar: calendar).interval(calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: interval.start, to: interval.end).day, 7)
    }

    func testFutureNavigationIsClampedAndTodayResetsPeriod() {
        var selection = GoalongActivityNavigation(day: date(20), period: 7, calendar: calendar)
        selection.step(1, now: date(20), calendar: calendar)
        XCTAssertEqual(selection.day, date(20))
        selection.today(now: date(20, hour: 15), calendar: calendar)
        XCTAssertEqual(selection.period, 1)
        XCTAssertEqual(selection.day, date(20))
    }

    func testPreviewNavigationDoesNotMutateRealSelection() {
        let real = GoalongActivityNavigation(day: date(20), period: 7, calendar: calendar)
        var preview = real
        preview.openDay(date(15), now: date(20), calendar: calendar)
        preview.selectPeriod(28)
        XCTAssertEqual(real.day, date(20))
        XCTAssertEqual(real.period, 7)
        XCTAssertNotEqual(preview, real)
    }

    func testPayloadMustMatchDatePeriodAndPreviewMode() {
        let payload = GoalongAnalyticsPreview.make(ending: date(18), count: 7, calendar: calendar, now: date(20))
        let selection = GoalongActivityNavigation(day: date(18), period: 7, calendar: calendar)
        XCTAssertTrue(selection.matches(payload, preview: true, calendar: calendar))
        XCTAssertFalse(selection.matches(payload, preview: false, calendar: calendar))
        XCTAssertFalse(GoalongActivityNavigation(day: date(17), period: 7, calendar: calendar).matches(payload, preview: true, calendar: calendar))
        XCTAssertFalse(GoalongActivityNavigation(day: date(18), period: 1, calendar: calendar).matches(payload, preview: true, calendar: calendar))
    }

    func testSitesReplaceBrowserIntervalsAndBothGroupingsPreserveTotal() {
        let period = GoalongLocalAnalytics.Period(days: [day(date(18))])
        let sites = GoalongActivityProjection.usage(period, grouping: .sites)
        let apps = GoalongActivityProjection.usage(period, grouping: .applications)
        XCTAssertEqual(period.activeSeconds, 240)
        XCTAssertEqual(sites.reduce(0) { $0 + $1.seconds }, 240)
        XCTAssertEqual(apps.reduce(0) { $0 + $1.seconds }, 240)
        XCTAssertEqual(sites.first { $0.id == "app:fixture.browser" }?.seconds, 30)
        XCTAssertEqual(apps.first { $0.id == "app:fixture.browser" }?.seconds, 150)
        XCTAssertEqual(sites.filter(\.isWebsite).reduce(0) { $0 + $1.seconds }, 120)
        XCTAssertFalse(apps.contains(where: \.isWebsite))
    }

    func testUsageDetailsSumToDisplayedTotalsAcrossDays() {
        let period = GoalongLocalAnalytics.Period(days: [day(date(17)), day(date(18))])
        for grouping in GoalongActivityUsageGrouping.allCases {
            for item in GoalongActivityProjection.usage(period, grouping: grouping) {
                XCTAssertEqual(period.days.reduce(0) { $0 + GoalongActivityProjection.seconds(for: item, in: $1, grouping: grouping) }, item.seconds)
            }
        }
    }

    func testUnclassifiedWorkIsNotPresentedAsMeasuredZero() {
        XCTAssertFalse(GoalongActivityProjection.hasClassification(.init(days: [day(date(18), classification: false)])))
        XCTAssertTrue(GoalongActivityProjection.hasClassification(.init(days: [day(date(18))])))
    }

    func testPartialMissingAndChangedClassifierPeriodsAreNotComparable() {
        let previous = GoalongLocalAnalytics.Period(days: [day(date(17))])
        XCTAssertTrue(GoalongActivityProjection.canCompare(.init(days: [day(date(18))]), to: previous, calendar: calendar))
        XCTAssertFalse(GoalongActivityProjection.canCompare(.init(days: [day(date(18), end: date(18, hour: 12))]), to: previous, calendar: calendar))
        XCTAssertFalse(GoalongActivityProjection.canCompare(.init(days: [day(date(18), state: .incomplete)]), to: previous, calendar: calendar))
        XCTAssertFalse(GoalongActivityProjection.canCompare(.init(days: [day(date(18), versions: ["changed"])]), to: previous, calendar: calendar))
        XCTAssertFalse(GoalongActivityProjection.canCompare(.init(days: []), to: previous, calendar: calendar))
    }

    @MainActor func testRealReadsDoNotCreateHistoryOrAnalysisFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GoalongAnalyticsModel(root: root)
        await model.load(day: date(18), count: 7)
        XCTAssertNotNil(model.payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor func testCorruptDailyReportIsReportedAndPreviewSkipsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recaps = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
        try FileManager.default.createDirectory(at: recaps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = Calendar.current.startOfDay(for: date(18))
        let file = ChatGPTRecapPersistence.jsonURL(for: selected, in: recaps)
        let original = Data("{}".utf8)
        try original.write(to: file)
        let model = GoalongAnalyticsModel(root: root)
        await model.load(day: selected, count: 1)
        XCTAssertTrue(model.payload?.archiveNotice?.contains("bilan") == true)
        XCTAssertFalse(model.payload?.cards.contains { $0.module == "dailyRecap" } ?? true)
        await model.load(day: selected, count: 1, preview: true)
        XCTAssertTrue(model.payload?.isPreview == true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testSamePeriodRefreshDoesNotBlankButChangingDateDoes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = GoalongAnalyticsModel(root: root)
        await model.load(day: date(18), count: 7)
        var cleared = false
        let subscription = model.$payload.dropFirst().sink { if $0 == nil { cleared = true } }
        await model.load(day: date(18), count: 7, force: true)
        XCTAssertFalse(cleared)
        await model.load(day: date(17), count: 7)
        XCTAssertTrue(cleared)
        subscription.cancel()
    }
}
#endif
