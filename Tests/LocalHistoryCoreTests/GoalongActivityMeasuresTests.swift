import Foundation
import XCTest
@testable import LocalHistoryCore

/// Simulates the agent: each context of a fixture event carrying a legacy work flag gets
/// that verdict (one task, "Projet"). The application itself never decides.
func agentVerdicts(_ events: [HistoryEvent], task: String = "Projet") -> GoalongWorkVerdicts {
    var tracker = GoalongWorkContext.Tracker()
    var values: [String: GoalongWorkAssignment] = [:]
    for event in events {
        guard let key = tracker.context(for: event)?.key, let work = event.classification?.isWork else { continue }
        values[key] = GoalongWorkAssignment(verdict: work ? .work : .other, task: work ? task : nil)
    }
    return GoalongWorkVerdicts(values)
}

func verdicts(_ apps: [String: GoalongWorkVerdict], host: String? = nil, task: String = "Projet") -> GoalongWorkVerdicts {
    GoalongWorkVerdicts(Dictionary(uniqueKeysWithValues: apps.map { app, verdict in
        (GoalongWorkContext.Label(application: app, bundleIdentifier: "fixture." + app, host: host, title: nil).key,
         GoalongWorkAssignment(verdict: verdict, task: verdict == .work ? task : nil))
    }))
}

