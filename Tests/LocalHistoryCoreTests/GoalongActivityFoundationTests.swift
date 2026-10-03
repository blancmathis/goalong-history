import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongActivityFoundationTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))! }
    private func event(_ seconds: Double, kind: EventKind = .heartbeat, evidence: String? = nil,
                       suppression: SuppressionReason? = nil, metadata: [String: String] = [:]) -> HistoryEvent {
        var m = metadata
        if let evidence { m[ForegroundActivityEvidence.metadataKey] = evidence }
        return HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(seconds), kind: kind,
            app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1),
            window: .init(title: "PRIVATE WINDOW TITLE", role: nil, subrole: nil),
            url: .init(value: "https://example.test/private?token=PRIVATE", host: "example.test", redactionApplied: true),
            suppressionReason: suppression, metadata: m)
    }
    private func root() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-foundations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: r.appendingPathComponent("events"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]); addTeardownBlock { try? FileManager.default.removeItem(at: r) }; return r
    }
    private func journal(_ rows: [HistoryEvent], root: URL, day date: Date? = nil) throws -> URL {
        let file = root.appendingPathComponent("events/" + GoalongActivityDayStore.dayKey(date ?? day, calendar: calendar) + ".jsonl")
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        var bytes = Data(); for row in rows { bytes.append(try e.encode(row)); bytes.append(10) }
        try bytes.write(to: file); return file
    }
    func testBreakdownPartitionsActiveSecondsAndPrecedenceWithIdleAndGap() {
        let rows = [event(0), event(60, kind: .mouseClick), event(120, kind: .typingBurst),
            event(180, kind: .keyboardShortcut, evidence: "media_playback"), event(240, kind: .scrollBurst, evidence: "call"),
            event(300, evidence: "display_assertion"), event(360, metadata: ["idle_seconds": "3600"]),
            event(420, metadata: ["idle_seconds": "3600"]), event(900), event(960)]
        let value = GoalongLocalAnalytics.build(events: rows, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(value.breakdown.totalSeconds, value.activeSeconds)
        XCTAssertEqual(value.breakdown.seconds(.reading), 120)
        for mode in [GoalongActivityBreakdown.Mode.pointer, .keyboard, .media, .call, .display] {
            XCTAssertEqual(value.breakdown.seconds(mode), 60, "\(mode)")
        }
        XCTAssertEqual(value.seconds(.idle), 60)
        XCTAssertEqual(value.breakdown.hours.first?.totalSeconds, 420)
        XCTAssertEqual(GoalongLocalAnalytics.Period(days: [value, value]).breakdown.totalSeconds, value.activeSeconds * 2)
        let key = value.segments.compactMap(\.contextKey).first!
        let classified = value.applying(.init([key: .init(verdict: .work, task: "Project")]))
        XCTAssertEqual(classified.breakdown, value.breakdown)
        XCTAssertEqual(classified.breakdown.totalSeconds, classified.activeSeconds)
    }
    func testMinutePrecedenceAppliesToEveryActivePartOfMinute() {
        let rows = [event(0, kind: .mouseClick), event(10, kind: .typingBurst), event(20, evidence: "display_assertion"),
            event(30, evidence: "media_playback"), event(40, evidence: "call"), event(60)]
        let value = GoalongLocalAnalytics.build(events: rows, day: day, now: day.addingTimeInterval(100), calendar: calendar)
        XCTAssertEqual(value.breakdown.seconds(.call), 60)
        XCTAssertEqual(value.breakdown.totalSeconds, value.activeSeconds)
    }
    func testPresenceExpiryAndFractionalMinuteAndHourBoundariesConserveDuration() {
        var rows: [HistoryEvent] = []
        for i in 0...12 { rows.append(event(3545.25 + Double(i) * 22.5, kind: i % 3 == 0 ? .typingBurst : .heartbeat,
            metadata: [ForegroundUsageObservation.policyKey: ForegroundUsageObservation.policyVersion,
                ForegroundUsageObservation.visibleKey: "true", ForegroundUsageObservation.idleLimitKey: "120", "idle_seconds": "115"])) }
        let value = GoalongLocalAnalytics.build(events: rows, day: day, now: day.addingTimeInterval(5000), calendar: calendar)
        XCTAssertEqual(value.activeSeconds, 60)
        XCTAssertEqual(value.breakdown.totalSeconds, value.activeSeconds)
        XCTAssertEqual(value.breakdown.hours.count, 2)
    }
    func testCoverageReasonsDoNotMergeDistinctHiddenIntervals() {
        let value = GoalongLocalAnalytics.build(events: [event(30, suppression: .privateBrowserWindow),
            event(60, suppression: .excludedApplication), event(90), event(120, kind: .systemSleep), event(600)],
            day: day, now: day.addingTimeInterval(900), calendar: calendar)
        XCTAssertEqual(value.segments.map(\.coverageReason), [.beforeFirstObservation, .privateBrowsing, .excludedApplication, nil, .sleep, .afterLastObservation])
        XCTAssertEqual(value.coverage.secondsByReason[.sleep], 480)
        XCTAssertEqual(value.coverage.concealedSeconds, 60)
        XCTAssertEqual(value.coverage.concealedSecondsByReason.values.reduce(0,+), value.seconds(.concealed))
        XCTAssertEqual(value.coverage.unobservedSecondsByReason.values.reduce(0,+), value.seconds(.unobserved))
        XCTAssertEqual(value.coverage.firstObservation, day.addingTimeInterval(30))
        XCTAssertEqual(value.coverage.lastObservation, day.addingTimeInterval(600))
        XCTAssertEqual(value.coverage.secondsByReason.values.reduce(0,+), value.seconds(.concealed) + value.seconds(.unobserved))
        let incomplete = GoalongLocalAnalytics.build(events: [], day: day, now: day.addingTimeInterval(900), calendar: calendar, incomplete: true)
        XCTAssertEqual(incomplete.dayReason, .unreadable)
    }
    func testAllExplicitCoverageOpenersAndReportedGap() {
        let reasons: [(EventKind, SuppressionReason?, GoalongCoverageReason)] = [
            (.recorderStopped, nil, .recorderStopped), (.recordingPaused, nil, .paused), (.sessionLocked, nil, .locked),
            (.historyCleared, nil, .historyCleared), (.secureInputSuppressed, nil, .secureInput),
            (.heartbeat, .excludedDomain, .excludedDomain), (.heartbeat, .secureInput, .secureInput),
            (.heartbeat, .sessionUnavailable, .sessionUnavailable), (.heartbeat, .accessibilityUnavailable, .accessibility)]
        for (kind, suppression, reason) in reasons {
            let value = GoalongLocalAnalytics.build(events: [event(0, kind: kind, suppression: suppression), event(60)],
                day: day, now: day.addingTimeInterval(90), calendar: calendar)
            XCTAssertEqual(value.segments.first?.coverageReason, reason)
        }
        let gap = GoalongLocalAnalytics.build(events: [event(0), event(60, metadata: ["observation_gap": "true"])],
            day: day, now: day.addingTimeInterval(90), calendar: calendar)
        XCTAssertEqual(gap.segments.first?.coverageReason, .observationGap)
    }
    func testSummaryRestoresAfterPurgeWithoutTitleURLOrTaskAndHasPrivatePermissions() throws {
        let root = try root(), now = day.addingTimeInterval(2 * 86400), store = GoalongActivityDayStore(root: root)
        let file = try journal([event(0, kind: .typingBurst), event(60), event(120, evidence: "call"), event(180)], root: root)
        let source = store.load(day: day, now: now, calendar: calendar)
        XCTAssertEqual(source.origin, .journal)
        let bytes = try Data(contentsOf: root.appendingPathComponent("activity-days/2026-08-10.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        var status = stat(); XCTAssertEqual(lstat(root.appendingPathComponent("activity-days/2026-08-10.json").path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        try FileManager.default.removeItem(at: file)
        let saved = store.load(day: day, now: now, calendar: calendar)
        XCTAssertEqual(saved.origin, .summary); XCTAssertFalse(saved.hasDetailedSource)
        XCTAssertEqual(saved.activeSeconds, source.activeSeconds)
        XCTAssertEqual(saved.breakdown, source.breakdown); XCTAssertEqual(saved.segments, source.segments)
        XCTAssertEqual(saved.coverage.summaryDays, 1)
    }
    func testRevisionMismatchRebuildsSummaryAndCorruptSummaryRebuildsOnlyWithJournal() throws {
        let root = try root(), now = day.addingTimeInterval(2 * 86400), store = GoalongActivityDayStore(root: root)
        let file = try journal([event(0), event(60)], root: root)
        XCTAssertEqual(store.load(day: day, now: now, calendar: calendar).activeSeconds, 60)
        _ = try journal([event(0), event(60), event(120)], root: root)
        XCTAssertEqual(store.load(day: day, now: now, calendar: calendar).activeSeconds, 120)
        XCTAssertEqual(try store.read(day: day, sourceRevision: store.sourceRevision(day: day, calendar: calendar), calendar: calendar).activeSeconds, 120)
        try Data("broken".utf8).write(to: root.appendingPathComponent("activity-days/2026-08-10.json"))
        XCTAssertEqual(store.load(day: day, now: now, calendar: calendar).activeSeconds, 120)
        try FileManager.default.removeItem(at: file)
        try Data("broken".utf8).write(to: root.appendingPathComponent("activity-days/2026-08-10.json"))
        XCTAssertEqual(store.load(day: day, now: day.addingTimeInterval(60 * 86400), calendar: calendar).dayReason, .purgedWithoutSummary)
    }
    func testBackfillFindsMissingPastDaysNeverTodayAndIsCancellable() throws {
        let root = try root(), store = GoalongActivityDayStore(root: root)
        _ = try journal([event(0), event(60)], root: root)
        let nextDay = day.addingTimeInterval(86400)
        _ = try journal([event(0), event(60)].map {
            HistoryEvent(sessionID: "fixture", timestamp: $0.timestamp.addingTimeInterval(86400), kind: $0.kind, app: $0.app)
        }, root: root, day: nextDay)
        XCTAssertEqual(try store.backfill(now: nextDay.addingTimeInterval(120), calendar: calendar, shouldContinue: { false }), 0)
        XCTAssertEqual(try store.backfill(now: nextDay.addingTimeInterval(120), calendar: calendar), 1)
        XCTAssertEqual(try store.read(day: day, calendar: calendar).activeSeconds, 60)
        XCTAssertThrowsError(try store.read(day: nextDay, calendar: calendar))
        XCTAssertEqual(try store.backfill(now: nextDay.addingTimeInterval(120), calendar: calendar), 0)
    }
    func testSummarySymlinkAndOversizedStoreNeverAuthorizePurge() throws {
        let root = try root(), store = GoalongActivityDayStore(root: root), now = day.addingTimeInterval(86400)
        _ = try journal([event(0), event(60)], root: root)
        let outside = root.appendingPathComponent("outside"); try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("activity-days"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.preserveBeforePurge(day: day, now: now, calendar: calendar))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertThrowsError(try store.read(day: day, calendar: calendar))
    }
    func testFiniteSummaryRetentionDoesNotRecreateExpiredDays() throws {
        let root = try root(), store = GoalongActivityDayStore(root: root), now = day.addingTimeInterval(10 * 86400)
        _ = try journal([event(0), event(60)], root: root)
        let value = store.load(day: day, now: now, calendar: calendar, summaryRetentionDays: 1)
        XCTAssertEqual(value.activeSeconds, 60)
        XCTAssertThrowsError(try store.read(day: day, calendar: calendar))
        XCTAssertEqual(try store.backfill(now: now, calendar: calendar, summaryRetentionDays: 1), 0)
    }

    func testLegacyRetentionDefaultsSummaryToIndefiniteAndPlannerDeletesAsMemories() throws {
        let policy = HistoryRetentionPolicy.migratingLegacy(retentionDays: 30)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        object.removeValue(forKey: "activitySummaries")
        let legacy = try JSONDecoder().decode(HistoryRetentionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.activitySummaries.days)
        let artifact = HistoryStoredArtifact(id: "summary", dataClass: .activitySummaries, start: day, end: day, localPath: "summary")
        XCTAssertEqual(HistoryDeletionPlanner.plan(request: .init(scope: .allMemories), artifacts: [artifact]).matchingArtifactIDs, ["summary"])
        XCTAssertEqual(HistoryDeletionPlanner.plan(request: .init(scope: .allDerivedData), artifacts: [artifact]).matchingArtifactIDs, ["summary"])
        XCTAssertFalse(RetentionPlanner.decisions(for: [artifact], policy: legacy, now: day.addingTimeInterval(100 * 86400))[0].shouldDelete)
    }
}
