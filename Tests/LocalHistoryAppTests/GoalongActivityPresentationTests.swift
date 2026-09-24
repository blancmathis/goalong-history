#if os(macOS)
import XCTest
import Foundation
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongActivityPresentationTests: XCTestCase {
    private let items: [GoalongActivityUsageItem] = [
        .init(id: "app:editor", name: "Éditeur", bundleIdentifier: "example.editor", isWebsite: false, seconds: 120),
        .init(id: "site:example.org", name: "example.org", bundleIdentifier: nil, isWebsite: true, seconds: 60),
        .init(id: "app:chat", name: "\u{200E}WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", isWebsite: false, seconds: 120)
    ]

    func testNativeAppIdentitySurvivesSearchingAndSorting() {
        let result = GoalongActivityPresentation.usage(items, search: "WHATSAPP", sort: .name)
        XCTAssertEqual(result.map(\.bundleIdentifier), ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(result.first?.displayName, "WhatsApp")
        XCTAssertEqual(result.first?.id, "app:chat")
        XCTAssertEqual(GoalongActivityPresentation.usage(items, search: "example.editor", sort: .duration).count, 1)
    }
    func testSearchSupportsAccentsWhitespaceAndEmptyResults() {
        XCTAssertEqual(GoalongActivityPresentation.usage(items, search: "  editeur  ", sort: .name).first?.id, "app:editor")
        XCTAssertTrue(GoalongActivityPresentation.usage(items, search: "not found", sort: .name).isEmpty)
        XCTAssertEqual(GoalongActivityPresentation.usage(items, search: "   ", sort: .duration).count, 3)
    }
    func testSortKeepsDurationsAndHasStableTies() {
        let result = GoalongActivityPresentation.usage(Array(items.reversed()), search: "", sort: .duration)
        XCTAssertEqual(result.map(\.id), ["app:editor", "app:chat", "site:example.org"])
        XCTAssertEqual(result.reduce(0) { $0 + $1.seconds }, 300)
        XCTAssertEqual(GoalongActivityPresentation.usage(items, search: "", sort: .name).map(\.id),
                       ["app:editor", "site:example.org", "app:chat"])
    }
    func testDisplayNamesRemoveInvisibleDirectionAndControlCharacters() {
        XCTAssertEqual(GoalongActivityPresentation.displayName("\u{200E}WhatsApp\n"), "WhatsApp")
        XCTAssertEqual(GoalongActivityPresentation.displayName("\u{202E}Test\u{202C}"), "Test")
        XCTAssertEqual(GoalongActivityPresentation.displayName(" \n "), "Activité non attribuée")
        XCTAssertEqual(GoalongActivityPresentation.displayName("Éditeur 東京"), "Éditeur 東京")
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c
    }
    private func day(_ date: Date, segments: [GoalongLocalAnalytics.Segment]) -> GoalongLocalAnalytics.Day {
        .init(date: date, end: calendar.date(byAdding: .day, value: 1, to: date)!, state: .ready,
              segments: segments, eventCount: segments.count, classifierVersions: [])
    }
    func testSparseChartCentersOnObservedHoursWithoutChangingTotals() throws {
        let start = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 9, day: 24)))
        let first = start.addingTimeInterval(9 * 3600 + 23 * 60)
        let data = day(start, segments: [
            .init(start: start, end: first, kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil),
            .init(start: first, end: first.addingTimeInterval(7), kind: .unclassified,
                  application: "Test", bundleIdentifier: "example.app", host: nil)
        ])
        let range = GoalongActivityPresentation.chartRange(data, fullDay: false, calendar: calendar)
        XCTAssertEqual(range.lowerBound, start.addingTimeInterval(9 * 3600))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 3 * 3600)
        XCTAssertEqual(data.activeSeconds, 7)
        XCTAssertTrue(range.contains(first))
    }
    func testEmptyChartKeepsWholeDayAndDSTLengths() throws {
        for (month, number, hours) in [(3, 29, 23), (10, 25, 25)] {
            let start = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: month, day: number)))
            let data = day(start, segments: [])
            for full in [false, true] {
                let range = GoalongActivityPresentation.chartRange(data, fullDay: full, calendar: calendar)
                XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), Double(hours * 3600))
            }
        }
    }
    func testLateNightViewportDoesNotInventNextDayCoverage() throws {
        let start = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 9, day: 24)))
        let first = start.addingTimeInterval(23 * 3600 + 40 * 60)
        let data = day(start, segments: [.init(start: first, end: first.addingTimeInterval(60), kind: .work,
            application: "Test", bundleIdentifier: "example.app", host: nil)])
        let range = GoalongActivityPresentation.chartRange(data, fullDay: false, calendar: calendar)
        XCTAssertEqual(range.upperBound, data.end)
        XCTAssertLessThanOrEqual(range.lowerBound, first)
        XCTAssertEqual(data.activeSeconds, 60)
    }
}
#endif
