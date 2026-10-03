import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongLocalAnalyticsFoldTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 10, day: 3))! }
    private var end: Date { calendar.date(byAdding: .day, value: 1, to: day)! }
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-fold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        try body(root, root.appendingPathComponent("events/\(formatter.string(from: day)).jsonl"))
    }
    private func row(_ index: Int, _ offset: Int) -> HistoryEvent {
        let style = index % 16
        let reasons: [SuppressionReason] = [.privateBrowserWindow, .excludedApplication, .excludedDomain,
            .secureInput, .manualPause, .sessionUnavailable, .accessibilityUnavailable]
        var metadata = ["idle_seconds": style == 1 ? "95" : "0"]
        var app: String? = index % 3 == 0 ? "Reader" : "Editor"
        var reason: SuppressionReason?
        var kind: EventKind = .heartbeat
        var title: String? = "Document \(index % 5)"
        if style == 2 { metadata["observation_gap"] = "true" }
        if style == 3 { reason = reasons[(index / 16) % reasons.count] }
        if (4...9).contains(style) {
            metadata[ForegroundUsageObservation.policyKey] = ForegroundUsageObservation.policyVersion
            metadata[ForegroundUsageObservation.visibleKey] = style == 5 ? "false" : "true"
            metadata[ForegroundUsageObservation.idleLimitKey] = "300"
            metadata["idle_seconds"] = "290"
            if style == 6 { metadata[ForegroundUsageObservation.policyKey] = "unknown-policy" }
            if style == 7 { metadata[ForegroundActivityEvidence.metadataKey] = "display_assertion" }
            if style == 8 { metadata[ForegroundActivityEvidence.metadataKey] = "media_playback"; metadata["idle_seconds"] = "3600" }
            if style == 9 { metadata[ForegroundActivityEvidence.metadataKey] = "call"; metadata["idle_seconds"] = "3600" }
        }
        if style == 10 { app = nil }
        if style == 11 { app = "" }
        if style == 12 { kind = .systemSleep }
        if style == 13 { kind = .typingBurst; title = nil }
        if style == 14 { metadata["idle_seconds"] = "unknown" }
        let host = index % 3 == 0 ? "example.test" : nil
        return HistoryEvent(id: "fold-\(index)", sessionID: "fixture", timestamp: day.addingTimeInterval(Double(offset)),
            kind: kind, app: app.map { .init(name: $0, bundleIdentifier: "fixture." + $0, processIdentifier: 1) },
            window: title.map { .init(title: $0, role: nil, subrole: nil) },
            url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
            suppressionReason: reason, metadata: metadata)
    }
    private func bytes(_ rows: [HistoryEvent]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(0x0A) }
        return data
    }
    private func append(_ rows: [HistoryEvent], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes(rows))
    }
    private func load(_ root: URL, state: GoalongLocalAnalytics.ResumableDayState? = nil,
                      now: Int) -> GoalongLocalAnalytics.ResumableDayLoad {
        GoalongLocalAnalytics.load(root: root, day: day, resuming: state,
            now: day.addingTimeInterval(Double(now)), calendar: calendar)
    }
    private func assertMatches(_ result: GoalongLocalAnalytics.ResumableDayLoad, rows: [HistoryEvent], root: URL,
                               now: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let at = day.addingTimeInterval(Double(now))
        XCTAssertEqual(result.day, GoalongLocalAnalytics.build(events: rows, day: day, now: at, calendar: calendar), file: file, line: line)
        let state = try XCTUnwrap(result.state, file: file, line: line)
        let projected = HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(start: day, endExclusive: end).events
        let ordered = GoalongLocalAnalytics.evidenceRows(projected, start: day, end: end)
        let latest = ordered.last?.timestamp ?? day
        let cutoff = max(day, min(latest, min(at, end)).addingTimeInterval(-900))
        XCTAssertEqual(state.windowStart, cutoff, file: file, line: line)
        XCTAssertEqual(state.events, ordered.filter { $0.timestamp >= cutoff }, file: file, line: line)
        XCTAssertEqual(state.foldedEventCount, ordered.filter { $0.timestamp < cutoff }.count, file: file, line: line)
        XCTAssertEqual(state.retainedEventCount, ordered.count, file: file, line: line)
        XCTAssertEqual(result.day.segments.reduce(0, { $0 + $1.seconds }), max(0, min(at, end).timeIntervalSince(day)), accuracy: 0.000001, file: file, line: line)
    }
    private struct Random {
        var value: UInt64
        mutating func number(_ bound: Int) -> Int {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Int(value >> 32) % bound
        }
    }

    func testSeededAppendSequencesMatchFullBuildAndKeepOnlyTheWindow() throws {
        for seed in [UInt64(1), 42, 777, 123456789] {
            try fixture { root, file in
                var random = Random(value: seed)
                var rows = (0...120).map { row($0, $0 * 30) }
                try bytes(rows).write(to: file)
                var now = 3600, result = load(root, now: now), id = rows.count
                try assertMatches(result, rows: rows, root: root, now: now)
                for step in 0..<50 {
                    let old = try XCTUnwrap(result.state)
                    let cutoff = Int(old.windowStart.timeIntervalSince(day))
                    now += 20 + random.number(100)
                    if step % 9 == 0 { now += 300 } // Gaps larger than maximumGap.
                    var batch: [HistoryEvent] = []
                    for offset in 0..<(4 + random.number(8)) {
                        let seconds: Int
                        if step % 11 == 0 && offset == 0 { seconds = max(0, cutoff - 1) }
                        else if step % 6 == 0 && offset < 2 { seconds = cutoff } // Ties exactly at T.
                        else if step % 8 == 0 && offset == 0 { seconds = now + 180 } // Future row retained, not yet displayed.
                        else { seconds = max(cutoff, now - random.number(700)) }
                        batch.append(row(id, seconds)); id += 1
                    }
                    for index in batch.indices { batch.swapAt(index, random.number(batch.count)) }
                    try append(batch, to: file); rows.append(contentsOf: batch)
                    result = load(root, state: old, now: now)
                    XCTAssertEqual(result.didResume, !batch.contains { $0.timestamp < old.windowStart }, "seed=\(seed), step=\(step)")
                    try assertMatches(result, rows: rows, root: root, now: now)
                }
                XCTAssertGreaterThan(try XCTUnwrap(result.state).foldedEventCount, 120)
                XCTAssertLessThan(try XCTUnwrap(result.state).events.count, rows.count / 2)
            }
        }
    }

    func testFinalizationDoesNotCommitLeadingOrTrailingMissingTime() throws {
        try fixture { root, file in
            var rows = (0...120).map { row($0, 3600 + $0 * 30) }
            try bytes(rows).write(to: file)
            let first = load(root, now: 7300)
            try assertMatches(first, rows: rows, root: root, now: 7300)
            let batch = [row(130, 7260), row(131, 7320)]
            try append(batch, to: file); rows += batch
            let resumed = load(root, state: first.state, now: 7400)
            XCTAssertTrue(resumed.didResume)
            try assertMatches(resumed, rows: rows, root: root, now: 7400)
        }
    }

    func testCheckpointKeepsTheContextTrackerForTitlelessInput() throws {
        try fixture { root, file in
            var rows = (0...120).map { index in
                HistoryEvent(id: "context-\(index)", sessionID: "fixture", timestamp: day.addingTimeInterval(Double(index * 30)),
                    kind: index == 0 ? .windowChanged : .typingBurst,
                    app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1),
                    window: index == 0 ? .init(title: "Old document", role: nil, subrole: nil) : nil,
                    metadata: ["idle_seconds": "0"])
            }
            try bytes(rows).write(to: file)
            let initial = load(root, now: 3600)
            XCTAssertGreaterThan(try XCTUnwrap(initial.state).foldedEventCount, 0)
            let appended = HistoryEvent(id: "context-appended", sessionID: "fixture", timestamp: day.addingTimeInterval(3660),
                kind: .typingBurst, app: rows[0].app, metadata: ["idle_seconds": "0"])
            try append([appended], to: file); rows.append(appended)
            let refreshed = load(root, state: initial.state, now: 3700)
            try assertMatches(refreshed, rows: rows, root: root, now: 3700)
            XCTAssertEqual(Set(refreshed.day.segments.filter(\.kind.isActive).compactMap(\.contextKey)).count, 1)
        }
    }

    func testFutureRowsNoSourceNowRollbackAndDayRollover() throws {
        try fixture { root, file in
            let rows = (0...120).map { row($0, 3600 + $0 * 30) }
            try bytes(rows).write(to: file)
            let future = load(root, now: 60)
            XCTAssertEqual(future.day.state, .noSource)
            try assertMatches(future, rows: rows, root: root, now: 60)
            let caughtUp = load(root, state: future.state, now: 7200)
            XCTAssertTrue(caughtUp.didResume)
            try assertMatches(caughtUp, rows: rows, root: root, now: 7200)
            let rewound = load(root, state: caughtUp.state, now: 7140)
            XCTAssertFalse(rewound.didResume)
            try assertMatches(rewound, rows: rows, root: root, now: 7140)
            let beforePrefix = load(root, state: caughtUp.state, now: 2000)
            XCTAssertFalse(beforePrefix.didResume)
            try assertMatches(beforePrefix, rows: rows, root: root, now: 2000)
            let next = GoalongLocalAnalytics.load(root: root, day: end, resuming: caughtUp.state,
                now: end.addingTimeInterval(3600), calendar: calendar)
            XCTAssertFalse(next.didResume)
            XCTAssertEqual(next.day, GoalongLocalAnalytics.build(events: rows, day: end, now: end.addingTimeInterval(3600), calendar: calendar))
            XCTAssertEqual(next.state?.foldedEventCount, 0)
            XCTAssertEqual(next.state?.events.count, 0)
        }
    }

    func testIncompleteSuffixAndCancellationDoNotPublishANewFold() throws {
        try fixture { root, file in
            let rows = (0...120).map { row($0, $0 * 30) }
            try bytes(rows).write(to: file)
            let initial = load(root, now: 3700)
            var calls = 0
            let complete = GoalongLocalAnalytics.load(root: root, day: day, resuming: initial.state,
                now: day.addingTimeInterval(3700), shouldContinue: { calls += 1; return true })
            XCTAssertTrue(complete.didResume)
            let limit = calls - 1
            calls = 0
            let cancelled = GoalongLocalAnalytics.load(root: root, day: day, resuming: initial.state,
                now: day.addingTimeInterval(3700), shouldContinue: { calls += 1; return calls < limit })
            XCTAssertTrue(cancelled.wasCancelled)
            XCTAssertEqual(cancelled.state?.cursor, initial.state?.cursor)
            XCTAssertEqual(cancelled.state?.events, initial.state?.events)
            XCTAssertEqual(cancelled.state?.foldedEventCount, initial.state?.foldedEventCount)
            try append([row(130, 3660)], to: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
            let failed = load(root, state: initial.state, now: 3700)
            XCTAssertEqual(failed.day.state, .incomplete)
            XCTAssertEqual(failed.day, load(root, now: 3700).day)
            XCTAssertEqual(failed.state?.cursor, initial.state?.cursor)
            XCTAssertEqual(failed.state?.events, initial.state?.events)
            XCTAssertEqual(failed.state?.foldedEventCount, initial.state?.foldedEventCount)
            XCTAssertEqual(failed.day.activeSeconds, 0)
        }
    }
}
