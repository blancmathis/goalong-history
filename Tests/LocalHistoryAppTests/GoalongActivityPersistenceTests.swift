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
    func testRetentionKeepsJournalIfSummaryCannotBeSavedOrJournalIsInvalid() throws {
        for blockedSummary in [true, false] {
            let root = try root(), file = try writeEvents(root: root)
            if blockedSummary {
                try Data("blocked".utf8).write(to: root.appendingPathComponent("activity-days"))
            } else { try Data("invalid JSON\n".utf8).write(to: file) }
            let store = retention(root: root); try store.updateDetailedRetention(fromLegacyDays: 1)
            store.applyCleanup(now: day.addingTimeInterval(10 * 86400))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
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
        XCTAssertEqual(try cleaner.delete(since: nil).activitySummaryFiles, 1)
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
                .init(directory: root.appendingPathComponent("activity-days"), dataClass: .activitySummaries, allowedSuffixes: [".json"])
            ], prepare: {}))
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
