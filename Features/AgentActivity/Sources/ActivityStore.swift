import Darwin
import Foundation

public enum AgentActivityStoreError: Error, LocalizedError {
    case configurationCorrupt
    case indexCorrupt
    case sourceNotFound(String)
    case sourceReferenceChanged(String)

    public var errorDescription: String? {
        switch self {
        case .configurationCorrupt:
            return "The Agent Activity configuration is invalid and was left untouched."
        case .indexCorrupt:
            return "The lightweight Agent Activity index is invalid."
        case .sourceNotFound(let id):
            return "The indexed agent source \(id) could not be found."
        case .sourceReferenceChanged(let id):
            return "The indexed source reference for \(id) changed while it was being read."
        }
    }
}

/// A direct-source result prepared by the scanner. The caller can keep only its most useful
/// summaries resident while the store retains compact freshness/count metrics for every
/// analyzed index entry in this process.
struct AgentPreparedCapture: Equatable, Sendable {
    var record: AgentCaptureRecord
    var retainFullSummary: Bool

    init(record: AgentCaptureRecord, retainFullSummary: Bool = true) {
        self.record = record
        self.retainFullSummary = retainFullSummary
    }
}

/// One source-state observation to be reconciled and committed with the rest of a scan.
struct AgentAvailabilityObservation: Equatable, Sendable {
    var entryID: String
    var availability: AgentSourceAvailability
    var detail: String?
    var observedAt: Date
    var expectedReference: AgentSourceReference?

    init(
        entryID: String,
        availability: AgentSourceAvailability,
        detail: String?,
        observedAt: Date = Date(),
        expectedReference: AgentSourceReference? = nil
    ) {
        self.entryID = entryID
        self.availability = availability
        self.detail = detail
        self.observedAt = observedAt
        self.expectedReference = expectedReference
    }
}

struct AgentFolderDiscoveryAttempt: Equatable, Sendable {
    var folderID: String
    var observedAt: Date
    var succeeded: Bool
}

struct AgentFolderRootObservation: Equatable, Sendable {
    var folderID: String
    var availability: AgentSourceAvailability
    var observedAt: Date
}

struct AgentFolderScanCommitResult: Equatable, Sendable {
    var changedEntryIDs: Set<String>
    var statusChangedEntryIDs: Set<String>
}

struct AgentFolderScanMutation: Equatable, Sendable {
    var folderID: String
    var preparedCaptures: [AgentPreparedCapture]
    var availabilityObservations: [AgentAvailabilityObservation]
    var maximumEntries: Int
    var discoveryAttempt: AgentFolderDiscoveryAttempt?
    var rootObservation: AgentFolderRootObservation?
}

struct AgentFolderScanSlice: Equatable, Sendable {
    var entries: [AgentSourceIndexEntry]
    var nextCursor: Int
    var visitedCount: Int
    var totalCount: Int
}

public final class AgentActivityStore: @unchecked Sendable {
    private struct FileSignature: Equatable {
        var byteCount: Int64
        var modifiedAt: Date?
        var fileNumber: UInt64?
    }

    private struct ReferenceLookupKey: Hashable {
        var kind: String
        var path: String
        var locator: String?

        init(_ reference: AgentSourceReference) {
            kind = reference.kind.rawValue
            path = reference.path
            locator = reference.locator
        }
    }

    /// Deliberately excludes all free-form transcript-derived strings. These values are
    /// process-local and let aggregate counts remain complete after full summaries leave the LRU.
    private struct TransientAnalysisMetrics: Equatable, Sendable {
        var referenceFingerprint: Int
        var sha256High: UInt64
        var sha256Low: UInt64
        var byteCount: Int64
        var startedAt: Date?
        var endedAt: Date?
        var messageCount: Int
        var visibleMessageCount: Int
        var toolCallCount: Int
        var errorCount: Int

        init(_ record: AgentCaptureRecord) {
            var referenceHasher = Hasher()
            referenceHasher.combine(record.index.reference.kind.rawValue)
            referenceHasher.combine(record.index.reference.path)
            referenceHasher.combine(record.index.reference.locator)
            referenceFingerprint = referenceHasher.finalize()
            sha256High = UInt64(record.sha256.prefix(16), radix: 16) ?? 0
            sha256Low = UInt64(record.sha256.dropFirst(16).prefix(16), radix: 16) ?? 0
            byteCount = record.byteCount
            startedAt = record.summary.startedAt
            endedAt = record.summary.endedAt
            messageCount = max(record.summary.messageCount, 0)
            visibleMessageCount = record.summary.visibleMessages.count
            toolCallCount = max(record.summary.toolCallCount, 0)
            errorCount = max(record.summary.errorCount, 0)
        }

        func matches(
            reference: AgentSourceReference,
            sha256: String,
            byteCount: Int64
        ) -> Bool {
            var referenceHasher = Hasher()
            referenceHasher.combine(reference.kind.rawValue)
            referenceHasher.combine(reference.path)
            referenceHasher.combine(reference.locator)
            return referenceFingerprint == referenceHasher.finalize()
                && sha256High == (UInt64(sha256.prefix(16), radix: 16) ?? 0)
                && sha256Low == (UInt64(sha256.dropFirst(16).prefix(16), radix: 16) ?? 0)
                && self.byteCount == byteCount
        }
    }

    /// Accounting for the process-local summary cache. The byte count is the complete UTF-8
    /// payload retained by the record plus a conservative fixed/container overhead; no joined
    /// search string is materialized or cached.
    private struct TransientSummaryCacheMetadata: Equatable, Sendable {
        var byteCount: Int
        var expiresAt: Date
    }

    private struct MutableStateSnapshot {
        var index: AgentActivityIndex
        var transientRecordsByID: [String: AgentCaptureRecord]
        var transientMetricsByID: [String: TransientAnalysisMetrics]
        var transientMetricAccessByID: [String: UInt64]
        var transientMetricAccessCounter: UInt64
        var transientAccessByID: [String: UInt64]
        var transientSummaryMetadataByID: [String: TransientSummaryCacheMetadata]
        var transientSummaryBytes: Int
        var transientAccessCounter: UInt64
        var indexLoadFailed: Bool
        var loadedIndexSignature: FileSignature?
        var loadedRawEntryCount: Int
    }

    private static let processLock = NSRecursiveLock()
    private static let absoluteMaximumIndexEntries = 50_000
    private static let maximumConfigurationBytes: Int64 = 1 * 1_024 * 1_024
    private static let maximumSerializedIndexBytes: Int64 = 12 * 1_024 * 1_024
    private static let maximumSignalBytes: Int64 = 16 * 1_024
    private static let minimumUnavailableRetryInterval: TimeInterval = 60
    static let maximumTransientRecords = 256
    static let maximumTransientAnalysisMetrics = 4_096
    static let maximumTransientSummaryBytes = 4 * 1_024 * 1_024
    static let transientSummaryTTL: TimeInterval = 5 * 60
    private static let persistedIndexTopLevelKeys: Set<String> = [
        "schemaVersion", "entries", "lastFullDiscoveryByFolder",
        "lastFullDiscoveryAttemptByFolder", "fullDiscoveryFailureCountByFolder",
        "rootStatusByFolder", "lastHandledSignalByProvider", "updatedAt",
    ]
    private static let persistedIndexEntryKeys: Set<String> = [
        "id", "stableConversationID", "watchedFolderID", "watchedFolderName",
        "provider", "reference", "relativePath", "sourceCreatedAt",
        "sourceModifiedAt", "conversationStartedAt", "conversationEndedAt",
        "firstIndexedAt", "lastObservedAt", "byteCount", "sha256",
        "sourceDevice", "sourceInode", "sourceChangedSeconds", "sourceChangedNanoseconds",
        "sourceContainerByteCount", "sourceContainerModifiedSeconds",
        "sourceContainerModifiedNanoseconds",
        "startOffset", "endOffset", "availability", "statusDetail",
    ]
    private static let persistedIndexReferenceKeys: Set<String> = ["kind", "path", "locator"]

    public let rootDirectory: URL
    public let configurationFile: URL
    public let indexFile: URL
    public let signalsDirectory: URL

    private let fileManager: FileManager
    private let currentDate: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var index: AgentActivityIndex
    private var entryIndexByID: [String: Int] = [:]
    private var entryIndexByReference: [ReferenceLookupKey: Int] = [:]
    private var entryPositionsByFolderID: [String: [Int]] = [:]
    private var transientRecordsByID: [String: AgentCaptureRecord] = [:]
    private var transientMetricsByID: [String: TransientAnalysisMetrics] = [:]
    private var transientMetricAccessByID: [String: UInt64] = [:]
    private var transientMetricAccessCounter: UInt64 = 0
    private var transientAccessByID: [String: UInt64] = [:]
    private var transientSummaryMetadataByID: [String: TransientSummaryCacheMetadata] = [:]
    private var transientSummaryBytes = 0
    private var transientAccessCounter: UInt64 = 0
    private var indexLoadFailed = false
    private var configurationLoadFailed = false
    private var loadedIndexSignature: FileSignature?
    private var loadedRawEntryCount = 0
    private var successfulIndexWriteCount = 0

