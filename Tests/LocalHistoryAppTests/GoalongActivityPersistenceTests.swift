#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongActivityPersistenceTests: XCTestCase {
    private var day: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 10))! }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-summary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func writeEvents(root: URL) throws -> URL {
        let url = root.appendingPathComponent("events/2026-08-10.jsonl")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var bytes = Data()
        for seconds in [0.0, 60, 120] {
            bytes.append(try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(seconds),
                kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1))))
            bytes.append(10)
        }
        try bytes.write(to: url); return url
    }
    private func retention(root: URL) -> HistoryRetentionStore {
        HistoryRetentionStore(legacyRetentionDays: 1, storage: HistoryRetentionStorage(
            policyFile: root.appendingPathComponent("retention-policy.json"), activationFile: root.appendingPathComponent("retention-policy-activated"),
            artifactDirectories: [.init(directory: root.appendingPathComponent("events"), dataClass: .detailedEvents, allowedSuffixes: [".jsonl"])],
            prepare: {}))
    }
    func testRetentionWritesSummaryBeforeRemovingJournalAndRestoresDay() throws {
        let root = try root(), file = try writeEvents(root: root), store = retention(root: root)
        try store.updateDetailedRetention(fromLegacyDays: 1)
        store.applyCleanup(now: day.addingTimeInterval(10 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let saved = try GoalongActivityDayStore(root: root).read(day: day)
        XCTAssertEqual(saved.activeSeconds, 120); XCTAssertEqual(saved.origin, .summary)
    }
    func testRetentionKeepsJournalIfSummaryCannotBeSaved() throws {
        let root = try root(), file = try writeEvents(root: root)
        try Data("blocked".utf8).write(to: root.appendingPathComponent("activity-days"))
        let store = retention(root: root); try store.updateDetailedRetention(fromLegacyDays: 1)
        store.applyCleanup(now: day.addingTimeInterval(10 * 86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testRetentionStillExpiresJournalWithNothingToSummarizeOrUnreadableContent() throws {
        // R4-donnees-01: a journal with only health rows (.noSource) or a corrupt line
        // (.incomplete) used to stay on disk forever.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for content in ["health", "corrupt"] {
            let root = try root(), file = try writeEvents(root: root)
            if content == "health" {
                var bytes = Data()
                for kind in [EventKind.permissionStatus, .recorderHealth] {
                    bytes.append(try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(60), kind: kind)))
                    bytes.append(10)
                }
                try bytes.write(to: file)
            } else { try Data("invalid JSON\n".utf8).write(to: file) }
            let expected: GoalongActivityDayStore.Preservation = content == "health" ? .nothingToSummarize : .unreadable
            XCTAssertEqual(try GoalongActivityDayStore(root: root).preserveBeforePurge(day: day, now: day.addingTimeInterval(10 * 86400)), expected, content)
            let store = retention(root: root); try store.updateDetailedRetention(fromLegacyDays: 1)
            store.applyCleanup(now: day.addingTimeInterval(10 * 86400))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), content)
            XCTAssertThrowsError(try GoalongActivityDayStore(root: root).read(day: day), content)
        }
    }
    func testSummaryFromAnotherTimeZoneSurvivesWithoutJournalAndIsNeverRecounted() throws {
        // R4-donnees-02 / R4-historique-01: a summary written in Paris, read from Tokyo.
        var paris = Calendar(identifier: .gregorian); paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        var tokyo = paris; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parisDay = paris.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let tokyoDay = tokyo.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let root = try root()
        let journal = root.appendingPathComponent("events/2026-08-10.jsonl")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var bytes = Data()
        for seconds in [0.0, 60, 120] {
            bytes.append(try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: parisDay.addingTimeInterval(3 * 3600 + seconds),
                kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1))))
            bytes.append(10)
        }
        try bytes.write(to: journal)
        let store = GoalongActivityDayStore(root: root)
        let later = parisDay.addingTimeInterval(10 * 86400)
        XCTAssertEqual(try store.preserveBeforePurge(day: parisDay, now: later, calendar: paris), .summarized)
        let summary = root.appendingPathComponent("activity-days/2026-08-10.json")
        let saved = try Data(contentsOf: summary)

        // Journal still present: Tokyo recounts the day but never replaces the settled summary.
        _ = store.load(day: tokyoDay, now: later, calendar: tokyo)
        try store.backfill(now: later, calendar: tokyo)
        XCTAssertEqual(try store.preserveBeforePurge(day: tokyoDay, now: later, calendar: tokyo), .summarized)
        XCTAssertEqual(try Data(contentsOf: summary), saved)

        // Journal purged: the Paris summary is still the account of 10 August, on Tokyo's date.
        try FileManager.default.removeItem(at: journal)
        let restored = try store.read(day: tokyoDay, calendar: tokyo)
        XCTAssertEqual(restored.date, tokyoDay)
        XCTAssertEqual(restored.origin, .summary)
        XCTAssertEqual(restored.activeSeconds, 120)
        XCTAssertTrue(store.hasForeignTimeZoneSummary(day: tokyoDay, calendar: tokyo))
        XCTAssertFalse(store.hasForeignTimeZoneSummary(day: parisDay, calendar: paris))
    }
    func testRetentionKeepsValidJournalWhenEventsFolderCannotBeListedCompletely() throws {
        // B01-R1-01: a linked *.jsonl entry makes every day load incomplete. That is an access
        // problem, not a defect of this journal: it must never expire without a summary.
        let root = try root(), file = try writeEvents(root: root)
        let target = root.appendingPathComponent("outside.txt")
        try Data("do-not-delete\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("events/2020-01-03.jsonl"), withDestinationURL: target)
        let later = day.addingTimeInterval(10 * 86400)
        XCTAssertEqual(GoalongLocalAnalytics.loadReportingDefect(root: root, day: day, now: later).defect, .access)
        XCTAssertThrowsError(try GoalongActivityDayStore(root: root).preserveBeforePurge(day: day, now: later))
        let store = retention(root: root); try store.updateDetailedRetention(fromLegacyDays: 1)
        store.applyCleanup(now: later)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // Once events/ is readable again, the day is summarized before its journal goes.
        try FileManager.default.removeItem(at: root.appendingPathComponent("events/2020-01-03.jsonl"))
        store.applyCleanup(now: later)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try GoalongActivityDayStore(root: root).read(day: day).activeSeconds, 120)
    }
    func testForeignSummaryOfAClockChangeDayIsReadAndNeverRecounted() throws {
        // B01-R1-02: Paris has 25 h on 2026-10-25 and 23 h on 2026-03-29; New York has 24 h on both.
        var paris = Calendar(identifier: .gregorian); paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        var newYork = paris; newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for (month, date) in [(10, 25), (3, 29)] {
            let parisDay = paris.date(from: DateComponents(year: 2026, month: month, day: date))!
            let localDay = newYork.date(from: DateComponents(year: 2026, month: month, day: date))!
            let root = try root(), key = GoalongActivityDayStore.dayKey(parisDay, calendar: paris)
            let journal = root.appendingPathComponent("events/\(key).jsonl")
            var bytes = Data()
            for seconds in [0.0, 60, 120] {
                bytes.append(try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: parisDay.addingTimeInterval(3 * 3600 + seconds),
                    kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1))))
                bytes.append(10)
            }
            try bytes.write(to: journal)
            let store = GoalongActivityDayStore(root: root), later = parisDay.addingTimeInterval(10 * 86400)
            XCTAssertEqual(try store.preserveBeforePurge(day: parisDay, now: later, calendar: paris), .summarized, key)
            let summary = root.appendingPathComponent("activity-days/\(key).json")
            let saved = try Data(contentsOf: summary)
            XCTAssertTrue(store.hasForeignTimeZoneSummary(day: localDay, calendar: newYork), key)
            _ = store.load(day: localDay, now: later, calendar: newYork)
            try store.backfill(now: later, calendar: newYork)
            XCTAssertEqual(try store.preserveBeforePurge(day: localDay, now: later, calendar: newYork), .summarized, key)
            XCTAssertEqual(try Data(contentsOf: summary), saved, key)
            try FileManager.default.removeItem(at: journal)
            let restored = try store.read(day: localDay, calendar: newYork)
            let localEnd = newYork.date(byAdding: .day, value: 1, to: localDay)!
            XCTAssertEqual(restored.date, localDay, key); XCTAssertEqual(restored.end, localEnd, key)
            XCTAssertEqual(restored.activeSeconds, 120, key); XCTAssertEqual(restored.breakdown.totalSeconds, 120, key)
            XCTAssertEqual(restored.segments.first?.start, localDay, key); XCTAssertEqual(restored.segments.last?.end, localEnd, key)
            XCTAssertTrue(zip(restored.segments, restored.segments.dropFirst()).allSatisfy { $0.end == $1.start }, key)
            XCTAssertNotEqual(store.load(day: localDay, now: later, calendar: newYork).dayReason, .purgedWithoutSummary, key)
        }
    }
    func testTargetedDayDeletionInvalidatesSummaryAndClearingRemovesDirectory() throws {
        let root = try root(); _ = try writeEvents(root: root)
        let store = GoalongActivityDayStore(root: root)
        try store.preserveBeforePurge(day: day, now: day.addingTimeInterval(86400))
        let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-memories"))
        let deleted = try cleaner.prepareDeletion(days: [day]).execute()
        XCTAssertEqual(deleted.activitySummaryFiles, 1)
        XCTAssertThrowsError(try store.read(day: day))
        try store.preserveBeforePurge(day: day, now: day.addingTimeInterval(86400))
        // R5-historique-01: the content-free purge marker goes with a full history clear too.
        try Data("purged\n".utf8).write(to: root.appendingPathComponent("activity-days/2026-08-09" + GoalongActivityDayStore.purgeMarkerSuffix))
        XCTAssertEqual(try cleaner.delete(since: nil).activitySummaryFiles, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("activity-days").path))
    }
    func testCacheRevisionChangesWhenSummaryAloneIsDeleted() throws {
        let root = try root(), file = try writeEvents(root: root), store = GoalongActivityDayStore(root: root)
        try store.preserveBeforePurge(day: day, now: day.addingTimeInterval(86400))
        try FileManager.default.removeItem(at: file)
        let before = GoalongActivityDayReader.sourceRevision(root: root, day: day, calendar: .current)
        _ = try DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-memories"))
            .prepareDeletion(days: [day]).execute()
        let after = GoalongActivityDayReader.sourceRevision(root: root, day: day, calendar: .current)
        XCTAssertNotEqual(before, after)
    }

    func testSummaryWritesCannotEnterDuringHistoryDeletionBarrier() {
        let barrier = DerivedHistoryWriteBarrier.shared
        let suspension = barrier.suspend(); defer { barrier.resume(suspension) }
        let value = GoalongActivityDayReader.load(root: URL(fileURLWithPath: "/unused"), day: day,
            now: day.addingTimeInterval(86400), calendar: .current, shouldContinue: { true })
        XCTAssertEqual(value.state, .incomplete); XCTAssertEqual(value.dayReason, .unreadable)
    }

    private func checkpoint(root: URL) -> URL {
        root.appendingPathComponent("activity-days/2026-08-10" + GoalongActivityCheckpointStore.suffix)
    }
    private func checkpointRetention(root: URL, days: Int) -> HistoryRetentionStore {
        HistoryRetentionStore(legacyRetentionDays: days, storage: HistoryRetentionStorage(
            policyFile: root.appendingPathComponent("retention-policy.json"),
            activationFile: root.appendingPathComponent("retention-policy-activated"),
            artifactDirectories: [
                .init(directory: root.appendingPathComponent("events"), dataClass: .detailedEvents, allowedSuffixes: [".jsonl"]),
                .init(directory: root.appendingPathComponent("activity-days"), dataClass: .detailedEvents,
                    allowedSuffixes: [GoalongActivityCheckpointStore.suffix]),
                .init(directory: root.appendingPathComponent("activity-days"), dataClass: .activitySummaries,
                    allowedSuffixes: GoalongActivityDayStore.summaryRetentionSuffixes)
            ], prepare: {}))
    }

    func testLiveRetentionStorageExpiresPurgeMarkersWithSummaries() {
        // B05-R2-01: the helper above declares its own suffixes; this guards the production list.
        let markerName = "2026-08-10" + GoalongActivityDayStore.purgeMarkerSuffix
        let activityDays = HistoryRetentionStorage.live.artifactDirectories.filter {
            $0.directory.lastPathComponent == GoalongActivityDayStore.directoryName
        }
        XCTAssertTrue(activityDays.contains { $0.dataClass == .activitySummaries && $0.recognizes(markerName) })
        XCTAssertTrue(activityDays.contains { $0.dataClass == .activitySummaries && $0.recognizes("2026-08-10.json") })
        XCTAssertFalse(activityDays.contains { $0.dataClass == .detailedEvents && $0.recognizes(markerName) })
    }

    func testPurgeMarkerExpiresWithTheDaySummaries() throws {
        // B05-R1-02: « Détail effacé » used to outlive the chosen summary duration forever.
        let calendar = Calendar.current
        func marker(_ root: URL, _ date: Date) -> URL {
            root.appendingPathComponent("activity-days/" + GoalongActivityDayStore.dayKey(date, calendar: calendar)
                + GoalongActivityDayStore.purgeMarkerSuffix)
        }
        func policy(summaryDays: Int) -> HistoryRetentionPolicy {
            .init(detailedEvents: .init(days: 1), semanticSnapshots: .init(days: 1), memories: .indefinite,
                  analysisCaches: .indefinite, minuteSeals: .indefinite, anchorReceipts: .indefinite,
                  activitySummaries: .init(days: summaryDays))
        }
        // An old marker expires with the summaries; a recent one stays.
        let root = try root(), recent = calendar.date(byAdding: .day, value: 150, to: day)!
        try FileManager.default.createDirectory(at: root.appendingPathComponent("activity-days"), withIntermediateDirectories: true)
        for date in [day, recent] { try Data("purged\n".utf8).write(to: marker(root, date)) }
        let store = checkpointRetention(root: root, days: 1)
        try store.activate(policy(summaryDays: 90))
        store.applyCleanup(now: calendar.date(byAdding: .day, value: 200, to: day)!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(root, day).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(root, recent).path))

        // A journal with nothing to summarize past the summary duration leaves no marker behind.
        let other = try self.root(), journal = try writeEvents(root: other)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(60), kind: .recorderHealth))
            + Data([10])).write(to: journal)
        let short = checkpointRetention(root: other, days: 1)
        try short.activate(policy(summaryDays: 5))
        short.applyCleanup(now: day.addingTimeInterval(10 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(other, day).path))
    }

    func testCheckpointExpiresWithDetailedEventsWhileSummaryRemains() throws {
        let root = try root(), journal = try writeEvents(root: root)
        _ = GoalongActivityDayStore(root: root).loadResumable(day: day, now: day.addingTimeInterval(86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
        let retention = checkpointRetention(root: root, days: 1)
        try retention.updateDetailedRetention(fromLegacyDays: 1)
        retention.applyCleanup(now: day.addingTimeInterval(10 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try GoalongActivityDayStore(root: root).read(day: day).activeSeconds, 120)
    }

    func testExpiredCheckpointCannotBeRecreatedAndCancelledLoadDoesNotWrite() throws {
        let root = try root(); _ = try writeEvents(root: root)
        let store = GoalongActivityDayStore(root: root)
        let expired = store.loadResumable(day: day, now: day.addingTimeInterval(10 * 86400), retentionDays: 1)
        XCTAssertEqual(expired.day.activeSeconds, 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
        let cancelled = store.loadResumable(day: day, now: day.addingTimeInterval(86400), shouldContinue: { false })
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
    }

    func testCheckpointAndSummaryAreBothRemovedByTargetedAndFullDeletion() throws {
        let root = try root(); _ = try writeEvents(root: root)
        let store = GoalongActivityDayStore(root: root)
        let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-memories"))
        for targeted in [true, false] {
            _ = store.loadResumable(day: day, now: day.addingTimeInterval(86400))
            try store.preserveBeforePurge(day: day, now: day.addingTimeInterval(86400))
            let result = try (targeted ? cleaner.prepareDeletion(days: [day]) : cleaner.prepareDeletion(since: nil)).execute()
            XCTAssertEqual(result.activitySummaryFiles, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
            XCTAssertThrowsError(try store.read(day: day))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("activity-days").path))
    }

    @MainActor func testActivityPageShowsPauseStateInsteadOfARetryableError() async throws {
        // R4-historique-03: during the global pause, Activité showed « Impossible de lire » + Réessayer.
        let root = try root(); _ = try writeEvents(root: root)
        _ = try GoalongGlobalPause.setPaused(true, in: root)
        let model = GoalongAnalyticsModel(root: root)
        await model.load(day: day, count: 1)
        XCTAssertTrue(model.paused)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
        _ = try GoalongGlobalPause.setPaused(false, in: root)
        await model.load(day: day, count: 1, force: true)
        XCTAssertFalse(model.paused)
    }

    func testGlobalPauseAndInvalidPausePreventCheckpointReadsAndWrites() throws {
        let root = try root(); _ = try writeEvents(root: root)
        _ = GoalongActivityDayStore(root: root).loadResumable(day: day, now: day.addingTimeInterval(86400))
        let saved = try Data(contentsOf: checkpoint(root: root))
        _ = try GoalongGlobalPause.setPaused(true, in: root)
        for invalid in [false, true] {
            if invalid { try Data("broken".utf8).write(to: GoalongGlobalPause.file(in: root)) }
            let blocked = GoalongActivityDayReader.loadResumable(root: root, day: day, resuming: nil,
                now: day.addingTimeInterval(86400), calendar: .current, shouldContinue: { true })
            XCTAssertEqual(blocked.day.state, .incomplete); XCTAssertNil(blocked.state)
            XCTAssertEqual(blocked.eventBytesRead, 0)
            XCTAssertEqual(try Data(contentsOf: checkpoint(root: root)), saved)
        }
    }

    func testHistoryBarrierPreventsCheckpointRestorationOrPublication() throws {
        let root = try root(); _ = try writeEvents(root: root)
        _ = GoalongActivityDayStore(root: root).loadResumable(day: day, now: day.addingTimeInterval(86400))
        let saved = try Data(contentsOf: checkpoint(root: root))
        let suspension = DerivedHistoryWriteBarrier.shared.suspend()
        defer { DerivedHistoryWriteBarrier.shared.resume(suspension) }
        let blocked = GoalongActivityDayReader.loadResumable(root: root, day: day, resuming: nil,
            now: day.addingTimeInterval(86400), calendar: .current, shouldContinue: { true })
        XCTAssertEqual(blocked.day.state, .incomplete); XCTAssertEqual(blocked.eventBytesRead, 0)
        XCTAssertNil(blocked.state); XCTAssertEqual(try Data(contentsOf: checkpoint(root: root)), saved)
    }

    func testUnreadableOrUnsupportedRetentionPolicyDoesNotPersistCheckpoint() throws {
        for unsupported in [false, true] {
            let root = try root(); _ = try writeEvents(root: root)
            let policy = root.appendingPathComponent("retention-policy.json")
            var bytes = Data("broken".utf8)
            if unsupported {
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
                    HistoryRetentionPolicy.migratingLegacy(retentionDays: 30))) as? [String: Any])
                value["schemaVersion"] = 99
                bytes = try JSONSerialization.data(withJSONObject: value)
            }
            try bytes.write(to: policy)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policy.path)
            let loaded = GoalongActivityDayReader.loadResumable(root: root, day: day, resuming: nil,
                now: day.addingTimeInterval(86400), calendar: .current, shouldContinue: { true })
            XCTAssertEqual(loaded.day.activeSeconds, 120)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint(root: root).path))
        }
    }

    func testWarmedReaderInvalidatesOnDeletionAndHonorsGlobalPause() async throws {
        let root = try root(), journal = try writeEvents(root: root)
        let reader = GoalongAnalyticsReader(root: root)
        let first = try await reader.read(ending: day, count: 1, force: false, preview: false)
        XCTAssertEqual(first.current.activeSeconds, 120)
        _ = try GoalongGlobalPause.setPaused(true, in: root)
        do {
            _ = try await reader.read(ending: day, count: 1, force: false, preview: false)
            XCTFail("A warmed cache cannot bypass the global pause")
        } catch { XCTAssertTrue(error is GoalongGlobalPause.PauseError) }
        _ = try GoalongGlobalPause.setPaused(false, in: root)
        try FileManager.default.removeItem(at: journal)
        _ = try DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-memories"))
            .prepareDeletion(days: [day]).execute()
        let deleted = try await reader.read(ending: day, count: 1, force: false, preview: false)
        XCTAssertEqual(deleted.current.activeSeconds, 0)
        XCTAssertEqual(deleted.current.days.first?.state, .noSource)
    }

    func testTodayReaderResumesAppendsButRejectsSameSizeRewriteAndChangedLastLine() async throws {
        let root = try root(), journal = try writeEvents(root: root), calendar = Calendar.current
        let now = day.addingTimeInterval(300), reader = GoalongAnalyticsReader(root: root)
        let first = try await reader.readToday(day, now: now, calendar: calendar)
        XCTAssertEqual(first.activeSeconds, 120)
        let saved = try Data(contentsOf: checkpoint(root: root))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: checkpoint(root: root).path)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var extra = try encoder.encode(HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(180),
            kind: .heartbeat, app: .init(name: "Editor", bundleIdentifier: "fixture.editor", processIdentifier: 1)))
        extra.append(10)
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd(); try handle.write(contentsOf: extra); try handle.close()
        let appended = try await reader.readToday(day, now: now.addingTimeInterval(30), calendar: calendar)
        let hashBytes = await reader.todayCheckpointBytesHashed, readBytes = await reader.todayEventBytesRead
        XCTAssertEqual(hashBytes, 0); XCTAssertEqual(readBytes, Int64(extra.count))
        XCTAssertEqual(appended, GoalongLocalAnalytics.load(root: root, day: day, now: now.addingTimeInterval(30)))
        XCTAssertEqual(try Data(contentsOf: checkpoint(root: root)), saved)
        // Keep inode, size, last line and mtime: ctime still rejects an earlier edit.
        let mtime = try FileManager.default.attributesOfItem(atPath: journal.path)[.modificationDate]!
        var changed = try Data(contentsOf: journal)
        let early = try XCTUnwrap(changed.range(of: Data("Editor".utf8)))
        changed.replaceSubrange(early, with: Data("Writer".utf8))
        let rewrite = try FileHandle(forWritingTo: journal)
        try rewrite.write(contentsOf: changed); try rewrite.close()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: journal.path)
        let edited = try await reader.readToday(day, now: now.addingTimeInterval(60), calendar: calendar)
        let editedBytes = await reader.todayEventBytesRead
        XCTAssertEqual(editedBytes, Int64(changed.count))
        XCTAssertEqual(edited, GoalongLocalAnalytics.load(root: root, day: day, now: now.addingTimeInterval(60)))
        // Growth cannot bypass the cursor's last-line check.
        let last = try XCTUnwrap(changed.range(of: Data("Editor".utf8), options: .backwards))
        changed.replaceSubrange(last, with: Data("Writer".utf8)); changed.append(extra)
        let growth = try FileHandle(forWritingTo: journal)
        try growth.write(contentsOf: changed); try growth.close()
        let invalid = try await reader.readToday(day, now: now.addingTimeInterval(90), calendar: calendar)
        let invalidBytes = await reader.todayEventBytesRead
        XCTAssertEqual(invalidBytes, Int64(changed.count))
        XCTAssertEqual(invalid, GoalongLocalAnalytics.load(root: root, day: day, now: now.addingTimeInterval(90)))
    }

    func testReaderClosesHeldDayBeforeSwitchingToToday() async throws {
        let root = try root(); _ = try writeEvents(root: root)
        let calendar = Calendar.current, reader = GoalongAnalyticsReader(root: root)
        _ = try await reader.readToday(day, now: day.addingTimeInterval(300), calendar: calendar)
        XCTAssertFalse(try GoalongActivityCheckpointStore(root: root).read(day: day).isFinished)
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        _ = try await reader.readToday(next, now: next.addingTimeInterval(60), calendar: calendar)
        XCTAssertTrue(try GoalongActivityCheckpointStore(root: root).read(day: day).isFinished)
    }

    @MainActor func testRetryAttemptsSurviveRestartLegacyDecodeAndOwnerCorrections() throws {
        let root = try root(), file = root.appendingPathComponent("work-classification.json")
        let definition = GoalongWorkDefinition(goals: "Project"), key = "abcdef0123456789"
        let legacy: [String: Any] = ["version": 1, "revision": definition.revision, "automatic": true,
            "entries": [key: ["verdict": "unclear", "byOwner": false, "seen": "2026-08-09"]], "corrections": []]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let store = GoalongWorkStore(fileURL: file, definition: { definition })
        XCTAssertEqual(store.entry(for: key)?.attempts, 1)
        XCTAssertEqual(store.entry(for: key)?.lastAskedDay, "2026-08-09")
        store.markAsked([key], revision: store.revision, day: "2026-08-10")
        store.merge([key: .init(verdict: .unclear)], revision: store.revision, day: "2026-08-10")
        let restored = GoalongWorkStore(fileURL: file, definition: { definition })
        XCTAssertEqual(restored.entry(for: key)?.attempts, 2)
        XCTAssertEqual(restored.verdicts.retries[key]?.lastAskedDay, "2026-08-10")
        restored.markAsked([key], revision: restored.revision, day: "2026-08-11")
        XCTAssertEqual(restored.entry(for: key)?.attempts, 3)
        let label = GoalongWorkContext.Label(application: "Editor", bundleIdentifier: nil, host: nil, title: nil)
        restored.correct(key: key, label: label, verdict: .unclear, task: nil, day: "2026-08-11")
        restored.markAsked([key], revision: restored.revision, day: "2026-08-12")
        XCTAssertEqual(restored.entry(for: key)?.byOwner, true)
        XCTAssertEqual(restored.entry(for: key)?.lastAskedDay, nil)
    }
    @MainActor func testFailedFirstRequestLeavesContextToClassify() throws {
        let root = try root(), file = root.appendingPathComponent("work-classification.json")
        let definition = GoalongWorkDefinition(goals: "Project"), key = "0123456789abcdef"
        let store = GoalongWorkStore(fileURL: file, definition: { definition })
        XCTAssertTrue(store.markAsked([key], revision: store.revision, day: "2026-08-10"))
        XCTAssertNil(store.entry(for: key))
        store.merge([key: .init(verdict: .unclear)], revision: store.revision, day: "2026-08-10")
        XCTAssertEqual(store.entry(for: key)?.attempts, 1)
        XCTAssertEqual(store.entry(for: key)?.lastAskedDay, "2026-08-10")
    }
    func testPrivacyFilterRequiresReviewedVisibleTextAndHonorsMasks() throws {
        let label = GoalongWorkContext.Label(application: "Editor", bundleIdentifier: "fixture.editor", host: "example.test", title: "Project")
        var selection = GoalongAnalysisSelection()
        let filter = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection)
        XCTAssertFalse(filter.permitsVisibleContext(label))
        selection.reviewed = true; selection.scope = GoalongAnalysisScope(visibleText: true)
        let allowed = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection)
        XCTAssertTrue(allowed.permitsVisibleContext(label))
        selection.scope?.excludedDomains = ["example.test"]
        XCTAssertFalse(GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy(), selection: selection).permitsVisibleContext(label))
    }
}
#endif
