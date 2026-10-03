import Darwin
import Foundation
import XCTest
@testable import LocalHistoryCore

final class HistoryLocalAnalyticsResumeTests: XCTestCase {
    private var start: Date { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_791_000_000)) }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: start)! }
    private var journalName: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start) + ".jsonl"
    }
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-resume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body(root, directory.appendingPathComponent(journalName))
    }
    private func row(_ index: Int, offset: Double? = nil, app: String = "Editor") -> HistoryEvent {
        HistoryEvent(id: "event-\(index)", sessionID: "fixture", timestamp: start.addingTimeInterval(offset ?? Double(index * 15)),
            kind: .heartbeat, app: .init(name: app, bundleIdentifier: "fixture.\(app)", processIdentifier: 1),
            window: .init(title: "Document", role: nil, subrole: nil), metadata: ["idle_seconds": "0"],
            integrity: EventIntegrity(sequence: UInt64(index + 1), previousEventHash: "previous",
                eventRoot: "root", eventHash: "hash-\(index)", fieldCommitments: []))
    }
    private func bytes(_ rows: [HistoryEvent], newline: Bool = true) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for (index, row) in rows.enumerated() {
            data.append(try encoder.encode(row))
            if newline || index < rows.count - 1 { data.append(0x0A) }
        }
        return data
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func read(_ root: URL, cursor: HistoryLocalAnalyticsCursor? = nil,
                      limits: ComputerHistoryEvidenceLoadLimits = .localAnalytics,
                      until: Date? = nil, shouldContinue: () -> Bool = { true }) -> ComputerHistoryEvidenceLoad {
        HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(start: start, endExclusive: until ?? end,
            limits: limits, resumeCursor: cursor, shouldContinue: shouldContinue)
    }
    private func load(_ root: URL, state: GoalongLocalAnalytics.ResumableDayState? = nil,
                      now: Date? = nil, shouldContinue: () -> Bool = { true }) -> GoalongLocalAnalytics.ResumableDayLoad {
        GoalongLocalAnalytics.load(root: root, day: start, resuming: state, now: now ?? end, shouldContinue: shouldContinue)
    }

    func testAppendResumeMatchesFullEventsDayAndCumulativeSummary() throws {
        try fixture { root, file in
            try bytes([row(0), row(1)]).write(to: file)
            let initial = load(root), before = read(root)
            let extra = try bytes([row(2), row(3)])
            try append(extra, to: file)
            let resumed = load(root, state: initial.state), full = load(root)
            XCTAssertTrue(resumed.didResume)
            XCTAssertEqual(resumed.eventBytesRead, Int64(extra.count))
            XCTAssertEqual(resumed.state?.events, full.state?.events)
            XCTAssertEqual(resumed.day, full.day)
            let delta = read(root, cursor: before.resumeCursor), complete = read(root)
            XCTAssertEqual(before.events + delta.events, complete.events)
            XCTAssertEqual(delta.sourceJournalSummary, complete.sourceJournalSummary)
            XCTAssertEqual(delta.metrics.retainedEventBytes, complete.metrics.retainedEventBytes)
            XCTAssertEqual(delta.metrics.retainedEventCount, complete.metrics.retainedEventCount)
            XCTAssertEqual(delta.resumeCursor, complete.resumeCursor)
            let unchanged = load(root, state: resumed.state)
            XCTAssertEqual(unchanged.eventBytesRead, 0)
            XCTAssertTrue(unchanged.didResume)
            XCTAssertEqual(unchanged.day, full.day)
        }
    }

    func testReplacementTruncationAndRewrittenLastLineForceFullReads() throws {
        try fixture { root, file in
            let original = try bytes([row(0), row(1)])
            try original.write(to: file)
            let beforeReplacement = load(root)
            try bytes([row(2), row(3)]).write(to: file, options: .atomic)
            let replaced = load(root, state: beforeReplacement.state)
            XCTAssertFalse(replaced.didResume)
            XCTAssertEqual(replaced.state?.events, load(root).state?.events)
            let short = try bytes([row(0)])
            try short.write(to: file)
            let truncated = load(root, state: replaced.state)
            XCTAssertFalse(truncated.didResume)
            XCTAssertEqual(truncated.eventBytesRead, Int64(short.count))
            try original.write(to: file)
            let beforeRewrite = load(root)
            let rewrite = try bytes([row(0), row(1, app: "Viewer")])
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: rewrite); try handle.truncate(atOffset: UInt64(rewrite.count)); try handle.close()
            let rewritten = load(root, state: beforeRewrite.state)
            XCTAssertFalse(rewritten.didResume)
            XCTAssertEqual(rewritten.day, load(root).day)
        }
    }

    func testPartialLastLineIsNeverConsumedAndCanBeCompleted() throws {
        try fixture { root, file in
            let first = try bytes([row(0)])
            let second = try bytes([row(1)])
            try (first + second.prefix(second.count / 2)).write(to: file)
            let initial = load(root)
            XCTAssertEqual(initial.state?.events.count, 1)
            XCTAssertEqual(initial.state?.cursor?.files.first?.consumedBytes, Int64(first.count))
            XCTAssertEqual(initial.day, GoalongLocalAnalytics.load(root: root, day: start, now: end))
            try append(Data(second.dropFirst(second.count / 2)), to: file)
            let resumed = load(root, state: initial.state)
            XCTAssertTrue(resumed.didResume)
            XCTAssertEqual(resumed.state?.events, load(root).state?.events)
            XCTAssertEqual(resumed.day, load(root).day)
            try append(try bytes([row(2)], newline: false), to: file)
            let withoutNewline = load(root, state: resumed.state)
            XCTAssertEqual(withoutNewline.state?.events.count, 2)
            try append(Data([0x0A]), to: file)
            let completed = load(root, state: withoutNewline.state)
            XCTAssertTrue(completed.didResume)
            XCTAssertEqual(completed.day.eventCount, 3)
            XCTAssertEqual(completed.day, load(root).day)
        }
    }

    func testBlankLinesAndLinesAcrossChunksKeepTheCorrectBoundary() throws {
        try fixture { root, file in
            let large = HistoryEvent(id: "large", sessionID: "fixture", timestamp: start,
                kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture", processIdentifier: 1),
                window: .init(title: String(repeating: "x", count: 140_000), role: nil, subrole: nil))
            try (Data([0x0A]) + bytes([large]) + Data([0x0A, 0x0A])).write(to: file)
            let initial = load(root)
            XCTAssertGreaterThan(try XCTUnwrap(initial.state?.cursor?.files.first?.lastLineBytes), 140_000)
            try append(try bytes([row(1)]), to: file)
            let resumed = load(root, state: initial.state)
            XCTAssertTrue(resumed.didResume)
            XCTAssertEqual(resumed.day, load(root).day)
            XCTAssertEqual(resumed.state?.cursor, load(root).state?.cursor)
        }
    }

    func testTrailingBlankLinesDoNotHideLastEventRewrite() throws {
        try fixture { root, file in
            let original = try bytes([row(0), row(1)]) + Data([0x0A, 0x0A])
            try original.write(to: file)
            let initial = load(root)
            let replacement = try bytes([row(0), row(1, app: "Viewer")]) + Data([0x0A, 0x0A])
            XCTAssertEqual(original.count, replacement.count)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: replacement); try handle.close()
            let loaded = load(root, state: initial.state)
            XCTAssertFalse(loaded.didResume)
            XCTAssertEqual(loaded.state?.events, load(root).state?.events)
            XCTAssertEqual(loaded.day, load(root).day)
        }
    }

    func testBudgetsApplyAcrossResumesAndFailedCursorDoesNotAdvance() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let rowsLimit = ComputerHistoryEvidenceLoadLimits(maximumRetainedRows: 2, maximumRetainedBytes: 1 << 20)
            let first = read(root, limits: rowsLimit)
            try append(try bytes([row(1)]), to: file)
            let second = read(root, cursor: first.resumeCursor, limits: rowsLimit)
            XCTAssertFalse(second.metrics.evidenceBudgetExceeded)
            XCTAssertEqual(second.resumeCursor?.retainedRows, 2)
            try append(try bytes([row(2)]), to: file)
            let rejected = read(root, cursor: second.resumeCursor, limits: rowsLimit)
            XCTAssertTrue(rejected.metrics.evidenceBudgetExceeded)
            XCTAssertTrue(rejected.events.isEmpty)
            XCTAssertEqual(rejected.resumeCursor, second.resumeCursor)
            XCTAssertEqual(rejected.issues, read(root, limits: rowsLimit).issues)
            XCTAssertEqual(rejected.metrics.peakEstimatedRetainedEvidenceBytes,
                read(root, limits: rowsLimit).metrics.peakEstimatedRetainedEvidenceBytes)

            let cost = try XCTUnwrap(first.resumeCursor?.retainedBytes)
            let bytesLimit = ComputerHistoryEvidenceLoadLimits(maximumRetainedRows: 100, maximumRetainedBytes: cost * 2)
            try bytes([row(0)]).write(to: file)
            let small = read(root, limits: bytesLimit)
            try append(try bytes([row(1), row(2)]), to: file)
            let byteRejected = read(root, cursor: small.resumeCursor, limits: bytesLimit)
            XCTAssertTrue(byteRejected.metrics.evidenceBudgetExceeded)
            XCTAssertEqual(byteRejected.resumeCursor, small.resumeCursor)
        }
    }

    func testCancellationBeforeAndDuringSuffixLeavesCheckpointUnchanged() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let initial = load(root)
            try append(try bytes((1...500).map { row($0) }), to: file)
            let cancelled = read(root, cursor: initial.state?.cursor, shouldContinue: { false })
            XCTAssertTrue(cancelled.metrics.wasCancelled)
            XCTAssertEqual(cancelled.resumeCursor, initial.state?.cursor)
            var calls = 0
            let interrupted = load(root, state: initial.state, shouldContinue: { calls += 1; return calls < 5 })
            XCTAssertTrue(interrupted.wasCancelled)
            XCTAssertEqual(interrupted.state?.cursor, initial.state?.cursor)
            XCTAssertEqual(interrupted.state?.events, initial.state?.events)
            let retried = load(root, state: interrupted.state)
            XCTAssertEqual(retried.day, load(root).day)
        }
    }

    func testMalformedSuffixDoesNotAdvanceAndCanBeRepaired() throws {
        try fixture { root, file in
            let good = try bytes([row(0)])
            try good.write(to: file)
            let initial = load(root)
            try append(Data("{broken}\n".utf8), to: file)
            let failed = load(root, state: initial.state)
            XCTAssertEqual(failed.day.state, .incomplete)
            XCTAssertEqual(failed.state?.cursor, initial.state?.cursor)
            try good.write(to: file)
            try append(try bytes([row(1)]), to: file)
            XCTAssertEqual(load(root, state: failed.state).day, load(root).day)
        }
    }

    func testOtherDaysAreNotDecodedOrModified() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let unrelated = root.appendingPathComponent("events/2001-01-01.jsonl")
            let invalid = Data("this must never be decoded\n".utf8)
            try invalid.write(to: unrelated)
            let initial = load(root)
            try append(try bytes([row(1)]), to: file)
            let resumed = load(root, state: initial.state)
            XCTAssertTrue(resumed.didResume)
            XCTAssertEqual(resumed.day.state, .ready)
            XCTAssertEqual(try Data(contentsOf: unrelated), invalid)
            XCTAssertEqual(resumed.state?.cursor?.files.map(\.name), [journalName])
        }
    }

    func testFileSetTimeZoneAndEndRollbackInvalidate() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let initial = read(root)
            let legacy = root.appendingPathComponent("events/legacy.jsonl")
            try bytes([row(1)]).write(to: legacy)
            XCTAssertFalse(read(root, cursor: initial.resumeCursor).didResume)
            try FileManager.default.removeItem(at: legacy)
            let changedZone = HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(
                start: start, endExclusive: end, resumeCursor: initial.resumeCursor, timeZoneIdentifier: "changed-zone")
            XCTAssertFalse(changedZone.didResume)
            XCTAssertFalse(read(root, cursor: initial.resumeCursor, until: start.addingTimeInterval(30)).didResume)
        }
    }

    func testEarlierFileGrowthPreservesFullReadOrderIncludingTimestampTies() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let later = root.appendingPathComponent("events/legacy.jsonl")
            try bytes([row(1, offset: 0, app: "Viewer")]).write(to: later)
            let initial = load(root)
            try append(try bytes([row(2, offset: 0, app: "Notes")]), to: file)
            try append(try bytes([row(3)]), to: later)
            let resumed = load(root, state: initial.state), full = load(root)
            XCTAssertTrue(resumed.didResume)
            XCTAssertEqual(resumed.state?.events.map(\.id), ["event-0", "event-2", "event-1", "event-3"])
            XCTAssertEqual(resumed.state?.events, full.state?.events)
            XCTAssertEqual(resumed.day, full.day)
            XCTAssertEqual(resumed.state?.cursor, full.state?.cursor)
        }
    }

    func testEndAdvancesButPreviouslyExcludedFutureRowsRequireFullRead() throws {
        try fixture { root, file in
            try bytes([row(0)]).write(to: file)
            let initial = load(root, now: start.addingTimeInterval(10))
            try append(try bytes([row(1)]), to: file)
            let advanced = load(root, state: initial.state, now: start.addingTimeInterval(30))
            XCTAssertTrue(advanced.didResume)
            XCTAssertEqual(advanced.day, load(root, now: start.addingTimeInterval(30)).day)
            try append(try bytes([row(2, offset: 60)]), to: file)
            let future = load(root, state: advanced.state, now: start.addingTimeInterval(40))
            XCTAssertNil(future.state?.cursor)
            let caughtUp = load(root, state: future.state, now: start.addingTimeInterval(70))
            XCTAssertFalse(caughtUp.didResume)
            XCTAssertEqual(caughtUp.day, load(root, now: start.addingTimeInterval(70)).day)
        }
    }

    func testSymlinkReplacementIsRejectedWithoutFollowingTarget() throws {
        try fixture { root, file in
            let data = try bytes([row(0)])
            try data.write(to: file)
            let initial = load(root)
            let target = root.appendingPathComponent("target.jsonl")
            try data.write(to: target)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            let rejected = load(root, state: initial.state)
            XCTAssertEqual(rejected.day.state, .incomplete)
            XCTAssertEqual(rejected.state?.cursor, initial.state?.cursor)
            XCTAssertEqual(try Data(contentsOf: target), data)
        }
    }

    func testPerformanceResumeAfterOneMiBAppend() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["GOALONG_PERF_ROOT"], let dayText = env["GOALONG_PERF_DAY"] else {
            throw XCTSkip("Set GOALONG_PERF_ROOT (a private copy) and GOALONG_PERF_DAY.")
        }
        let root = URL(fileURLWithPath: rootPath)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let day = try XCTUnwrap(formatter.date(from: dayText))
        let horizon = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func timed<T>(_ label: String, _ body: () -> T) -> T {
            let wall = ProcessInfo.processInfo.systemUptime, before = cpu()
            let result = body()
            print(String(format: "PERF %@: %.3f s (cpu %.3f s)", label,
                ProcessInfo.processInfo.systemUptime - wall, cpu() - before))
            return result
        }
        let first = timed("activity full initial") {
            GoalongLocalAnalytics.load(root: root, day: day, resuming: nil, now: horizon)
        }
        XCTAssertEqual(first.day.state, .ready)
        XCTAssertNotNil(first.state?.cursor)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var extra = Data(), index = 0
        while extra.count < 1_048_576 {
            let event = HistoryEvent(id: "perf-append-\(index)", sessionID: "perf",
                timestamp: day.addingTimeInterval(20 * 3600 + Double(index % 3600)), kind: .heartbeat,
                app: .init(name: "Perf", bundleIdentifier: "fixture.perf", processIdentifier: 1),
                window: .init(title: "Synthetic appended activity", role: nil, subrole: nil), metadata: ["idle_seconds": "0"])
            extra.append(try encoder.encode(event)); extra.append(0x0A); index += 1
        }
        try append(extra, to: root.appendingPathComponent("events/\(dayText).jsonl"))
        let resumed = timed("activity resume after 1 MiB append") {
            GoalongLocalAnalytics.load(root: root, day: day, resuming: first.state, now: horizon)
        }
        let full = timed("activity full after 1 MiB append") {
            GoalongLocalAnalytics.load(root: root, day: day, resuming: nil, now: horizon)
        }
        XCTAssertTrue(resumed.didResume)
        XCTAssertEqual(resumed.day, full.day)
        XCTAssertEqual(resumed.state?.events, full.state?.events)
        XCTAssertEqual(resumed.eventBytesRead, Int64(extra.count))
        _ = timed("activity resume unchanged") {
            GoalongLocalAnalytics.load(root: root, day: day, resuming: resumed.state, now: horizon)
        }
        print("PERF resume bytes=\(resumed.eventBytesRead) full bytes=\(full.eventBytesRead) added rows=\(index) events=\(full.day.eventCount)")
    }
}