    private var lock: NSRecursiveLock { Self.processLock }

    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        try self.init(rootDirectory: rootDirectory, fileManager: fileManager, currentDate: Date.init)
    }

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        currentDate: @escaping () -> Date
    ) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.currentDate = currentDate
        configurationFile = self.rootDirectory.appendingPathComponent("configuration.json", isDirectory: false)
        indexFile = self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        signalsDirectory = self.rootDirectory.appendingPathComponent("signals", isDirectory: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = AgentActivityIndex()

        try createSecureDirectory(self.rootDirectory)
        try createSecureDirectory(signalsDirectory)
        try loadIndex()
    }

    public func loadConfiguration() -> AgentActivityConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: configurationFile.path) else {
            configurationLoadFailed = false
            return .default
        }
        guard
            let data = boundedRegularFileData(
                at: configurationFile,
                maximumBytes: Self.maximumConfigurationBytes
            ),
            let value = try? decoder.decode(AgentActivityConfiguration.self, from: data)
        else {
            configurationLoadFailed = true
            return .default
        }
        configurationLoadFailed = false
        return value.validated()
    }

    public func configurationIsValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = loadConfiguration()
        return !configurationLoadFailed
    }

    @discardableResult
    public func saveConfiguration(_ configuration: AgentActivityConfiguration) throws -> AgentActivityConfiguration {
        let validated = configuration.validated()
        lock.lock()
        defer { lock.unlock() }
        let data = try encoder.encode(validated)
        guard Int64(data.count) <= Self.maximumConfigurationBytes else {
            throw AgentActivityStoreError.configurationCorrupt
        }

        let configurationExisted = fileManager.fileExists(atPath: configurationFile.path)
        var previousConfigurationData: Data?
        if configurationExisted {
            guard
                let existingData = boundedRegularFileData(
                    at: configurationFile,
                    maximumBytes: Self.maximumConfigurationBytes
                ),
                (try? decoder.decode(AgentActivityConfiguration.self, from: existingData)) != nil
            else {
                configurationLoadFailed = true
                throw AgentActivityStoreError.configurationCorrupt
            }
            previousConfigurationData = existingData
        }
        try secureAtomicWrite(data, to: configurationFile)
        configurationLoadFailed = false

        do {
            if reloadIndexFromDisk() {
                let activeFolders = validated.watchedFolders.filter(\.isEnabled)
                let activeFolderIDs = Set(activeFolders.map(\.id))
                let activeProviderKeys = Set(activeFolders.map { $0.provider.rawValue })
                try performPersistedIndexMutation {
                    let wasPruned = pruneInactiveFolderMetadata(
                        activeFolderIDs: activeFolderIDs,
                        activeProviderKeys: activeProviderKeys
                    )
                    let wasTrimmed = enforceBound(maximumEntries: validated.maximumIndexEntries)
                    return ((), wasPruned || wasTrimmed)
                }
            }
        } catch {
            if let previousConfigurationData {
                try? secureAtomicWrite(previousConfigurationData, to: configurationFile)
            } else if !configurationExisted {
                try? fileManager.removeItem(at: configurationFile)
            }
            configurationLoadFailed = false
            throw error
        }
        return validated
    }

    public func entry(for reference: AgentSourceReference) -> AgentSourceIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return entryIndexByReference[ReferenceLookupKey(reference)].map { index.entries[$0] }
    }

    public func entry(id: String) -> AgentSourceIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return entryIndexByID[id].map { index.entries[$0] }
    }

    public func entries(folderID: String? = nil) -> [AgentSourceIndexEntry] {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        let values = folderID.map { id in index.entries.filter { $0.watchedFolderID == id } } ?? index.entries
        return values.sorted { left, right in
            let leftDate = left.sourceModifiedAt ?? left.lastObservedAt
            let rightDate = right.sourceModifiedAt ?? right.lastObservedAt
            if leftDate == rightDate { return left.id < right.id }
            return leftDate > rightDate
        }
    }

    /// Returns one bounded rotating slice for a normal metadata poll. The scanner keeps the
    /// cursor in memory; persisted entry metadata remains sufficient to skip body reads after a
    /// restart when size/timestamps are unchanged.
    func scanSlice(
        folderID: String,
        cursor: Int,
        maximumEntries: Int,
        maximumVisits: Int,
        observedAt: Date,
        unavailableRetryInterval: TimeInterval
    ) -> AgentFolderScanSlice {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else {
            return AgentFolderScanSlice(entries: [], nextCursor: 0, visitedCount: 0, totalCount: 0)
        }
        let positions = entryPositionsByFolderID[folderID] ?? []
        guard !positions.isEmpty else {
            return AgentFolderScanSlice(entries: [], nextCursor: 0, visitedCount: 0, totalCount: 0)
        }

        let entryLimit = max(0, maximumEntries)
        let visitLimit = min(max(0, maximumVisits), positions.count)
        let retryInterval = max(unavailableRetryInterval, Self.minimumUnavailableRetryInterval)
        let normalizedCursor = ((cursor % positions.count) + positions.count) % positions.count
        var selected: [AgentSourceIndexEntry] = []
        selected.reserveCapacity(min(entryLimit, visitLimit))
        var visited = 0
        while visited < visitLimit, selected.count < entryLimit {
            let position = positions[(normalizedCursor + visited) % positions.count]
            let entry = index.entries[position]
            if entry.availability == .available
                || observedAt.timeIntervalSince(entry.lastObservedAt) >= retryInterval
            {
                selected.append(entry)
            }
            visited += 1
        }
        return AgentFolderScanSlice(
            entries: selected,
            nextCursor: (normalizedCursor + visited) % positions.count,
            visitedCount: visited,
            totalCount: positions.count
        )
    }

    func indexWriteCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return successfulIndexWriteCount
    }

    /// Replaces the current entry for a conversation. No historical version is retained.
    @discardableResult
    public func upsert(
        _ record: AgentCaptureRecord,
        maximumEntries: Int
    ) throws -> Bool {
        try upsertBatch([record], maximumEntries: maximumEntries).contains(record.id)
    }

    /// Applies current observations together and persists the bounded metadata index once.
    /// No transcript body or historical version is retained.
    @discardableResult
    public func upsertBatch(
        _ records: [AgentCaptureRecord],
        maximumEntries: Int
    ) throws -> Set<String> {
        try upsertPreparedBatch(
            records.map { AgentPreparedCapture(record: $0) },
            maximumEntries: maximumEntries
        )
    }

    /// Commits metadata once for a scanner batch. Compact, content-free analysis metrics are
    /// retained for every surviving entry; full summaries use a separate 256-record LRU.
    @discardableResult
    func upsertPreparedBatch(
        _ preparedCaptures: [AgentPreparedCapture],
        maximumEntries: Int
    ) throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else {
            throw AgentActivityStoreError.indexCorrupt
        }

        guard !preparedCaptures.isEmpty else { return [] }
        return try performPersistedIndexMutation {
            applyPreparedCaptures(preparedCaptures, maximumEntries: maximumEntries)
        }
    }

    @discardableResult
    public func markAvailability(
        entryID: String,
        availability: AgentSourceAvailability,
        detail: String?,
        observedAt: Date = Date(),
        expectedReference: AgentSourceReference? = nil
    ) throws -> Bool {
        try markAvailabilityBatch([
            AgentAvailabilityObservation(
                entryID: entryID,
                availability: availability,
                detail: detail,
                observedAt: observedAt,
                expectedReference: expectedReference
            )
        ]).contains(entryID)
    }

    /// Applies source availability observations with one atomic index write. The returned IDs
    /// are those whose user-visible state/detail changed (timestamp-only refreshes are omitted).
    @discardableResult
    func markAvailabilityBatch(_ observations: [AgentAvailabilityObservation]) throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        guard !observations.isEmpty else { return [] }
        return try performPersistedIndexMutation {
            applyAvailabilityObservations(observations)
        }
    }

    /// Reconciles one folder scan and writes the metadata index at most once. Transcript-derived
    /// summaries remain process-local; only sanitized source metadata reaches this transaction.
    func commitFolderScan(
        preparedCaptures: [AgentPreparedCapture],
        availabilityObservations: [AgentAvailabilityObservation],
        maximumEntries: Int,
        discoveryAttempt: AgentFolderDiscoveryAttempt?,
        rootObservation: AgentFolderRootObservation? = nil
    ) throws -> AgentFolderScanCommitResult {
        let folderID =
            discoveryAttempt?.folderID
            ?? preparedCaptures.first?.record.watchedFolderID
            ?? availabilityObservations.compactMap { observation in
                entry(id: observation.entryID)?.watchedFolderID
            }.first
            ?? ""
        return try commitScanCycle(
            folderMutations: [
                AgentFolderScanMutation(
                    folderID: folderID,
                    preparedCaptures: preparedCaptures,
                    availabilityObservations: availabilityObservations,
                    maximumEntries: maximumEntries,
                    discoveryAttempt: discoveryAttempt,
                    rootObservation: rootObservation
                )
            ],
            handledSignals: [:]
        )
    }

    func commitScanCycle(
        folderMutations: [AgentFolderScanMutation],
        handledSignals: [AgentProvider: Date]
    ) throws -> AgentFolderScanCommitResult {
        lock.lock()
        defer { lock.unlock() }
        let mutations = folderMutations.filter {
            !$0.preparedCaptures.isEmpty || !$0.availabilityObservations.isEmpty
                || $0.discoveryAttempt != nil || $0.rootObservation != nil
        }
        guard !mutations.isEmpty || !handledSignals.isEmpty else {
            return AgentFolderScanCommitResult(changedEntryIDs: [], statusChangedEntryIDs: [])
        }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        return try performPersistedIndexMutation {
            var changedEntryIDs = Set<String>()
            var statusChangedEntryIDs = Set<String>()
            var mutated = false
            for folderMutation in mutations {
                guard !folderMutation.folderID.isEmpty,
                    folderMutation.preparedCaptures.allSatisfy({
                        $0.record.watchedFolderID == folderMutation.folderID
                    }),
                    folderMutation.discoveryAttempt.map({
                        $0.folderID == folderMutation.folderID
                    }) ?? true,
                    folderMutation.rootObservation.map({
                        $0.folderID == folderMutation.folderID
                    }) ?? true,
                    folderMutation.availabilityObservations.allSatisfy({ observation in
                        guard let position = entryIndexByID[observation.entryID],
                            index.entries.indices.contains(position)
                        else { return true }
                        return index.entries[position].watchedFolderID == folderMutation.folderID
                    })
                else { throw AgentActivityStoreError.indexCorrupt }
                let prepared = applyPreparedCaptures(
                    folderMutation.preparedCaptures,
                    maximumEntries: folderMutation.maximumEntries
                )
                let availability = applyAvailabilityObservations(
                    folderMutation.availabilityObservations
                )
                changedEntryIDs.formUnion(prepared.result)
                statusChangedEntryIDs.formUnion(availability.result)
                mutated = mutated || prepared.shouldPersist || availability.shouldPersist
                if let discoveryAttempt = folderMutation.discoveryAttempt {
                    mutated = applyDiscoveryAttempt(discoveryAttempt) || mutated
                }
                if let rootObservation = folderMutation.rootObservation {
                    let rootStatusChanged = applyRootObservation(rootObservation)
                    if rootStatusChanged {
                        statusChangedEntryIDs.formUnion(
                            index.entries.lazy
                                .filter { $0.watchedFolderID == folderMutation.folderID }
                                .map(\.id)
                        )
                    }
                    mutated = rootStatusChanged || mutated
                }
            }
            for (provider, date) in handledSignals {
                if let existing = index.lastHandledSignalByProvider[provider.rawValue], existing >= date {
                    continue
                }
                index.lastHandledSignalByProvider[provider.rawValue] = date
                index.updatedAt = max(index.updatedAt, date)
                mutated = true
            }
            return (
                AgentFolderScanCommitResult(
                    changedEntryIDs: changedEntryIDs,
                    statusChangedEntryIDs: statusChangedEntryIDs
                ),
                mutated
            )
        }
    }

    /// Whether this process already analyzed the exact indexed source revision. Unlike
    /// `cachedRecord`, this remains true after a full summary is evicted from the 256-entry LRU.
    func hasTransientAnalysis(
        id: String,
        reference: AgentSourceReference,
        sha256: String? = nil,
        byteCount: Int64? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        guard let entryPosition = entryIndexByID[id], index.entries.indices.contains(entryPosition) else {
            removeTransientAnalysis(id: id)
            return false
        }
        let entry = index.entries[entryPosition]
        guard entry.reference == reference,
            let metrics = transientMetricsByID[id],
            metrics.matches(
                reference: entry.reference,
                sha256: entry.sha256,
                byteCount: entry.byteCount
            ),
            sha256.map({ $0 == entry.sha256 }) ?? true,
            byteCount.map({ $0 == entry.byteCount }) ?? true
        else {
            removeTransientAnalysis(id: id)
            return false
        }
        touchTransientMetric(id: id)
        return true
    }

    func transientAnalysisCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return transientMetricsByID.count
    }

    func analyzedEntryIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        reconcileTransientCache()
        return Set(transientMetricsByID.keys)
    }

    func transientSummaryEntryIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        pruneExpiredTransientSummaries(at: currentDate())
        reconcileTransientCache()
        return Set(transientRecordsByID.keys)
    }

    func transientSummaryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        pruneExpiredTransientSummaries(at: currentDate())
        return transientRecordsByID.count
    }

    func transientSummaryByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        pruneExpiredTransientSummaries(at: currentDate())
        return transientSummaryBytes
    }

    public func cachedRecord(id: String) -> AgentCaptureRecord? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        let now = currentDate()
        pruneExpiredTransientSummaries(at: now)
        guard let entryIndex = entryIndexByID[id], index.entries.indices.contains(entryIndex) else {
            removeTransientAnalysis(id: id)
            return nil
        }
        let entry = index.entries[entryIndex]
        guard var record = transientRecordsByID[id],
            record.isAnalyzed,
            record.index.reference == entry.reference,
            record.sha256 == entry.sha256,
            record.byteCount == entry.byteCount
        else {
            removeTransientSummary(id: id)
            return nil
        }
        record.index = entry
        transientRecordsByID[id] = record
        touchTransientMetric(id: id)
        touchTransientRecord(id: id, at: now)
        return record
    }

    public func clearTransientAnalyses() {
        lock.lock()
        defer { lock.unlock() }
        transientRecordsByID.removeAll(keepingCapacity: false)
        transientMetricsByID.removeAll(keepingCapacity: false)
        transientMetricAccessByID.removeAll(keepingCapacity: false)
        transientMetricAccessCounter = 0
        transientAccessByID.removeAll(keepingCapacity: false)
        transientSummaryMetadataByID.removeAll(keepingCapacity: false)
        transientSummaryBytes = 0
        transientAccessCounter = 0
    }

    /// Releases transcript-derived UI summaries immediately while retaining only compact
    /// per-revision metrics. A later metadata poll therefore remains warm and does not reread
    /// original bodies merely because the dashboard window was hidden.
    public func discardTransientSummaries() {
        lock.lock()
        defer { lock.unlock() }
        transientRecordsByID.removeAll(keepingCapacity: false)
        transientAccessByID.removeAll(keepingCapacity: false)
        transientSummaryMetadataByID.removeAll(keepingCapacity: false)
        transientSummaryBytes = 0
        transientAccessCounter = 0
    }

    public func latestRecords() -> [AgentCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        pruneExpiredTransientSummaries(at: currentDate())
        return newestEntries(index.entries, limit: Self.maximumTransientRecords).map { storedEntry in
            let entry = effectiveEntry(storedEntry)
            guard var record = transientRecordsByID[entry.id] else {
                return AgentCaptureRecord(index: entry, isAnalyzed: false)
            }
            record.index = entry
            return record
        }
    }

    public func overview(for day: Date) -> AgentActivityOverview {
        lock.lock()
        _ = reloadIndexFromDisk()
        pruneExpiredTransientSummaries(at: currentDate())
        let indexBytes = self.indexBytes()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var newestRelevant: [AgentSourceIndexEntry] = []
        newestRelevant.reserveCapacity(Self.maximumTransientRecords)
        var sessionCount = 0
        var analyzedSessionCount = 0
        var messageCount = 0
        var visibleMessageCount = 0
        var toolCallCount = 0
        var errorCount = 0
        var sourceBytes: Int64 = 0
        var lastCaptureAt: Date?
        for storedEntry in index.entries {
            let entry = effectiveEntry(storedEntry)
            let metrics = transientMetricsByID[entry.id]
            guard isRelevant(entry: entry, metrics: metrics, dayStart: dayStart, dayEnd: dayEnd) else {
                continue
            }
            insertNewestBounded(entry, into: &newestRelevant, limit: Self.maximumTransientRecords)
            let activityDate = recencyDate(for: entry, metrics: metrics)
            lastCaptureAt = max(lastCaptureAt ?? activityDate, activityDate)
            guard entry.availability == .available else { continue }
            sessionCount += 1
            if metrics != nil { analyzedSessionCount += 1 }
            messageCount += metrics?.messageCount ?? 0
            visibleMessageCount += metrics?.visibleMessageCount ?? 0
            toolCallCount += metrics?.toolCallCount ?? 0
            errorCount += metrics?.errorCount ?? 0
            sourceBytes += entry.byteCount
        }
        newestRelevant.sort { isNewer($0, than: $1) }
        let captures = newestRelevant.map { entry in
            guard var record = transientRecordsByID[entry.id] else {
                return AgentCaptureRecord(index: entry, isAnalyzed: false)
            }
            record.index = entry
            return record
        }
        lock.unlock()

        return AgentActivityOverview(
            day: dayStart,
            captures: captures,
            sessionCount: sessionCount,
            analyzedSessionCount: analyzedSessionCount,
            messageCount: messageCount,
            visibleMessageCount: visibleMessageCount,
            toolCallCount: toolCallCount,
            errorCount: errorCount,
            sourceBytes: sourceBytes,
            indexBytes: indexBytes,
            lastCaptureAt: lastCaptureAt
        )
    }

    public func directRead(
        entryID: String,
        maximumBytes: Int64,
        expectedReference: AgentSourceReference? = nil,
        observedAt: Date = Date()
    ) throws -> AgentCaptureRecord {
        lock.lock()
        guard reloadIndexFromDisk() else {
            lock.unlock()
            throw AgentActivityStoreError.indexCorrupt
        }
        guard let entryIndex = entryIndexByID[entryID], index.entries.indices.contains(entryIndex) else {
            lock.unlock()
            throw AgentActivityStoreError.sourceNotFound(entryID)
        }
        let entry = index.entries[entryIndex]
        guard expectedReference == nil || entry.reference == expectedReference else {
            lock.unlock()
            throw AgentActivityStoreError.sourceReferenceChanged(entryID)
        }
        lock.unlock()
        let folder = AgentWatchedFolder(
            id: entry.watchedFolderID,
            displayName: entry.watchedFolderName,
            path: sourceRoot(for: entry),
            provider: entry.provider
        )
        let session = try AgentDirectSourceReader.makeScanSession(
            folder: folder,
            fileManager: fileManager
        )
        let candidate = try session.candidate(for: entry)
        let record = try session.read(
            candidate: candidate,
            previous: entry,
            maximumBytes: maximumBytes,
            observedAt: observedAt
        )
        try session.verifyOpenCodeSourcesUnchanged()

        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        guard let currentIndex = entryIndexByID[entryID], index.entries.indices.contains(currentIndex) else {
            throw AgentActivityStoreError.sourceNotFound(entryID)
        }
        let current = index.entries[currentIndex]
        guard current.reference == entry.reference else {
            throw AgentActivityStoreError.sourceReferenceChanged(entryID)
        }
        return record
    }

    public func verifiesCurrentSource(entryID: String, maximumBytes: Int64) -> Bool {
        guard let current = try? directRead(entryID: entryID, maximumBytes: maximumBytes),
            let expected = entry(id: entryID),
            expected.availability == .available,
            expected.reference == current.index.reference
        else { return false }
        return current.sha256 == expected.sha256
    }

    public func lastFullDiscovery(folderID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return index.lastFullDiscoveryByFolder[folderID]
    }

    func lastFullDiscoveryAttempt(folderID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return index.lastFullDiscoveryAttemptByFolder[folderID]
    }

    func fullDiscoveryFailureCount(folderID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return max(index.fullDiscoveryFailureCountByFolder[folderID] ?? 0, 0)
    }

    public func rootStatus(folderID: String) -> AgentFolderRootStatus? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return index.rootStatusByFolder[folderID]
    }

    /// Persists both successful and failed attempts, so repeated discovery failures cannot
    /// collapse the normal scan interval into a full filesystem/database scan loop.
    func markFullDiscoveryAttempt(folderID: String, at date: Date, succeeded: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        try performPersistedIndexMutation {
            let mutated = applyDiscoveryAttempt(
                AgentFolderDiscoveryAttempt(folderID: folderID, observedAt: date, succeeded: succeeded)
            )
            return ((), mutated)
        }
    }

    public func markFullDiscovery(folderID: String, at date: Date) throws {
        try markFullDiscoveryAttempt(folderID: folderID, at: date, succeeded: true)
    }

    public func lastHandledSignal(provider: AgentProvider) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return index.lastHandledSignalByProvider[provider.rawValue]
    }

    public func markSignalHandled(provider: AgentProvider, at date: Date) throws {
        try markSignalsHandled([provider: date])
    }

    func markSignalsHandled(_ datesByProvider: [AgentProvider: Date]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        guard !datesByProvider.isEmpty else { return }
        try performPersistedIndexMutation {
            var mutated = false
            var latest = index.updatedAt
            for (provider, date) in datesByProvider {
                if let existing = index.lastHandledSignalByProvider[provider.rawValue], existing >= date {
                    continue
                }
                index.lastHandledSignalByProvider[provider.rawValue] = date
                latest = max(latest, date)
                mutated = true
            }
            if latest != index.updatedAt { index.updatedAt = latest }
            return ((), mutated)
        }
    }

    public func latestSignal(provider: AgentProvider) -> AgentHookSignal? {
        let file = signalsDirectory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
        lock.lock()
        defer { lock.unlock() }
        guard let data = boundedRegularFileData(at: file, maximumBytes: Self.maximumSignalBytes) else { return nil }
        return try? decoder.decode(AgentHookSignal.self, from: data)
    }

    public func indexEntryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        return index.entries.count
    }

    public func indexBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return regularFileBytes(at: indexFile)
    }

    public func storageBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var total = regularFileBytes(at: configurationFile) + regularFileBytes(at: indexFile)
        let signalFiles =
            (try? fileManager.contentsOfDirectory(
                at: signalsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        total += signalFiles.reduce(into: Int64(0)) { result, url in
            result += regularFileBytes(at: url)
        }
        return total
    }

    public func indexIsValid(maximumEntries: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = reloadIndexFromDisk()
        let boundedMaximum = min(max(maximumEntries, 0), Self.absoluteMaximumIndexEntries)
        return !indexLoadFailed
            && index.entries.count <= boundedMaximum
            && indexIsStructurallyValid(index)
    }

    /// Removes discovery cursors only for folders the caller has explicitly declared inactive.
    @discardableResult
    public func pruneDiscoveryCursors(activeFolderIDs: Set<String>) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { throw AgentActivityStoreError.indexCorrupt }
        let successful = index.lastFullDiscoveryByFolder.filter { activeFolderIDs.contains($0.key) }
        let attempts = index.lastFullDiscoveryAttemptByFolder.filter { activeFolderIDs.contains($0.key) }
        let failures = index.fullDiscoveryFailureCountByFolder.filter { activeFolderIDs.contains($0.key) }
        let rootStatuses = index.rootStatusByFolder.filter { activeFolderIDs.contains($0.key) }
        guard
            successful != index.lastFullDiscoveryByFolder
                || attempts != index.lastFullDiscoveryAttemptByFolder
                || failures != index.fullDiscoveryFailureCountByFolder
                || rootStatuses != index.rootStatusByFolder
        else { return false }
        return try performPersistedIndexMutation {
            index.lastFullDiscoveryByFolder = successful
            index.lastFullDiscoveryAttemptByFolder = attempts
            index.fullDiscoveryFailureCountByFolder = failures
            index.rootStatusByFolder = rootStatuses
            index.updatedAt = max(index.updatedAt, Date())
            return (true, true)
        }
    }

    /// Removes metadata for folders that are no longer authorized for direct reads. Filtering by
    /// the opaque folder identity keeps entries and cursors belonging to every other root intact.
    @discardableResult
    private func pruneInactiveFolderMetadata(
        activeFolderIDs: Set<String>,
        activeProviderKeys: Set<String>
    ) -> Bool {
        let removedEntryIDs = index.entries.compactMap { entry in
            activeFolderIDs.contains(entry.watchedFolderID) ? nil : entry.id
        }
        let entries = index.entries.filter { activeFolderIDs.contains($0.watchedFolderID) }
        let successful = index.lastFullDiscoveryByFolder.filter { activeFolderIDs.contains($0.key) }
        let attempts = index.lastFullDiscoveryAttemptByFolder.filter { activeFolderIDs.contains($0.key) }
        let failures = index.fullDiscoveryFailureCountByFolder.filter { activeFolderIDs.contains($0.key) }
        let rootStatuses = index.rootStatusByFolder.filter { activeFolderIDs.contains($0.key) }
        let handledSignals = index.lastHandledSignalByProvider.filter {
            activeProviderKeys.contains($0.key)
        }
        guard
            entries != index.entries
                || successful != index.lastFullDiscoveryByFolder
                || attempts != index.lastFullDiscoveryAttemptByFolder
                || failures != index.fullDiscoveryFailureCountByFolder
                || rootStatuses != index.rootStatusByFolder
                || handledSignals != index.lastHandledSignalByProvider
        else { return false }

        for id in removedEntryIDs { removeTransientAnalysis(id: id) }
        index.entries = entries
        index.lastFullDiscoveryByFolder = successful
        index.lastFullDiscoveryAttemptByFolder = attempts
        index.fullDiscoveryFailureCountByFolder = failures
        index.rootStatusByFolder = rootStatuses
        index.lastHandledSignalByProvider = handledSignals
        index.updatedAt = max(index.updatedAt, currentDate())
        rebuildEntryLookups()
        return true
    }

    private func applyPreparedCaptures(
        _ preparedCaptures: [AgentPreparedCapture],
        maximumEntries: Int
    ) -> (result: Set<String>, shouldPersist: Bool) {
        var changedIDs = Set<String>()
        var persistedRecordIDs = Set<String>()
        var latestObservedAt = index.updatedAt
        var indexMutated = false
        for prepared in preparedCaptures {
            var record = prepared.record
            record.index = record.index.sanitizedForPersistence()
            persistedRecordIDs.insert(record.id)
            let referenceKey = ReferenceLookupKey(record.index.reference)
            if let idPosition = entryIndexByID[record.id],
                let referencePosition = entryIndexByReference[referenceKey],
                idPosition != referencePosition
            {
                let duplicate = index.entries.remove(at: referencePosition)
                removeTransientAnalysis(id: duplicate.id)
                rebuildEntryLookups()
                indexMutated = true
            }

            let priorIndex = entryIndexByID[record.id] ?? entryIndexByReference[referenceKey]
            let prior = priorIndex.map { index.entries[$0] }
            if let prior, observation(record.index, isOlderThan: prior) {
                if prior.reference == record.index.reference,
                    prior.sha256 == record.sha256,
                    prior.byteCount == record.byteCount,
                    record.isAnalyzed
                {
                    var currentAnalysis = record
                    currentAnalysis.index = prior
                    cacheTransientRecord(
                        currentAnalysis,
                        retainFullSummary: prepared.retainFullSummary
                    )
                }
                continue
            }
            var mergedIndex = record.index
            if let prior {
                mergedIndex.firstIndexedAt = min(prior.firstIndexedAt, mergedIndex.firstIndexedAt)
                mergedIndex.lastObservedAt = max(prior.lastObservedAt, mergedIndex.lastObservedAt)
                mergedIndex.sourceCreatedAt = mergedIndex.sourceCreatedAt ?? prior.sourceCreatedAt
                mergedIndex.conversationStartedAt =
                    mergedIndex.conversationStartedAt
                    ?? prior.conversationStartedAt
                mergedIndex.conversationEndedAt =
                    mergedIndex.conversationEndedAt
                    ?? prior.conversationEndedAt
                if !datesMateriallyDifferent(prior.sourceModifiedAt, mergedIndex.sourceModifiedAt) {
                    mergedIndex.sourceModifiedAt = prior.sourceModifiedAt ?? mergedIndex.sourceModifiedAt
                }
            }
            let sourceChanged = materiallyChanged(prior, mergedIndex)
            if sourceChanged {
                changedIDs.insert(record.id)
            } else if let prior {
                // A forced integrity read or explicit day analysis may recreate transient
                // summaries for an identical revision. Keep the persisted metadata byte-for-byte
                // stable so verification does not cause an index write.
                mergedIndex = prior
                if sourceIdentityDiffers(prior, record.index) {
                    // A shared provider container (OpenCode's SQLite database) can change
                    // while this conversation's exact digest remains stable. Advance only
                    // the inexpensive freshness identity so warm scans do not reread the
                    // unchanged session forever or report a false logical change.
                    mergedIndex.sourceDevice = record.index.sourceDevice
                    mergedIndex.sourceInode = record.index.sourceInode
                    mergedIndex.sourceChangedSeconds = record.index.sourceChangedSeconds
                    mergedIndex.sourceChangedNanoseconds = record.index.sourceChangedNanoseconds
                    mergedIndex.sourceContainerByteCount = record.index.sourceContainerByteCount
                    mergedIndex.sourceContainerModifiedSeconds =
                        record.index.sourceContainerModifiedSeconds
                    mergedIndex.sourceContainerModifiedNanoseconds =
                        record.index.sourceContainerModifiedNanoseconds
                }
            }

            if let priorIndex {
                if let prior, prior.reference != mergedIndex.reference {
                    entryIndexByReference.removeValue(forKey: ReferenceLookupKey(prior.reference))
                }
                if let prior, prior.id != mergedIndex.id {
                    entryIndexByID.removeValue(forKey: prior.id)
                    removeTransientAnalysis(id: prior.id)
                }
                if prior != mergedIndex { indexMutated = true }
                index.entries[priorIndex] = mergedIndex
                entryIndexByID[mergedIndex.id] = priorIndex
                entryIndexByReference[ReferenceLookupKey(mergedIndex.reference)] = priorIndex
            } else {
                entryIndexByID[record.id] = index.entries.count
                entryIndexByReference[ReferenceLookupKey(mergedIndex.reference)] = index.entries.count
                index.entries.append(mergedIndex)
                indexMutated = true
            }
            var cachedRecord = record
            cachedRecord.index = mergedIndex
            cacheTransientRecord(cachedRecord, retainFullSummary: prepared.retainFullSummary)
            latestObservedAt = max(latestObservedAt, mergedIndex.lastObservedAt)
        }
        if enforceBound(maximumEntries: maximumEntries, preserving: persistedRecordIDs) {
            indexMutated = true
        }
        reconcileTransientCache()
        if latestObservedAt != index.updatedAt {
            index.updatedAt = latestObservedAt
            indexMutated = true
        }
        return (changedIDs, indexMutated)
    }

    private func applyAvailabilityObservations(
        _ observations: [AgentAvailabilityObservation]
    ) -> (result: Set<String>, shouldPersist: Bool) {
        var changedIDs = Set<String>()
        var mutated = false
        var latestObservedAt = index.updatedAt
        for observation in observations {
            guard let entryPosition = entryIndexByID[observation.entryID] else { continue }
            var entry = index.entries[entryPosition]
            if let expectedReference = observation.expectedReference,
                entry.reference != expectedReference
            {
                continue
            }
            // Observation order is determined only by when Goalong saw the source. A restored
            // source may legitimately have an older filesystem mtime than its missing entry.
            guard observation.observedAt.timeIntervalSince(entry.lastObservedAt) >= -1 else { continue }
            _ = observation.detail
            let boundedDetail = AgentSourceStatusCode.persistedValue(for: observation.availability)
            let statusChanged =
                entry.availability != observation.availability
                || entry.statusDetail != boundedDetail
            // Repeating the same unavailable state conveys no new durable information.
            // Keep the original failure timestamp so the scanner can apply process-local
            // exponential backoff without rewriting the index every minute.
            guard statusChanged else { continue }

            entry.availability = observation.availability
            entry.statusDetail = boundedDetail
            entry.lastObservedAt = max(entry.lastObservedAt, observation.observedAt)
            index.entries[entryPosition] = entry
            if var transient = transientRecordsByID[observation.entryID] {
                transient.index = entry
                transientRecordsByID[observation.entryID] = transient
            }
            if statusChanged { changedIDs.insert(observation.entryID) }
            latestObservedAt = max(latestObservedAt, observation.observedAt)
            mutated = true
        }
        if latestObservedAt != index.updatedAt {
            index.updatedAt = latestObservedAt
            mutated = true
        }
        return (changedIDs, mutated)
    }

    @discardableResult
    private func applyDiscoveryAttempt(_ attempt: AgentFolderDiscoveryAttempt) -> Bool {
        if let existing = index.lastFullDiscoveryAttemptByFolder[attempt.folderID] {
            if existing > attempt.observedAt { return false }
            if existing == attempt.observedAt,
                !attempt.succeeded
                    || (index.lastFullDiscoveryByFolder[attempt.folderID] ?? .distantPast)
                        >= attempt.observedAt
            {
                return false
            }
        }
        index.lastFullDiscoveryAttemptByFolder[attempt.folderID] = attempt.observedAt
        if attempt.succeeded {
            index.lastFullDiscoveryByFolder[attempt.folderID] = max(
                index.lastFullDiscoveryByFolder[attempt.folderID] ?? .distantPast,
                attempt.observedAt
            )
            index.fullDiscoveryFailureCountByFolder.removeValue(forKey: attempt.folderID)
        } else {
            let current = max(index.fullDiscoveryFailureCountByFolder[attempt.folderID] ?? 0, 0)
            index.fullDiscoveryFailureCountByFolder[attempt.folderID] = min(current + 1, 30)
        }
        index.updatedAt = max(index.updatedAt, attempt.observedAt)
        return true
    }

    @discardableResult
    private func applyRootObservation(_ observation: AgentFolderRootObservation) -> Bool {
        guard !observation.folderID.isEmpty else { return false }
        if let existing = index.rootStatusByFolder[observation.folderID],
            existing.availability == observation.availability
        {
            return false
        }
        index.rootStatusByFolder[observation.folderID] = AgentFolderRootStatus(
            availability: observation.availability,
            changedAt: observation.observedAt
        )
        index.updatedAt = max(index.updatedAt, observation.observedAt)
        return true
    }

    private func sourceRoot(for entry: AgentSourceIndexEntry) -> String {
        if entry.reference.kind == .sqliteConversation {
            return URL(fileURLWithPath: entry.reference.path).deletingLastPathComponent().path
        }
        let relativeComponents = entry.relativePath.split(separator: "/").count
        var root = URL(fileURLWithPath: entry.reference.path)
        for _ in 0..<relativeComponents { root.deleteLastPathComponent() }
        return root.path
    }

    /// Root reachability is stored once per folder to avoid O(n) index rewrites. Published
    /// records still project that state onto every child so an unreachable root is never shown
    /// as if its conversations were currently available.
    private func effectiveEntry(_ storedEntry: AgentSourceIndexEntry) -> AgentSourceIndexEntry {
        guard let rootStatus = index.rootStatusByFolder[storedEntry.watchedFolderID],
            rootStatus.availability != .available
        else { return storedEntry }
        var entry = storedEntry
        entry.availability = rootStatus.availability
        entry.statusDetail = AgentSourceStatusCode.persistedValue(for: rootStatus.availability)
        return entry
    }

    @discardableResult
    private func enforceBound(maximumEntries: Int, preserving ids: Set<String> = []) -> Bool {
        let boundedMaximum = min(max(maximumEntries, 0), Self.absoluteMaximumIndexEntries)
        guard index.entries.count > boundedMaximum else { return false }
        index.entries.sort { left, right in
            if ids.contains(left.id) != ids.contains(right.id) { return !ids.contains(left.id) }
            if (left.availability == .available) != (right.availability == .available) {
                return left.availability != .available
            }
            return left.lastObservedAt < right.lastObservedAt
        }
        let removalCount = index.entries.count - boundedMaximum
        for removed in index.entries.prefix(removalCount) {
            removeTransientAnalysis(id: removed.id)
        }
        index.entries.removeSubrange(0..<removalCount)
        rebuildEntryLookups()
        return true
    }

    private func loadIndex() throws {
        lock.lock()
        defer { lock.unlock() }
        guard reloadIndexFromDisk() else { return }
        let maximumEntries = configuredMaximumEntriesForLoad()
        let canonicalBytes = try encoder.encode(index)
        let onDiskBytes = boundedRegularFileData(
            at: indexFile,
            maximumBytes: Self.maximumSerializedIndexBytes
        )
        let requiresCanonicalRewrite = onDiskBytes.map { $0 != canonicalBytes } ?? false
        if index.entries.count > maximumEntries || requiresCanonicalRewrite {
            try performPersistedIndexMutation {
                _ = enforceBound(maximumEntries: maximumEntries)
                return ((), true)
            }
        }
    }

    /// Reloads while the process-wide lock is held so separate store instances merge
    /// against the latest atomically written metadata instead of losing each other's updates.
    @discardableResult
    private func reloadIndexFromDisk() -> Bool {
        guard fileManager.fileExists(atPath: indexFile.path) else {
            index = AgentActivityIndex()
            indexLoadFailed = false
            loadedIndexSignature = nil
            loadedRawEntryCount = 0
            rebuildEntryLookups()
            reconcileTransientCache()
            return true
        }

        let currentSignature = fileSignature(at: indexFile)
        if let currentSignature, currentSignature == loadedIndexSignature {
            guard !indexLoadFailed else { return false }
            return true
        }

        guard let currentSignature,
            currentSignature.byteCount <= Self.maximumSerializedIndexBytes,
            let data = boundedRegularFileData(
                at: indexFile,
                maximumBytes: Self.maximumSerializedIndexBytes
            ),
            Self.indexJSONContainsOnlyMetadataKeys(data),
            let loaded = try? decoder.decode(AgentActivityIndex.self, from: data),
            indexIsStructurallyValid(loaded)
        else {
            indexLoadFailed = true
            loadedIndexSignature = currentSignature
            return false
        }

        index = loaded
        indexLoadFailed = false
        loadedIndexSignature = currentSignature
        loadedRawEntryCount = loaded.entries.count
        rebuildEntryLookups()
        reconcileTransientCache()
        return true
    }

    private static func indexJSONContainsOnlyMetadataKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys).isSubset(of: persistedIndexTopLevelKeys),
            let entries = dictionary["entries"] as? [Any]
        else { return false }

        return entries.allSatisfy { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                Set(entry.keys).isSubset(of: persistedIndexEntryKeys),
                let reference = entry["reference"] as? [String: Any],
                Set(reference.keys).isSubset(of: persistedIndexReferenceKeys)
            else { return false }
            return true
        }
    }

    private func persistIndex() throws {
        try enforceSerializedIndexBound()
        index.entries.sort { $0.id < $1.id }
        rebuildEntryLookups()
        guard indexIsStructurallyValid(index) else { throw AgentActivityStoreError.indexCorrupt }
        let data = try encoder.encode(index)
        guard Int64(data.count) <= Self.maximumSerializedIndexBytes else {
            throw AgentActivityStoreError.indexCorrupt
        }
        try secureAtomicWrite(data, to: indexFile)
        indexLoadFailed = false
        loadedIndexSignature = fileSignature(at: indexFile)
        loadedRawEntryCount = index.entries.count
        successfulIndexWriteCount += 1
    }

    /// Enforces the on-disk byte ceiling without ever materializing an oversized whole index.
    /// Encoding each bounded metadata entry independently gives an exact JSON byte total because
    /// the full array adds only its commas and brackets. Eviction remains deterministic and
    /// preserves the configured entry limit as an upper bound.
    private func enforceSerializedIndexBound() throws {
        var metadataOnlyIndex = index
        metadataOnlyIndex.entries = []
        let metadataBytes = try encoder.encode(metadataOnlyIndex).count
        guard Int64(metadataBytes) <= Self.maximumSerializedIndexBytes else {
            throw AgentActivityStoreError.indexCorrupt
        }
        guard !index.entries.isEmpty else { return }

        index.entries.sort { left, right in
            if (left.availability == .available) != (right.availability == .available) {
                return left.availability != .available
            }
            if left.lastObservedAt != right.lastObservedAt {
                return left.lastObservedAt < right.lastObservedAt
            }
            return left.id < right.id
        }
        var encodedEntryBytes: [Int] = []
        encodedEntryBytes.reserveCapacity(index.entries.count)
        var serializedBytes = metadataBytes + max(index.entries.count - 1, 0)
        for entry in index.entries {
            let byteCount = try encoder.encode(entry).count
            encodedEntryBytes.append(byteCount)
            serializedBytes += byteCount
        }
        guard Int64(serializedBytes) > Self.maximumSerializedIndexBytes else { return }

        var removalCount = 0
        var remainingCount = index.entries.count
        while Int64(serializedBytes) > Self.maximumSerializedIndexBytes,
            removalCount < encodedEntryBytes.count
        {
            serializedBytes -= encodedEntryBytes[removalCount]
            if remainingCount > 1 { serializedBytes -= 1 }
            removalCount += 1
            remainingCount -= 1
        }
        guard Int64(serializedBytes) <= Self.maximumSerializedIndexBytes else {
            throw AgentActivityStoreError.indexCorrupt
        }
        for removed in index.entries.prefix(removalCount) {
            removeTransientAnalysis(id: removed.id)
        }
        index.entries.removeSubrange(0..<removalCount)
        rebuildEntryLookups()
    }

    private func configuredMaximumEntriesForLoad() -> Int {
        guard fileManager.fileExists(atPath: configurationFile.path) else {
            configurationLoadFailed = false
            return AgentActivityConfiguration.default.maximumIndexEntries
        }
        guard
            let data = boundedRegularFileData(
                at: configurationFile,
                maximumBytes: Self.maximumConfigurationBytes
            ),
            let configuration = try? decoder.decode(AgentActivityConfiguration.self, from: data)
        else {
            configurationLoadFailed = true
            return AgentActivityConfiguration.default.maximumIndexEntries
        }
        configurationLoadFailed = false
        return configuration.validated().maximumIndexEntries
    }

    private func indexIsStructurallyValid(_ candidate: AgentActivityIndex) -> Bool {
        guard candidate.schemaVersion == 2,
            candidate.entries.count <= Self.absoluteMaximumIndexEntries,
            candidate.lastFullDiscoveryByFolder.count <= 10_000,
            candidate.lastFullDiscoveryAttemptByFolder.count <= 10_000,
            candidate.fullDiscoveryFailureCountByFolder.count <= 10_000,
            candidate.rootStatusByFolder.count <= AgentActivityConfiguration.maximumWatchedFolders,
            candidate.lastHandledSignalByProvider.count <= AgentProvider.allCases.count,
            cursorMapIsValid(candidate.lastFullDiscoveryByFolder),
            cursorMapIsValid(candidate.lastFullDiscoveryAttemptByFolder),
            (candidate.fullDiscoveryFailureCountByFolder.allSatisfy {
                !$0.key.isEmpty && $0.key.utf8.count <= 1_024 && (0...30).contains($0.value)
            }),
            candidate.lastHandledSignalByProvider.keys.allSatisfy({
                AgentProvider(rawValue: $0) != nil
            }),
            candidate.rootStatusByFolder.allSatisfy({ key, _ in
                !key.isEmpty && key.utf8.count <= AgentSourceIndexEntry.maximumFolderIDBytes
            }),
            Set(candidate.entries.map(\.id)).count == candidate.entries.count,
            Set(candidate.entries.map { ReferenceLookupKey($0.reference) }).count == candidate.entries.count
        else { return false }
        return candidate.entries.allSatisfy {
            AgentStableConversationIdentifier.isPersisted($0.stableConversationID)
                && $0.id
                    == AgentStableConversationIdentifier.entryID(
                        provider: $0.provider,
                        persistedIdentifier: $0.stableConversationID
                    )
                && !$0.watchedFolderID.isEmpty
                && $0.watchedFolderID.utf8.count <= AgentSourceIndexEntry.maximumFolderIDBytes
                && $0.watchedFolderName == $0.provider.displayName
                && $0.reference.path.hasPrefix("/")
                && $0.reference.path.utf8.count <= AgentSourceReference.maximumPathBytes
                && $0.relativePath.utf8.count <= AgentSourceIndexEntry.maximumRelativePathBytes
                && ($0.reference.locator?.utf8.count ?? 0) <= AgentSourceReference.maximumLocatorBytes
                && referenceLocatorIsValid($0.reference)
                && AgentSourceStatusCode.isPersistedValue($0.statusDetail)
                && $0.statusDetail == AgentSourceStatusCode.persistedValue(for: $0.availability)
                && $0.byteCount >= 0
                && ($0.sha256.isEmpty || isSHA256Hex($0.sha256))
                && ($0.availability != .available || isSHA256Hex($0.sha256))
                && sourceIdentityIsValid($0)
                && sourceContainerIdentityIsValid($0)
                && offsetsAreValid($0)
        }
    }

    private func sourceIdentityIsValid(_ entry: AgentSourceIndexEntry) -> Bool {
        let valuesPresent = [
            entry.sourceDevice != nil,
            entry.sourceInode != nil,
            entry.sourceChangedSeconds != nil,
            entry.sourceChangedNanoseconds != nil,
        ]
        guard valuesPresent.allSatisfy({ $0 }) || valuesPresent.allSatisfy({ !$0 }) else {
            return false
        }
        guard let nanoseconds = entry.sourceChangedNanoseconds else { return true }
        return (0..<1_000_000_000).contains(nanoseconds)
    }

    private func sourceContainerIdentityIsValid(_ entry: AgentSourceIndexEntry) -> Bool {
        let valuesPresent = [
            entry.sourceContainerByteCount != nil,
            entry.sourceContainerModifiedSeconds != nil,
            entry.sourceContainerModifiedNanoseconds != nil,
        ]
        guard valuesPresent.allSatisfy({ $0 }) || valuesPresent.allSatisfy({ !$0 }) else {
            return false
        }
        guard let byteCount = entry.sourceContainerByteCount,
            let nanoseconds = entry.sourceContainerModifiedNanoseconds
        else { return true }
        return byteCount >= 0 && (0..<1_000_000_000).contains(nanoseconds)
    }

    private func cursorMapIsValid(
        _ values: [String: Date],
        maximumKeyBytes: Int = 1_024
    ) -> Bool {
        values.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= maximumKeyBytes }
    }

    private func referenceLocatorIsValid(_ reference: AgentSourceReference) -> Bool {
        switch reference.kind {
        case .file:
            return reference.locator == nil
        case .sqliteConversation:
            guard let locator = reference.locator else { return false }
            return !locator.isEmpty && locator.utf8.count <= 8_192
        }
    }

    private func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private func offsetsAreValid(_ entry: AgentSourceIndexEntry) -> Bool {
        switch (entry.startOffset, entry.endOffset) {
        case (nil, nil):
            return true
        case (let start?, let end?):
            return start >= 0 && end >= start && end <= entry.byteCount
        default:
            return false
        }
    }

    private func materiallyChanged(
        _ previous: AgentSourceIndexEntry?,
        _ current: AgentSourceIndexEntry
    ) -> Bool {
        guard let previous else { return true }
        return previous.id != current.id
            || previous.stableConversationID != current.stableConversationID
            || previous.sha256 != current.sha256
            || previous.byteCount != current.byteCount
            || datesMateriallyDifferent(previous.sourceCreatedAt, current.sourceCreatedAt)
            || datesMateriallyDifferent(previous.sourceModifiedAt, current.sourceModifiedAt)
            || datesMateriallyDifferent(previous.conversationStartedAt, current.conversationStartedAt)
            || datesMateriallyDifferent(previous.conversationEndedAt, current.conversationEndedAt)
            || previous.availability != current.availability
            || previous.reference != current.reference
    }

    private func sourceIdentityDiffers(
        _ previous: AgentSourceIndexEntry,
        _ current: AgentSourceIndexEntry
    ) -> Bool {
        previous.sourceDevice != current.sourceDevice
            || previous.sourceInode != current.sourceInode
            || previous.sourceChangedSeconds != current.sourceChangedSeconds
            || previous.sourceChangedNanoseconds != current.sourceChangedNanoseconds
            || previous.sourceContainerByteCount != current.sourceContainerByteCount
            || previous.sourceContainerModifiedSeconds != current.sourceContainerModifiedSeconds
            || previous.sourceContainerModifiedNanoseconds
                != current.sourceContainerModifiedNanoseconds
    }

    private func observation(_ candidate: AgentSourceIndexEntry, isOlderThan current: AgentSourceIndexEntry) -> Bool {
        // Filesystem mtimes are source metadata, not observation ordering. A restored source can
        // legitimately be older than the last readable version and must still become available.
        return candidate.lastObservedAt.timeIntervalSince(current.lastObservedAt) < -1
    }

    private func datesMateriallyDifferent(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return false
        case (let left?, let right?):
            return abs(left.timeIntervalSince(right)) >= 1
        default:
            return true
        }
    }

    private func cacheTransientRecord(
        _ record: AgentCaptureRecord,
        retainFullSummary: Bool = true
    ) {
        let now = currentDate()
        pruneExpiredTransientSummaries(at: now)
        guard record.isAnalyzed else {
            let metricsMatch =
                transientMetricsByID[record.id].map {
                    $0.matches(
                        reference: record.index.reference,
                        sha256: record.sha256,
                        byteCount: record.byteCount
                    )
                } ?? false
            if var cached = transientRecordsByID[record.id],
                cached.index.reference == record.index.reference,
                cached.sha256 == record.sha256,
                cached.byteCount == record.byteCount
            {
                cached.index = record.index
                transientRecordsByID[record.id] = cached
            } else if !metricsMatch {
                removeTransientAnalysis(id: record.id)
            }
            return
        }
        transientMetricsByID[record.id] = TransientAnalysisMetrics(record)
        touchTransientMetric(id: record.id)
        enforceTransientMetricBound()
        guard retainFullSummary else {
            removeTransientSummary(id: record.id)
            return
        }
        var boundedRecord = record
        boundedRecord.summary = record.summary.boundedForTransientCache()
        let byteCount = transientSummaryByteCount(for: boundedRecord.summary)
        guard byteCount <= Self.maximumTransientSummaryBytes else {
            removeTransientSummary(id: record.id)
            return
        }
        removeTransientSummary(id: record.id)
        transientRecordsByID[record.id] = boundedRecord
        transientSummaryMetadataByID[record.id] = TransientSummaryCacheMetadata(
            byteCount: byteCount,
            expiresAt: now.addingTimeInterval(Self.transientSummaryTTL)
        )
        transientSummaryBytes += byteCount
        touchTransientRecord(id: record.id, at: now)
        while transientRecordsByID.count > Self.maximumTransientRecords
            || transientSummaryBytes > Self.maximumTransientSummaryBytes,
            let leastRecentID = transientAccessByID.min(by: { $0.value < $1.value })?.key
        {
            removeTransientSummary(id: leastRecentID)
        }
    }

    private func touchTransientRecord(id: String, at date: Date) {
        transientAccessCounter &+= 1
        transientAccessByID[id] = transientAccessCounter
        if var metadata = transientSummaryMetadataByID[id] {
            metadata.expiresAt = date.addingTimeInterval(Self.transientSummaryTTL)
            transientSummaryMetadataByID[id] = metadata
        }
    }

    private func removeTransientSummary(id: String) {
        transientRecordsByID.removeValue(forKey: id)
        transientAccessByID.removeValue(forKey: id)
        if let metadata = transientSummaryMetadataByID.removeValue(forKey: id) {
            transientSummaryBytes = max(0, transientSummaryBytes - metadata.byteCount)
        }
    }

    private func removeTransientAnalysis(id: String) {
        removeTransientSummary(id: id)
        transientMetricsByID.removeValue(forKey: id)
        transientMetricAccessByID.removeValue(forKey: id)
    }

    private func touchTransientMetric(id: String) {
        transientMetricAccessCounter &+= 1
        transientMetricAccessByID[id] = transientMetricAccessCounter
    }

    private func enforceTransientMetricBound() {
        guard transientMetricsByID.count > Self.maximumTransientAnalysisMetrics else { return }
        let removeCount = min(
            256,
            transientMetricsByID.count - Self.maximumTransientAnalysisMetrics + 255
        )
        let oldest = transientMetricAccessByID.sorted { left, right in
            if left.value == right.value { return left.key < right.key }
            return left.value < right.value
        }.prefix(removeCount).map(\.key)
        for id in oldest { removeTransientAnalysis(id: id) }
    }

    private func reconcileTransientCache() {
        pruneExpiredTransientSummaries(at: currentDate())
        for id in Array(transientMetricsByID.keys) {
            guard let position = entryIndexByID[id], index.entries.indices.contains(position) else {
                removeTransientAnalysis(id: id)
                continue
            }
            let current = index.entries[position]
            guard let metrics = transientMetricsByID[id],
                metrics.matches(
                    reference: current.reference,
                    sha256: current.sha256,
                    byteCount: current.byteCount
                )
            else {
                removeTransientAnalysis(id: id)
                continue
            }
        }
        for id in Array(transientRecordsByID.keys) {
            guard let position = entryIndexByID[id], index.entries.indices.contains(position) else {
                removeTransientSummary(id: id)
                continue
            }
            let current = index.entries[position]
            guard var record = transientRecordsByID[id],
                record.isAnalyzed,
                record.index.reference == current.reference,
                record.sha256 == current.sha256,
                record.byteCount == current.byteCount,
                transientMetricsByID[id] != nil,
                transientSummaryMetadataByID[id] != nil
            else {
                removeTransientSummary(id: id)
                continue
            }
            record.index = current
            transientRecordsByID[id] = record
        }
    }

    private func pruneExpiredTransientSummaries(at date: Date) {
        let expiredIDs = transientSummaryMetadataByID.compactMap { id, metadata in
            metadata.expiresAt <= date ? id : nil
        }
        for id in expiredIDs { removeTransientSummary(id: id) }
    }

    private func transientSummaryByteCount(for summary: AgentDocumentSummary) -> Int {
        var total = 256
        func add(_ value: String?) {
            guard let value else { return }
            let (next, overflow) = total.addingReportingOverflow(value.utf8.count + 32)
            total = overflow ? Int.max : next
        }
        func add(_ values: [String]) {
            for value in values { add(value) }
        }
        add(summary.sessionID)
        add(summary.title)
        add(summary.excerpt)
        add(summary.projectPath)
        add(summary.models)
        add(summary.tools)
        add(summary.touchedFiles)
        add(summary.commands)
        for message in summary.visibleMessages { add(message.text) }
        return total
    }

    private func rebuildEntryLookups() {
        entryIndexByID.removeAll(keepingCapacity: false)
        entryIndexByReference.removeAll(keepingCapacity: false)
        entryPositionsByFolderID.removeAll(keepingCapacity: false)
        entryIndexByID.reserveCapacity(index.entries.count)
        entryIndexByReference.reserveCapacity(index.entries.count)
        for (position, entry) in index.entries.enumerated() {
            entryIndexByID[entry.id] = position
            entryIndexByReference[ReferenceLookupKey(entry.reference)] = position
            entryPositionsByFolderID[entry.watchedFolderID, default: []].append(position)
        }
    }

    /// Restores every in-memory view if validation, encoding, or atomic persistence fails.
    /// Transcript-derived summaries and compact metrics therefore never describe a write that
    /// did not reach the lightweight index.
    private func performPersistedIndexMutation<Result>(
        _ mutation: () throws -> (result: Result, shouldPersist: Bool)
    ) throws -> Result {
        let snapshot = MutableStateSnapshot(
            index: index,
            transientRecordsByID: transientRecordsByID,
            transientMetricsByID: transientMetricsByID,
            transientMetricAccessByID: transientMetricAccessByID,
            transientMetricAccessCounter: transientMetricAccessCounter,
            transientAccessByID: transientAccessByID,
            transientSummaryMetadataByID: transientSummaryMetadataByID,
            transientSummaryBytes: transientSummaryBytes,
            transientAccessCounter: transientAccessCounter,
            indexLoadFailed: indexLoadFailed,
            loadedIndexSignature: loadedIndexSignature,
            loadedRawEntryCount: loadedRawEntryCount
        )
        do {
            let output = try mutation()
            if output.shouldPersist { try persistIndex() }
            return output.result
        } catch {
            index = snapshot.index
            transientRecordsByID = snapshot.transientRecordsByID
            transientMetricsByID = snapshot.transientMetricsByID
            transientMetricAccessByID = snapshot.transientMetricAccessByID
            transientMetricAccessCounter = snapshot.transientMetricAccessCounter
            transientAccessByID = snapshot.transientAccessByID
            transientSummaryMetadataByID = snapshot.transientSummaryMetadataByID
            transientSummaryBytes = snapshot.transientSummaryBytes
            transientAccessCounter = snapshot.transientAccessCounter
            indexLoadFailed = snapshot.indexLoadFailed
            loadedIndexSignature = snapshot.loadedIndexSignature
            loadedRawEntryCount = snapshot.loadedRawEntryCount
            rebuildEntryLookups()
            throw error
        }
    }

    private func isRelevant(
        entry: AgentSourceIndexEntry,
        metrics: TransientAnalysisMetrics?,
        dayStart: Date,
        dayEnd: Date
    ) -> Bool {
        let conversationDates = [
            metrics?.startedAt,
            metrics?.endedAt,
            entry.conversationStartedAt,
            entry.conversationEndedAt,
        ].compactMap { $0 }
        if let intervalStart = conversationDates.min(),
            let intervalEnd = conversationDates.max(),
            intervalStart < dayEnd,
            intervalEnd >= dayStart
        {
            return true
        }

        // Treat source times as observations, not endpoints joined to the conversation interval.
        // This makes a recently modified old conversation visible today without falsely filling
        // every day between creation and modification.
        let sourceDates = [entry.sourceModifiedAt, entry.sourceCreatedAt].compactMap { $0 }
        if sourceDates.contains(where: { $0 >= dayStart && $0 < dayEnd }) { return true }
        return conversationDates.isEmpty && sourceDates.isEmpty
            && entry.lastObservedAt >= dayStart && entry.lastObservedAt < dayEnd
    }

    private func recencyDate(
        for entry: AgentSourceIndexEntry,
        metrics: TransientAnalysisMetrics? = nil
    ) -> Date {
        [
            metrics?.endedAt,
            metrics?.startedAt,
            entry.conversationEndedAt,
            entry.conversationStartedAt,
            entry.sourceModifiedAt,
            entry.sourceCreatedAt,
        ].compactMap { $0 }.max() ?? entry.lastObservedAt
    }

    private func isNewer(_ left: AgentSourceIndexEntry, than right: AgentSourceIndexEntry) -> Bool {
        let leftDate = recencyDate(for: left, metrics: transientMetricsByID[left.id])
        let rightDate = recencyDate(for: right, metrics: transientMetricsByID[right.id])
        if leftDate == rightDate { return left.id < right.id }
        return leftDate > rightDate
    }

    private func isOlder(_ left: AgentSourceIndexEntry, than right: AgentSourceIndexEntry) -> Bool {
        isNewer(right, than: left)
    }

    private func newestEntries(
        _ entries: [AgentSourceIndexEntry],
        limit: Int
    ) -> [AgentSourceIndexEntry] {
        var heap: [AgentSourceIndexEntry] = []
        heap.reserveCapacity(min(max(limit, 0), entries.count))
        for entry in entries { insertNewestBounded(entry, into: &heap, limit: limit) }
        return heap.sorted { isNewer($0, than: $1) }
    }

    /// Maintains an oldest-first min heap capped at `limit` without allocating a copy of the
    /// complete (up to 50k-entry) index.
    private func insertNewestBounded(
        _ entry: AgentSourceIndexEntry,
        into heap: inout [AgentSourceIndexEntry],
        limit: Int
    ) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(entry)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard isOlder(heap[child], than: heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
            return
        }
        guard let oldest = heap.first, isNewer(entry, than: oldest) else { return }
        heap[0] = entry
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var olderChild = left
            if right < heap.count, isOlder(heap[right], than: heap[left]) {
                olderChild = right
            }
            guard isOlder(heap[olderChild], than: heap[parent]) else { break }
            heap.swapAt(parent, olderChild)
            parent = olderChild
        }
    }

    private func regularFileBytes(at url: URL) -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG
        else { return 0 }
        return max(Int64(status.st_size), 0)
    }

    private func boundedRegularFileData(at url: URL, maximumBytes: Int64) -> Data? {
        guard maximumBytes >= 0,
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize >= 0,
            Int64(fileSize) <= maximumBytes,
            maximumBytes < Int64(Int.max),
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
        } catch {
            return nil
        }
        guard Int64(data.count) <= maximumBytes else { return nil }
        return data
    }

    private func fileSignature(at url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return FileSignature(
            byteCount: size,
            modifiedAt: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func createSecureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw AgentActivityStoreError.indexCorrupt }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            Darwin.fchmod(descriptor, 0o700) == 0,
            Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & 0o777 == 0o700
        else { throw AgentActivityStoreError.indexCorrupt }
    }

    private func secureAtomicWrite(_ data: Data, to url: URL) throws {
        try createSecureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw AgentActivityStoreError.indexCorrupt }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            Darwin.fchmod(descriptor, 0o600) == 0,
            Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & 0o777 == 0o600
        else { throw AgentActivityStoreError.indexCorrupt }
    }
}
