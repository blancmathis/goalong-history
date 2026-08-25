#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct ComputerHistoryRecentLoadResult: Equatable {
        let memories: [ComputerHistoryDayMemory]
        let isComplete: Bool
        let issues: [String]
    }

    /// Persists the structured causal memory separately from regenerable minute-level
    /// analysis. Markdown is regenerated from the structure on read and only one optional
    /// mirror is kept in Codex's local memory extension directory.
    final class ComputerHistoryStore {
        private static let currentStorageFormatVersion = 2
        private static let maximumStoredMemoryBytes = 32 * 1_024 * 1_024
        private static let defaultRecentEncodedByteBudget = 64 * 1_024 * 1_024
        private static let absoluteRecentEncodedByteBudget = 96 * 1_024 * 1_024
        private static let defaultRecentDirectoryEntryBudget = 20_000
        private static let absoluteRecentDirectoryEntryBudget = 50_000
        private static let defaultRecentDirectoryTimeBudget: TimeInterval = 2
        private static let absoluteRecentDirectoryTimeBudget: TimeInterval = 10
        private static let storageMutationLock = NSLock()

        struct RecentLoadLimits: Equatable {
            var maximumSingleFileBytes: Int
            var defaultCumulativeBytes: Int
            var absoluteCumulativeBytes: Int
            var maximumDiagnosticMessages: Int
            var maximumDirectoryEntries: Int
            var maximumDirectoryEnumerationSeconds: TimeInterval

            init(
                maximumSingleFileBytes: Int,
                defaultCumulativeBytes: Int,
                absoluteCumulativeBytes: Int,
                maximumDiagnosticMessages: Int,
                maximumDirectoryEntries: Int = ComputerHistoryStore.defaultRecentDirectoryEntryBudget,
                maximumDirectoryEnumerationSeconds: TimeInterval = ComputerHistoryStore
                    .defaultRecentDirectoryTimeBudget
            ) {
                self.maximumSingleFileBytes = maximumSingleFileBytes
                self.defaultCumulativeBytes = defaultCumulativeBytes
                self.absoluteCumulativeBytes = absoluteCumulativeBytes
                self.maximumDiagnosticMessages = maximumDiagnosticMessages
                self.maximumDirectoryEntries = maximumDirectoryEntries
                self.maximumDirectoryEnumerationSeconds = maximumDirectoryEnumerationSeconds
            }

            static let production = RecentLoadLimits(
                maximumSingleFileBytes: ComputerHistoryStore.maximumStoredMemoryBytes,
                defaultCumulativeBytes: ComputerHistoryStore.defaultRecentEncodedByteBudget,
                absoluteCumulativeBytes: ComputerHistoryStore.absoluteRecentEncodedByteBudget,
                maximumDiagnosticMessages: 8,
                maximumDirectoryEntries: ComputerHistoryStore.defaultRecentDirectoryEntryBudget,
                maximumDirectoryEnumerationSeconds: ComputerHistoryStore
                    .defaultRecentDirectoryTimeBudget
            )

            fileprivate func validated() -> RecentLoadLimits {
                let absolute = min(
                    max(1, absoluteCumulativeBytes),
                    ComputerHistoryStore.absoluteRecentEncodedByteBudget
                )
                return RecentLoadLimits(
                    maximumSingleFileBytes: min(
                        max(1, maximumSingleFileBytes),
                        ComputerHistoryStore.maximumStoredMemoryBytes
                    ),
                    defaultCumulativeBytes: min(
                        max(1, defaultCumulativeBytes),
                        min(absolute, ComputerHistoryStore.defaultRecentEncodedByteBudget)
                    ),
                    absoluteCumulativeBytes: absolute,
                    maximumDiagnosticMessages: min(max(0, maximumDiagnosticMessages), 32),
                    maximumDirectoryEntries: min(
                        max(1, maximumDirectoryEntries),
                        ComputerHistoryStore.absoluteRecentDirectoryEntryBudget
                    ),
                    maximumDirectoryEnumerationSeconds: min(
                        max(0.001, maximumDirectoryEnumerationSeconds),
                        ComputerHistoryStore.absoluteRecentDirectoryTimeBudget
                    )
                )
            }
        }

        private let fileManager = FileManager.default
        private let rootDirectory: URL
        private let memoryDirectory: URL
        private let codexMemoryDirectory: URL
        private let recentLoadLimits: RecentLoadLimits
        private let diagnosticSink: (String) -> Void
        private let persistedDataReadObserver: ((URL, Data) -> Void)?
        private let beforeAtomicRename: ((URL) -> Void)?
        private let evidenceLoader: (Date, Date) -> ComputerHistoryEvidenceLoad
        private let derivedWriteBarrier: DerivedHistoryWriteBarrier
        private let recentLoadClock: () -> TimeInterval
        private let recentLoadOperationLock = NSLock()

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            codexMemoryDirectory: URL? = nil,
            recentLoadLimits: RecentLoadLimits = .production,
            diagnosticSink: @escaping (String) -> Void = { Diagnostics.write($0) },
            persistedDataReadObserver: ((URL, Data) -> Void)? = nil,
            beforeAtomicRename: ((URL) -> Void)? = nil,
            evidenceLoader: ((Date, Date) -> ComputerHistoryEvidenceLoad)? = nil,
            derivedWriteBarrier: DerivedHistoryWriteBarrier = .shared,
            recentLoadClock: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            }
        ) {
            self.rootDirectory = rootDirectory
            memoryDirectory = rootDirectory.appendingPathComponent("computer-history", isDirectory: true)
            self.codexMemoryDirectory = codexMemoryDirectory ?? Self.codexMemoryDirectoryURL()
            self.recentLoadLimits = recentLoadLimits.validated()
            self.diagnosticSink = diagnosticSink
            self.persistedDataReadObserver = persistedDataReadObserver
            self.beforeAtomicRename = beforeAtomicRename
            self.evidenceLoader = evidenceLoader ?? { start, endExclusive in
                HistoryLocalStoreReader(rootDirectory: rootDirectory)
                    .loadComputerHistoryEvidence(start: start, endExclusive: endExclusive)
            }
            self.derivedWriteBarrier = derivedWriteBarrier
            self.recentLoadClock = recentLoadClock
        }

        /// Directories containing Computer History's long-lived memories.
        /// HistoryRetentionStore treats both the authoritative Goalong copy and the
        /// optional Codex mirror as the same `.memories` data class so they expire
        /// together instead of leaving an orphaned mirror after local cleanup.
        static func retentionDirectories(rootDirectory: URL) -> [URL] {
            [
                rootDirectory.appendingPathComponent("computer-history", isDirectory: true),
                codexMemoryDirectoryURL(),
            ]
        }

        @discardableResult
        func buildAndWrite(for day: Date) throws -> ComputerHistoryDayMemory? {
            let start = Calendar.current.startOfDay(for: day)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
            let loaded = evidenceLoader(start, next)
            if loaded.metrics.wasCancelled {
                throw StorageError.incompleteSourceEvidence(
                    "the bounded source pass was cancelled"
                )
            }
            if loaded.metrics.sourceChangedDuringRead {
                throw StorageError.incompleteSourceEvidence(
                    "a source changed while it was read"
                )
            }
            if loaded.metrics.sourceAccessWasIncomplete {
                throw StorageError.incompleteSourceEvidence(
                    "one or more retained source files could not be opened safely"
                )
            }
            if loaded.metrics.evidenceBudgetExceeded {
                throw StorageError.incompleteSourceEvidence(
                    "the 32,768-row or 64 MiB retained-evidence budget was exceeded"
                )
            }
            if let issue = loaded.issues.first {
                throw StorageError.incompleteSourceEvidence(issue.message)
            }
            // Raw events may have expired while the long-lived Computer History memory is
            // still intentionally retained. Source absence is therefore not deletion
            // authority: only the explicit clear-history path may remove stored memories.
            guard !loaded.events.isEmpty else { return nil }
            for issue in loaded.issues {
                Diagnostics.write(
                    "Computer History load gap: \(issue.path):\(issue.line.map(String.init) ?? "-") \(issue.message)"
                )
            }

            let prior = loadRecent(before: start, maximumDays: 30, renderMarkdown: false)
            guard prior.isComplete else {
                throw StorageError.incompleteRecentMemoryListing
            }
            let memory = ComputerHistoryEngine.analyze(
                events: loaded.events,
                semanticSnapshots: loaded.semanticSnapshots,
                day: start,
                priorMemories: prior.memories,
                sourceJournalSummary: loaded.sourceJournalSummary
            )
            return try write(memory, for: start)
        }

        func loadStored(for day: Date) -> ComputerHistoryDayMemory? {
            guard let loaded = loadPersistedMemory(at: JSONFile(for: day)),
                dayString(loaded.stored.dayStart) == dayString(day)
            else { return nil }
            let memory = loaded.stored.rehydrated()
            migrateLegacyStorageIfNeeded(loaded)
            return memory
        }

        func loadRecent(maximumDays: Int = 30) -> ComputerHistoryRecentLoadResult {
            loadRecent(before: .distantFuture, maximumDays: maximumDays, renderMarkdown: true)
        }

        func answer(_ query: String, maximumDays: Int = 30) -> ComputerHistoryAnswer {
            let boundedDays = min(max(1, maximumDays), 365)
            let recent = loadRecent(
                before: .distantFuture,
                maximumDays: boundedDays,
                renderMarkdown: false
            )
            let sourceSearch: ComputerHistorySourceSearchResult?
            if ComputerHistorySearchService.shouldSearchRawSources(for: query) {
                let now = Date()
                let today = Calendar.current.startOfDay(for: now)
                let firstDay = Calendar.current.date(
                    byAdding: .day,
                    value: -(boundedDays - 1),
                    to: today
                ) ?? today
                sourceSearch = HistoryLocalStoreReader(rootDirectory: rootDirectory)
                    .searchComputerHistorySource(
                        query: query,
                        start: firstDay,
                        endExclusive: now.addingTimeInterval(0.001)
                    )
                for issue in sourceSearch?.issues ?? [] {
                    diagnosticSink(
                        "Computer History source search gap: \(issue.path):"
                            + "\(issue.line.map(String.init) ?? "-") \(issue.message)"
                    )
                }
            } else {
                sourceSearch = nil
            }
            let baseAnswer = ComputerHistorySearchService(
                memories: recent.memories,
                sourceSearch: sourceSearch
            ).ask(query)
            guard !recent.isComplete else { return baseAnswer }
            return ComputerHistoryAnswer(
                schemaVersion: baseAnswer.schemaVersion,
                query: baseAnswer.query,
                generatedAt: baseAnswer.generatedAt,
                answer: baseAnswer.answer,
                hits: baseAnswer.hits,
                limitations: baseAnswer.limitations + [
                    "Retained Computer History loading was incomplete ("
                        + "\(max(1, recent.issues.count)) bounded issue(s)); results use only "
                        + "readable last-known-good memories and absence is not exhaustive."
                ]
            )
        }

        func modificationDate(for day: Date) -> Date? {
            let eventFile = rootDirectory
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent(dayString(day) + ".jsonl")
            return try? eventFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        /// Files that represent one retained Computer History memory. The compact JSON is
        /// authoritative; the Markdown file is the sole optional Codex-facing projection.
        func memoryFileURLs(for day: Date) -> [URL] {
            [JSONFile(for: day), CodexMarkdownFile(for: day)]
        }

        /// Removes only Computer History-owned memory files, never raw events, seals,
        /// Screen Time, Agent Activity, or unrelated files. A matching symlink or other
        /// non-regular node aborts the operation before any deletion.
        @discardableResult
        func deleteMemories(since cutoff: Date? = nil) throws -> Int {
            let plans = try deletionPlans(
                since: cutoff,
                trustedAncestor: OwnedFileDeletionPlan.trustedAncestor(
                    for: memoryDeletionDirectories
                )
            )
            return try OwnedFileDeletionPlan.execute(plans)
        }

        var memoryDeletionDirectories: [URL] {
            [memoryDirectory, codexMemoryDirectory]
        }

        /// Internal so DerivedHistoryCleaner can preflight Computer History together with
        /// every other derived category before any category is modified.
        func deletionPlans(
            since cutoff: Date? = nil,
            trustedAncestor: URL
        ) throws -> [OwnedFileDeletionPlan] {
            let cutoffKey = cutoff.map(dayString)
            var plans: [OwnedFileDeletionPlan] = []

            for (directory, dayKey) in [
                (memoryDirectory, dayKeyFromGoalongOwnedMemoryFile),
                (codexMemoryDirectory, dayKeyFromCodexMirrorFile),
            ] {
                if let plan = try OwnedFileDeletionPlan.prepare(
                    directory: directory,
                    trustedAncestor: trustedAncestor,
                    cutoffKey: cutoffKey,
                    dayKey: dayKey
                ) {
                    plans.append(plan)
                }
            }
            return plans
        }

        private func loadRecent(
            before date: Date,
            maximumDays: Int,
            renderMarkdown: Bool
        ) -> ComputerHistoryRecentLoadResult {
            recentLoadOperationLock.lock()
            defer { recentLoadOperationLock.unlock() }
            let limit = min(max(1, maximumDays), 365)
            let cumulativeByteBudget = limit <= 30
                ? recentLoadLimits.defaultCumulativeBytes
                : recentLoadLimits.absoluteCumulativeBytes
            // Keep a fixed bounded backfill window. Scaling this with `limit` made
            // `maximumDays: 1` stop after only four corrupt recent files even when an
            // older valid memory was available.
            let maximumCandidateAttempts = 512
            var collectedIssues: [String] = []
            var diagnostics = BoundedRecentLoadDiagnostics(
                maximumMessages: recentLoadLimits.maximumDiagnosticMessages,
                sink: { [diagnosticSink] message in
                    collectedIssues.append(message)
                    diagnosticSink(message)
                }
            )

            func result(
                _ memories: [ComputerHistoryDayMemory],
                isComplete: Bool
            ) -> ComputerHistoryRecentLoadResult {
                diagnostics.finish()
                return ComputerHistoryRecentLoadResult(
                    memories: memories,
                    isComplete: isComplete,
                    issues: collectedIssues
                )
            }

            let directoryDescriptor: Int32
            do {
                guard let opened = try openSecureDirectory(
                    memoryDirectory,
                    createIfMissing: false
                ) else {
                    return result([], isComplete: true)
                }
                directoryDescriptor = opened
            } catch {
                diagnostics.report(
                    "Computer History recent-memory directory could not be opened safely: "
                        + error.localizedDescription
                )
                return result([], isComplete: false)
            }
            defer { Darwin.close(directoryDescriptor) }

            var initialDirectoryStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &initialDirectoryStatus) == 0,
                Self.isDirectory(initialDirectoryStatus)
            else {
                diagnostics.report(
                    "Computer History recent-memory directory could not be inspected safely."
                )
                return result([], isComplete: false)
            }
            let enumerationDescriptor = Darwin.dup(directoryDescriptor)
            guard enumerationDescriptor >= 0 else {
                diagnostics.report(
                    "Computer History recent-memory directory could not be duplicated for listing."
                )
                return result([], isComplete: false)
            }
            guard let directoryStream = Darwin.fdopendir(enumerationDescriptor) else {
                let code = errno
                Darwin.close(enumerationDescriptor)
                diagnostics.report(
                    "Computer History recent-memory directory could not be listed: "
                        + String(cString: strerror(code))
                )
                return result([], isComplete: false)
            }
            defer { Darwin.closedir(directoryStream) }

            let startedAt = recentLoadClock()
            var visitedEntries = 0
            var qualifyingCandidateCount = 0
            var candidates = BoundedNewestCandidates(capacity: maximumCandidateAttempts)
            var exhaustedBudgetMessage: String?
            var listingErrorCode: Int32?
            var listingHadCandidateGap = false

            // `readdir` advances lazily on a duplicate of the pinned directory descriptor.
            // Candidate inspection and later reads remain relative to the original capability.
            while true {
                errno = 0
                guard let entry = Darwin.readdir(directoryStream) else {
                    if errno != 0 { listingErrorCode = errno }
                    break
                }
                let name = Self.directoryEntryName(entry)
                if name == "." || name == ".." { continue }
                guard visitedEntries < recentLoadLimits.maximumDirectoryEntries else {
                    exhaustedBudgetMessage =
                        "Computer History recent-memory listing reached the "
                        + "\(recentLoadLimits.maximumDirectoryEntries)-entry budget; "
                        + "no partial newest-day result was returned."
                    break
                }
                guard recentLoadClock() - startedAt
                    < recentLoadLimits.maximumDirectoryEnumerationSeconds
                else {
                    exhaustedBudgetMessage =
                        "Computer History recent-memory listing reached the "
                        + "\(recentLoadLimits.maximumDirectoryEnumerationSeconds)-second "
                        + "time budget; no partial newest-day result was returned."
                    break
                }
                visitedEntries += 1

                let candidateURL = memoryDirectory.appendingPathComponent(name)
                guard
                    let key = dayKeyFromMemoryFile(candidateURL),
                    let day = dayFromMemoryFile(candidateURL),
                    day < date
                else { continue }
                qualifyingCandidateCount += 1
                var status = stat()
                let statusResult = name.withCString {
                    Darwin.fstatat(
                        directoryDescriptor,
                        $0,
                        &status,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard statusResult == 0,
                    Self.isRegularFile(status),
                    let byteCount = Int(exactly: status.st_size),
                    byteCount >= 0
                else {
                    listingHadCandidateGap = true
                    diagnostics.report(
                        "Computer History skipped \(key): the owned memory path was "
                            + "unreadable or not a regular file."
                    )
                    continue
                }
                let identity = RecentFileIdentity(status)
                candidates.insert(
                    RecentCandidate(
                        URL: candidateURL,
                        day: day,
                        key: key,
                        byteCount: byteCount,
                        identity: identity
                    )
                )
            }

            if exhaustedBudgetMessage == nil,
                recentLoadClock() - startedAt
                    >= recentLoadLimits.maximumDirectoryEnumerationSeconds
            {
                exhaustedBudgetMessage =
                    "Computer History recent-memory listing reached the "
                    + "\(recentLoadLimits.maximumDirectoryEnumerationSeconds)-second "
                    + "time budget; no partial newest-day result was returned."
            }

            if let listingErrorCode {
                diagnostics.report(
                    "Computer History recent-memory listing failed: "
                        + String(cString: strerror(listingErrorCode))
                )
                return result([], isComplete: false)
            }
            if let exhaustedBudgetMessage {
                // Stopping before the enumerator is exhausted cannot prove which entries
                // are globally newest. Fail closed instead of returning a plausible but
                // potentially stale subset under the exact-newest API contract.
                diagnostics.report(exhaustedBudgetMessage)
                return result([], isComplete: false)
            }
            var finalDirectoryStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &finalDirectoryStatus) == 0,
                Self.sameDirectoryListingSnapshot(
                    initialDirectoryStatus,
                    finalDirectoryStatus
                ),
                secureDirectoryPathMatches(
                    descriptor: directoryDescriptor,
                    directory: memoryDirectory
                )
            else {
                diagnostics.report(
                    "Computer History recent-memory directory changed while it was listed; "
                        + "no partial newest-day result was returned."
                )
                return result([], isComplete: false)
            }

            // A corrupt recent file must not consume a result slot and hide a valid older
            // day. Decoding is nevertheless bounded so a damaged directory cannot cause an
            // unbounded scan. Results remain oldest-to-newest, matching the prior contract.
            var memories: [ComputerHistoryDayMemory] = []
            memories.reserveCapacity(limit)
            var preparedLegacyMigration: LoadedPersistedMemory?
            var consumedEncodedBytes = 0
            var hadCandidateGap = false
            var examinedCandidates: [RecentCandidate] = []
            examinedCandidates.reserveCapacity(min(limit * 4, maximumCandidateAttempts))

            for candidate in candidates.newestFirst() {
                examinedCandidates.append(candidate)
                guard candidate.byteCount <= recentLoadLimits.maximumSingleFileBytes else {
                    hadCandidateGap = true
                    diagnostics.report(
                        "Computer History skipped \(candidate.key): encoded memory is "
                            + "\(candidate.byteCount) bytes; daily limit is "
                            + "\(recentLoadLimits.maximumSingleFileBytes) bytes."
                    )
                    continue
                }
                guard candidate.byteCount <= cumulativeByteBudget - consumedEncodedBytes else {
                    hadCandidateGap = true
                    diagnostics.report(
                        "Computer History skipped \(candidate.key): cumulative encoded-memory "
                            + "budget of \(cumulativeByteBudget) bytes is exhausted."
                    )
                    continue
                }

                // Reserve the stat-observed bytes before reading. Corrupt input consumes
                // budget too, preventing a directory full of bad maximum-sized files from
                // forcing an unbounded sequence of transient allocations.
                consumedEncodedBytes += candidate.byteCount
                let decoded: (
                    memory: ComputerHistoryDayMemory,
                    migration: LoadedPersistedMemory?
                )? = autoreleasepool {
                    guard let loaded = try? loadPersistedMemory(
                        name: candidate.URL.lastPathComponent,
                        directoryDescriptor: directoryDescriptor,
                        fileURL: candidate.URL,
                        maximumBytes: recentLoadLimits.maximumSingleFileBytes,
                        expectedByteCount: candidate.byteCount,
                        expectedIdentity: candidate.identity
                    ),
                        loaded.stored.dayStart < date,
                        dayString(loaded.stored.dayStart) == dayString(candidate.day)
                    else { return nil }
                    // `loadRecent` must stay read-only until its complete listing and all
                    // selected path identities have been revalidated. Direct `loadStored`
                    // reads still perform the best-effort CAS migration.
                    let memory = loaded.stored.rehydrated(renderMarkdown: renderMarkdown)
                    let needsMigration =
                        (loaded.stored.storageFormatVersion ?? 1)
                            < Self.currentStorageFormatVersion
                        || !loaded.stored.hasSameAnalysis(as: memory)
                    var migration: LoadedPersistedMemory?
                    if needsMigration, preparedLegacyMigration == nil {
                        // Keep at most one original byte buffer until the complete
                        // listing/path snapshot is validated. The full legacy arrays
                        // are released with `loaded`; this candidate shares only the
                        // already compact returned analysis and one bounded source file.
                        var compactStored = PersistedMemory(memory)
                        compactStored.storageFormatVersion = 1
                        migration = LoadedPersistedMemory(
                            URL: loaded.URL,
                            data: loaded.data,
                            stored: compactStored,
                            directoryIdentity: loaded.directoryIdentity
                        )
                    }
                    return (
                        memory,
                        migration
                    )
                }
                guard let decoded else {
                    hadCandidateGap = true
                    diagnostics.report(
                        "Computer History skipped \(candidate.key): encoded memory is corrupt, "
                            + "unreadable, or changed during loading."
                    )
                    continue
                }
                memories.append(decoded.memory)
                if preparedLegacyMigration == nil, let migration = decoded.migration {
                    preparedLegacyMigration = migration
                }
                if memories.count == limit { break }
            }

            if memories.count < limit,
                qualifyingCandidateCount > maximumCandidateAttempts
            {
                diagnostics.reportFinal(
                    "Computer History recent-memory listing required more than "
                        + "\(maximumCandidateAttempts) bounded backfill candidates; "
                        + "no partial newest-day result was returned."
                )
                return result([], isComplete: false)
            }

            guard examinedCandidates.allSatisfy({ candidate in
                Self.recentFileIdentity(
                    name: candidate.URL.lastPathComponent,
                    directoryDescriptor: directoryDescriptor
                ) == candidate.identity
            }) else {
                diagnostics.reportFinal(
                    "Computer History selected recent-memory files changed while they were "
                        + "loaded; no partial newest-day result was returned."
                )
                return result([], isComplete: false)
            }
            var completedDirectoryStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &completedDirectoryStatus) == 0,
                Self.sameDirectoryListingSnapshot(
                    initialDirectoryStatus,
                    completedDirectoryStatus
                ),
                secureDirectoryPathMatches(
                    descriptor: directoryDescriptor,
                    directory: memoryDirectory
                )
            else {
                diagnostics.reportFinal(
                    "Computer History recent-memory directory changed while memories were "
                        + "loaded; no partial newest-day result was returned."
                )
                return result([], isComplete: false)
            }

            // The complete read-only snapshot is now proven. Compact at most one
            // selected legacy day through the normal CAS/barrier path. This makes
            // progress on every load without a second read or an unbounded collection
            // of original byte buffers. Failure never invalidates the readable result.
            if let preparedLegacyMigration {
                migrateLegacyStorageIfNeeded(preparedLegacyMigration)
            }
            return result(
                Array(memories.reversed()),
                isComplete: !hadCandidateGap && !listingHadCandidateGap
            )
        }

        /// Internal so the storage contract can be tested without writing real history.
        @discardableResult
        func write(
            _ memory: ComputerHistoryDayMemory,
            for day: Date
        ) throws -> ComputerHistoryDayMemory {
            try Self.withStorageMutationLock {
                try prepareDirectory(memoryDirectory)
                let JSONURL = JSONFile(for: day)
                let existing = loadPersistedMemory(at: JSONURL)

                var stored: PersistedMemory
                var preserveUnknownFutureFormat = false
                if let existing, existing.stored.hasSameAnalysis(as: memory) {
                    stored = existing.stored
                    if (stored.storageFormatVersion ?? 1) <= Self.currentStorageFormatVersion {
                        stored.storageFormatVersion = Self.currentStorageFormatVersion
                    } else {
                        // Do not rewrite a future format and silently discard fields this build
                        // does not understand when its analysis is otherwise unchanged.
                        preserveUnknownFutureFormat = true
                    }
                } else {
                    stored = PersistedMemory(memory)
                }

                if !preserveUnknownFutureFormat {
                    let encoded = try Self.encode(stored)
                    guard encoded.count <= Self.maximumStoredMemoryBytes else {
                        throw StorageError.memoryTooLarge(
                            actualBytes: encoded.count,
                            maximumBytes: Self.maximumStoredMemoryBytes
                        )
                    }
                    try writeAtomicallyIfChanged(
                        encoded,
                        to: JSONURL
                    )
                    try removeRedundantLocalMarkdown(for: day)
                }

                let effectiveMemory = stored.rehydrated()
                do {
                    try prepareDirectory(codexMemoryDirectory)
                    let codexURL = CodexMarkdownFile(for: day)
                    try writeAtomicallyIfChanged(Data(effectiveMemory.markdown.utf8), to: codexURL)
                } catch {
                    // The compact Goalong JSON remains authoritative if a custom CODEX_HOME
                    // is unavailable. Its Markdown can always be regenerated on demand.
                    Diagnostics.write("Could not mirror Computer History memory into Codex: \(error)")
                }
                return effectiveMemory
            }
        }

        private func loadPersistedMemory(
            at fileURL: URL,
            maximumBytes: Int = ComputerHistoryStore.maximumStoredMemoryBytes,
            expectedByteCount: Int? = nil
        ) -> LoadedPersistedMemory? {
            do {
                guard let directoryDescriptor = try openSecureDirectory(
                    fileURL.deletingLastPathComponent(),
                    createIfMissing: false
                ) else { return nil }
                defer { Darwin.close(directoryDescriptor) }
                let loaded = try loadPersistedMemory(
                    name: fileURL.lastPathComponent,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL,
                    maximumBytes: maximumBytes,
                    expectedByteCount: expectedByteCount,
                    expectedIdentity: nil
                )
                guard secureDirectoryPathMatches(
                    descriptor: directoryDescriptor,
                    directory: fileURL.deletingLastPathComponent()
                ) else { return nil }
                return loaded
            } catch {
                return nil
            }
        }

        private func loadPersistedMemory(
            name: String,
            directoryDescriptor: Int32,
            fileURL: URL,
            maximumBytes: Int,
            expectedByteCount: Int?,
            expectedIdentity: RecentFileIdentity?
        ) throws -> LoadedPersistedMemory? {
            var directoryStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
                Self.isDirectory(directoryStatus)
            else {
                throw StorageError.unsafeStoragePath(fileURL.deletingLastPathComponent())
            }
            let directoryIdentity = DirectoryIdentity(directoryStatus)
            guard let initialStatus = try fileStatus(
                name: name,
                directoryDescriptor: directoryDescriptor,
                fileURL: fileURL
            ) else { return nil }
            guard Self.isRegularFile(initialStatus) else {
                throw StorageError.unsafeStoragePath(fileURL)
            }
            let initialIdentity = RecentFileIdentity(initialStatus)
            guard expectedIdentity.map({ $0 == initialIdentity }) ?? true,
                let fileSize = Int(exactly: initialStatus.st_size),
                fileSize >= 0,
                fileSize <= min(maximumBytes, Self.maximumStoredMemoryBytes),
                expectedByteCount.map({ $0 == fileSize }) ?? true
            else { return nil }

            let descriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw posixError(operation: "openat", fileURL: fileURL)
            }
            defer { Darwin.close(descriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                Self.isRegularFile(openedStatus),
                RecentFileIdentity(openedStatus) == initialIdentity
            else {
                throw StorageError.storedMemoryChangedDuringRead(fileURL)
            }

            var data = Data(count: fileSize)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < fileSize {
                    let readCount = Darwin.read(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        fileSize - offset
                    )
                    if readCount < 0, errno == EINTR { continue }
                    guard readCount > 0 else {
                        if readCount < 0 {
                            throw posixError(operation: "read", fileURL: fileURL)
                        }
                        throw StorageError.storedMemoryChangedDuringRead(fileURL)
                    }
                    offset += readCount
                }
            }
            persistedDataReadObserver?(fileURL, data)

            var completedStatus = stat()
            guard Darwin.fstat(descriptor, &completedStatus) == 0,
                RecentFileIdentity(completedStatus) == initialIdentity,
                let pathStatus = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ),
                RecentFileIdentity(pathStatus) == initialIdentity
            else {
                throw StorageError.storedMemoryChangedDuringRead(fileURL)
            }
            guard let stored = try? Self.decode(data) else { return nil }
            var decodedStatus = stat()
            var completedDirectoryStatus = stat()
            guard Darwin.fstat(descriptor, &decodedStatus) == 0,
                RecentFileIdentity(decodedStatus) == initialIdentity,
                let decodedPathStatus = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ),
                RecentFileIdentity(decodedPathStatus) == initialIdentity,
                Darwin.fstat(directoryDescriptor, &completedDirectoryStatus) == 0,
                DirectoryIdentity(completedDirectoryStatus) == directoryIdentity
            else {
                throw StorageError.storedMemoryChangedDuringRead(fileURL)
            }
            return LoadedPersistedMemory(
                URL: fileURL,
                data: data,
                stored: stored,
                directoryIdentity: directoryIdentity
            )
        }

        private func migrateLegacyStorageIfNeeded(_ loaded: LoadedPersistedMemory) {
            let version = loaded.stored.storageFormatVersion ?? 1
            guard version <= Self.currentStorageFormatVersion,
                let fileDay = dayFromMemoryFile(loaded.URL),
                dayString(loaded.stored.dayStart) == dayString(fileDay)
            else { return }

            let legacyMarkdownURL = MarkdownFile(for: loaded.stored.dayStart)
            let compacted = loaded.stored.rehydrated(renderMarkdown: false)
            let needsAnalysisCompaction = !loaded.stored.hasSameAnalysis(as: compacted)
            let hasRedundantMarkdown: Bool
            do {
                hasRedundantMarkdown = try redundantLocalMarkdownExists(
                    at: legacyMarkdownURL,
                    expectedDirectoryIdentity: loaded.directoryIdentity
                )
            } catch {
                Diagnostics.write(
                    "Could not inspect Computer History legacy Markdown "
                        + "\(legacyMarkdownURL.path): \(error)"
                )
                return
            }
            guard version < Self.currentStorageFormatVersion
                || hasRedundantMarkdown
                || needsAnalysisCompaction
            else { return }

            // Although migration is triggered by a read, it rewrites a derived file and
            // removes the redundant Markdown projection. Admit it through the same clear
            // barrier as every other derived writer so a concurrent clear cannot be
            // followed by a late migration that recreates Computer History storage.
            guard let admission = derivedWriteBarrier.admission(),
                let permit = derivedWriteBarrier.beginJob(admission: admission)
            else { return }
            defer { derivedWriteBarrier.endJob(permit) }
            guard derivedWriteBarrier.isCurrent(permit) else { return }

            do {
                try Self.withStorageMutationLock {
                    var upgraded = PersistedMemory(compacted)
                    upgraded.storageFormatVersion = Self.currentStorageFormatVersion
                    let replaced = try writeAtomically(
                        Self.encode(upgraded),
                        to: loaded.URL,
                        ifCurrentContentsEqual: loaded.data,
                        expectedDirectoryIdentity: loaded.directoryIdentity
                    )
                    guard replaced else { return }
                    try removeRedundantLocalMarkdown(
                        for: loaded.stored.dayStart,
                        expectedDirectoryIdentity: loaded.directoryIdentity
                    )
                }
            } catch {
                // A failed migration must never make an otherwise readable memory vanish.
                Diagnostics.write("Could not compact Computer History memory \(loaded.URL.path): \(error)")
            }
        }

        private static func withStorageMutationLock<Result>(
            _ body: () throws -> Result
        ) rethrows -> Result {
            storageMutationLock.lock()
            defer { storageMutationLock.unlock() }
            return try body()
        }

        private func writeAtomicallyIfChanged(
            _ data: Data,
            to fileURL: URL
        ) throws {
            try withSecureDirectory(fileURL.deletingLastPathComponent(), createIfMissing: true) {
                descriptor in
                let name = fileURL.lastPathComponent
                let expectation: DestinationExpectation
                if let existing = try fileStatus(
                    name: name,
                    directoryDescriptor: descriptor,
                    fileURL: fileURL
                ) {
                    guard Self.isRegularFile(existing) else {
                        throw StorageError.unsafeStoragePath(fileURL)
                    }
                    if try fileContentsEqual(
                        data,
                        name: name,
                        status: existing,
                        directoryDescriptor: descriptor,
                        fileURL: fileURL
                    ) {
                        guard secureDirectoryPathMatches(
                            descriptor: descriptor,
                            directory: fileURL.deletingLastPathComponent()
                        ) else {
                            throw StorageError.unsafeStoragePath(
                                fileURL.deletingLastPathComponent()
                            )
                        }
                        return
                    }
                    expectation = .identity(RecentFileIdentity(existing))
                } else {
                    expectation = .absent
                }
                guard try writeAtomically(
                    data,
                    name: name,
                    directoryDescriptor: descriptor,
                    fileURL: fileURL,
                    expectedDestination: expectation
                ) else {
                    throw StorageError.storedMemoryChangedDuringRead(fileURL)
                }
            }
        }

        /// Replaces a file only while it still contains the bytes that were decoded by the
        /// caller. Every in-process Computer History mutation is serialized by
        /// `storageMutationLock`, so a legacy read can never overwrite a newer write from a
        /// different store instance after its comparison succeeds.
        private func writeAtomically(
            _ data: Data,
            to fileURL: URL,
            ifCurrentContentsEqual expectedData: Data,
            expectedDirectoryIdentity: DirectoryIdentity
        ) throws -> Bool {
            try withSecureDirectory(
                fileURL.deletingLastPathComponent(),
                createIfMissing: false,
                enforcePermissions: false
            ) { descriptor in
                var directoryStatus = stat()
                guard Darwin.fstat(descriptor, &directoryStatus) == 0,
                    DirectoryIdentity(directoryStatus) == expectedDirectoryIdentity,
                    secureDirectoryPathMatches(
                        descriptor: descriptor,
                        directory: fileURL.deletingLastPathComponent()
                    )
                else { return false }
                guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw posixError(
                        operation: "fchmod",
                        fileURL: fileURL.deletingLastPathComponent()
                    )
                }
                let name = fileURL.lastPathComponent
                guard
                    let existing = try fileStatus(
                        name: name,
                        directoryDescriptor: descriptor,
                        fileURL: fileURL
                    )
                else { return false }
                guard Self.isRegularFile(existing) else {
                    throw StorageError.unsafeStoragePath(fileURL)
                }
                guard try fileContentsEqual(
                    expectedData,
                    name: name,
                    status: existing,
                    directoryDescriptor: descriptor,
                    fileURL: fileURL
                ) else { return false }
                if data == expectedData { return true }
                return try writeAtomically(
                    data,
                    name: name,
                    directoryDescriptor: descriptor,
                    fileURL: fileURL,
                    expectedDestination: .contents(
                        expectedData,
                        identity: RecentFileIdentity(existing)
                    )
                )
            }
        }

        private func removeRedundantLocalMarkdown(
            for day: Date,
            expectedDirectoryIdentity: DirectoryIdentity? = nil
        ) throws {
            let markdownURL = MarkdownFile(for: day)
            try withSecureDirectory(
                memoryDirectory,
                createIfMissing: false,
                enforcePermissions: expectedDirectoryIdentity == nil
            ) { descriptor in
                var directoryStatus = stat()
                guard Darwin.fstat(descriptor, &directoryStatus) == 0,
                    expectedDirectoryIdentity.map({ $0 == DirectoryIdentity(directoryStatus) })
                        ?? true,
                    secureDirectoryPathMatches(
                        descriptor: descriptor,
                        directory: memoryDirectory
                    )
                else {
                    throw StorageError.unsafeStoragePath(memoryDirectory)
                }
                if expectedDirectoryIdentity != nil,
                    Darwin.fchmod(descriptor, mode_t(0o700)) != 0
                {
                    throw posixError(operation: "fchmod", fileURL: memoryDirectory)
                }
                let name = markdownURL.lastPathComponent
                guard
                    let status = try fileStatus(
                        name: name,
                        directoryDescriptor: descriptor,
                        fileURL: markdownURL
                    )
                else { return }
                guard Self.isRegularFile(status) else {
                    throw StorageError.unsafeStoragePath(markdownURL)
                }
                guard name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw posixError(operation: "unlinkat", fileURL: markdownURL)
                }
            }
        }

        private func redundantLocalMarkdownExists(
            at markdownURL: URL,
            expectedDirectoryIdentity: DirectoryIdentity
        ) throws -> Bool {
            guard let descriptor = try openSecureDirectory(
                memoryDirectory,
                createIfMissing: false
            ) else { return false }
            defer { Darwin.close(descriptor) }

            var directoryStatus = stat()
            guard Darwin.fstat(descriptor, &directoryStatus) == 0,
                DirectoryIdentity(directoryStatus) == expectedDirectoryIdentity,
                secureDirectoryPathMatches(
                    descriptor: descriptor,
                    directory: memoryDirectory
                )
            else {
                throw StorageError.unsafeStoragePath(memoryDirectory)
            }
            guard
                let status = try fileStatus(
                    name: markdownURL.lastPathComponent,
                    directoryDescriptor: descriptor,
                    fileURL: markdownURL
                )
            else { return false }
            guard Self.isRegularFile(status) else {
                throw StorageError.unsafeStoragePath(markdownURL)
            }
            return true
        }

        private func JSONFile(for day: Date) -> URL {
            memoryDirectory.appendingPathComponent(dayString(day) + ".computer-history.json")
        }

        private func MarkdownFile(for day: Date) -> URL {
            memoryDirectory.appendingPathComponent(dayString(day) + ".computer-history.md")
        }

        private func CodexMarkdownFile(for day: Date) -> URL {
            codexMemoryDirectory.appendingPathComponent(dayString(day) + "-goalong-computer-history.md")
        }

        private func prepareDirectory(_ directory: URL) throws {
            try withSecureDirectory(directory, createIfMissing: true) { _ in }
        }

        /// Opens every application-owned path component relative to a validated directory
        /// descriptor. No component is followed through a symlink, and the final descriptor
        /// remains open while its child is inspected, written, or removed.
        private func withSecureDirectory<Result>(
            _ directory: URL,
            createIfMissing: Bool,
            enforcePermissions: Bool = true,
            _ body: (Int32) throws -> Result
        ) throws -> Result {
            guard let descriptor = try openSecureDirectory(
                directory,
                createIfMissing: createIfMissing
            ) else {
                throw StorageError.unsafeStoragePath(directory.standardizedFileURL)
            }
            defer { Darwin.close(descriptor) }
            if enforcePermissions {
                guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw posixError(operation: "fchmod", fileURL: directory)
                }
            }
            return try body(descriptor)
        }

        private func openSecureDirectory(
            _ directory: URL,
            createIfMissing: Bool
        ) throws -> Int32? {
            let normalizedDirectory = directory.standardizedFileURL
            let trustedAncestor = OwnedFileDeletionPlan.trustedAncestor(
                for: memoryDeletionDirectories
            ).standardizedFileURL
            let ancestorComponents = trustedAncestor.pathComponents
            let directoryComponents = normalizedDirectory.pathComponents
            guard directoryComponents.count >= ancestorComponents.count,
                Array(directoryComponents.prefix(ancestorComponents.count)) == ancestorComponents
            else {
                throw StorageError.unsafeStoragePath(normalizedDirectory)
            }

            var trustedStatus = stat()
            guard trustedAncestor.path.withCString({ Darwin.lstat($0, &trustedStatus) }) == 0,
                Self.isDirectory(trustedStatus)
            else {
                throw StorageError.unsafeStoragePath(trustedAncestor)
            }
            var descriptor = trustedAncestor.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw posixError(operation: "open", fileURL: trustedAncestor)
            }

            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
                Self.sameIdentity(descriptorStatus, trustedStatus),
                Self.isDirectory(descriptorStatus)
            else {
                Darwin.close(descriptor)
                throw StorageError.unsafeStoragePath(trustedAncestor)
            }

            var currentURL = trustedAncestor
            do {
                for name in directoryComponents.dropFirst(ancestorComponents.count) {
                    currentURL.appendPathComponent(name, isDirectory: true)
                    var status = stat()
                    var result = name.withCString {
                        Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                    }
                    if result != 0, errno == ENOENT, !createIfMissing {
                        Darwin.close(descriptor)
                        return nil
                    }
                    if result != 0, errno == ENOENT, createIfMissing {
                        let created = name.withCString {
                            Darwin.mkdirat(descriptor, $0, mode_t(0o700))
                        }
                        let creationError = errno
                        guard created == 0 || creationError == EEXIST else {
                            throw posixError(
                                operation: "mkdirat",
                                fileURL: currentURL,
                                code: creationError
                            )
                        }
                        result = name.withCString {
                            Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                        }
                    }
                    guard result == 0, Self.isDirectory(status) else {
                        throw StorageError.unsafeStoragePath(currentURL)
                    }

                    let nextDescriptor = name.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard nextDescriptor >= 0 else {
                        throw StorageError.unsafeStoragePath(currentURL)
                    }
                    var openedStatus = stat()
                    guard Darwin.fstat(nextDescriptor, &openedStatus) == 0,
                        Self.isDirectory(openedStatus),
                        Self.sameIdentity(openedStatus, status)
                    else {
                        Darwin.close(nextDescriptor)
                        throw StorageError.unsafeStoragePath(currentURL)
                    }
                    Darwin.close(descriptor)
                    descriptor = nextDescriptor
                }
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        private func fileStatus(
            name: String,
            directoryDescriptor: Int32,
            fileURL: URL
        ) throws -> stat? {
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result != 0 else { return status }
            let code = errno
            guard code == ENOENT else {
                throw posixError(operation: "fstatat", fileURL: fileURL, code: code)
            }
            return nil
        }

        private func fileContentsEqual(
            _ data: Data,
            name: String,
            status: stat,
            directoryDescriptor: Int32,
            fileURL: URL
        ) throws -> Bool {
            guard status.st_size == data.count else { return false }
            let initialIdentity = RecentFileIdentity(status)
            let descriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw posixError(operation: "openat", fileURL: fileURL)
            }
            defer { Darwin.close(descriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                Self.isRegularFile(openedStatus),
                RecentFileIdentity(openedStatus) == initialIdentity,
                openedStatus.st_size == data.count
            else {
                throw StorageError.unsafeStoragePath(fileURL)
            }

            var buffer = [UInt8](
                repeating: 0,
                count: min(64 * 1_024, max(1, data.count))
            )
            var offset = 0
            while offset < data.count {
                let requested = min(buffer.count, data.count - offset)
                let readCount: Int = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, requested)
                }
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    if readCount < 0 {
                        throw posixError(operation: "read", fileURL: fileURL)
                    }
                    return false
                }
                let matches = data.withUnsafeBytes { source in
                    memcmp(
                        source.baseAddress?.advanced(by: offset),
                        buffer,
                        readCount
                    ) == 0
                }
                guard matches else { return false }
                offset += readCount
            }
            var trailingByte: UInt8 = 0
            var trailingCount: Int
            while true {
                trailingCount = Darwin.read(descriptor, &trailingByte, 1)
                if trailingCount < 0, errno == EINTR { continue }
                break
            }
            guard trailingCount >= 0 else {
                throw posixError(operation: "read", fileURL: fileURL)
            }
            guard trailingCount == 0 else { return false }

            var completedStatus = stat()
            guard Darwin.fstat(descriptor, &completedStatus) == 0,
                RecentFileIdentity(completedStatus) == initialIdentity,
                let pathStatus = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ),
                RecentFileIdentity(pathStatus) == initialIdentity
            else { return false }
            return true
        }

        private func destinationMatches(
            _ expectation: DestinationExpectation,
            name: String,
            directoryDescriptor: Int32,
            fileURL: URL
        ) throws -> Bool {
            switch expectation {
            case .absent:
                return try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ) == nil
            case let .identity(expectedIdentity):
                guard let status = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ), Self.isRegularFile(status)
                else { return false }
                return RecentFileIdentity(status) == expectedIdentity
            case let .contents(expectedData, expectedIdentity):
                guard let status = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ), Self.isRegularFile(status),
                    RecentFileIdentity(status) == expectedIdentity
                else { return false }
                return try fileContentsEqual(
                    expectedData,
                    name: name,
                    status: status,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                )
            }
        }

        private func writeAtomically(
            _ data: Data,
            name: String,
            directoryDescriptor: Int32,
            fileURL: URL,
            expectedDestination: DestinationExpectation
        ) throws -> Bool {
            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                throw posixError(operation: "openat", fileURL: fileURL)
            }
            var shouldRemoveTemporaryFile = true
            defer {
                Darwin.close(descriptor)
                if shouldRemoveTemporaryFile {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }
                }
            }

            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw posixError(operation: "write", fileURL: fileURL)
                    }
                    offset += written
                }
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError(operation: "fchmod", fileURL: fileURL)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw posixError(operation: "fsync", fileURL: fileURL)
            }
            var temporaryStatus = stat()
            guard Darwin.fstat(descriptor, &temporaryStatus) == 0,
                Self.isRegularFile(temporaryStatus)
            else {
                throw StorageError.unsafeStoragePath(fileURL)
            }
            let temporaryIdentity = RecentFileIdentity(temporaryStatus)
            beforeAtomicRename?(fileURL)
            guard secureDirectoryPathMatches(
                descriptor: directoryDescriptor,
                directory: fileURL.deletingLastPathComponent()
            ) else { return false }
            var currentTemporaryStatus = stat()
            guard Darwin.fstat(descriptor, &currentTemporaryStatus) == 0,
                Self.isRegularFile(currentTemporaryStatus),
                RecentFileIdentity(currentTemporaryStatus) == temporaryIdentity,
                let temporaryPathStatus = try fileStatus(
                    name: temporaryName,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ),
                Self.isRegularFile(temporaryPathStatus),
                RecentFileIdentity(temporaryPathStatus) == temporaryIdentity,
                secureDirectoryPathMatches(
                    descriptor: directoryDescriptor,
                    directory: fileURL.deletingLastPathComponent()
                )
            else { return false }
            // Keep the expected-byte CAS as the final operation before rename. Any path
            // or temporary-entry checks after this comparison would reopen a material
            // race window in which a newer destination could be overwritten.
            guard try destinationMatches(
                expectedDestination,
                name: name,
                directoryDescriptor: directoryDescriptor,
                fileURL: fileURL
            ) else { return false }
            let renamed = temporaryName.withCString { temporary in
                name.withCString { destination in
                    Darwin.renameat(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination
                    )
                }
            }
            guard renamed == 0 else {
                throw posixError(operation: "renameat", fileURL: fileURL)
            }
            shouldRemoveTemporaryFile = false

            guard
                let writtenStatus = try fileStatus(
                    name: name,
                    directoryDescriptor: directoryDescriptor,
                    fileURL: fileURL
                ),
                Darwin.fstat(descriptor, &currentTemporaryStatus) == 0,
                Self.isRegularFile(writtenStatus),
                Self.isRegularFile(currentTemporaryStatus),
                Self.sameIdentity(writtenStatus, currentTemporaryStatus),
                writtenStatus.st_size == data.count,
                currentTemporaryStatus.st_size == data.count,
                secureDirectoryPathMatches(
                    descriptor: directoryDescriptor,
                    directory: fileURL.deletingLastPathComponent()
                )
            else {
                throw StorageError.unsafeStoragePath(fileURL)
            }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw posixError(operation: "fsync", fileURL: fileURL)
            }
            return true
        }

        private static func isDirectory(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFDIR
        }

        private static func isRegularFile(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFREG
        }

        private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
        }

        private static func sameDirectoryListingSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
            isDirectory(lhs)
                && isDirectory(rhs)
                && sameIdentity(lhs, rhs)
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }

        private func secureDirectoryPathMatches(
            descriptor: Int32,
            directory: URL
        ) -> Bool {
            var pinnedStatus = stat()
            guard Darwin.fstat(descriptor, &pinnedStatus) == 0,
                let reopened = try? openSecureDirectory(
                    directory,
                    createIfMissing: false
                )
            else { return false }
            defer { Darwin.close(reopened) }
            var reopenedStatus = stat()
            return Darwin.fstat(reopened, &reopenedStatus) == 0
                && Self.isDirectory(reopenedStatus)
                && Self.sameIdentity(pinnedStatus, reopenedStatus)
        }

        private static func recentFileIdentity(
            name: String,
            directoryDescriptor: Int32
        ) -> RecentFileIdentity? {
            var information = stat()
            let result = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result == 0, isRegularFile(information), information.st_size >= 0 else {
                return nil
            }
            return RecentFileIdentity(information)
        }

        private static func directoryEntryName(
            _ entry: UnsafeMutablePointer<dirent>
        ) -> String {
            withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
        }

        private func posixError(
            operation: String,
            fileURL: URL,
            code: Int32 = errno
        ) -> StorageError {
            .posix(operation: operation, URL: fileURL, code: code)
        }

        private func dayFromMemoryFile(_ URL: URL) -> Date? {
            guard let rawDay = dayKeyFromMemoryFile(URL) else { return nil }
            let fields = rawDay.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields[0].count == 4,
                fields[1].count == 2,
                fields[2].count == 2,
                let year = Int(fields[0]),
                let month = Int(fields[1]),
                let day = Int(fields[2])
            else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                dayString(date) == rawDay
            else { return nil }
            return date
        }

        private func dayKeyFromMemoryFile(_ URL: URL) -> String? {
            dayKey(URL, suffixes: [".computer-history.json"])
        }

        private func dayKeyFromGoalongOwnedMemoryFile(_ URL: URL) -> String? {
            dayKey(URL, suffixes: [".computer-history.json", ".computer-history.md"])
        }

        private func dayKeyFromCodexMirrorFile(_ URL: URL) -> String? {
            dayKey(URL, suffixes: ["-goalong-computer-history.md"])
        }

        private func dayKey(_ URL: URL, suffixes: [String]) -> String? {
            let name = URL.lastPathComponent
            guard let suffix = suffixes.first(where: name.hasSuffix) else { return nil }
            let rawDay = String(name.dropLast(suffix.count))
            let fields = rawDay.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields[0].count == 4,
                fields[1].count == 2,
                fields[2].count == 2,
                fields.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                let year = Int(fields[0]),
                let month = Int(fields[1]),
                let day = Int(fields[2])
            else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                dayString(date) == rawDay
            else { return nil }
            return rawDay
        }

        private func dayString(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let normalized = Calendar.current.startOfDay(for: date)
            let components = calendar.dateComponents([.year, .month, .day], from: normalized)
            return String(
                format: "%04d-%02d-%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }

        private static func codexMemoryDirectoryURL() -> URL {
            let fileManager = FileManager.default
            let configuredCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            return configuredCodexHome
                .appendingPathComponent("memories", isDirectory: true)
                .appendingPathComponent("extensions", isDirectory: true)
                .appendingPathComponent("goalong", isDirectory: true)
        }

        private static func encode(_ value: PersistedMemory) throws -> Data {
            let encoder = JSONEncoder()
            // Preserve Date's exact Double representation. Even a tiny round-trip drift
            // would make an unchanged re-analysis look different and rewrite the file.
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(
                    "b:" + String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
                )
            }
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        }

        private static func decode(_ data: Data) throws -> PersistedMemory {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let encoded = try? container.decode(String.self),
                    encoded.hasPrefix("b:"),
                    let bits = UInt64(encoded.dropFirst(2), radix: 16)
                {
                    return Date(
                        timeIntervalSinceReferenceDate: Double(bitPattern: bits)
                    )
                }
                // Accept the short-lived numeric format 2 written by development builds.
                if let seconds = try? container.decode(Double.self) {
                    return Date(timeIntervalSince1970: seconds)
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported compact Computer History date"
                )
            }
            do {
                return try decoder.decode(PersistedMemory.self, from: data)
            } catch {
                // Storage format 1 used ISO-8601 strings. Decode it unchanged so the
                // next successful read/write can atomically compact it to format 2.
                let legacyDecoder = JSONDecoder()
                legacyDecoder.dateDecodingStrategy = .iso8601
                return try legacyDecoder.decode(PersistedMemory.self, from: data)
            }
        }

        private struct LoadedPersistedMemory {
            let URL: URL
            let data: Data
            let stored: PersistedMemory
            let directoryIdentity: DirectoryIdentity
        }

        private enum DestinationExpectation {
            case absent
            case identity(RecentFileIdentity)
            case contents(Data, identity: RecentFileIdentity)
        }

        private struct DirectoryIdentity: Equatable {
            let device: dev_t
            let inode: ino_t

            init(_ status: stat) {
                device = status.st_dev
                inode = status.st_ino
            }
        }

        private struct RecentCandidate {
            let URL: URL
            let day: Date
            let key: String
            let byteCount: Int
            let identity: RecentFileIdentity

            static func isNewer(_ lhs: RecentCandidate, than rhs: RecentCandidate) -> Bool {
                if lhs.key != rhs.key { return lhs.key > rhs.key }
                return lhs.URL.lastPathComponent > rhs.URL.lastPathComponent
            }

            static func isOlder(_ lhs: RecentCandidate, than rhs: RecentCandidate) -> Bool {
                isNewer(rhs, than: lhs)
            }
        }

        private struct RecentFileIdentity: Equatable {
            let device: dev_t
            let inode: ino_t
            let size: off_t
            let modificationSeconds: time_t
            let modificationNanoseconds: Int
            let changeSeconds: time_t
            let changeNanoseconds: Int

            init(_ status: stat) {
                device = status.st_dev
                inode = status.st_ino
                size = status.st_size
                modificationSeconds = status.st_mtimespec.tv_sec
                modificationNanoseconds = status.st_mtimespec.tv_nsec
                changeSeconds = status.st_ctimespec.tv_sec
                changeNanoseconds = status.st_ctimespec.tv_nsec
            }
        }

        /// A min-heap whose root is the oldest retained candidate. Its storage never grows
        /// past `capacity`, while a complete directory pass still identifies the exact
        /// globally newest candidates independent of filesystem enumeration order.
        private struct BoundedNewestCandidates {
            let capacity: Int
            private var heap: [RecentCandidate] = []

            init(capacity: Int) {
                self.capacity = max(0, capacity)
                heap.reserveCapacity(self.capacity)
            }

            mutating func insert(_ candidate: RecentCandidate) {
                guard capacity > 0 else { return }
                if heap.count < capacity {
                    heap.append(candidate)
                    siftUp(from: heap.count - 1)
                    return
                }
                guard let oldest = heap.first,
                    RecentCandidate.isNewer(candidate, than: oldest)
                else { return }
                heap[0] = candidate
                siftDown(from: 0)
            }

            func newestFirst() -> [RecentCandidate] {
                heap.sorted { RecentCandidate.isNewer($0, than: $1) }
            }

            private mutating func siftUp(from index: Int) {
                var child = index
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard RecentCandidate.isOlder(heap[child], than: heap[parent]) else {
                        return
                    }
                    heap.swapAt(child, parent)
                    child = parent
                }
            }

            private mutating func siftDown(from index: Int) {
                var parent = index
                while true {
                    let left = (parent * 2) + 1
                    guard left < heap.count else { return }
                    let right = left + 1
                    var oldestChild = left
                    if right < heap.count,
                        RecentCandidate.isOlder(heap[right], than: heap[left])
                    {
                        oldestChild = right
                    }
                    guard RecentCandidate.isOlder(heap[oldestChild], than: heap[parent]) else {
                        return
                    }
                    heap.swapAt(parent, oldestChild)
                    parent = oldestChild
                }
            }
        }

        private struct BoundedRecentLoadDiagnostics {
            let maximumMessages: Int
            let sink: (String) -> Void
            private(set) var emittedMessages = 0
            private(set) var suppressedMessages = 0

            mutating func report(_ message: String) {
                guard maximumMessages > 0 else { return }
                // Reserve the final slot for a single aggregate notice if more candidate
                // failures occur than should be written to diagnostics individually.
                guard emittedMessages < maximumMessages - 1 else {
                    suppressedMessages += 1
                    return
                }
                sink(message)
                emittedMessages += 1
            }

            mutating func reportFinal(_ message: String) {
                guard maximumMessages > 0, emittedMessages < maximumMessages else { return }
                sink(message)
                emittedMessages += 1
            }

            mutating func finish() {
                guard suppressedMessages > 0, emittedMessages < maximumMessages else { return }
                sink(
                    "Computer History suppressed \(suppressedMessages) additional "
                        + "recent-memory load diagnostic(s)."
                )
                emittedMessages += 1
                suppressedMessages = 0
            }
        }

        enum StorageError: LocalizedError {
            case incompleteRecentMemoryListing
            case incompleteSourceEvidence(String)
            case memoryTooLarge(actualBytes: Int, maximumBytes: Int)
            case storedMemoryChangedDuringRead(URL)
            case unsafeStoragePath(URL)
            case posix(operation: String, URL: URL, code: Int32)

            var errorDescription: String? {
                switch self {
                case .incompleteRecentMemoryListing:
                    return "Computer History refused to write after an incomplete recent-memory listing."
                case let .incompleteSourceEvidence(reason):
                    return "Computer History kept the last-known-good memory because source "
                        + "evidence was incomplete: \(reason)."
                case let .memoryTooLarge(actualBytes, maximumBytes):
                    return "Computer History memory is \(actualBytes) encoded bytes; "
                        + "the daily limit is \(maximumBytes) bytes."
                case let .storedMemoryChangedDuringRead(URL):
                    return "Computer History storage changed while \(URL.path) was being read."
                case let .unsafeStoragePath(URL):
                    return "Refused unsafe Computer History storage path \(URL.path)."
                case let .posix(operation, URL, code):
                    return "Computer History \(operation) failed for \(URL.path): "
                        + String(cString: strerror(code))
                }
            }
        }

        /// The disk representation intentionally excludes `markdown`: it is a pure,
        /// deterministic projection of these fields. The optional format marker lets
        /// this decoder read the legacy full `ComputerHistoryDayMemory` JSON unchanged.
        private struct PersistedMemory: Codable, Equatable {
            var storageFormatVersion: Int?
            let schemaVersion: Int
            let dayStart: Date
            let dayEnd: Date
            let generatedAt: Date
            let title: String
            let executiveSummary: String
            let episodes: [ComputerHistoryEpisode]
            let resources: [ComputerHistoryResourceReference]
            let workflowPatterns: [ComputerHistoryWorkflowPattern]
            let suggestions: [ComputerHistorySuggestion]
            let coverage: ComputerHistoryCoverage
            let securityNotice: String

            init(_ memory: ComputerHistoryDayMemory) {
                storageFormatVersion = ComputerHistoryStore.currentStorageFormatVersion
                schemaVersion = memory.schemaVersion
                dayStart = memory.dayStart
                dayEnd = memory.dayEnd
                generatedAt = memory.generatedAt
                title = memory.title
                executiveSummary = memory.executiveSummary
                episodes = memory.episodes
                resources = memory.resources
                workflowPatterns = memory.workflowPatterns
                suggestions = memory.suggestions
                coverage = memory.coverage
                securityNotice = memory.securityNotice
            }

            func hasSameAnalysis(as memory: ComputerHistoryDayMemory) -> Bool {
                schemaVersion == memory.schemaVersion
                    && dayStart == memory.dayStart
                    && dayEnd == memory.dayEnd
                    && title == memory.title
                    && executiveSummary == memory.executiveSummary
                    && episodes == memory.episodes
                    && resources == memory.resources
                    && workflowPatterns == memory.workflowPatterns
                    && suggestions == memory.suggestions
                    && coverage == memory.coverage
                    && securityNotice == memory.securityNotice
            }

            func rehydrated(renderMarkdown: Bool = true) -> ComputerHistoryDayMemory {
                let base = ComputerHistoryDayMemory(
                    schemaVersion: schemaVersion,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    generatedAt: generatedAt,
                    title: title,
                    executiveSummary: executiveSummary,
                    episodes: episodes,
                    resources: resources,
                    workflowPatterns: workflowPatterns,
                    suggestions: suggestions,
                    coverage: coverage,
                    markdown: "",
                    securityNotice: securityNotice
                )
                let compacted = ComputerHistoryEngine.compactStoredMemory(
                    base,
                    renderMarkdown: false
                )
                guard renderMarkdown else { return compacted }
                return ComputerHistoryDayMemory(
                    schemaVersion: compacted.schemaVersion,
                    dayStart: compacted.dayStart,
                    dayEnd: compacted.dayEnd,
                    generatedAt: compacted.generatedAt,
                    title: compacted.title,
                    executiveSummary: compacted.executiveSummary,
                    episodes: compacted.episodes,
                    resources: compacted.resources,
                    workflowPatterns: compacted.workflowPatterns,
                    suggestions: compacted.suggestions,
                    coverage: compacted.coverage,
                    markdown: ComputerHistoryMarkdownRenderer.render(compacted),
                    securityNotice: compacted.securityNotice
                )
            }
        }
    }
#endif
