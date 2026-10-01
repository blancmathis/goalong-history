#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Simulates the agent: each context of a fixture event carrying a legacy work flag gets
/// that verdict (one task, "Projet"). The application itself never decides.
private func agentVerdicts(_ events: [HistoryEvent], task: String = "Projet") -> GoalongWorkVerdicts {
    var tracker = GoalongWorkContext.Tracker()
    var values: [String: GoalongWorkAssignment] = [:]
    for event in events {
        guard let key = tracker.context(for: event)?.key, let work = event.classification?.isWork else { continue }
        values[key] = GoalongWorkAssignment(verdict: work ? .work : .other, task: work ? task : nil)
    }
    return GoalongWorkVerdicts(values)
}

private func verdicts(_ apps: [String: GoalongWorkVerdict], host: String? = nil, task: String = "Projet") -> GoalongWorkVerdicts {
    GoalongWorkVerdicts(Dictionary(uniqueKeysWithValues: apps.map { app, verdict in
        (GoalongWorkContext.Label(application: app, bundleIdentifier: "fixture." + app, host: host, title: nil).key,
         GoalongWorkAssignment(verdict: verdict, task: verdict == .work ? task : nil))
    }))
}

final class GoalongActivityInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day))! }

    private func day(_ number: Int, from start: Double, minutes: Int, app: String = "Editor", host: String? = nil,
                     work: Bool? = nil, now: Date? = nil) -> GoalongLocalAnalytics.Day {
        let base = date(number)
        let events = (0...minutes).map { minute in
            HistoryEvent(id: "\(number)-\(start)-\(minute)", sessionID: "fixture",
                timestamp: base.addingTimeInterval(start + Double(minute * 60)), kind: .heartbeat,
                app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1),
                url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
                classification: .init(category: "fixture", isWork: work, confidence: 0.9, classifierVersion: "fixture-v1"))
        }
        return GoalongLocalAnalytics.build(events: events, day: base,
            now: now ?? base.addingTimeInterval(86400), calendar: calendar).applying(agentVerdicts(events))
    }

    func testTodayIsComparedWithYesterdayAtTheSameClockTime() {
        // Yesterday: 2 h in the morning, 3 h in the evening. Today at 13:00: 2 h 30.
        let yesterdayMorning = day(9, from: 8 * 3600, minutes: 120)
        let evening = day(9, from: 18 * 3600, minutes: 180)
        let yesterday = GoalongLocalAnalytics.Day(date: yesterdayMorning.date, end: yesterdayMorning.end, state: .ready,
            segments: mergedSegments(yesterdayMorning, evening), eventCount: 300, classifierVersions: [])
        let now = date(10).addingTimeInterval(13 * 3600)
        let today = day(10, from: 9 * 3600, minutes: 150, now: now)
        let summary = GoalongActivitySummary(period: .init(days: [today]), previous: .init(days: [yesterday]),
                                             calendar: calendar, now: now)
        let comparison = try? XCTUnwrap(summary.comparison)
        XCTAssertEqual(comparison?.label, "hier à la même heure")
        XCTAssertEqual(comparison?.previous ?? 0, 7200, accuracy: 1, "The evening has not happened yet today")
        XCTAssertEqual(comparison?.current ?? 0, 9000, accuracy: 1)
    }

    func testPeriodsCompareDailyAveragesOfObservedDaysOnly() {
        let current = GoalongLocalAnalytics.Period(days: [day(10, from: 9 * 3600, minutes: 240), GoalongLocalAnalytics.build(
            events: [], day: date(11), now: date(12), calendar: calendar), day(12, from: 9 * 3600, minutes: 120)])
        let previous = GoalongLocalAnalytics.Period(days: [day(7, from: 9 * 3600, minutes: 60),
            day(8, from: 9 * 3600, minutes: 60), day(9, from: 9 * 3600, minutes: 60)])
        let summary = GoalongActivitySummary(period: current, previous: previous, calendar: calendar, now: date(20))
        XCTAssertEqual(summary.averageActivePerDay ?? 0, 3 * 3600, accuracy: 1, "An empty day is not a zero day")
        XCTAssertEqual(summary.comparison?.previous ?? 0, 3600, accuracy: 1)
        XCTAssertEqual(summary.bestDay?.date, date(10))
    }

    func testDailyAverageLeavesOutTodayWhileItIsInProgress() {
        let now = date(12).addingTimeInterval(10 * 3600)
        let current = GoalongLocalAnalytics.Period(days: [day(10, from: 9 * 3600, minutes: 300),
            day(11, from: 9 * 3600, minutes: 300), day(12, from: 9 * 3600, minutes: 30, now: now)])
        let summary = GoalongActivitySummary(period: current, previous: .init(days: []), calendar: calendar, now: now)
        XCTAssertTrue(summary.averageExcludesToday)
        XCTAssertEqual(summary.averageActivePerDay ?? 0, 5 * 3600, accuracy: 1)
        let onlyToday = GoalongActivitySummary(period: .init(days: [day(12, from: 9 * 3600, minutes: 30, now: now)]),
                                               previous: .init(days: []), calendar: calendar, now: now)
        XCTAssertFalse(onlyToday.averageExcludesToday)
        XCTAssertEqual(onlyToday.averageActivePerDay ?? 0, 1800, accuracy: 1)
    }

    func testInsightsAskToClassifyUntilWorkIsMeasurable() {
        let unclassified = GoalongActivitySummary(period: .init(days: [day(10, from: 9 * 3600, minutes: 90)]),
                                                  previous: .init(days: []), calendar: calendar, now: date(20))
        XCTAssertFalse(unclassified.workIsMeasurable)
        XCTAssertTrue(unclassified.insights(topUsage: nil, biggestChange: nil).contains { $0.id == "classify" })

        let classified = GoalongActivitySummary(period: GoalongLocalAnalytics.Period(days: [day(10, from: 9 * 3600, minutes: 90)])
                                                    .applying(verdicts(["Editor": .work])),
                                                previous: .init(days: []), calendar: calendar, now: date(20))
        XCTAssertTrue(classified.workIsMeasurable)
        XCTAssertEqual(classified.workShare, 1, accuracy: 0.001)
        let insights = classified.insights(topUsage: nil, biggestChange: nil)
        XCTAssertTrue(insights.contains { $0.id == "work" && $0.text.contains("plus longue session sur une même tâche") })
        XCTAssertFalse(insights.contains { $0.id == "classify" })
    }

    func testUsageCarriesClassSplitAndPreviousPeriod() {
        let current = GoalongLocalAnalytics.Period(days: [day(10, from: 9 * 3600, minutes: 60, work: true)])
        let previous = GoalongLocalAnalytics.Period(days: [day(9, from: 9 * 3600, minutes: 20, work: true)])
        let item = GoalongActivityProjection.usage(current, grouping: .applications, previous: previous).first
        XCTAssertEqual(item?.workSeconds, 3600)
        XCTAssertEqual(item?.dominantClass, .work)
        XCTAssertEqual(item?.previousSeconds, 1200)
        XCTAssertEqual(GoalongActivitySummary.biggestChange([item!])?.id, item?.id)
        XCTAssertNil(GoalongActivityProjection.usage(current, grouping: .applications).first?.previousSeconds)
    }

    func testSessionsAndHourProfileConserveUsageTime() throws {
        let events = [(9 * 3600.0, 30), (9 * 3600.0 + 31 * 60 + 60, 10), (15 * 3600.0, 20)]
        let base = date(10)
        var rows: [HistoryEvent] = []
        for (start, length) in events {
            for minute in 0...length {
                rows.append(HistoryEvent(id: UUID().uuidString, sessionID: "f", timestamp: base.addingTimeInterval(start + Double(minute * 60)),
                    kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.Editor", processIdentifier: 1)))
            }
            rows.append(HistoryEvent(id: UUID().uuidString, sessionID: "f", timestamp: base.addingTimeInterval(start + Double(length * 60) + 1),
                kind: .recorderStopped))
        }
        let period = GoalongLocalAnalytics.Period(days: [GoalongLocalAnalytics.build(events: rows, day: base,
            now: base.addingTimeInterval(86400), calendar: calendar)])
        let item = try XCTUnwrap(GoalongActivityProjection.usage(period, grouping: .applications).first)
        let sessions = GoalongActivityProjection.sessions(for: item, in: period, grouping: .applications)
        XCTAssertEqual(sessions.count, 2, "A one-minute gap stays in the same session; the afternoon is another")
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.seconds }, item.seconds, accuracy: 1)
        let hours = GoalongActivityProjection.secondsByHour(for: item, in: period, grouping: .applications, calendar: calendar)
        XCTAssertEqual(hours.reduce(0, +), item.seconds, accuracy: 1)
        XCTAssertGreaterThan(hours[9], 0); XCTAssertGreaterThan(hours[15], 0); XCTAssertEqual(hours[12], 0)
    }

    @MainActor func testWorkStoreKeepsCorrectionsAcrossDefinitionsAndDropsStaleAgentVerdicts() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var definition = GoalongWorkDefinition(goals: "Goalong")
        let store = GoalongWorkStore(fileURL: file, definition: { definition })
        let docs = GoalongWorkContext.Label(application: "Browser", bundleIdentifier: "fixture.Browser",
                                            host: "docs.example.org", title: "Swift concurrency")
        let video = GoalongWorkContext.Label(application: "Browser", bundleIdentifier: "fixture.Browser",
                                             host: "video.example.org", title: "Bêtisier")
        store.merge([docs.key: GoalongWorkAssignment(verdict: .work, task: "Goalong"),
                     video.key: GoalongWorkAssignment(verdict: .other)], revision: store.revision, day: "2026-09-10")
        XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "Goalong")
        XCTAssertEqual(store.knownTasks, ["Goalong"])
        store.merge([video.key: GoalongWorkAssignment(verdict: .work, task: "X")], revision: "stale", day: "2026-09-10")
        XCTAssertEqual(store.verdicts.assignment(for: video.key)?.verdict, .other, "An answer for an older definition is ignored")

        store.correct(key: video.key, label: video, verdict: .work, task: "Veille", day: "2026-09-10")
        store.merge([video.key: GoalongWorkAssignment(verdict: .other)], revision: store.revision, day: "2026-09-10")
        XCTAssertEqual(store.verdicts.assignment(for: video.key)?.task, "Veille", "The user's correction always wins")
        XCTAssertEqual(store.examples.map(\.title), ["Bêtisier"])
        var status = stat()
        XCTAssertEqual(lstat(file.path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o600)

        definition = GoalongWorkDefinition(goals: "Goalong et Atlas")
        let reloaded = GoalongWorkStore(fileURL: file, definition: { definition })
        XCTAssertNil(reloaded.verdicts.assignment(for: docs.key), "A new definition drops the agent's verdicts")
        XCTAssertEqual(reloaded.verdicts.assignment(for: video.key)?.byOwner, true)
        reloaded.renameTask("Veille", to: "Goalong")
        XCTAssertEqual(reloaded.verdicts.assignment(for: video.key)?.task, "Goalong")
        reloaded.correct(key: video.key, label: video, verdict: nil, task: nil, day: "2026-09-10")
        XCTAssertNil(reloaded.verdicts.assignment(for: video.key))
        XCTAssertTrue(reloaded.examples.isEmpty)
    }

    func testCSVExportHasOneRowPerDayAndUsageAndNeutralisesFormulas() {
        let hostile = day(10, from: 9 * 3600, minutes: 10, app: "=HYPERLINK(\"x\";\"y\")")
        let second = day(11, from: 9 * 3600, minutes: 30, app: "Editor", work: true)
        let csv = GoalongActivityExport.csv(period: .init(days: [hostile, second]), grouping: .sites, calendar: calendar)
        let lines = csv.split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.first, GoalongActivityExport.header.joined(separator: ";"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("2026-09-10;application;\"'=HYPERLINK"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("2026-09-11;application;Editor;fixture.Editor;travail;1800;1800;0;0"), lines[2])
    }

    private func mergedSegments(_ a: GoalongLocalAnalytics.Day, _ b: GoalongLocalAnalytics.Day) -> [GoalongLocalAnalytics.Segment] {
        // Keep the morning, then the evening activity; everything else stays unobserved.
        let active = (a.segments + b.segments).filter { $0.kind.isActive }.sorted { $0.start < $1.start }
        var result: [GoalongLocalAnalytics.Segment] = []
        var cursor = a.date
        for segment in active {
            if segment.start > cursor {
                result.append(.init(start: cursor, end: segment.start, kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil))
            }
            result.append(segment); cursor = segment.end
        }
        result.append(.init(start: cursor, end: a.end, kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil))
        return result
    }
}
#endif
