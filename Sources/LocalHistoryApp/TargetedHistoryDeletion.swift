#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum TargetedHistoryDeletionRequest {
        case computerHistoryEpisode(id: String, day: Date)
        case activitySession(ActivitySession)
    }

    struct TargetedHistoryDeletionSelection: Equatable {
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

    enum TargetedHistoryDeletionError: LocalizedError {
        case invalidInterval
        case sourceIncomplete
        case selectionNoLongerExists
        case selectionExceedsLimit(Int, Int)
        case sourceChangedDuringCommit

        var errorDescription: String? {
            switch self {
            case .invalidInterval:
                return "The selected local-history interval is invalid."
            case .sourceIncomplete:
                return
                    "Goalong could not read the complete original source safely, so no targeted deletion was attempted."
            case .selectionNoLongerExists:
                return
                    "The selected item no longer matches the current source. Refresh Computer History and try again."
            case .selectionExceedsLimit(let actual, let maximum):
                return
                    "The selected item contains \(actual) source events, above the bounded deletion limit of \(maximum)."
            case .sourceChangedDuringCommit:
                return
                    "The selected source changed before every exact event could be removed. Goalong invalidated derived views; refresh before retrying."
            }
        }
    }
#endif
