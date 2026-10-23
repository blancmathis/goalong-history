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

    func testChartAverageIsTheHeadlineAverageWithoutToday() throws {
        let now = date(12).addingTimeInterval(10 * 3600)
        let current = GoalongLocalAnalytics.Period(days: [day(10, from: 9 * 3600, minutes: 300),
            day(11, from: 9 * 3600, minutes: 300), day(12, from: 9 * 3600, minutes: 30, now: now)])
        let summary = GoalongActivitySummary(period: current, previous: .init(days: []), calendar: calendar, now: now)
        let line = try XCTUnwrap(GoalongDailyClassChart.averageLine(for: summary))
        XCTAssertEqual(line.value, summary.averageActivePerDay ?? -1, accuracy: 0.001)
        XCTAssertNotEqual(line.value, current.activeSeconds / Double(current.observedDays.count), accuracy: 1)
        XCTAssertTrue(line.excludesToday)
        // One completed day is not enough for a rule.
        let single = GoalongActivitySummary(period: .init(days: [day(11, from: 9 * 3600, minutes: 300), day(12, from: 9 * 3600, minutes: 30, now: now)]),
                                            previous: .init(days: []), calendar: calendar, now: now)
        XCTAssertNil(GoalongDailyClassChart.averageLine(for: single))
    }

    func testHeadlineComparisonNamesTheDailyAverageOverSeveralDays() throws {
        let comparison = GoalongActivitySummary.Comparison(current: 5 * 3600, previous: 3600, label: "les 7 jours précédents")
        XCTAssertTrue(try XCTUnwrap(comparison.headlineLine(isDay: false)).contains("par jour par rapport aux 7 jours précédents"))
        let dayLine = GoalongActivitySummary.Comparison(current: 5 * 3600, previous: 3600, label: "la veille")
        XCTAssertFalse(try XCTUnwrap(dayLine.headlineLine(isDay: true)).contains("par jour"))
        XCTAssertNil(GoalongActivitySummary.Comparison(current: 100, previous: 90, label: "la veille").headlineLine(isDay: true))
    }

    func testManualClassifyTargetsTheLatestUnclassifiedReadyDayOfAPeriod() {
        let days = [day(10, from: 9 * 3600, minutes: 90), day(11, from: 9 * 3600, minutes: 90),
                    day(12, from: 9 * 3600, minutes: 90, work: true)]
        XCTAssertEqual(days.map { $0.seconds(.unclassified) >= 120 }, [true, true, false])
        XCTAssertEqual(GoalongWorkAgent.manualTarget(days: days, fallback: date(12)), date(11))
        XCTAssertEqual(GoalongWorkAgent.manualTarget(days: [days[2], days[2]], fallback: date(12)), date(12), "Nothing to classify: the fallback")
        XCTAssertEqual(GoalongWorkAgent.manualTarget(days: [days[0]], fallback: date(12)), date(12), "A single day keeps the selected day")
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
        XCTAssertTrue(store.merge([video.key: GoalongWorkAssignment(verdict: .work, task: "X")], revision: "stale", day: "2026-09-10").isEmpty,
                      "Nothing is reported as classified for an older definition")
        XCTAssertEqual(store.verdicts.assignment(for: video.key)?.verdict, .other, "An answer for an older definition is ignored")

        store.correct(key: video.key, label: video, verdict: .work, task: "Veille", day: "2026-09-10")
        let applied = store.merge([video.key: GoalongWorkAssignment(verdict: .other), docs.key: GoalongWorkAssignment(verdict: .other)],
                                  revision: store.revision, day: "2026-09-10")
        XCTAssertEqual(Array(applied.keys), [docs.key], "Only the verdicts actually stored are counted")
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

    @MainActor func testUnreadableWorkFileIsKeptAsideNeverOverwritten() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("work-damaged-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("work-classification.json")
        let label = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
        for broken in ["{\"version\":2,\"entries\":{}}", "{tronqué"] {
            try Data(broken.utf8).write(to: file)
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
            XCTAssertNotNil(store.storageNotice)
            let kept = try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("work-classification.damaged-") }
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(kept[0]), encoding: .utf8), broken)
            store.correct(key: label.key, label: label, verdict: .work, task: nil, day: "2026-09-10")
            XCTAssertNil(store.lastError)
            XCTAssertNil(GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }).storageNotice)
            for name in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(at: folder.appendingPathComponent(name)) }
        }

        // The file cannot be moved aside: nothing is written over it.
        try Data("{tronqué".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let blocked = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        XCTAssertNotNil(blocked.storageNotice)
        blocked.correct(key: label.key, label: label, verdict: .work, task: nil, day: "2026-09-10")
        XCTAssertNotNil(blocked.lastError)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{tronqué")

        // Once the file can be moved aside, the next change is saved without a relaunch.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let other = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil, title: "Boîte")
        blocked.correct(key: other.key, label: other, verdict: .other, task: nil, day: "2026-09-10")
        XCTAssertNil(blocked.lastError)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("work-classification.damaged-") }.count, 1)
        XCTAssertEqual(Set(GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }).corrections.map(\.key)),
                       [label.key, other.key])
        for name in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(at: folder.appendingPathComponent(name)) }

        // Deleted by the user, as the notice says: writing resumes.
        try Data("{tronqué".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let deleted = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fm.removeItem(at: file)
        deleted.correct(key: label.key, label: label, verdict: .work, task: nil, day: "2026-09-10")
        XCTAssertNil(deleted.lastError); XCTAssertNil(deleted.storageNotice)
        XCTAssertEqual(GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }).corrections.map(\.key), [label.key])

        // Repaired by the user: its corrections and its automatic switch stay, the new one is added.
        // The agent classed the corrected context meanwhile, from an empty file: the correction still wins (B02-R2-01).
        try Data("{tronqué".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let repaired = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        repaired.merge([label.key: GoalongWorkAssignment(verdict: .other, task: nil, byOwner: false)],
                       revision: repaired.revision, day: "2026-09-11")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fm.removeItem(at: file)
        let source = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        source.correct(key: label.key, label: label, verdict: .work, task: nil, day: "2026-09-10")
        source.automatic = false
        repaired.correct(key: other.key, label: other, verdict: .other, task: nil, day: "2026-09-11")
        XCTAssertNil(repaired.lastError); XCTAssertNil(repaired.storageNotice)
        XCTAssertFalse(repaired.automatic)
        XCTAssertEqual(repaired.verdicts.assignment(for: label.key)?.byOwner, true)
        let reread = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        XCTAssertEqual(Set(reread.corrections.map(\.key)), [label.key, other.key])
        XCTAssertEqual(reread.entry(for: label.key)?.verdict, .work); XCTAssertEqual(reread.entry(for: label.key)?.byOwner, true)
        XCTAssertFalse(reread.automatic)
        for name in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(at: folder.appendingPathComponent(name)) }

        // Switched while the file was unreadable: the user's newer choice stays after the repair.
        try Data("{tronqué".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let switched = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        switched.automatic = false
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fm.removeItem(at: file)
        GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
            .correct(key: label.key, label: label, verdict: .work, task: nil, day: "2026-09-10")
        switched.correct(key: other.key, label: other, verdict: .other, task: nil, day: "2026-09-11")
        XCTAssertNil(switched.lastError)
        XCTAssertFalse(GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }).automatic)
    }

    @MainActor func testFullHistoryClearErasesWorkCorrectionsAndTheirTitles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        let bank = GoalongWorkContext.Label(application: "Browser", bundleIdentifier: "fixture.Browser",
                                            host: "bank.example.org", title: "Relevé de compte")
        store.correct(key: bank.key, label: bank, verdict: .other, task: nil, day: "2026-09-10")
        store.automatic = false
        let revision = store.revision
        store.removeAll()
        XCTAssertTrue(store.corrections.isEmpty); XCTAssertTrue(store.verdicts.isEmpty)
        let reloaded = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
        XCTAssertTrue(reloaded.corrections.isEmpty)
        XCTAssertEqual(reloaded.revision, revision); XCTAssertFalse(reloaded.automatic)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Relevé"), "No title stays on disk")

        // Unreadable copies hold the same titles: the full clear erases them too.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("work-clear-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); try? fm.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("work-classification.json")
        let titled = Data("{\"corrections\":[{\"label\":{\"title\":\"Relevé de compte\",\"host\":\"bank.example.org\"".utf8)
        try titled.write(to: saved)
        let asideStore = GoalongWorkStore(fileURL: saved, definition: { GoalongWorkDefinition(goals: "Goalong") })
        XCTAssertNotNil(asideStore.storageNotice)
        asideStore.removeAll()
        XCTAssertNil(asideStore.lastError); XCTAssertNil(asideStore.storageNotice)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), ["work-classification.json"])
        XCTAssertFalse(try String(contentsOf: saved, encoding: .utf8).contains("Relevé"))

        // Left in place (folder read-only at launch), then deletable: the full clear removes it.
        try titled.write(to: saved)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let blocked = GoalongWorkStore(fileURL: saved, definition: { GoalongWorkDefinition(goals: "Goalong") })
        blocked.removeAll()
        XCTAssertNotNil(blocked.lastError, "A file that cannot be erased is reported")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        blocked.removeAll()
        XCTAssertNil(blocked.lastError); XCTAssertNil(blocked.storageNotice)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), ["work-classification.json"])
        XCTAssertFalse(try String(contentsOf: saved, encoding: .utf8).contains("Relevé"))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if cutoff == nil {\n                    // Work corrections keep window titles"),
                      "Only the full clear erases the work corrections")
        XCTAssertTrue(source.contains("GoalongWorkStore.shared.removeAll()"))
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

    func testCSVExportKeepsOneRowForEveryDayWithoutUsage() {
        // R5-historique-02: incomplete, unrecorded and empty days used to vanish from the file.
        let active = day(10, from: 9 * 3600, minutes: 10, app: "Editor", work: true)
        let incomplete = GoalongLocalAnalytics.build(events: [], day: date(11), now: date(13), calendar: calendar, incomplete: true)
        let missing = GoalongLocalAnalytics.build(events: [], day: date(12), now: date(13), calendar: calendar)
        let future = GoalongLocalAnalytics.build(events: [], day: date(14), now: date(13), calendar: calendar)
        let csv = GoalongActivityExport.csv(period: .init(days: [active, incomplete, missing, future]), grouping: .sites,
                                            calendar: calendar, now: date(13).addingTimeInterval(3600))
        let lines = csv.split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 4, csv)
        XCTAssertTrue(lines[1].hasPrefix("2026-09-10;application;Editor;"), lines[1])
        XCTAssertEqual(lines[2], "2026-09-11;jour;;;incomplet;;;;")
        XCTAssertEqual(lines[3], "2026-09-12;jour;;;\(missing.state == .ready ? "sans activité;0;0;0;0" : "sans données;;;;")")
        XCTAssertFalse(csv.contains("2026-09-14"), "A future day is not exported")
    }

    func testPageLeftOnTodayFollowsTheNewDayAtMidnight() {
        // R5-historique-03: at 00:10 the page left open on « aujourd’hui » at 23:50 showed the old day.
        let evening = date(10).addingTimeInterval(23 * 3600 + 50 * 60), after = date(11).addingTimeInterval(600)
        var onToday = GoalongActivityNavigation(day: evening, now: evening, calendar: calendar)
        XCTAssertFalse(onToday.followToday(now: evening.addingTimeInterval(60), calendar: calendar))
        XCTAssertEqual(onToday.day, date(10))
        XCTAssertTrue(onToday.followToday(now: after, calendar: calendar))
        XCTAssertEqual(onToday.day, date(11))
        XCTAssertFalse(onToday.followToday(now: after.addingTimeInterval(60), calendar: calendar), "Followed once")

        var past = GoalongActivityNavigation(day: evening, now: evening, calendar: calendar)
        past.selectDay(date(8), now: evening, calendar: calendar)
        XCTAssertTrue(past.followToday(now: after, calendar: calendar))
        XCTAssertEqual(past.day, date(8), "A past day chosen by the user stays")

        // A week ending today keeps its period and moves too.
        var week = GoalongActivityNavigation(day: evening, period: 7, now: evening, calendar: calendar)
        week.followToday(now: after, calendar: calendar)
        XCTAssertEqual(week.day, date(11)); XCTAssertEqual(week.period, 7)
    }

    func testNavigationRebuiltPageStillFollowsTodayAfterMidnight() {
        // B05-R1-01: the page is rebuilt on each section change and used to learn the new day on
        // return, so the shown day never moved. The navigation itself remembers the day it saw.
        let evening = date(10).addingTimeInterval(23 * 3600 + 50 * 60), after = date(11).addingTimeInterval(600)
        var navigation = GoalongActivityNavigation(day: evening, now: evening, calendar: calendar)
        navigation.openDay(evening, now: evening, calendar: calendar)
        // No call while the user is on Travail; the page reappears at 00:10.
        XCTAssertTrue(navigation.followToday(now: after, calendar: calendar))
        XCTAssertEqual(navigation.day, date(11))

        // A day opened from a week keeps its way back, moved to the new week too.
        var fromWeek = GoalongActivityNavigation(day: evening, period: 7, now: evening, calendar: calendar)
        fromWeek.openDay(date(9), now: evening, calendar: calendar)
        fromWeek.followToday(now: after, calendar: calendar)
        XCTAssertEqual(fromWeek.day, date(9))
        fromWeek.restorePeriod()
        XCTAssertEqual(fromWeek.day, date(11)); XCTAssertEqual(fromWeek.period, 7)
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
