#if os(macOS)
    import Foundation
    import LocalHistoryCore

    struct HistoryDeletionOutcome: Equatable {
        let request: HistoryDeletionRequest
        let deletedEventCount: Int
        let deletedSemanticSnapshotCount: Int
        let removedDerivedFileCount: Int
        let removedProofFileCount: Int
        let rebuiltDays: [Date]
        let affectedDays: [Date]
        let proofsPreserved: Bool
        let warnings: [String]

        var totalDetailedItemCount: Int {
            deletedEventCount + deletedSemanticSnapshotCount
        }
    }

    /// Executes confirmed user deletions while keeping every derived representation
    /// consistent with the surviving detailed events. Raw and semantic directories are
    /// backed up until both mutations succeed; a failure restores both stores instead of
    /// reporting a partial success. Derived artifacts are invalidated before rebuilding,
    /// so a rebuild error cannot leave stale deleted content searchable.
    final class HistoryDeletionCoordinator {
        private let rootDirectory: URL
        private let codexMemoryDirectory: URL
        private let fileManager: FileManager
        private let queue: DispatchQueue
        private let calendar: Calendar

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            codexMemoryDirectory: URL? = nil,
            fileManager: FileManager = .default,
            calendar: Calendar = .current
        ) {
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
            self.calendar = calendar
            self.codexMemoryDirectory = codexMemoryDirectory
                ?? Self.defaultCodexMemoryDirectory(fileManager: fileManager)
            queue = DispatchQueue(
                label: "ai.goalong.localhistory.history-deletion",
                qos: .userInitiated
            )
        }

        func execute(
            _ request: HistoryDeletionRequest,
            completion: @escaping (Result<HistoryDeletionOutcome, Error>) -> Void
        ) {
            queue.async {
                let backup: DetailedBackup?
                do {
                    backup = self.requestTouchesDetailedData(request)
                        ? try self.makeDetailedBackup()
                        : nil
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }

                do {
                    let outcome = try self.executeSynchronously(request)
                    if let backup {
                        try? self.fileManager.removeItem(at: backup.URL)
                    }
                    DispatchQueue.main.async { completion(.success(outcome)) }
                } catch {
                    var finalError: Error = error
                    if let backup {
                        do {
                            try self.restoreDetailedBackup(backup)
                        } catch {
                            finalError = HistoryDeletionCoordinatorError.rollbackFailed(
                                deletionError: String(describing: finalError),
                                rollbackError: String(describing: error)
                            )
                        }
                    }
                    DispatchQueue.main.async { completion(.failure(finalError)) }
                }
            }
        }

        private func executeSynchronously(
            _ request: HistoryDeletionRequest
        ) throws -> HistoryDeletionOutcome {
            let eventsDirectory = rootDirectory.appendingPathComponent("events", isDirectory: true)
            let semanticDirectory = rootDirectory.appendingPathComponent("semantic", isDirectory: true)

            let eventResult: HistoryEventDeletionResult
            let semanticResult: HistorySemanticDeletionResult
            if requestTouchesDetailedData(request) {
                eventResult = try HistoryJSONLDeletionEngine.deleteEvents(
                    in: eventsDirectory,
                    request: request,
                    calendar: calendar,
                    fileManager: fileManager
                )
                semanticResult = try HistoryJSONLDeletionEngine.deleteSemanticSnapshots(
                    in: semanticDirectory,
                    request: request,
                    additionallyDeleting: eventResult.referencedSemanticSnapshotIDs,
                    calendar: calendar,
                    fileManager: fileManager
                )
            } else {
                eventResult = .empty
                semanticResult = .empty
            }

            let affectedDays = distinctDays(
                eventResult.affectedDays + semanticResult.affectedDays
            ).sorted()
            var removedDerived = 0
            var removedProofs = 0
            var rebuiltDays: [Date] = []
            var warnings: [String] = []

            switch request.scope {
            case .timelineEntry, .interval, .day:
                if let earliest = affectedDays.first {
                    // Compact memories and analysis are day-local. Computer History
                    // workflow evidence depends on previous days, so every later causal
                    // memory is invalidated and rebuilt in order.
                    for day in affectedDays {
                        removedDerived += try removeDayLocalDerivedFiles(for: day)
                    }
                    removedDerived += try removeComputerHistoryFiles(from: earliest)
                    let remainingDays = eventDays().filter { $0 >= earliest }
                    let affectedSet = Set(affectedDays)
                    for day in remainingDays where affectedSet.contains(day) {
                        do {
                            _ = try ActivityAnalysisStore(
                                rootDirectory: rootDirectory,
                                fileManager: fileManager
                            ).buildAndWrite(for: day)
                            _ = try LocalActivityMemoryStore(
                                rootDirectory: rootDirectory,
                                fileManager: fileManager
                            ).buildAndWrite(for: day)
                        } catch {
                            warnings.append(
                                "Day-local derived data for \(dayString(day)) could not be rebuilt: \(error)"
                            )
                            // Files were already invalidated, so deleted content cannot
                            // remain searchable even when regeneration is unavailable.
                        }
                    }
                    let historyStore = ComputerHistoryStore(
                        rootDirectory: rootDirectory,
                        codexMemoryDirectory: codexMemoryDirectory,
                        fileManager: fileManager
                    )
                    for day in remainingDays {
                        do {
                            if try historyStore.buildAndWrite(for: day) != nil {
                                rebuiltDays.append(day)
                            }
                        } catch {
                            warnings.append(
                                "Computer History for \(dayString(day)) could not be rebuilt: \(error)"
                            )
                        }
                    }
                }

            case .allDetailedData:
                removedDerived += try removeAllDerivedFiles()

            case .allMemories:
                removedDerived += try removeAllMemoryFiles()

            case .allDerivedData:
                removedDerived += try removeAllDerivedFiles()

            case .allLocalHistoryIncludingProofs:
                removedDerived += try removeAllDerivedFiles()
                removedProofs += try removeAllProofFiles()
                warnings.append(
                    "Commitments already published to an external verification service cannot be recalled by a local deletion."
                )
            }

            return HistoryDeletionOutcome(
                request: request,
                deletedEventCount: eventResult.deletedEventCount,
                deletedSemanticSnapshotCount: semanticResult.deletedSnapshotCount,
                removedDerivedFileCount: removedDerived,
                removedProofFileCount: removedProofs,
                rebuiltDays: distinctDays(rebuiltDays).sorted(),
                affectedDays: affectedDays,
                proofsPreserved: request.scope != .allLocalHistoryIncludingProofs,
                warnings: warnings
            )
        }

        private func requestTouchesDetailedData(
            _ request: HistoryDeletionRequest
        ) -> Bool {
            switch request.scope {
            case .timelineEntry, .interval, .day, .allDetailedData,
                 .allLocalHistoryIncludingProofs:
                return true
            case .allMemories, .allDerivedData:
                return false
            }
        }

        private func removeDayLocalDerivedFiles(for day: Date) throws -> Int {
            let base = dayString(day)
            return try removeIfPresent([
                rootDirectory
                    .appendingPathComponent("analysis", isDirectory: true)
                    .appendingPathComponent(base + ".analysis.json"),
                rootDirectory
                    .appendingPathComponent("analysis", isDirectory: true)
                    .appendingPathComponent(base + ".agent.md"),
                rootDirectory
                    .appendingPathComponent("memories", isDirectory: true)
                    .appendingPathComponent(base + ".memory.json"),
                rootDirectory
                    .appendingPathComponent("memories", isDirectory: true)
                    .appendingPathComponent(base + ".memory.md"),
            ])
        }

        private func removeComputerHistoryFiles(from day: Date) throws -> Int {
            let cutoff = calendar.startOfDay(for: day)
            let localDirectory = rootDirectory.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            let local = contents(of: localDirectory).filter {
                guard let candidate = dayFromFilename($0.lastPathComponent) else { return false }
                return candidate >= cutoff
            }
            let mirrored = contents(of: codexMemoryDirectory).filter {
                guard $0.lastPathComponent.hasSuffix("-goalong-computer-history.md"),
                    let candidate = dayFromFilename($0.lastPathComponent)
                else { return false }
                return candidate >= cutoff
            }
            return try removeIfPresent(local + mirrored)
        }

        private func removeAllMemoryFiles() throws -> Int {
            try removeIfPresent(
                contents(of: rootDirectory.appendingPathComponent("memories", isDirectory: true))
                    + contents(of: rootDirectory.appendingPathComponent("computer-history", isDirectory: true))
                    + contents(of: codexMemoryDirectory).filter {
                        $0.lastPathComponent.hasSuffix("-goalong-computer-history.md")
                    }
            )
        }

        private func removeAllDerivedFiles() throws -> Int {
            try removeIfPresent(
                contents(of: rootDirectory.appendingPathComponent("analysis", isDirectory: true))
                    + contents(of: rootDirectory.appendingPathComponent("memories", isDirectory: true))
                    + contents(of: rootDirectory.appendingPathComponent("computer-history", isDirectory: true))
                    + contents(of: codexMemoryDirectory).filter {
                        $0.lastPathComponent.hasSuffix("-goalong-computer-history.md")
                    }
            )
        }

        private func removeAllProofFiles() throws -> Int {
            let proofDirectories = [
                rootDirectory.appendingPathComponent("minute-seals", isDirectory: true),
                rootDirectory.appendingPathComponent("receipts", isDirectory: true),
                rootDirectory.appendingPathComponent("shares", isDirectory: true),
            ]
            var candidates = proofDirectories.flatMap(contents)
            candidates.append(
                rootDirectory.appendingPathComponent("anchor-upload-state.json")
            )
            return try removeIfPresent(candidates)
        }

        private func eventDays() -> [Date] {
            let directory = rootDirectory.appendingPathComponent("events", isDirectory: true)
            return distinctDays(
                contents(of: directory).compactMap {
                    dayFromFilename($0.lastPathComponent)
                }
            ).sorted()
        }

        private func removeIfPresent(_ URLs: [URL]) throws -> Int {
            var removed = 0
            for URL in URLs where fileManager.fileExists(atPath: URL.path) {
                try fileManager.removeItem(at: URL)
                removed += 1
            }
            return removed
        }

        private func contents(of directory: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        private func makeDetailedBackup() throws -> DetailedBackup {
            let URL = fileManager.temporaryDirectory.appendingPathComponent(
                "GoalongHistoryDeletionBackup-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: URL, withIntermediateDirectories: true)
            var existingNames = Set<String>()
            for name in ["events", "semantic"] {
                let source = rootDirectory.appendingPathComponent(name, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                existingNames.insert(name)
                try fileManager.copyItem(
                    at: source,
                    to: URL.appendingPathComponent(name, isDirectory: true)
                )
            }
            return DetailedBackup(URL: URL, existingDirectoryNames: existingNames)
        }

        private func restoreDetailedBackup(_ backup: DetailedBackup) throws {
            defer { try? fileManager.removeItem(at: backup.URL) }
            for name in ["events", "semantic"] {
                let destination = rootDirectory.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                guard backup.existingDirectoryNames.contains(name) else { continue }
                try fileManager.copyItem(
                    at: backup.URL.appendingPathComponent(name, isDirectory: true),
                    to: destination
                )
            }
        }

        private func distinctDays(_ values: [Date]) -> [Date] {
            var seen = Set<Date>()
            return values.map { calendar.startOfDay(for: $0) }
                .filter { seen.insert($0).inserted }
        }

        private func dayString(_ date: Date) -> String {
            Self.dayFormatter(calendar: calendar).string(
                from: calendar.startOfDay(for: date)
            )
        }

        private func dayFromFilename(_ filename: String) -> Date? {
            guard let range = filename.range(
                of: #"^\d{4}-\d{2}-\d{2}"#,
                options: .regularExpression
            ) else { return nil }
            return Self.dayFormatter(calendar: calendar)
                .date(from: String(filename[range]))
                .map { calendar.startOfDay(for: $0) }
        }

        private static func dayFormatter(calendar: Calendar) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }

        private static func defaultCodexMemoryDirectory(
            fileManager: FileManager
        ) -> URL {
            let configuredCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map {
                    URL(
                        fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                        isDirectory: true
                    )
                }
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
            return configuredCodexHome
                .appendingPathComponent("memories", isDirectory: true)
                .appendingPathComponent("extensions", isDirectory: true)
                .appendingPathComponent("goalong", isDirectory: true)
        }
    }

    private struct DetailedBackup {
        let URL: URL
        let existingDirectoryNames: Set<String>
    }

    enum HistoryDeletionCoordinatorError: Error, LocalizedError {
        case rollbackFailed(deletionError: String, rollbackError: String)

        var errorDescription: String? {
            switch self {
            case .rollbackFailed(let deletionError, let rollbackError):
                return "Deletion failed (\(deletionError)) and the detailed-data rollback also failed (\(rollbackError)). Stop capture and inspect the local data directory before continuing."
            }
        }
    }
#endif
