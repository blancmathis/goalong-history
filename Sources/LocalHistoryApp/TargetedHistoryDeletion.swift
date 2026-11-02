#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum TargetedHistoryDeletionRequest {
        case computerHistoryEpisode(id: String, day: Date)
        case activitySession(ActivitySession)
    }

    struct TargetedHistoryDeletionSelection: Equatable, Codable {
        let eventIDs: Set<String>
        let semanticSnapshotIDs: Set<String>
        let start: Date
        let end: Date
        let affectedDays: Set<Date>
        let semanticDays: Set<Date>
    }

    struct TargetedHistoryDeletionResolver {
        let rootDirectory: URL

        init(rootDirectory: URL = AppPaths.applicationSupportDirectory) {
            self.rootDirectory = rootDirectory.standardizedFileURL
        }

        func resolve(
            _ request: TargetedHistoryDeletionRequest
        ) throws -> TargetedHistoryDeletionSelection {
            switch request {
            case .computerHistoryEpisode(let episodeID, let day):
                return try resolveEpisode(id: episodeID, day: day)
            case .activitySession(let session):
                return try resolveSession(session)
            }
        }

        private func resolveEpisode(
            id episodeID: String,
            day: Date
        ) throws -> TargetedHistoryDeletionSelection {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: day)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                throw TargetedHistoryDeletionError.invalidInterval
            }
            let loaded = HistoryLocalStoreReader(rootDirectory: rootDirectory)
                .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)
            guard !loaded.metrics.wasCancelled,
                !loaded.metrics.sourceChangedDuringRead,
                !loaded.metrics.sourceAccessWasIncomplete,
                !loaded.metrics.evidenceBudgetExceeded,
                loaded.issues.isEmpty
            else {
                throw TargetedHistoryDeletionError.sourceIncomplete
            }
            guard let sourceIDs = ComputerHistoryEngine.exactSourceEventIDs(
                forEpisodeID: episodeID,
                events: loaded.events,
                semanticSnapshots: loaded.semanticSnapshots,
                day: dayStart,
                calendar: calendar
            ) else {
                throw TargetedHistoryDeletionError.selectionNoLongerExists
            }
            let eventIDs = Set(sourceIDs)
            let selected = loaded.events.filter { eventIDs.contains($0.id) }
            guard Set(selected.map(\.id)) == eventIDs else {
                throw TargetedHistoryDeletionError.sourceIncomplete
            }
            return try selection(
                events: selected,
                semanticSnapshots: loaded.semanticSnapshots,
                calendar: calendar
            )
        }

        private func resolveSession(
            _ session: ActivitySession
        ) throws -> TargetedHistoryDeletionSelection {
            guard session.start <= session.end else {
                throw TargetedHistoryDeletionError.invalidInterval
            }
            let loaded = HistoryLocalStoreReader(rootDirectory: rootDirectory)
                .loadActivityMemoryEvidence(
                    start: session.start,
                    endExclusive: Date(
                        timeIntervalSinceReferenceDate:
                            session.end.timeIntervalSinceReferenceDate.nextUp
                    )
                )
            guard !loaded.metrics.wasCancelled,
                !loaded.metrics.sourceChangedDuringRead,
                !loaded.metrics.sourceAccessWasIncomplete,
                !loaded.metrics.evidenceBudgetExceeded,
                loaded.issues.isEmpty
            else {
                throw TargetedHistoryDeletionError.sourceIncomplete
            }
            let sourceKey = DashboardDataReader.sessionSourceKey(for: session)
            let events = loaded.events.filter {
                $0.timestamp >= session.start
                    && $0.timestamp <= session.end
                    && DashboardDataReader.isSessionEvent($0)
                    && DashboardDataReader.sessionSourceKey(for: $0) == sourceKey
            }
            guard events.count == session.eventCount else {
                throw TargetedHistoryDeletionError.selectionNoLongerExists
            }
            return try selection(
                events: events,
                semanticSnapshots: loaded.semanticSnapshots,
                calendar: .current
            )
        }

        private func selection(
            events: [HistoryEvent],
            semanticSnapshots: [String: SemanticContextPayload],
            calendar: Calendar
        ) throws -> TargetedHistoryDeletionSelection {
            guard !events.isEmpty,
                events.count <= 32_768,
                let start = events.map(\.timestamp).min(),
                let end = events.map(\.timestamp).max()
            else {
                if events.count > 32_768 {
                    throw TargetedHistoryDeletionError.selectionExceedsLimit(
                        events.count,
                        32_768
                    )
                }
                throw TargetedHistoryDeletionError.selectionNoLongerExists
            }
            let semanticReferences = events.compactMap(\.semanticContext)
            let semanticSnapshotIDs = Set(semanticReferences.map(\.snapshotID))
            let semanticDays = Set(
                semanticReferences.map { calendar.startOfDay(for: $0.capturedAt) }
                    + semanticSnapshotIDs.compactMap { identifier in
                        semanticSnapshots[identifier].map {
                            calendar.startOfDay(for: $0.capturedAt)
                        }
                    }
            )
            return TargetedHistoryDeletionSelection(
                eventIDs: Set(events.map(\.id)),
                semanticSnapshotIDs: semanticSnapshotIDs,
                start: start,
                end: end,
                affectedDays: Set(events.map { calendar.startOfDay(for: $0.timestamp) }),
                semanticDays: semanticDays
            )
        }
    }

    extension TargetedHistoryDeletionRequest {
        /// Stable identity of the request. Hashed so the journal never stores titles or hosts.
        var journalKey: String {
            switch self {
            case .computerHistoryEpisode(let id, let day):
                return SHA256Digest.hashHex(
                    "episode\u{1F}\(id)\u{1F}\(AppPaths.localDayString(for: day))"
                )
            case .activitySession(let session):
                return SHA256Digest.hashHex(
                    [
                        "session",
                        String(session.start.timeIntervalSinceReferenceDate),
                        String(session.end.timeIntervalSinceReferenceDate),
                        String(session.eventCount),
                        DashboardDataReader.sessionSourceKey(for: session),
                    ].joined(separator: "\u{1F}")
                )
            }
        }
    }

    /// Resolved selections whose deletion started but did not finish. A retry of the same
    /// request replays the stored selection, because the partly deleted source can no longer
    /// be resolved. Holds only opaque identifiers and dates, never content.
    ///
    /// Entries never outlive the data they point to: « Tout effacer » removes the file,
    /// « Effacer depuis » and retention remove the entries of the erased period, and every
    /// entry expires after `maximumAge`. A later retry then resolves the source again.
    struct TargetedHistoryDeletionJournal {
        static let fileName = "targeted-deletion-pending.json"
        static let maximumEntries = 64
        static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

        private struct Entry: Codable {
            let recordedAt: Date
            let selection: TargetedHistoryDeletionSelection
        }

        /// One lock for the whole process: every read-modify-write of the journal (commit,
        /// « Tout effacer », « Effacer depuis », retention, expiry) runs under it, so two
        /// writers never overwrite each other's entries. It is a leaf lock: nothing under it
        /// waits for `DerivedHistoryWriteBarrier` or any other lock, so it cannot deadlock
        /// with it. Recursive, because the expiry purge inside `entries()` writes too.
        private static let lock = NSRecursiveLock()

        let fileURL: URL
        private let now: () -> Date
        /// Test seam: runs between the read and the write of a rewrite.
        private let beforeWrite: (() -> Void)?

        init(
            rootDirectory: URL,
            now: @escaping () -> Date = Date.init,
            beforeWrite: (() -> Void)? = nil
        ) {
            fileURL = rootDirectory.appendingPathComponent(Self.fileName)
            self.now = now
            self.beforeWrite = beforeWrite
        }

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return try body()
        }

        func pendingSelection(for key: String) -> TargetedHistoryDeletionSelection? {
            locked { entries()[key]?.selection }
        }

        func record(_ selection: TargetedHistoryDeletionSelection, for key: String) throws {
            try locked { try recordLocked(selection, for: key) }
        }

        private func recordLocked(
            _ selection: TargetedHistoryDeletionSelection,
            for key: String
        ) throws {
            var all = entries()
            all[key] = Entry(recordedAt: now(), selection: selection)
            if all.count > Self.maximumEntries {
                for stale in all.sorted(by: { $0.value.recordedAt < $1.value.recordedAt })
                    .prefix(all.count - Self.maximumEntries)
                {
                    all.removeValue(forKey: stale.key)
                }
            }
            try write(all)
        }

        func remove(_ key: String) throws {
            try removeEntries { stored, _ in stored == key }
        }

        /// « Tout effacer »: the whole journal goes with the history.
        func removeAll() throws {
            try locked { try removeAllLocked() }
        }

        private func removeAllLocked() throws {
            do { try FileManager.default.removeItem(at: fileURL) } catch CocoaError.fileNoSuchFile {}
        }

        /// « Effacer depuis »: drops every entry that reaches the erased period.
        func removeEntries(since cutoff: Date) throws {
            try removeEntries { _, selection in selection.end >= cutoff }
        }

        /// Retention: drops every entry that reaches before the cutoff.
        func removeEntries(before cutoff: Date) throws {
            try removeEntries { _, selection in selection.start < cutoff }
        }

        private func removeEntries(
            where shouldRemove: (String, TargetedHistoryDeletionSelection) -> Bool
        ) throws {
            try locked {
                let all = entries()
                let kept = all.filter { !shouldRemove($0.key, $0.value.selection) }
                guard kept.count != all.count else { return }
                if kept.isEmpty { try removeAllLocked() } else { try write(kept) }
            }
        }

        /// Live entries only. Expired ones are dropped from disk on the way.
        private func entries() -> [String: Entry] {
            let stored = storedEntries()
            let oldest = now().addingTimeInterval(-Self.maximumAge)
            let live = stored.filter { $0.value.recordedAt >= oldest }
            if live.count != stored.count {
                do {
                    if live.isEmpty { try removeAllLocked() } else { try write(live) }
                } catch {
                    Diagnostics.write("Expired targeted deletion journal entries not removed: \(error)")
                }
            }
            return live
        }

        private func storedEntries() -> [String: Entry] {
            guard let data = try? Data(contentsOf: fileURL) else { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode([String: Entry].self, from: data) else {
                Diagnostics.write("Unreadable targeted deletion journal ignored")
                return [:]
            }
            return decoded
        }

        private func write(_ all: [String: Entry]) throws {
            beforeWrite?()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(all).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    struct TargetedHistoryDeletionOutcome: Equatable {
        let rawCount: Int
        let semanticCount: Int
        let derived: DerivedHistoryDeletionResult

        var total: Int { rawCount + semanticCount + derived.total }
    }

    /// Commits one targeted deletion. The caller owns the derived-writer barrier. Work runs
    /// off the main thread; `completion` runs on main.
    ///
    /// Contract: either nothing is deleted, or the commit reports a failure and a retry of
    /// the same request completes it. Content goes first (semantic snapshots, then derived
    /// files), raw events last, and the resolved selection is journaled before the first
    /// deletion: a retry replays it even when the partly deleted source no longer resolves.
    final class TargetedHistoryDeletionCommitter {
        private let rootDirectory: URL
        private let rawStore: JSONLStore
        private let semanticStore: SemanticContextStore
        private let derivedCleaner: DerivedHistoryCleaner
        private let journal: TargetedHistoryDeletionJournal
        /// Test seam: rewrites the raw outcome to simulate a source change during the commit.
        private let transformRawOutcome: ((JSONLTargetedDeletionOutcome) -> JSONLTargetedDeletionOutcome)?

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            rawStore: JSONLStore,
            semanticStore: SemanticContextStore,
            derivedCleaner: DerivedHistoryCleaner,
            transformRawOutcome: ((JSONLTargetedDeletionOutcome) -> JSONLTargetedDeletionOutcome)? = nil
        ) {
            self.rootDirectory = rootDirectory.standardizedFileURL
            self.rawStore = rawStore
            self.semanticStore = semanticStore
            self.derivedCleaner = derivedCleaner
            journal = TargetedHistoryDeletionJournal(rootDirectory: self.rootDirectory)
            self.transformRawOutcome = transformRawOutcome
        }

        func commit(
            _ request: TargetedHistoryDeletionRequest,
            completion: @escaping (Result<TargetedHistoryDeletionOutcome, Error>) -> Void
        ) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let key = request.journalKey
                let selection: TargetedHistoryDeletionSelection
                let derivedPlan: DerivedHistoryDeletionPlan
                let isRetry: Bool
                do {
                    let pending = journal.pendingSelection(for: key)
                    isRetry = pending != nil
                    selection = try pending
                        ?? TargetedHistoryDeletionResolver(rootDirectory: rootDirectory)
                        .resolve(request)
                    try semanticStore.preflightSnapshotDeletion(
                        withIDs: selection.semanticSnapshotIDs,
                        on: selection.semanticDays
                    )
                    derivedPlan = try derivedCleaner.prepareDeletion(days: selection.affectedDays)
                    if !isRetry { try journal.record(selection, for: key) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                semanticStore.deleteSnapshots(
                    withIDs: selection.semanticSnapshotIDs,
                    on: selection.semanticDays
                ) { [self] semanticResult in
                    let semanticCount: Int
                    let derived: DerivedHistoryDeletionResult
                    do {
                        semanticCount = try semanticResult.get()
                        derived = try derivedPlan.execute()
                    } catch {
                        completion(.failure(error))
                        return
                    }
                    deleteRawEvents(
                        selection: selection,
                        key: key,
                        isRetry: isRetry
                    ) { [self] rawResult in
                        completion(
                            rawResult.flatMap { rawCount in
                                finish(key: key)
                                return .success(
                                    TargetedHistoryDeletionOutcome(
                                        rawCount: rawCount,
                                        semanticCount: semanticCount,
                                        derived: derived
                                    )
                                )
                            }
                        )
                    }
                }
            }
        }

        /// Raw events go last. A retry tolerates identifiers an earlier attempt removed.
        private func deleteRawEvents(
            selection: TargetedHistoryDeletionSelection,
            key: String,
            isRetry: Bool,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            rawStore.deleteEvents(
                withIDs: selection.eventIDs,
                from: selection.start,
                through: selection.end,
                requireEveryID: !isRetry
            ) { [self] rawResult in
                let raw: JSONLTargetedDeletionOutcome
                do {
                    let outcome = try rawResult.get()
                    raw = transformRawOutcome?(outcome) ?? outcome
                } catch {
                    completion(.failure(error))
                    return
                }
                guard isRetry || raw.eventCount >= selection.eventIDs.count else {
                    completion(.failure(TargetedHistoryDeletionError.sourceChangedDuringCommit))
                    return
                }
                // Rows can only reference the selected snapshots; any other one is removed
                // too, after the journal learns it so a retry still covers it.
                let extra = raw.semanticSnapshotIDs.subtracting(selection.semanticSnapshotIDs)
                guard !extra.isEmpty else {
                    completion(.success(raw.eventCount))
                    return
                }
                do {
                    try journal.record(
                        TargetedHistoryDeletionSelection(
                            eventIDs: selection.eventIDs,
                            semanticSnapshotIDs: selection.semanticSnapshotIDs.union(extra),
                            start: selection.start,
                            end: selection.end,
                            affectedDays: selection.affectedDays,
                            semanticDays: selection.semanticDays
                        ),
                        for: key
                    )
                } catch {
                    completion(.failure(error))
                    return
                }
                semanticStore.deleteSnapshots(withIDs: extra, on: nil) { result in
                    completion(result.map { _ in raw.eventCount })
                }
            }
        }

        private func finish(key: String) {
            do { try journal.remove(key) } catch {
                // Everything is deleted; a stale entry only makes a later retry a no-op replay.
                Diagnostics.write("Targeted deletion journal entry not removed: \(error)")
            }
        }
    }

    enum TargetedHistoryDeletionError: LocalizedError {
        case invalidInterval
        case sourceIncomplete
        case selectionNoLongerExists
        case selectionExceedsLimit(Int, Int)
        case sourceChangedDuringCommit

        var errorDescription: String? {
            switch self {
            case .invalidInterval:
                return "La période choisie est invalide."
            case .sourceIncomplete:
                return
                    "Goalong n’a pas pu lire toute la source d’origine en sécurité : aucune suppression n’a été tentée."
            case .selectionNoLongerExists:
                return
                    "L’élément choisi ne correspond plus à la source actuelle. Actualisez l’historique et réessayez."
            case .selectionExceedsLimit(let actual, let maximum):
                return
                    "L’élément choisi contient \(GoalongUIFormat.count(actual, "événement")), au-delà de la limite de suppression de \(GoalongUIFormat.count(maximum, "événement")). Choisissez une période plus courte."
            case .sourceChangedDuringCommit:
                return
                    "La source a changé avant la fin de la suppression. Goalong a invalidé les vues dérivées ; actualisez avant de réessayer."
            }
        }
    }
#endif
