#if os(macOS)
import Foundation
import LocalHistoryCore

/// Small adapter for the Activité reader; all summary implementation lives in Core.
enum GoalongActivityDayReader {
    /// A day's loader reads only the journal named after that day, so yesterday stays cached
    /// while today's journal grows. A new summary of the day is read once more.
    static func sourceRevision(root: URL, day: Date, calendar: Calendar) -> String {
        let summary = root.appendingPathComponent("activity-days/" + GoalongActivityDayStore.dayKey(day, calendar: calendar) + ".json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: summary.path)
        let checkpoint = root.appendingPathComponent("activity-days/" + GoalongActivityDayStore.dayKey(day, calendar: calendar)
            + GoalongActivityCheckpointStore.suffix)
        let checkpointAttributes = try? FileManager.default.attributesOfItem(atPath: checkpoint.path)
        return GoalongActivityCheckpointStore(root: root).sourceRevision(day: day, calendar: calendar) + "|summary|"
            + "\(attributes?[.systemFileNumber] ?? "missing")|\(attributes?[.size] ?? "-")|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            + "|checkpoint|\(checkpointAttributes?[.systemFileNumber] ?? "missing")|\(checkpointAttributes?[.size] ?? "-")|\((checkpointAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    static func load(root: URL, day: Date, now: Date, calendar: Calendar, shouldContinue: () -> Bool) -> GoalongLocalAnalytics.Day {
        let barrier = DerivedHistoryWriteBarrier.shared
        guard let pause = try? GoalongGlobalPause.admit(in: root), let permit = barrier.beginJob() else {
            return GoalongLocalAnalytics.build(events: [], day: day, now: now, calendar: calendar, incomplete: true)
        }
        defer { barrier.endJob(permit) }
        let policy = try? SupportDiagnostics.readPrivateFile(root.appendingPathComponent("retention-policy.json"), maximum: 65_536)
        let decoded = policy.flatMap { try? JSONDecoder().decode(HistoryRetentionPolicy.self, from: $0) }
        let days = decoded?.detailedEvents.days
        return GoalongActivityDayStore(root: root).load(day: day, now: now, calendar: calendar,
            retentionDays: policy == nil ? 30 : days, summaryRetentionDays: decoded?.activitySummaries.days,
            allowsCheckpoints: allowsCheckpoints(root: root, policy: decoded),
            shouldContinue: { shouldContinue() && barrier.isCurrent(permit) && (try? GoalongGlobalPause.revalidate(pause, in: root)) != nil })
    }

    static func loadResumable(root: URL, day: Date, resuming state: GoalongLocalAnalytics.ResumableDayState?,
                             now: Date, calendar: Calendar, shouldContinue: () -> Bool) -> GoalongLocalAnalytics.ResumableDayLoad {
        let barrier = DerivedHistoryWriteBarrier.shared
        guard let pause = try? GoalongGlobalPause.admit(in: root), let permit = barrier.beginJob() else {
            return GoalongLocalAnalytics.load(root: root, day: day, resuming: nil, now: now,
                calendar: calendar, shouldContinue: { false })
        }
        defer { barrier.endJob(permit) }
        let policy = try? SupportDiagnostics.readPrivateFile(root.appendingPathComponent("retention-policy.json"), maximum: 65_536)
        let decoded = policy.flatMap { try? JSONDecoder().decode(HistoryRetentionPolicy.self, from: $0) }
        return GoalongActivityDayStore(root: root).loadResumable(day: day, resuming: state,
            now: now, calendar: calendar, retentionDays: policy == nil ? 30 : decoded?.detailedEvents.days,
            allowsCheckpoints: allowsCheckpoints(root: root, policy: decoded),
            shouldContinue: { shouldContinue() && barrier.isCurrent(permit) && (try? GoalongGlobalPause.revalidate(pause, in: root)) != nil })
    }

    private static func allowsCheckpoints(root: URL, policy: HistoryRetentionPolicy?) -> Bool {
        if let policy { return policy.isSupportedForAutomaticCleanup }
        var info = stat()
        return lstat(root.appendingPathComponent("retention-policy.json").path, &info) != 0 && errno == ENOENT
    }
}

/// No polling: delayed launch/day-change runs, one cancellable day at a time at utility QoS.
@MainActor final class GoalongActivitySummaryBackfill {
    static let shared = GoalongActivitySummaryBackfill()
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?

    func start(root: URL = AppPaths.applicationSupportDirectory, delay: TimeInterval = 180) {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start(root: root, delay: delay) }
            }
        }
        task?.cancel()
        let barrier = DerivedHistoryWriteBarrier.shared
        let admission = barrier.admission()
        task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let admission else { return }
                let store = GoalongActivityDayStore(root: root), now = Date(), calendar = Calendar.current
                for day in try store.journalDays(before: now, calendar: calendar)
                    where GoalongActivityDayStore.isSettled(day, now: now, calendar: calendar) {
                    guard !Task.isCancelled, barrier.isCurrent(admission), let permit = barrier.beginJob(admission: admission) else { return }
                    autoreleasepool {
                        _ = GoalongActivityDayReader.load(root: root, day: day, now: now, calendar: calendar,
                            shouldContinue: { !Task.isCancelled && barrier.isCurrent(permit) })
                    }
                    barrier.endJob(permit)
                    await Task.yield()
                }
            } catch is CancellationError { } catch {
                SupportDiagnostics.shared.failure(error, component: .storage)
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }
}
#endif