/// Work verdicts, work blocks, hourly split and the weekday × hour profile are all
/// projections of the same intervals: they must conserve totals and never invent time.
final class GoalongActivityMeasuresTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))! } // a Thursday

    private func event(_ seconds: Double, on date: Date? = nil, app: String = "Editor", bundle: String? = nil,
                       host: String? = nil, work: Bool? = nil) -> HistoryEvent {
        HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: (date ?? day).addingTimeInterval(seconds),
            kind: .heartbeat, app: .init(name: app, bundleIdentifier: bundle ?? "fixture." + app, processIdentifier: 1),
            url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
            classification: .init(category: "fixture", isWork: work, confidence: 0.9, classifierVersion: "fixture-v1"))
    }

    private func minutes(_ range: ClosedRange<Int>, from start: Double, on date: Date? = nil, app: String = "Editor",
                         host: String? = nil, work: Bool? = nil) -> [HistoryEvent] {
        range.map { event(start + Double($0 * 60), on: date, app: app, host: host, work: work) }
    }

    private func build(_ events: [HistoryEvent], on date: Date? = nil) -> GoalongLocalAnalytics.Day {
        let start = date ?? day
        return GoalongLocalAnalytics.build(events: events, day: start, now: start.addingTimeInterval(86400), calendar: calendar)
            .applying(agentVerdicts(events))
    }

    func testWorkVerdictsReclassifyActiveTimeOnlyAndKeepEveryTotal() {
        let events = minutes(0...10, from: 36_000, app: "Browser", host: "chat.example.org")
            + minutes(11...20, from: 36_000, app: "Browser", host: "news.example.com")
            + minutes(21...30, from: 36_000, app: "Messages")
        let raw = build(events)
        XCTAssertEqual(raw.seconds(.work), 0)
        let label = { (app: String, host: String?) in
            GoalongWorkContext.Label(application: app, bundleIdentifier: "fixture." + app, host: host, title: nil).key
        }
        let ruled = raw.applying(GoalongWorkVerdicts([
            label("Messages", nil): GoalongWorkAssignment(verdict: .other),
            label("Browser", "chat.example.org"): GoalongWorkAssignment(verdict: .work, task: "Recherche"),
            label("Browser", "news.example.com"): GoalongWorkAssignment(verdict: .other),
        ]))
        XCTAssertEqual(ruled.activeSeconds, raw.activeSeconds)
        XCTAssertEqual(ruled.segments.reduce(0) { $0 + $1.seconds }, raw.segments.reduce(0) { $0 + $1.seconds })
        XCTAssertEqual(ruled.seconds(.work), 660, "Only the context judged as work counts, not the whole browser")
        XCTAssertEqual(ruled.seconds(.other), raw.activeSeconds - 660)
        XCTAssertEqual(ruled.seconds(.unobserved), raw.seconds(.unobserved))
        XCTAssertEqual(raw.applying(GoalongWorkVerdicts()), raw, "No verdict, no change")
        XCTAssertTrue(zip(ruled.segments, ruled.segments.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    func testWebsiteRuleWinsOverItsBrowserAndMostSpecificHostWins() {
        let rules = GoalongUsageClassificationRules(applications: ["fixture.Browser": .other],
                                                   websites: ["example.org": .other, "docs.example.org": .work])
        XCTAssertEqual(rules.verdict(application: "Browser", bundleIdentifier: "fixture.Browser", host: "docs.example.org"), .work)
        XCTAssertEqual(rules.verdict(application: "Browser", bundleIdentifier: "fixture.Browser", host: "www.example.org"), .other)
        XCTAssertEqual(rules.verdict(application: "Browser", bundleIdentifier: "fixture.Browser", host: "elsewhere.net"), .other)
        XCTAssertNil(rules.verdict(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil))
        XCTAssertEqual(GoalongUsageClassificationRules(applications: ["Notes": .work])
            .verdict(application: "Notes", bundleIdentifier: nil, host: nil), .work)
    }

    func testWorkBlocksTolerateShortDetoursButNotLongOnes() {
        let morning: [HistoryEvent] = minutes(0...30, from: 36_000, work: true)          // 30 min of work
        let detour: [HistoryEvent] = [event(38_000 - 110, app: "Chat", work: false)]      // short detour
        let back: [HistoryEvent] = minutes(0...10, from: 37_980, work: true)             // back to work
        let later: [HistoryEvent] = minutes(0...30, from: 39_600, work: true)            // after a 16 min gap
        let events = morning + detour + back + later
        let result = build(events)
        let blocks = result.workBlocks(minimumMinutes: 25)
        XCTAssertEqual(blocks.count, 2)
        let expected: TimeInterval = 2_490 // 30 min + the 90 s before the detour + 10 min
        XCTAssertEqual(blocks.first?.workSeconds ?? 0, expected, accuracy: 1)
        XCTAssertEqual(result.workBlocks(minimumMinutes: 25, toleranceSeconds: 30).count, 2)
        let blockedWork: TimeInterval = result.workBlocks(minimumMinutes: 1).map(\.workSeconds).reduce(0, +)
        XCTAssertLessThanOrEqual(blockedWork, result.seconds(.work))
    }

    func testHoursSplitActiveTimeByClassAndBoundsIgnoreGaps() {
        let events = minutes(0...20, from: 9 * 3600, work: true) + minutes(21...40, from: 9 * 3600, app: "Video", work: false)
            + minutes(0...5, from: 14 * 3600)
        let result = build(events)
        let hours = result.hours(minimumMinutes: 25, calendar: calendar).filter { $0.seconds > 0 }
        XCTAssertEqual(hours.reduce(0) { $0 + $1.seconds }, result.activeSeconds)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.workSeconds }, result.seconds(.work))
        XCTAssertEqual(hours.reduce(0) { $0 + $1.otherSeconds }, result.seconds(.other))
        XCTAssertEqual(hours.reduce(0) { $0 + $1.unclassifiedSeconds }, result.seconds(.unclassified))
        XCTAssertEqual(result.firstActiveStart, day.addingTimeInterval(9 * 3600))
        XCTAssertEqual(result.lastActiveEnd, day.addingTimeInterval(14 * 3600 + 5 * 60))
    }

    func testWeekdayProfileAveragesObservedDaysAndLeavesUnobservedWeekdaysEmpty() {
        let thursday = day, nextThursday = calendar.date(byAdding: .day, value: 7, to: day)!
        let friday = calendar.date(byAdding: .day, value: 1, to: day)!
        let period = GoalongLocalAnalytics.Period(days: [
            build(minutes(0...60, from: 10 * 3600, on: thursday), on: thursday),
            build(minutes(0...20, from: 10 * 3600, on: nextThursday), on: nextThursday),
            build([], on: friday),
        ])
        let grid = period.averageActiveSecondsByWeekdayAndHour(calendar: calendar)
        let thursdayIndex = calendar.component(.weekday, from: thursday) - 1
        XCTAssertEqual(grid[thursdayIndex]?[10] ?? 0, (3600 + 1200) / 2, accuracy: 1)
        XCTAssertNil(grid[calendar.component(.weekday, from: friday) - 1], "No observation is not a zero")
        XCTAssertEqual(period.activeSecondsByHourOfDay(calendar: calendar).reduce(0, +), period.activeSeconds, accuracy: 1)
    }

    func testSwitchRateUsesActiveTimeAndNeedsAtLeastOneSwitch() {
        let alternating = (0...20).map { event(36_000 + Double($0 * 30), app: $0 % 2 == 0 ? "A" : "B") }
        let period = GoalongLocalAnalytics.Period(days: [build(alternating)])
        XCTAssertEqual(period.contextChanges, 19)
        XCTAssertEqual(period.secondsPerContextChange ?? 0, period.activeSeconds / 19, accuracy: 0.01)
        XCTAssertNil(GoalongLocalAnalytics.Period(days: [build(minutes(0...10, from: 0))]).secondsPerContextChange)
    }

    func testActivityHasItsOwnEvidenceCeilingAboveBusyRealDays() throws {
        XCTAssertGreaterThanOrEqual(ComputerHistoryEvidenceLoadLimits.localAnalytics.maximumRetainedRows, 200_000)
        let asked = ComputerHistoryEvidenceLoadLimits(maximumRetainedRows: 1_000_000, maximumRetainedBytes: .max)
        XCTAssertEqual(asked.validated, .production, "Other projections keep the original ceiling")
        XCTAssertEqual(asked.validated(ceiling: .localAnalytics), .localAnalytics)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analytics-ceiling-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = minutes(0...59, from: 36_000)
        let bytes = try rows.reduce(into: Data()) { data, row in data.append(try encoder.encode(row)); data.append(10) }
        try bytes.write(to: folder.appendingPathComponent("2026-09-10.jsonl"))
        let reader = HistoryLocalStoreReader(rootDirectory: root)
        let small = reader.loadLocalAnalyticsEvidence(start: day, endExclusive: day.addingTimeInterval(86400),
            limits: .init(maximumRetainedRows: 20, maximumRetainedBytes: 64 * 1_024 * 1_024))
        XCTAssertTrue(small.metrics.evidenceBudgetExceeded)
        let full = reader.loadLocalAnalyticsEvidence(start: day, endExclusive: day.addingTimeInterval(86400))
        XCTAssertFalse(full.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(full.events.count, 60)
    }

    func testActivityDecodesRowsInBatchesYetKeepsJournalOrderAndTheFirstBadRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analytics-batches-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        // More rows than one decoding batch, written out of time order like buffered input.
        let rows = (0..<9_000).map { event(36_000 + Double(($0 * 7_919) % 9_000) * 3, app: $0 % 3 == 0 ? "A" : "B") }
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let file = folder.appendingPathComponent("2026-09-10.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = HistoryLocalStoreReader(rootDirectory: root)
        let loaded = reader.loadLocalAnalyticsEvidence(start: day, endExclusive: day.addingTimeInterval(86400))
        XCTAssertTrue(loaded.issues.isEmpty)
        XCTAssertEqual(loaded.events.map(\.id), rows.map(\.id), "Journal order, not time order")
        XCTAssertEqual(loaded.metrics.rawEventCount, rows.count)

        var broken = lines
        broken[5_000] = "{not json"
        broken[7_000] = "{nor this"
        try (broken.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let rejected = reader.loadLocalAnalyticsEvidence(start: day, endExclusive: day.addingTimeInterval(86400))
        XCTAssertTrue(rejected.events.isEmpty)
        XCTAssertTrue(rejected.metrics.sourceAccessWasIncomplete)
        XCTAssertEqual(rejected.issues.compactMap(\.line), [5_001], "Only the first bad row, by its line number")
    }
}
