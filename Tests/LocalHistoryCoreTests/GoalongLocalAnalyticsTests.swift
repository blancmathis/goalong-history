import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongLocalAnalyticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))! }
    private func event(_ seconds: Double, app: String? = "Editor", host: String? = nil,
                       work: Bool? = true, confidence: Double = 0.9,
                       kind: EventKind = .heartbeat, suppression: SuppressionReason? = nil,
                       metadata: [String: String]? = nil) -> HistoryEvent {
        HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: day.addingTimeInterval(seconds),
            kind: kind, app: app.map { .init(name: $0, bundleIdentifier: "fixture." + $0, processIdentifier: 1) },
            window: .init(title: "DO NOT RETAIN confidential title", role: nil, subrole: nil),
            url: host.map { .init(value: "https://" + $0 + "/private?token=secret", host: $0, redactionApplied: false) },
            classification: .init(category: "fixture", isWork: work, confidence: confidence, classifierVersion: "fixture-v1"),
            suppressionReason: suppression, metadata: metadata)
    }
    private func build(_ events: [HistoryEvent], now: Double = 86400) -> GoalongLocalAnalytics.Day {
        GoalongLocalAnalytics.build(events: events, day: day, now: day.addingTimeInterval(now), calendar: calendar)
    }
    func testConservationAndNoLeadingOrTrailingExtrapolation() {
        let result = build([event(3600), event(3660), event(3720, work: false), event(3780, work: nil), event(3840)])
        XCTAssertEqual(result.activeSeconds, 240)
        XCTAssertEqual(result.seconds(.work), 120)
        XCTAssertEqual(result.seconds(.other), 60)
        XCTAssertEqual(result.seconds(.unclassified), 60)
        XCTAssertEqual(result.seconds(.unobserved), 86400 - 240)
        XCTAssertEqual(result.segments.reduce(0) { $0 + $1.seconds }, 86400)
        XCTAssertTrue(zip(result.segments, result.segments.dropFirst()).allSatisfy { $0.end == $1.start })
    }
    func testFocusThresholdAndClassificationChangesDoNotChangeTheContext() {
        let events = (0...30).map { event(3600 + Double($0 * 60), work: $0 < 15) }
        let result = build(events)
        XCTAssertEqual(result.focus(minimumMinutes: 25).count, 1)
        XCTAssertEqual(result.focusSeconds(minimumMinutes: 25), 1800)
        XCTAssertEqual(result.focusSeconds(minimumMinutes: 50), 0)
        XCTAssertEqual(result.contextChanges, 0)
    }
    func testAppAndDomainChangesBreakFocus() {
        let events = [event(0, host: "a.test"), event(60, host: "a.test"), event(120, host: "b.test"),
                      event(180, app: "Other"), event(240, app: "Other")]
        let result = build(events)
        XCTAssertEqual(result.contextChanges, 2)
        XCTAssertEqual(result.sequences.count, 3)
        XCTAssertEqual(result.sequences.map(\.seconds), [120, 60, 60])
    }
    func testGapsNeverBecomeRestOrContinuousFocus() {
        let result = build([event(0), event(60), event(3600), event(3660)])
        XCTAssertEqual(result.activeSeconds, 120)
        XCTAssertEqual(result.seconds(.idle), 0)
        XCTAssertEqual(result.sequences.count, 2)
        XCTAssertEqual(result.contextChanges, 0)
    }
    func testExplicitGapCutsEvenShortIntervals() {
        let result = build([event(0), event(60, metadata: ["observation_gap": "true"]), event(120)])
        XCTAssertEqual(result.activeSeconds, 60)
        XCTAssertEqual(result.segments.first?.kind, .unobserved)
    }
    func testIdleSignalIsSeparateAndNeverAddedToActiveTime() {
        let result = build([event(0), event(60, metadata: ["idle_seconds": "95"]), event(120), event(180)])
        XCTAssertEqual(result.seconds(.idle), 120)
        XCTAssertEqual(result.activeSeconds, 60)
        XCTAssertEqual(result.focusSeconds(minimumMinutes: 1), 60)
    }
    func testSuppressedIntervalDoesNotExposeContext() {
        let result = build([event(0, suppression: .privateBrowserWindow), event(60, kind: .captureResumed), event(120), event(180)])
        let hidden = result.segments.filter { $0.kind == .concealed }
        XCTAssertEqual(hidden.count, 1)
        XCTAssertNil(hidden.first?.application)
        XCTAssertNil(hidden.first?.host)
        XCTAssertEqual(result.activeSeconds, 60)
    }
    func testUnavailablePermissionsAreMissingEvidenceNotPrivateTime() {
        let result = build([event(0, suppression: .accessibilityUnavailable), event(60), event(120)])
        XCTAssertEqual(result.seconds(.concealed), 0)
        XCTAssertEqual(result.activeSeconds, 60)
    }
    func testEveryContinuityBoundaryCutsTheSequence() {
        for kind in [EventKind.recorderStopped, .recordingPaused, .recordingResumed, .systemSleep, .systemWake, .sessionLocked, .sessionUnlocked] {
            let result = build([event(0), event(60, kind: kind), event(120), event(180)])
            XCTAssertEqual(result.activeSeconds, 120, "\(kind)")
            XCTAssertEqual(result.sequences.count, 2, "\(kind)")
        }
    }
    func testUncertainClassificationStaysUnclassified() {
        let result = build([event(0, confidence: 0.2), event(60)])
        XCTAssertEqual(result.seconds(.work), 0)
        XCTAssertEqual(result.seconds(.unclassified), 60)
    }
    func testMissingFutureSingleEventAndCorruptOrderFailHonestly() {
        XCTAssertEqual(build([]).state, .noSource)
        XCTAssertEqual(build([event(0)]).activeSeconds, 0)
        XCTAssertEqual(build([event(60), event(0)]).state, .incomplete)
        XCTAssertEqual(build([event(0), event(60)], now: 30).activeSeconds, 0)
        let future = GoalongLocalAnalytics.build(events: [], day: day, now: day.addingTimeInterval(-60), calendar: calendar)
        XCTAssertTrue(future.segments.isEmpty)
        XCTAssertEqual(future.end, future.date)
    }
    func testHourlyBucketsReconcileFocusAndActive() {
        let events = (0...60).map { event(3300 + Double($0 * 60)) }
        let result = build(events)
        let hours = result.hours(minimumMinutes: 25, calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.seconds }, result.activeSeconds)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.focusSeconds }, result.focusSeconds(minimumMinutes: 25))
    }
    func testDaylightSavingCalendarBuckets() {
        var paris = calendar; paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        for (month, date, expected) in [(3, 29, 23), (10, 25, 25)] {
            let start = paris.date(from: .init(year: 2026, month: month, day: date))!
            let end = paris.date(byAdding: .day, value: 1, to: start)!
            let result = GoalongLocalAnalytics.build(events: [], day: start, now: end, calendar: paris)
            XCTAssertEqual(result.hours(minimumMinutes: 25, calendar: paris).count, expected)
            XCTAssertEqual(result.seconds(.unobserved), Double(expected * 3600))
        }
    }
    func testWebsitesAreASubsetAndApplicationsReconcile() {
        let day = build([event(0, host: "a.test"), event(60, host: "a.test"), event(120, app: "Other"), event(180)])
        let period = GoalongLocalAnalytics.Period(days: [day])
        XCTAssertEqual(period.usage().reduce(0) { $0 + $1.seconds }, period.activeSeconds)
        XCTAssertEqual(period.usage(websites: true).reduce(0) { $0 + $1.seconds }, 120)
        XCTAssertLessThanOrEqual(period.focusSeconds(minimumMinutes: 1), period.activeSeconds)
    }
    func testBoundedReaderPreservesMeasurementButDropsSensitivePayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-analytics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = [event(3600, host: "example.org", metadata: ["idle_seconds": "0", "analysis.semantic_text": "DO NOT RETAIN"]), event(3660)]
        let bytes = try rows.reduce(into: Data()) { result, row in result.append(try encoder.encode(row)); result.append(10) }
        try bytes.write(to: folder.appendingPathComponent("2026-09-10.jsonl"))
        let load = HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(start: day, endExclusive: day.addingTimeInterval(86400))
        XCTAssertTrue(load.issues.isEmpty, "\(load.issues)")
        XCTAssertEqual(load.events.count, 2)
        XCTAssertEqual(load.events.first?.classification?.isWork, true)
        XCTAssertEqual(load.events.first?.metadata?["idle_seconds"], "0")
        XCTAssertNil(load.events.first?.window)
        XCTAssertNil(load.events.first?.metadata?["analysis.semantic_text"])
        XCTAssertEqual(load.events.first?.url?.value, "https://example.org")
        XCTAssertTrue(load.semanticSnapshots.isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("2026-09-10.jsonl")), bytes)
    }
}
