import Darwin
import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongActivityCheckpointTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 10, day: 4))! }
    private var end: Date { calendar.date(byAdding: .day, value: 1, to: day)! }

    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, root.appendingPathComponent("events/2026-10-04.jsonl"))
    }
    private func rows() -> [HistoryEvent] {
        (0...120).map { index in
            HistoryEvent(id: "row-\(index)", sessionID: "fixture", timestamp: day.addingTimeInterval(Double(index * 30)),
                kind: index % 4 == 0 ? .windowChanged : .typingBurst,
                app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1),
                window: index % 4 == 0 ? .init(title: "Document \(index % 7)", role: nil, subrole: nil) : nil,
                metadata: ["idle_seconds": "0"])
        }
    }
    private func bytes(_ rows: [HistoryEvent]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var bytes = Data()
        for row in rows { bytes.append(try encoder.encode(row)); bytes.append(10) }
        return bytes
    }
    private func append(_ bytes: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    private func checkpoint(_ root: URL) -> URL {
        root.appendingPathComponent("activity-days/2026-10-04" + GoalongActivityCheckpointStore.suffix)
    }
    private func save(_ root: URL, now: Date? = nil) -> GoalongLocalAnalytics.ResumableDayLoad {
        GoalongActivityDayStore(root: root).loadResumable(day: day, now: now ?? end, calendar: calendar)
    }

    func testRelaunchReadsOnlyAppendedLinesAndPreservesEveryMeasurement() throws {
        try fixture { root, journal in
            try bytes(rows()).write(to: journal)
            let first = save(root)
            XCTAssertGreaterThan(first.eventBytesRead, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint(root).path))
            let attributes = try FileManager.default.attributesOfItem(atPath: checkpoint(root).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let state = try GoalongActivityCheckpointStore(root: root).read(day: day, calendar: calendar)
            XCTAssertEqual(state.cursor, first.state?.cursor)
            XCTAssertEqual(state.foldedEventCount, first.state?.foldedEventCount)
            XCTAssertEqual(state.events, first.state?.events)
            let restart = save(root)
            XCTAssertTrue(restart.didResume); XCTAssertEqual(restart.eventBytesRead, 0)
            XCTAssertEqual(restart.day, first.day)
            let extra = try bytes([HistoryEvent(id: "appended", sessionID: "fixture", timestamp: day.addingTimeInterval(3660),
                kind: .typingBurst, app: rows()[0].app, metadata: ["idle_seconds": "0"])])
            try append(extra, to: journal)
            let appended = save(root)
            XCTAssertTrue(appended.didResume); XCTAssertEqual(appended.eventBytesRead, Int64(extra.count))
            XCTAssertEqual(appended.day, GoalongLocalAnalytics.load(root: root, day: day, now: end))
            XCTAssertEqual(save(root).day, appended.day)
        }
    }

    func testTodayCheckpointThrottleAndDayEndWithoutJournalGrowth() throws {
        try fixture { root, journal in
            try bytes(rows()).write(to: journal)
            let store = GoalongActivityDayStore(root: root), now = day.addingTimeInterval(3700)
            let initial = store.loadResumable(day: day, now: now)
            XCTAssertGreaterThan(initial.checkpointBytesHashed, 0)
            let file = checkpoint(root), saved = try Data(contentsOf: file)
            // Align filesystem mtime with the fixture clock, not the machine's real day.
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            let extra = try bytes([HistoryEvent(id: "appended", sessionID: "fixture",
                timestamp: now, kind: .typingBurst, app: rows()[0].app)])
            try append(extra, to: journal)
            var warm = store.loadResumable(day: day, resuming: initial.state, now: now.addingTimeInterval(30))
            XCTAssertTrue(warm.didResume); XCTAssertEqual(warm.eventBytesRead, Int64(extra.count))
            XCTAssertEqual(warm.checkpointBytesHashed, 0)
            XCTAssertEqual(try Data(contentsOf: file), saved)
            // Even a new reader within the interval validates the old checkpoint once,
            // then decodes its suffix without immediately hashing again to save it.
            let relaunched = store.loadResumable(day: day, now: now.addingTimeInterval(30))
            XCTAssertEqual(relaunched.day, warm.day)
            XCTAssertEqual(relaunched.checkpointBytesHashed, initial.eventBytesRead)
            XCTAssertEqual(try Data(contentsOf: file), saved)
            try append(extra, to: journal)
            warm = store.loadResumable(day: day, resuming: warm.state, now: now.addingTimeInterval(600))
            XCTAssertTrue(warm.didResume)
            XCTAssertEqual(warm.checkpointBytesHashed, initial.eventBytesRead + Int64(2 * extra.count))
            XCTAssertNotEqual(try Data(contentsOf: file), saved)
            // Closing the day must save even with an unchanged cursor and a recent mtime.
            let finished = store.loadResumable(day: day, resuming: warm.state, now: end)
            XCTAssertTrue(finished.didResume); XCTAssertEqual(finished.eventBytesRead, 0)
            XCTAssertEqual(finished.checkpointBytesHashed, initial.eventBytesRead + Int64(2 * extra.count))
            let disk = try GoalongActivityCheckpointStore(root: root).read(day: day)
            XCTAssertTrue(disk.isFinished)
            XCTAssertEqual(finished.day, GoalongLocalAnalytics.load(root: root, day: day, now: end))
        }
    }

    func testReplacementTruncationEarlierPrefixRewriteAndDeletionRejectCache() throws {
        for mutation in ["replace", "truncate", "prefix", "delete"] {
            try fixture { root, journal in
                let original = try bytes(rows()); try original.write(to: journal)
                _ = save(root)
                let store = GoalongActivityCheckpointStore(root: root)
                switch mutation {
                case "replace": try original.write(to: journal, options: .atomic)
                case "truncate": try Data(original.prefix(original.count / 2)).write(to: journal)
                case "prefix":
                    let mtime = try FileManager.default.attributesOfItem(atPath: journal.path)[.modificationDate]!
                    // Keep inode, size and the last line; restore mtime too.
                    var changed = original
                    let range = try XCTUnwrap(changed.range(of: Data("Document".utf8)))
                    changed.replaceSubrange(range, with: Data("Modified".utf8))
                    let handle = try FileHandle(forWritingTo: journal)
                    try handle.write(contentsOf: changed); try handle.close()
                    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: journal.path)
                default: try FileManager.default.removeItem(at: journal)
                }
                XCTAssertThrowsError(try store.read(day: day, calendar: calendar), mutation)
                let reloaded = save(root)
                XCTAssertFalse(reloaded.didResume, mutation)
                XCTAssertEqual(reloaded.day, GoalongLocalAnalytics.load(root: root, day: day, now: end), mutation)
            }
        }
    }

    func testLateArrivalRollbackAndTimezoneFallBackToFullProjection() throws {
        try fixture { root, journal in
            try bytes(rows()).write(to: journal)
            _ = save(root, now: day.addingTimeInterval(3700))
            let early = HistoryEvent(id: "late-old", sessionID: "fixture", timestamp: day.addingTimeInterval(60),
                kind: .typingBurst, app: rows()[0].app, metadata: ["idle_seconds": "0"])
            try append(try bytes([early]), to: journal)
            let late = save(root, now: day.addingTimeInterval(3700))
            XCTAssertFalse(late.didResume)
            XCTAssertEqual(late.day, GoalongLocalAnalytics.load(root: root, day: day, now: day.addingTimeInterval(3700)))
            let rollback = save(root, now: day.addingTimeInterval(1800))
            XCTAssertFalse(rollback.didResume)
            XCTAssertEqual(rollback.day, GoalongLocalAnalytics.build(events: rows() + [early], day: day, now: day.addingTimeInterval(1800)))
            var otherZone = calendar; otherZone.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertThrowsError(try GoalongActivityCheckpointStore(root: root).read(day: day, calendar: otherZone))
        }
    }

    func testUnsafeOversizedCorruptAndCancelledCheckpointsAreRejected() throws {
        for mutation in ["permissions", "hardlink", "symlink", "directory", "oversized", "corrupt"] {
            try fixture { root, journal in
                try bytes(rows()).write(to: journal); _ = save(root)
                let file = checkpoint(root), store = GoalongActivityCheckpointStore(root: root)
                switch mutation {
                case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                case "hardlink": XCTAssertEqual(link(file.path, root.appendingPathComponent("linked").path), 0)
                case "symlink":
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: journal)
                case "directory":
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                case "oversized": try Data(repeating: 0, count: GoalongActivityCheckpointStore.maximumBytes + 1).write(to: file)
                default: try Data("broken".utf8).write(to: file)
                }
                XCTAssertThrowsError(try store.read(day: day), mutation)
                XCTAssertEqual(save(root).day, GoalongLocalAnalytics.load(root: root, day: day, now: end), mutation)
            }
        }
        try fixture { root, journal in
            try bytes(rows()).write(to: journal); let initial = save(root)
            let store = GoalongActivityCheckpointStore(root: root), saved = try Data(contentsOf: checkpoint(root))
            XCTAssertThrowsError(try store.read(day: day, shouldContinue: { false }))
            XCTAssertThrowsError(try store.write(try XCTUnwrap(initial.state), day: day,
                sourceRevision: store.sourceRevision(day: day), shouldContinue: { false }))
            XCTAssertEqual(try Data(contentsOf: checkpoint(root)), saved)
        }
    }

    func testRewriteBetweenPrefixValidationAndSuffixReadCannotReuseOldFold() throws {
        try fixture { root, journal in
            let original = try bytes(rows()); try original.write(to: journal)
            _ = save(root)
            var changed = original
            let range = try XCTUnwrap(changed.range(of: Data("Document".utf8)))
            changed.replaceSubrange(range, with: Data("Modified".utf8))
            var checks = 0
            let loaded = GoalongActivityDayStore(root: root).loadResumable(day: day, now: end,
                shouldContinue: {
                    checks += 1
                    if checks == 3 {
                        let handle = try! FileHandle(forWritingTo: journal)
                        try! handle.write(contentsOf: changed); try! handle.close()
                    }
                    return true
                })
            XCTAssertGreaterThan(checks, 3)
            XCTAssertFalse(loaded.didResume)
            XCTAssertEqual(loaded.day, GoalongLocalAnalytics.load(root: root, day: day, now: end))
        }
    }

    func testOversizedWindowKeepsExactNumbersWithoutPersistingSourceRows() throws {
        try fixture { root, journal in
            let rows = (0...8_192).map { index in
                HistoryEvent(id: "dense-\(index)", sessionID: "fixture", timestamp: day.addingTimeInterval(Double(index / 10)),
                    kind: .typingBurst, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1),
                    metadata: ["idle_seconds": "0"])
            }
            try bytes(rows).write(to: journal)
            let loaded = save(root)
            XCTAssertEqual(loaded.day, GoalongLocalAnalytics.build(events: rows, day: day, now: end))
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root).path))
        }
    }
}
