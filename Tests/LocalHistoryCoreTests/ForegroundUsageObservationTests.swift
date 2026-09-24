import Foundation
import XCTest
@testable import LocalHistoryCore

final class ForegroundUsageObservationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 9, day: 24))! }
    private func row(_ time: Double, idle: Double? = nil, limit: Int = 300,
                     visible: Bool = true, evidence: ForegroundActivityEvidence? = nil,
                     kind: EventKind = .heartbeat, suppression: SuppressionReason? = nil,
                     host: String? = "example.org", app: String = "Reader") -> HistoryEvent {
        let at = day.addingTimeInterval(time)
        let observation = ForegroundUsageObservation(observedAt: at, idleSeconds: idle ?? time,
            idleLimitSeconds: limit, isForegroundVisible: visible, evidence: evidence)
        return HistoryEvent(schemaVersion: 4, sessionID: "test", timestamp: at, kind: kind,
            app: .init(name: app, bundleIdentifier: "test." + app, processIdentifier: 42),
            url: host.map { .init(value: "https://" + $0 + "/private?q=secret", host: $0, redactionApplied: true) },
            classification: .init(category: "reading", isWork: true, confidence: 0.9, classifierVersion: "fixture"),
            suppressionReason: suppression, metadata: observation.metadata(at: at))
    }
    private func analytics(_ rows: [HistoryEvent]) -> GoalongLocalAnalytics.Day {
        GoalongLocalAnalytics.build(events: rows, day: day, now: day.addingTimeInterval(86400), calendar: calendar)
    }
    private func website(_ rows: [HistoryEvent]) -> Double {
        var accumulator = DailyWebsiteUsageAccumulator(day: day, currentTime: day.addingTimeInterval(86400), calendar: calendar)
        rows.forEach { accumulator.ingest($0) }
        return accumulator.finish().reduce(0) { $0 + $1.foregroundSeconds }
    }
    func testQuietReadingForOneTwoThreeAndFourMinutesIsFullyCounted() {
        for duration in [60, 120, 180, 240] {
            let rows = stride(from: 0, through: duration, by: 30).map { row(Double($0)) }
            XCTAssertEqual(analytics(rows).activeSeconds, Double(duration))
            XCTAssertEqual(website(rows), Double(duration))
        }
    }
    func testAbsenceStopsAtFiveMinutesWithoutErasingEarlierReading() {
        let rows = stride(from: 0, through: 1200, by: 30).map { row(Double($0)) }
        let result = analytics(rows)
        XCTAssertEqual(result.activeSeconds, 300)
        XCTAssertEqual(result.seconds(.idle), 900)
        XCTAssertEqual(website(rows), 300)
    }
    func testExactCutoffInsideAnObservationInterval() {
        let rows = [row(0, idle: 285), row(30, idle: 315)]
        XCTAssertEqual(analytics(rows).activeSeconds, 15)
        XCTAssertEqual(analytics(rows).seconds(.idle), 15)
        XCTAssertEqual(website(rows), 15)
    }
    func testActualInputRenewsReadingButLaterReturnDoesNotBackfillAbsence() {
        let rows = [row(0), row(60), row(120), row(180), row(240), row(300), row(360),
            row(420, idle: 0, kind: .mouseClick), row(480, idle: 60), row(540, idle: 120)]
        XCTAssertEqual(analytics(rows).activeSeconds, 420)
        XCTAssertEqual(analytics(rows).seconds(.idle), 120)
        XCTAssertEqual(website(rows), 420)
    }
    func testAutomaticWindowTitleChangesCannotRenewPresence() {
        let rows = (0...20).map { row(Double($0 * 30), kind: .windowChanged) }
        XCTAssertEqual(analytics(rows).activeSeconds, 300)
        XCTAssertEqual(website(rows), 300)
    }
    func testConfiguredLongReadingDoesNotDependOnApplicationName() {
        for app in ["Preview", "Safari", "Editor", "Unknown new application"] {
            let rows = (0...40).map { row(Double($0 * 30), limit: 1800, app: app) }
            XCTAssertEqual(analytics(rows).activeSeconds, 1200)
            XCTAssertEqual(website(rows), 1200)
        }
    }
    func testExplicitScreenOnModeCountsLongReadingButStillRequiresVisibleForeground() {
        let rows = (0...90).map { row(Double($0 * 30), idle: 9999, limit: 0) }
        XCTAssertEqual(analytics(rows).activeSeconds, 2700)
        XCTAssertEqual(website(rows), 2700)
        XCTAssertEqual(analytics([row(0, limit: 0, visible: false), row(30, limit: 0)]).activeSeconds, 0)
    }
    func testFortyFiveMinuteCallsAndSilentVideosRemainActive() {
        for evidence in [ForegroundActivityEvidence.call, .mediaPlayback] {
            let rows = (0...90).map { row(Double($0 * 30), idle: 3600, evidence: evidence) }
            XCTAssertEqual(analytics(rows).activeSeconds, 2700)
            XCTAssertEqual(website(rows), 2700)
        }
    }
    func testMediaStoppingDoesNotEraseMediaOrExtendEarlierIdle() {
        let rows = [row(0, idle: 3600, evidence: .call), row(30, idle: 3600, evidence: .call),
                    row(60, idle: 3600), row(90, idle: 3600), row(120, idle: 3600, evidence: .call),
                    row(150, idle: 3600, evidence: .call)]
        XCTAssertEqual(analytics(rows).activeSeconds, 90)
        XCTAssertEqual(website(rows), 90)
    }
    func testProcessOnlyAssertionStopsWebsiteAtExactReadingDeadline() {
        let rows = [row(0, idle: 290, evidence: .displayAssertion), row(30, idle: 320, evidence: .displayAssertion)]
        let result = analytics(rows)
        XCTAssertEqual(result.activeSeconds, 30)
        XCTAssertEqual(result.seconds(.work), 10)
        XCTAssertEqual(result.seconds(.unclassified), 20)
        XCTAssertEqual(GoalongLocalAnalytics.Period(days: [result]).usage(websites: true).first?.seconds, 10)
        XCTAssertEqual(website(rows), 10)
    }
    func testAppSwitchAttributesOnlyThePreviousVisibleApp() {
        let result = analytics([row(0, app: "A"), row(30, app: "B"), row(60, app: "A")])
        let usage = GoalongLocalAnalytics.Period(days: [result]).usage()
        XCTAssertEqual(usage.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(Set(usage.map(\.seconds)), [30])
    }
    func testNoTrailingExtrapolationForCurrentOrHistoricalDay() {
        let only = [row(0, idle: 0)]
        XCTAssertEqual(analytics(only).activeSeconds, 0)
        XCTAssertEqual(website(only), 0)
        var current = DailyWebsiteUsageAccumulator(day: day, currentTime: day.addingTimeInterval(60), calendar: calendar)
        only.forEach { current.ingest($0) }
        XCTAssertEqual(current.finish().reduce(0) { $0 + $1.foregroundSeconds }, 0)
    }
    func testLongGapAndFailedObservationNeverBecomeScreenTime() {
        let rows = [row(0, limit: 0), row(30, limit: 0), row(3600, limit: 0), row(3630, limit: 0)]
        XCTAssertEqual(analytics(rows).activeSeconds, 60)
        XCTAssertEqual(website(rows), 60)
        let failed = HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(30), kind: .recorderHealth,
            metadata: ["observation_gap": "true"])
        XCTAssertEqual(analytics([row(0), failed, row(60)]).activeSeconds, 0)
        XCTAssertEqual(website([row(0), failed, row(60)]), 0)
    }
    func testSleepLockPauseAndExclusionsOverrideAllModes() {
        for limit in [300, 0] {
            for kind in [EventKind.systemSleep, .sessionLocked, .recordingPaused, .recorderStopped] {
                let rows = [row(0, limit: limit, evidence: .call), row(30, limit: limit, evidence: .call, kind: kind),
                            row(90, limit: limit), row(120, limit: limit)]
                XCTAssertEqual(analytics(rows).activeSeconds, 60, "\(kind)")
                XCTAssertEqual(website(rows), 60, "\(kind)")
            }
            for reason in [SuppressionReason.privateBrowserWindow, .excludedApplication, .excludedDomain,
                           .secureInput, .manualPause, .sessionUnavailable, .accessibilityUnavailable] {
                let rows = [row(0, limit: limit, evidence: .call, suppression: reason), row(60, limit: limit)]
                XCTAssertEqual(analytics(rows).activeSeconds, 0)
                XCTAssertEqual(website(rows), 0)
            }
        }
    }
    func testInvalidIdleAndUnknownPolicyFailClosed() {
        for idle in [Double.nan, .infinity, -10] {
            XCTAssertEqual(analytics([row(0, idle: idle), row(30)]).activeSeconds, 0)
            XCTAssertEqual(website([row(0, idle: idle), row(30)]), 0)
        }
        let invalid = HistoryEvent(sessionID: "test", timestamp: day, kind: .heartbeat,
            app: row(0).app, metadata: [ForegroundUsageObservation.policyKey: "unknown", "idle_seconds": "0"])
        XCTAssertFalse(ForegroundActivityEvidence.isActiveUsageEvidence(invalid))
    }
    func testPolicyIsPersistedAndNotReinterpretedFromCurrentPreferences() {
        let short = [row(0, idle: 290, limit: 300), row(30, idle: 320, limit: 1800)]
        XCTAssertEqual(analytics(short).activeSeconds, 10)
        XCTAssertEqual(website(short), 10)
        let old = HistoryEvent(sessionID: "legacy", timestamp: day, kind: .heartbeat, app: row(0).app,
            metadata: ["idle_seconds": "120"])
        XCTAssertFalse(ForegroundActivityEvidence.isActiveUsageEvidence(old))
        XCTAssertNil(ForegroundUsageObservation.remainingActiveSeconds(old))
    }
    func testShortLivedObservationAndPlaybackExpiry() {
        let observation = ForegroundUsageObservation(observedAt: day, idleSeconds: 100,
            isForegroundVisible: true, evidence: .call)
        XCTAssertEqual(observation.metadata(at: day)[ForegroundActivityEvidence.metadataKey], "call")
        XCTAssertNil(observation.metadata(at: day.addingTimeInterval(16))[ForegroundActivityEvidence.metadataKey])
        XCTAssertEqual(observation.metadata(at: day.addingTimeInterval(61))[ForegroundUsageObservation.visibleKey], "false")
        XCTAssertEqual(observation.metadata(at: day.addingTimeInterval(-10))[ForegroundUsageObservation.visibleKey], "false")
        XCTAssertEqual(observation.metadata(at: day.addingTimeInterval(10), directInput: true)["idle_seconds"], "0.000")
    }
    func testOldConfigurationMigratesWithoutChangingCapturePermissions() throws {
        let config = RecorderConfig.default
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json.removeValue(forKey: "foregroundIdleSeconds")
        let restored = try JSONDecoder().decode(RecorderConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.effectiveForegroundIdleSeconds, 300)
        XCTAssertEqual(restored.captureClicks, config.captureClicks)
        XCTAssertEqual(restored.captureElementLabels, config.captureElementLabels)
        XCTAssertEqual(restored.captureURLs, config.captureURLs)
        for (input, expected) in [(0, 0), (-1, 300), (1, 120), (300, 300), (600, 600), (99999, 1800)] {
            var next = config; next.foregroundIdleSeconds = input
            XCTAssertEqual(next.validated().effectiveForegroundIdleSeconds, expected)
        }
    }
    func testPresenceDoesNotChangeContextIdentity() {
        let context = ContextSnapshot(app: row(0).app!, window: nil, focusedElement: nil, url: nil, suppressionReason: nil)
        let observed = context.withForegroundUsage(.init(observedAt: day, idleSeconds: 200, isForegroundVisible: true))
        XCTAssertEqual(context, observed)
        XCTAssertEqual(context.fingerprint, observed.fingerprint)
    }
    func testBookkeepingCannotCreateDisagreementBetweenWebsiteAndAnalytics() {
        let diagnostic = HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(15), kind: .diagnostic)
        let healthy = HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(45), kind: .recorderHealth)
        let rows = [row(0), diagnostic, row(30), healthy, row(60)]
        XCTAssertEqual(analytics(rows).activeSeconds, 60)
        XCTAssertEqual(website(rows), 60)
    }

    func testWebsiteDiskProjectionRetainsOnlyPresenceMetadata() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let original = row(120)
        let projection = try decoder.decode(DailyWebsiteUsageEventProjection.self, from: encoder.encode(original))
        XCTAssertEqual(projection.timestamp, original.timestamp)
        XCTAssertEqual(projection.historyEvent.metadata, original.metadata)
        XCTAssertTrue(ForegroundActivityEvidence.isActiveUsageEvidence(projection.historyEvent))
        XCTAssertEqual(projection.historyEvent.url?.value, "https://")
    }
}
