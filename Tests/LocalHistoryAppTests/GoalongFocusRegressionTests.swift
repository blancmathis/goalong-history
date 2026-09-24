#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongFocusRegressionTests: XCTestCase {
    func testEveryPreviewDayIncludingWeekendsHasVisibleFocusAtEveryThreshold() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        for dayNumber in 1...30 {
            let date = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 9, day: dayNumber)))
            let payload = GoalongAnalyticsPreview.make(ending: date, count: 1, calendar: calendar, now: date)
            let day = try XCTUnwrap(payload.current.days.first)
            for minimum in [10, 25, 50] {
                let focus = day.focusSeconds(minimumMinutes: minimum)
                XCTAssertGreaterThan(focus, 0, "Preview day \(dayNumber), threshold \(minimum)")
                XCTAssertLessThanOrEqual(focus, day.activeSeconds)
                let hours = day.hours(minimumMinutes: minimum, calendar: calendar)
                XCTAssertEqual(hours.reduce(0) { $0 + $1.focusSeconds }, focus, accuracy: 0.001)
                XCTAssertTrue(hours.contains { $0.focusSeconds > 0 })
                XCTAssertTrue(hours.allSatisfy { $0.focusSeconds <= $0.seconds })
            }
        }
    }

    func testNoFocusIsNotFabricatedForShortRealSequences() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 9, day: 24)))
        let events = (0...60).map { minute in
            HistoryEvent(id: "short-\(minute)", sessionID: "fixture", timestamp: date.addingTimeInterval(Double(minute * 60)),
                kind: .heartbeat,
                app: .init(name: minute % 4 < 2 ? "Editor" : "Browser", bundleIdentifier: nil, processIdentifier: 1),
                metadata: ["idle_seconds": "0"])
        }
        let day = GoalongLocalAnalytics.build(events: events, day: date, now: date.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(day.activeSeconds, 3600)
        XCTAssertEqual(day.focusSeconds(minimumMinutes: 25), 0)
        XCTAssertGreaterThan(day.sequences.count, 1)
    }

    func testAllDisclosureCallSitesUseTheFullRowComponent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/LocalHistoryApp")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        let native = try NSRegularExpression(pattern: #"\bDisclosureGroup\s*(?:\(|\{)"#)
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if url.lastPathComponent == "GoalongDisclosureGroup.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(native.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), url.lastPathComponent)
            count += text.components(separatedBy: "GoalongDisclosureGroup").count - 1
        }
        XCTAssertGreaterThan(count, 30)
    }
}
#endif
