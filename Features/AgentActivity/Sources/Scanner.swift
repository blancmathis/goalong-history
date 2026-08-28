import Dispatch
import Foundation

struct AgentScannerCycleMetrics: Equatable, Sendable {
    var metadataResolutionCount = 0
    var sourceBodyReadCount = 0
    var discoveredCandidateCount = 0
    var visitedIndexEntryCount = 0
    var materializedIndexEntryCount = 0
    var rootOpenAttemptCount = 0
    var sourceTraversalVisitCount = 0
    var indexWriteCount = 0
    var stoppedByBudget = false
    var deferredGrowingSourceCount = 0
    var sourceBodyReadBytes: Int64 = 0
    var sourceBodyReadStopReason: AgentSourceBodyReadStopReason?
}

struct AgentPendingDiscoveryUsage: Equatable, Sendable {
    var activeInventoryCount: Int
    var entryCount: Int
    var estimatedBytes: Int
}

private struct AgentPendingDiscovery: Sendable {
    var candidates: [AgentSourceCandidate]
    var discoveryCursor: AgentDirectSourceDiscoveryCursor?
    var potentiallyMissingEntries: [AgentSourceIndexEntry]
    var seenStableIDs: Set<String>
    var analysisDay: Date?
    var analyzeContent: Bool
    var rehashUnchangedSources: Bool
    var incompleteReason: AgentSourceInventoryIncompleteReason?
    var requiresRediscoveryAfterDrain: Bool
    var bodyDeadlineExhaustionCount: Int
}

private struct AgentUnavailableRetryState: Sendable {
    var failureCount: Int
    var nextRetryAt: Date
}

private struct AgentProviderSignalProgress: Sendable {
    var signaledAt: Date
    var satisfiedFolderIDs: Set<String>
}

public final class AgentActivityScanner: @unchecked Sendable {
    private static let maximumReturnedCaptures = 256
    private static let maximumVisibleSummaryRehydrations = 64
    private static let maximumVisibleSummaryRehydrationBytes: Int64 = 32 * 1_024 * 1_024
    private static let maximumNormalMetadataChecks = 256
    private static let maximumNormalIndexVisits = 256
    private static let minimumFullDiscoveryIntervalSeconds: TimeInterval = 24 * 60 * 60
    private static let unavailableSourceRetrySeconds: TimeInterval = 60
    private static let maximumUnavailableRetrySeconds: TimeInterval = 15 * 60
    private static let maximumUnavailableRetryStates = 10_000
    /// Discovery already materializes a bounded provider inventory. Retaining that metadata-only
    /// inventory until it drains avoids reopening and recursively traversing the same source for
    /// every 256-body batch. The combined 24 MiB ceiling covers at most one 12 MiB candidate
    /// projection plus reconciliation IDs/metadata; the queue still never contains chat bodies.
    private static let maximumPendingDiscoveryEntries = 100_000
    private static let maximumPendingDiscoveryBytes = 24 * 1_024 * 1_024
    private static let maximumPendingBodyDeadlineExhaustions = 2
    private static let maximumRootOpenAttemptsPerCycle = 32
    /// Active JSONL transcripts can grow on every agent turn. Rehashing the entire file at
    /// the 30-second metadata cadence makes background I/O proportional to transcript size
    /// instead of new activity. Metadata polling remains live, but an already-indexed file
    /// that only grew is read once it has been quiet long enough. Explicit analysis, new
    /// sources, truncations, replacements, and forced reconciliation are never deferred.
    static let growingSourceQuiescenceSeconds: TimeInterval = 2 * 60

    private let store: AgentActivityStore
    private let fileManager: FileManager
    private let sourceTraversalLimits: AgentSourceTraversalLimits
    private let sourceTraversalUptimeNanoseconds: AgentSourceTraversalBudget.UptimeNanoseconds
    private let sourceTraversalCancellationCheck: AgentSourceTraversalBudget.CancellationCheck
    private let sourceBodyReadLimits: AgentSourceBodyReadLimits
    private let selectedDayAnalysisBodyReadLimits: AgentSourceBodyReadLimits
    private let sourceBodyReadUptimeNanoseconds: AgentSourceBodyReadBudget.UptimeNanoseconds
    private let sourceBodyReadCancellationCheck: AgentSourceBodyReadBudget.CancellationCheck
    private let scanLock = NSLock()
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var rotatingFolderCursor = 0
    private var rotatingCursorByFolderID: [String: Int] = [:]
    private var pendingDiscoveryByFolderID: [String: AgentPendingDiscovery] = [:]
    private var rediscoveryFolderIDs: Set<String> = []
    private var signalProgressByProvider: [AgentProvider: AgentProviderSignalProgress] = [:]
    private var unavailableRetryByFolderID: [String: AgentUnavailableRetryState] = [:]
    private var unavailableRetryByEntryID: [String: AgentUnavailableRetryState] = [:]
    private var pendingFolderMutations: [AgentFolderScanMutation] = []
    private var lastCycleMetrics = AgentScannerCycleMetrics()
    private var hasAnalysisSelection = false
    private var lastAnalysisDay: Date?
    private var analysisPassIsActive = false
    private var analysisPassCompletedFolderIDs: Set<String> = []
    private var analysisRemainingVisitsByFolderID: [String: Int] = [:]

    public init(store: AgentActivityStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
        sourceTraversalLimits = .production
        sourceTraversalUptimeNanoseconds = { DispatchTime.now().uptimeNanoseconds }
        sourceTraversalCancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
        sourceBodyReadLimits = .production
        selectedDayAnalysisBodyReadLimits = .selectedDayAnalysis
        sourceBodyReadUptimeNanoseconds = { DispatchTime.now().uptimeNanoseconds }
        sourceBodyReadCancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    }

    init(
        store: AgentActivityStore,
        fileManager: FileManager = .default,
        sourceTraversalLimits: AgentSourceTraversalLimits,
        sourceTraversalUptimeNanoseconds: @escaping AgentSourceTraversalBudget.UptimeNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        },
        sourceTraversalCancellationCheck: @escaping AgentSourceTraversalBudget.CancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        },
        sourceBodyReadLimits: AgentSourceBodyReadLimits = .production,
        selectedDayAnalysisBodyReadLimits: AgentSourceBodyReadLimits? = nil,
        sourceBodyReadUptimeNanoseconds: @escaping AgentSourceBodyReadBudget.UptimeNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        },
        sourceBodyReadCancellationCheck: @escaping AgentSourceBodyReadBudget.CancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) {
        self.store = store
        self.fileManager = fileManager
        self.sourceTraversalLimits = sourceTraversalLimits
        self.sourceTraversalUptimeNanoseconds = sourceTraversalUptimeNanoseconds
        self.sourceTraversalCancellationCheck = sourceTraversalCancellationCheck
        self.sourceBodyReadLimits = sourceBodyReadLimits
        self.selectedDayAnalysisBodyReadLimits =
            selectedDayAnalysisBodyReadLimits ?? sourceBodyReadLimits
        self.sourceBodyReadUptimeNanoseconds = sourceBodyReadUptimeNanoseconds
        self.sourceBodyReadCancellationCheck = sourceBodyReadCancellationCheck
    }

    func cycleMetricsForTesting() -> AgentScannerCycleMetrics {
        scanLock.lock()
        defer { scanLock.unlock() }
        return lastCycleMetrics
    }

    func pendingDiscoveryUsageForTesting() -> AgentPendingDiscoveryUsage {
        scanLock.lock()
        defer { scanLock.unlock() }
        var entryCount = 0
        var estimatedBytes = 0
        for pending in pendingDiscoveryByFolderID.values {
            entryCount += pending.candidates.count
            entryCount += pending.potentiallyMissingEntries.count
            entryCount += pending.seenStableIDs.count
            entryCount += pending.discoveryCursor?.retainedCandidateCount ?? 0
            estimatedBytes += pending.candidates.reduce(0) {
                $0 + estimatedPendingBytes(for: $1)
            }
            estimatedBytes += pending.potentiallyMissingEntries.reduce(0) {
                $0 + estimatedPendingBytes(for: $1)
            }
            estimatedBytes += pending.seenStableIDs.reduce(0) {
                $0 + min($1.utf8.count + 32, 8_224)
            }
            estimatedBytes += pending.discoveryCursor?.retainedEstimatedBytes ?? 0
        }
        return AgentPendingDiscoveryUsage(
            activeInventoryCount: pendingDiscoveryByFolderID.count,
            entryCount: entryCount,
            estimatedBytes: estimatedBytes
        )
    }

    public func cancelCurrentScan() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
    }

    public func resetCancellation() {
        cancellationLock.lock()
        cancellationRequested = false
        cancellationLock.unlock()
    }

    public func scan(
        configuration: AgentActivityConfiguration,
        forceFullDiscovery: Bool = false,
        analysisDay: Date? = nil,
        analyzeContent: Bool = true,
        at observedAt: Date = Date()
    ) -> AgentScanResult {
        scanLock.lock()
        defer {
            resetCancellation()
            scanLock.unlock()
        }
        let validated = configuration.validated()
        if analyzeContent {
            resetTransientAnalysesIfSelectionChanged(to: analysisDay)
            beginAnalysisPassIfNeeded()
        }
        var result = AgentScanResult()
        var metrics = AgentScannerCycleMetrics()
        pendingFolderMutations.removeAll(keepingCapacity: true)
        var remainingNormalIndexVisits = Self.maximumNormalIndexVisits
        var remainingSourceBodyReads = Self.maximumReturnedCaptures
        var remainingSummaryRehydrations = Self.maximumVisibleSummaryRehydrations
        var remainingSummaryRehydrationBytes = Self.maximumVisibleSummaryRehydrationBytes
        let sourceBodyReadBudget = AgentSourceBodyReadBudget(
            limits: analyzeContent ? selectedDayAnalysisBodyReadLimits : sourceBodyReadLimits,
            uptimeNanoseconds: sourceBodyReadUptimeNanoseconds,
            isCancelled: { [self] in
                isScanCancellationRequested() || sourceBodyReadCancellationCheck()
            }
        )
        let writesBeforeScan = store.indexWriteCountForTesting()
        let enabledFolders = validated.watchedFolders.filter(\.isEnabled)
        let prioritizedFolders = enabledFolders.reduce(
            into: (ready: [AgentWatchedFolder](), retrying: [AgentWatchedFolder]())
        ) { groups, folder in
            if store.fullDiscoveryFailureCount(folderID: folder.id) > 0 {
                groups.retrying.append(folder)
            } else {
                groups.ready.append(folder)
            }
        }
        let retryPrioritizedFolders = prioritizedFolders.ready + prioritizedFolders.retrying
        let rotatedFolders: [AgentWatchedFolder]
        let rotationStart: Int
        if retryPrioritizedFolders.isEmpty {
            rotatedFolders = []
            rotationStart = 0
            rotatingFolderCursor = 0
        } else {
            rotationStart = rotatingFolderCursor % retryPrioritizedFolders.count
            rotatedFolders =
                Array(retryPrioritizedFolders[rotationStart...])
                + Array(retryPrioritizedFolders[..<rotationStart])
        }
        let activeFolderIDs = Set(rotatedFolders.map(\.id))
        rotatingCursorByFolderID = rotatingCursorByFolderID.filter { key, _ in
            activeFolderIDs.contains(key)
        }
        pendingDiscoveryByFolderID = pendingDiscoveryByFolderID.filter { key, _ in
            activeFolderIDs.contains(key)
        }
        rediscoveryFolderIDs = rediscoveryFolderIDs.filter { key in
            activeFolderIDs.contains(key)
        }
        unavailableRetryByFolderID = unavailableRetryByFolderID.filter { key, _ in
            activeFolderIDs.contains(key)
        }
        analysisPassCompletedFolderIDs.formIntersection(activeFolderIDs)
        analysisRemainingVisitsByFolderID = analysisRemainingVisitsByFolderID.filter {
            activeFolderIDs.contains($0.key)
        }
        let providers = Set(rotatedFolders.map(\.provider))
        let incompleteAttemptCount = rotatedFolders.reduce(into: 0) { count, folder in
            count = max(count, store.fullDiscoveryFailureCount(folderID: folder.id))
        }
        var pendingSignals: [AgentProvider: AgentHookSignal] = [:]
        for provider in providers {
            guard let signal = store.latestSignal(provider: provider) else { continue }
            let handled = store.lastHandledSignal(provider: provider) ?? .distantPast
            if signal.signaledAt > handled { pendingSignals[provider] = signal }
        }

        signalProgressByProvider = signalProgressByProvider.filter { provider, _ in
            pendingSignals[provider] != nil
        }
        for (provider, signal) in pendingSignals {
            let providerFolderIDs = Set(
                rotatedFolders.lazy.filter { $0.provider == provider }.map(\.id)
            )
            if var progress = signalProgressByProvider[provider],
                progress.signaledAt == signal.signaledAt
            {
                progress.satisfiedFolderIDs.formIntersection(providerFolderIDs)
                signalProgressByProvider[provider] = progress
            } else {
                signalProgressByProvider[provider] = AgentProviderSignalProgress(
                    signaledAt: signal.signaledAt,
                    satisfiedFolderIDs: []
                )
            }
        }

        let fullDiscoveryInterval = max(
            validated.fullDiscoveryIntervalSeconds,
            Self.minimumFullDiscoveryIntervalSeconds
        )
        let prioritizedWork = rotatedFolders.enumerated().sorted { left, right in
            let leftPriority = discoveryPriority(
                folder: left.element,
                forceFullDiscovery: forceFullDiscovery,
                fullDiscoveryInterval: fullDiscoveryInterval,
                pendingSignals: pendingSignals,
                observedAt: observedAt
            )
            let rightPriority = discoveryPriority(
                folder: right.element,
                forceFullDiscovery: forceFullDiscovery,
                fullDiscoveryInterval: fullDiscoveryInterval,
                pendingSignals: pendingSignals,
                observedAt: observedAt
            )
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return left.offset < right.offset
        }

        let sourceTraversalBudget = AgentSourceTraversalBudget(
            limits: sourceTraversalLimits.escalated(
                afterIncompleteAttempts: incompleteAttemptCount
            ),
            uptimeNanoseconds: sourceTraversalUptimeNanoseconds,
            isCancelled: { [self] in
                isScanCancellationRequested() || sourceTraversalCancellationCheck()
            }
        )
        var successfulDiscoveryCount = 0
        var processedFolderCount = 0
        for prioritized in prioritizedWork {
            let folder = prioritized.element
            let priority = discoveryPriority(
                folder: folder,
                forceFullDiscovery: forceFullDiscovery,
                fullDiscoveryInterval: fullDiscoveryInterval,
                pendingSignals: pendingSignals,
                observedAt: observedAt
            )
            guard metrics.rootOpenAttemptCount < Self.maximumRootOpenAttemptsPerCycle,
                sourceTraversalBudget.checkpoint()
            else {
                metrics.stoppedByBudget = true
                break
            }
            if priority >= 10,
                remainingNormalIndexVisits <= 0
                    || (analyzeContent && remainingSourceBodyReads <= 0)
            {
                metrics.stoppedByBudget = true
                break
            }
            let signalNeedsDiscovery =
                pendingSignals[folder.provider].map { signal in
                    signalProgressByProvider[folder.provider]?.signaledAt != signal.signaledAt
                        || signalProgressByProvider[folder.provider]?.satisfiedFolderIDs.contains(folder.id)
                            != true
                } ?? false
            let folderAnalyzeContent =
                analyzeContent
                && analysisPassIsActive
                && !analysisPassCompletedFolderIDs.contains(folder.id)
            let outcome = scan(
                folder: folder,
                sourceTraversalBudget: sourceTraversalBudget,
                sourceBodyReadBudget: sourceBodyReadBudget,
                configuration: validated,
                forceFullDiscovery: forceFullDiscovery,
                hasPendingSignal: signalNeedsDiscovery,
                analysisDay: analysisDay,
                analyzeContent: folderAnalyzeContent,
                observedAt: observedAt,
                result: &result,
                metrics: &metrics,
                remainingNormalIndexVisits: &remainingNormalIndexVisits,
                remainingSourceBodyReads: &remainingSourceBodyReads,
                remainingSummaryRehydrations: &remainingSummaryRehydrations,
                remainingSummaryRehydrationBytes: &remainingSummaryRehydrationBytes
            )
            processedFolderCount += 1
            if outcome.discoverySucceeded { successfulDiscoveryCount += 1 }
            if signalNeedsDiscovery,
                outcome.performedFullDiscovery,
                outcome.discoverySucceeded,
                var progress = signalProgressByProvider[folder.provider]
            {
                progress.satisfiedFolderIDs.insert(folder.id)
                signalProgressByProvider[folder.provider] = progress
            }
            if !pendingDiscoveryByFolderID.isEmpty { break }
        }
        if !retryPrioritizedFolders.isEmpty {
            rotatingFolderCursor =
                (rotationStart + max(processedFolderCount, 1)) % retryPrioritizedFolders.count
        }

        let handledSignals = pendingSignals.filter { provider, signal in
            guard let progress = signalProgressByProvider[provider],
                progress.signaledAt == signal.signaledAt
            else { return false }
            let providerFolderIDs = Set(
                rotatedFolders.lazy.filter { $0.provider == provider }.map(\.id)
            )
            return providerFolderIDs.isSubset(of: progress.satisfiedFolderIDs)
        }.mapValues(\.signaledAt)
        var commitSucceeded = false
        do {
            let committed = try store.commitScanCycle(
                folderMutations: pendingFolderMutations,
                handledSignals: handledSignals
            )
            result.changedSourceCount += committed.changedEntryIDs.count
            result.statusChangeCount += committed.statusChangedEntryIDs.count
            result.fullDiscoveryCount = successfulDiscoveryCount
            commitSucceeded = true
            for provider in handledSignals.keys {
                signalProgressByProvider.removeValue(forKey: provider)
            }
            for mutation in pendingFolderMutations {
                for prepared in mutation.preparedCaptures
                where committed.changedEntryIDs.contains(prepared.record.id) {
                    guard result.captures.count < Self.maximumReturnedCaptures else { break }
                    result.captures.append(prepared.record)
                }
            }
        } catch {
            pendingDiscoveryByFolderID.removeAll(keepingCapacity: true)
            appendFailure("Could not save the Agent Activity scan: \(error.localizedDescription)", result: &result)
        }
        if analyzeContent, analysisPassIsActive {
            let hasDiscoveryWork =
                !pendingDiscoveryByFolderID.isEmpty || !rediscoveryFolderIDs.isEmpty
            let allFoldersCompleted = activeFolderIDs.isSubset(of: analysisPassCompletedFolderIDs)
            result.analysisIncomplete = commitSucceeded && (hasDiscoveryWork || !allFoldersCompleted)
            if !result.analysisIncomplete {
                finishAnalysisPass()
            }
        }
        metrics.indexWriteCount = store.indexWriteCountForTesting() - writesBeforeScan
        let bodyUsage = sourceBodyReadBudget.usage()
        metrics.sourceTraversalVisitCount = sourceTraversalBudget.usage().visitedNodeOrRowCount
        metrics.sourceBodyReadBytes = bodyUsage.byteCount
        metrics.sourceBodyReadStopReason = bodyUsage.stopReason
        lastCycleMetrics = metrics
        return result
    }

    private func isScanCancellationRequested() -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private struct FolderScanOutcome {
        var completed: Bool
        var performedFullDiscovery: Bool
        var discoverySucceeded: Bool
    }

    private func scan(
        folder: AgentWatchedFolder,
        sourceTraversalBudget: AgentSourceTraversalBudget,
        sourceBodyReadBudget: AgentSourceBodyReadBudget,
        configuration: AgentActivityConfiguration,
        forceFullDiscovery: Bool,
        hasPendingSignal: Bool,
        analysisDay: Date?,
        analyzeContent: Bool,
        observedAt: Date,
        result: inout AgentScanResult,
        metrics: inout AgentScannerCycleMetrics,
        remainingNormalIndexVisits: inout Int,
        remainingSourceBodyReads: inout Int,
        remainingSummaryRehydrations: inout Int,
        remainingSummaryRehydrationBytes: inout Int64
    ) -> FolderScanOutcome {
        // A process-local root failure gate must run before materializing any child index
        // entries. Durable state records only availability transitions; repeated probes are
        // scheduled in memory so an inaccessible 50k-entry root stays O(1) between retries.
        if !forceFullDiscovery,
            !retryIsAllowed(unavailableRetryByFolderID[folder.id], at: observedAt)
        {
            if analyzeContent { completeAnalysisPass(for: folder.id) }
            return FolderScanOutcome(
                completed: true,
                performedFullDiscovery: false,
                discoverySucceeded: false
            )
        }
        let lastFull = store.lastFullDiscovery(folderID: folder.id) ?? .distantPast
        let fullDiscoveryInterval = max(
            configuration.fullDiscoveryIntervalSeconds,
            Self.minimumFullDiscoveryIntervalSeconds
        )
        let scheduledFull = observedAt.timeIntervalSince(lastFull) >= fullDiscoveryInterval
        let requiresRediscovery = rediscoveryFolderIDs.contains(folder.id)
        let requestedFullDiscovery =
            forceFullDiscovery || hasPendingSignal || scheduledFull
            || requiresRediscovery
        if analyzeContent, var pending = pendingDiscoveryByFolderID[folder.id] {
            // A visible-page request must upgrade an inventory that was originally created by a
            // metadata-only background scan. Otherwise the background request would swallow the
            // user's explicit analysis until the next daily discovery.
            pending.analysisDay = analysisDay
            pending.analyzeContent = true
            pendingDiscoveryByFolderID[folder.id] = pending
        }
        let isContinuingDiscovery = pendingDiscoveryByFolderID[folder.id] != nil
        let anotherDiscoveryIsPending = pendingDiscoveryByFolderID.keys.contains { $0 != folder.id }
        let needsFullDiscovery =
            !isContinuingDiscovery && !anotherDiscoveryIsPending && requestedFullDiscovery
            && fullDiscoveryBackoffHasElapsed(
                folderID: folder.id,
                configuration: configuration,
                force: forceFullDiscovery || requiresRediscovery,
                at: observedAt
            )
        let isDiscoveryWork = needsFullDiscovery || isContinuingDiscovery
        if isDiscoveryWork,
            metrics.sourceBodyReadStopReason == .deadlineExceeded
                || metrics.sourceBodyReadStopReason == .cancelled
        {
            metrics.stoppedByBudget = true
            return FolderScanOutcome(
                completed: true,
                performedFullDiscovery: false,
                discoverySucceeded: false
            )
        }
        guard sourceTraversalBudget.checkpoint() else {
            metrics.stoppedByBudget = true
            _ = commitFolderScan(
                folder: folder,
                preparedCaptures: [],
                availabilityObservations: [],
                maximumEntries: configuration.maximumIndexEntries,
                discoveryAttempt: isDiscoveryWork
                    ? AgentFolderDiscoveryAttempt(
                        folderID: folder.id,
                        observedAt: observedAt,
                        succeeded: false
                    )
                    : nil,
                result: &result
            )
            return FolderScanOutcome(
                completed: true,
                performedFullDiscovery: isDiscoveryWork,
                discoverySucceeded: false
            )
        }
        var analysisSliceVisitCount = 0
        var analysisSliceWasInterrupted = false
        let knownEntries: [AgentSourceIndexEntry]
        if needsFullDiscovery || isContinuingDiscovery {
            knownEntries = store.entries(folderID: folder.id)
        } else {
            let analysisVisitLimit =
                analyzeContent
                ? min(
                    remainingNormalIndexVisits,
                    analysisRemainingVisitsByFolderID[folder.id] ?? remainingNormalIndexVisits
                )
                : remainingNormalIndexVisits
            let slice = store.scanSlice(
                folderID: folder.id,
                cursor: rotatingCursorByFolderID[folder.id] ?? 0,
                maximumEntries: min(Self.maximumNormalMetadataChecks, analysisVisitLimit),
                maximumVisits: analysisVisitLimit,
                observedAt: observedAt,
                unavailableRetryInterval: Self.unavailableSourceRetrySeconds
            )
            knownEntries = slice.entries
            rotatingCursorByFolderID[folder.id] = slice.nextCursor
            metrics.visitedIndexEntryCount += slice.visitedCount
            remainingNormalIndexVisits = max(0, remainingNormalIndexVisits - slice.visitedCount)
            if analyzeContent {
                if analysisRemainingVisitsByFolderID[folder.id] == nil {
                    analysisRemainingVisitsByFolderID[folder.id] = slice.totalCount
                }
                analysisSliceVisitCount = slice.visitedCount
                if slice.totalCount == 0 { completeAnalysisPass(for: folder.id) }
            }
            if slice.totalCount > slice.visitedCount { metrics.stoppedByBudget = true }
            result.skippedSourceCount += max(0, slice.totalCount - slice.entries.count)
        }
        metrics.materializedIndexEntryCount += knownEntries.count
        let session: AgentDirectSourceScanSession
        do {
            metrics.rootOpenAttemptCount += 1
            session = try AgentDirectSourceReader.makeScanSession(
                folder: folder,
                traversalBudget: sourceTraversalBudget,
                bodyReadBudget: sourceBodyReadBudget,
                fileManager: fileManager
            )
            unavailableRetryByFolderID.removeValue(forKey: folder.id)
            queueRootObservationIfChanged(
                folder: folder,
                availability: .available,
                observedAt: observedAt,
                maximumEntries: configuration.maximumIndexEntries
            )
        } catch let interruption as AgentSourceBodyReadInterrupted {
            metrics.stoppedByBudget = true
            metrics.sourceBodyReadStopReason = interruption.reason
            analysisSliceWasInterrupted = analyzeContent
            _ = commitFolderScan(
                folder: folder,
                preparedCaptures: [],
                availabilityObservations: [],
                maximumEntries: configuration.maximumIndexEntries,
                discoveryAttempt: isDiscoveryWork
                    ? AgentFolderDiscoveryAttempt(
                        folderID: folder.id,
                        observedAt: observedAt,
                        succeeded: false
                    )
                    : nil,
                result: &result
            )
            return FolderScanOutcome(
                completed: true,
                performedFullDiscovery: isDiscoveryWork,
                discoverySucceeded: false
            )
        } catch {
            recordUnavailableRetry(folderID: folder.id, at: observedAt)
            let rootAvailability = availability(for: error)
            let rootObservation = rootObservationIfChanged(
                folder: folder,
                availability: rootAvailability,
                observedAt: observedAt
            )
            let persisted = commitFolderScan(
                folder: folder,
                preparedCaptures: [],
                availabilityObservations: [],
                maximumEntries: configuration.maximumIndexEntries,
                discoveryAttempt: isDiscoveryWork && rootObservation != nil
                    ? AgentFolderDiscoveryAttempt(
                        folderID: folder.id,
                        observedAt: observedAt,
                        succeeded: false
                    )
                    : nil,
                rootObservation: rootObservation,
                result: &result
            )
            appendFailure("\(folder.path): \(error.localizedDescription)", result: &result)
            pendingDiscoveryByFolderID.removeValue(forKey: folder.id)
            if analyzeContent { completeAnalysisPass(for: folder.id) }
            return FolderScanOutcome(
                completed: persisted,
                performedFullDiscovery: isDiscoveryWork,
                discoverySucceeded: false
            )
        }

        var completed = true
        var availabilityUpdates: [AgentAvailabilityObservation] = []
        availabilityUpdates.reserveCapacity(min(knownEntries.count, configuration.maximumIndexEntries))
        let knownByReference = Dictionary(
            uniqueKeysWithValues: knownEntries.map { (referenceKey($0.reference), $0) }
        )
        let knownByID = Dictionary(uniqueKeysWithValues: knownEntries.map { ($0.id, $0) })
        var pendingDiscovery = pendingDiscoveryByFolderID[folder.id]
        var candidates: [AgentSourceCandidate] = []
        if needsFullDiscovery {
            do {
                let discoveryCursor = session.makeDiscoveryCursor(
                    maximumCandidates: configuration.maximumIndexEntries
                )
                let discovery = try session.discoverNextPage(
                    using: discoveryCursor,
                    maximumCandidates: Self.maximumPendingDiscoveryEntries
                )
                metrics.discoveredCandidateCount += discovery.candidates.count
                let potentiallyMissing =
                    discovery.incompleteReason == .candidateLimit ? [] : knownEntries
                candidates = discovery.candidates.sorted { left, right in
                    let leftPrevious = knownByReference[referenceKey(left.reference)]
                    let rightPrevious = knownByReference[referenceKey(right.reference)]
                    let leftRelevant =
                        analyzeContent
                        && isRelevant(candidate: left, previous: leftPrevious, to: analysisDay)
                    let rightRelevant =
                        analyzeContent
                        && isRelevant(candidate: right, previous: rightPrevious, to: analysisDay)
                    if leftRelevant != rightRelevant { return leftRelevant }
                    let leftPriority =
                        leftPrevious == nil
                        ? 0
                        : (metadataMatches(previous: leftPrevious!, candidate: left) ? 2 : 1)
                    let rightPriority =
                        rightPrevious == nil
                        ? 0
                        : (metadataMatches(previous: rightPrevious!, candidate: right) ? 2 : 1)
                    if leftPriority != rightPriority { return leftPriority < rightPriority }
                    return candidatePriority(left, right)
                }
                pendingDiscovery = AgentPendingDiscovery(
                    candidates: candidates,
                    discoveryCursor: discovery.hasMoreCandidates ? discoveryCursor : nil,
                    potentiallyMissingEntries: potentiallyMissing,
                    seenStableIDs: [],
                    analysisDay: analysisDay,
                    analyzeContent: analyzeContent,
                    rehashUnchangedSources: forceFullDiscovery,
                    incompleteReason: discovery.hasMoreCandidates ? nil : discovery.incompleteReason,
                    requiresRediscoveryAfterDrain: !discovery.hasMoreCandidates
                        && discovery.incompleteReason != nil
                        && discovery.incompleteReason != .candidateLimit,
                    bodyDeadlineExhaustionCount: 0
                )
                if discovery.incompleteReason != nil || discovery.hasMoreCandidates {
                    metrics.stoppedByBudget = true
                }
            } catch let interruption as AgentSourceBodyReadInterrupted {
                metrics.stoppedByBudget = true
                metrics.sourceBodyReadStopReason = interruption.reason
                analysisSliceWasInterrupted = analyzeContent
                completed =
                    commitFolderScan(
                        folder: folder,
                        preparedCaptures: [],
                        availabilityObservations: [],
                        maximumEntries: configuration.maximumIndexEntries,
                        discoveryAttempt: AgentFolderDiscoveryAttempt(
                            folderID: folder.id,
                            observedAt: observedAt,
                            succeeded: false
                        ),
                        result: &result
                    ) && completed
                return FolderScanOutcome(
                    completed: completed,
                    performedFullDiscovery: true,
                    discoverySucceeded: false
                )
            } catch {
                recordUnavailableRetry(folderID: folder.id, at: observedAt)
                let rootObservation = rootObservationIfChanged(
                    folder: folder,
                    availability: availability(for: error),
                    observedAt: observedAt
                )
                completed =
                    commitFolderScan(
                        folder: folder,
                        preparedCaptures: [],
                        availabilityObservations: [],
                        maximumEntries: configuration.maximumIndexEntries,
                        discoveryAttempt: rootObservation == nil
                            ? nil
                            : AgentFolderDiscoveryAttempt(
                                folderID: folder.id,
                                observedAt: observedAt,
                                succeeded: false
                            ),
                        rootObservation: rootObservation,
                        result: &result
                    ) && completed
                appendFailure("\(folder.path): \(error.localizedDescription)", result: &result)
                if analyzeContent { completeAnalysisPass(for: folder.id) }
                return FolderScanOutcome(
                    completed: completed,
                    performedFullDiscovery: true,
                    discoverySucceeded: false
                )
            }
        } else if var continuingDiscovery = pendingDiscovery {
            if continuingDiscovery.candidates.isEmpty,
                let discoveryCursor = continuingDiscovery.discoveryCursor
            {
                do {
                    let discovery = try session.discoverNextPage(
                        using: discoveryCursor,
                        maximumCandidates: Self.maximumPendingDiscoveryEntries
                    )
                    metrics.discoveredCandidateCount += discovery.candidates.count
                    candidates = discovery.candidates.sorted { left, right in
                        let leftPrevious = knownByReference[referenceKey(left.reference)]
                        let rightPrevious = knownByReference[referenceKey(right.reference)]
                        let leftRelevant =
                            analyzeContent
                            && isRelevant(candidate: left, previous: leftPrevious, to: analysisDay)
                        let rightRelevant =
                            analyzeContent
                            && isRelevant(candidate: right, previous: rightPrevious, to: analysisDay)
                        if leftRelevant != rightRelevant { return leftRelevant }
                        let leftPriority =
                            leftPrevious == nil
                            ? 0
                            : (metadataMatches(previous: leftPrevious!, candidate: left) ? 2 : 1)
                        let rightPriority =
                            rightPrevious == nil
                            ? 0
                            : (metadataMatches(previous: rightPrevious!, candidate: right) ? 2 : 1)
                        if leftPriority != rightPriority { return leftPriority < rightPriority }
                        return candidatePriority(left, right)
                    }
                    continuingDiscovery.candidates = candidates
                    continuingDiscovery.discoveryCursor =
                        discovery.hasMoreCandidates ? discoveryCursor : nil
                    if !discovery.hasMoreCandidates {
                        continuingDiscovery.incompleteReason = discovery.incompleteReason
                        continuingDiscovery.requiresRediscoveryAfterDrain =
                            discovery.incompleteReason != nil
                            && discovery.incompleteReason != .candidateLimit
                        if discovery.incompleteReason == .candidateLimit {
                            continuingDiscovery.potentiallyMissingEntries.removeAll(
                                keepingCapacity: false
                            )
                        }
                    }
                    pendingDiscovery = continuingDiscovery
                    if discovery.incompleteReason != nil || discovery.hasMoreCandidates {
                        metrics.stoppedByBudget = true
                    }
                } catch let interruption as AgentSourceBodyReadInterrupted {
                    metrics.stoppedByBudget = true
                    metrics.sourceBodyReadStopReason = interruption.reason
                    return FolderScanOutcome(
                        completed: true,
                        performedFullDiscovery: true,
                        discoverySucceeded: false
                    )
                } catch {
                    if let sourceError = error as? AgentSourceReadError,
                        case .changedDuringRead = sourceError
                    {
                        // The path is still readable, but the retained cursor belongs to an older
                        // source identity. Discard that mixed inventory and restart from the new
                        // original on the next cycle without applying unavailable-source backoff.
                        rediscoveryFolderIDs.insert(folder.id)
                    } else {
                        recordUnavailableRetry(folderID: folder.id, at: observedAt)
                    }
                    appendFailure("\(folder.path): \(error.localizedDescription)", result: &result)
                    pendingDiscoveryByFolderID.removeValue(forKey: folder.id)
                    if analyzeContent { completeAnalysisPass(for: folder.id) }
                    return FolderScanOutcome(
                        completed: false,
                        performedFullDiscovery: true,
                        discoverySucceeded: false
                    )
                }
            } else {
                candidates = continuingDiscovery.candidates
            }
        } else {
            let entriesToResolve = knownEntries.filter { shouldRetry(entry: $0, at: observedAt) }
            result.skippedSourceCount += knownEntries.count - entriesToResolve.count
            metrics.metadataResolutionCount += entriesToResolve.count
            do {
                let resolutionBatch = try session.candidates(for: entriesToResolve)
                if resolutionBatch.incompleteReason != nil {
                    metrics.stoppedByBudget = true
                    analysisSliceWasInterrupted = analyzeContent
                }
                for resolution in resolutionBatch.resolutions {
                    if let candidate = resolution.candidate {
                        unavailableRetryByEntryID.removeValue(forKey: resolution.entry.id)
                        candidates.append(candidate)
                    } else if let error = resolution.error {
                        if isProviderContainerFailure(error, for: resolution.entry) {
                            recordUnavailableRetry(folderID: folder.id, at: observedAt)
                            queueRootObservationIfChanged(
                                folder: folder,
                                availability: availability(for: error),
                                observedAt: observedAt,
                                maximumEntries: configuration.maximumIndexEntries
                            )
                            appendFailure(
                                "\(resolution.entry.reference.path): \(error.localizedDescription)",
                                result: &result
                            )
                            continue
                        }
                        recordUnavailableRetry(entryID: resolution.entry.id, at: observedAt)
                        availabilityUpdates.append(
                            AgentAvailabilityObservation(
                                entryID: resolution.entry.id,
                                availability: availability(for: error),
                                detail: error.localizedDescription,
                                observedAt: observedAt,
                                expectedReference: resolution.entry.reference
                            )
                        )
                        appendFailure(
                            "\(resolution.entry.reference.path): \(error.localizedDescription)",
                            result: &result
                        )
                    }
                }
            } catch let interruption as AgentSourceBodyReadInterrupted {
                metrics.stoppedByBudget = true
                metrics.sourceBodyReadStopReason = interruption.reason
                analysisSliceWasInterrupted = analyzeContent
                return FolderScanOutcome(
                    completed: true,
                    performedFullDiscovery: false,
                    discoverySucceeded: false
                )
            } catch {
                let observations = availabilityObservations(
                    entries: entriesToResolve,
                    availability: availability(for: error),
                    error: error,
                    observedAt: observedAt
                )
                completed =
                    commitFolderScan(
                        folder: folder,
                        preparedCaptures: [],
                        availabilityObservations: observations,
                        maximumEntries: configuration.maximumIndexEntries,
                        discoveryAttempt: nil,
                        result: &result
                    ) && completed
                appendFailure("\(folder.path): \(error.localizedDescription)", result: &result)
                if analyzeContent { completeAnalysisPass(for: folder.id) }
                return FolderScanOutcome(
                    completed: false,
                    performedFullDiscovery: false,
                    discoverySucceeded: false
                )
            }
        }

        let workAnalysisDay = pendingDiscovery?.analysisDay ?? analysisDay
        let shouldAnalyzeContent = pendingDiscovery?.analyzeContent ?? analyzeContent
        let rehashUnchanged = pendingDiscovery?.rehashUnchangedSources ?? false
        let analyzedEntryIDs =
            !shouldAnalyzeContent || workAnalysisDay == nil
            ? Set<String>()
            : store.analyzedEntryIDs()
        let summarizedEntryIDs =
            !shouldAnalyzeContent || workAnalysisDay == nil
            ? Set<String>()
            : store.transientSummaryEntryIDs()
        var seenStableIDs = pendingDiscovery?.seenStableIDs ?? []
        var preparedCaptures: [AgentPreparedCapture] = []
        preparedCaptures.reserveCapacity(min(candidates.count, Self.maximumReturnedCaptures))
        var retainedFullSummaryCount = 0
        var deferredCandidates: [AgentSourceCandidate] = []
        var deferredCandidatesWereTruncated = false
        var didExhaustBodyDeadline = false
        let seenStableIDsBeforeCurrentBatch = seenStableIDs

        for (position, candidate) in candidates.enumerated() {
            let previous = knownByReference[referenceKey(candidate.reference)]
            if let previous, isDiscoveryWork, seenStableIDs.contains(previous.id) {
                // An incomplete cursor exposes its first bounded page so a process restart still
                // makes durable progress. The retained collector may surface that candidate again
                // at completion; skip it before any body read or hash work.
                result.skippedSourceCount += 1
                continue
            }
            let isRelevantDay = isRelevant(candidate: candidate, previous: previous, to: workAnalysisDay)
            let sameMetadata = previous.map { metadataMatches(previous: $0, candidate: candidate) } ?? false
            // Compact analysis metrics cover every indexed source, while full summaries are an
            // intentionally bounded LRU. Once that LRU is full, rereading an already-analyzed
            // source would only evict another summary and create perpetual body-read churn.
            let needsExplicitAnalysis =
                previous.map { previous in
                    shouldAnalyzeContent
                        && workAnalysisDay != nil
                        && isRelevantDay
                        && (!analyzedEntryIDs.contains(previous.id)
                            || (!summarizedEntryIDs.contains(previous.id)
                                && summarizedEntryIDs.count
                                    < AgentActivityStore.maximumTransientRecords))
                } ?? false
            let isSummaryRehydration =
                previous.map { previous in
                    sameMetadata
                        && needsExplicitAnalysis
                        && analyzedEntryIDs.contains(previous.id)
                } ?? false
            let needsBodyRead = !sameMetadata || rehashUnchanged || needsExplicitAnalysis
            if needsBodyRead,
                let previous,
                shouldDeferGrowingSourceRead(
                    candidate: candidate,
                    previous: previous,
                    analyzeContent: shouldAnalyzeContent,
                    rehashUnchanged: rehashUnchanged,
                    observedAt: observedAt
                )
            {
                seenStableIDs.insert(previous.id)
                result.skippedSourceCount += 1
                metrics.deferredGrowingSourceCount += 1
                continue
            }
            if isSummaryRehydration {
                let expectedBytes = max(candidate.byteCount ?? previous?.byteCount ?? 0, 0)
                guard remainingSummaryRehydrations > 0,
                    expectedBytes <= remainingSummaryRehydrationBytes
                else {
                    result.skippedSourceCount += 1
                    metrics.stoppedByBudget = true
                    continue
                }
                remainingSummaryRehydrations -= 1
                remainingSummaryRehydrationBytes -= expectedBytes
            }
            if needsBodyRead, remainingSourceBodyReads <= 0 {
                if isDiscoveryWork {
                    appendBoundedDeferredCandidates(
                        candidates[position...],
                        to: &deferredCandidates,
                        didTruncate: &deferredCandidatesWereTruncated
                    )
                } else {
                    result.skippedSourceCount += candidates.count - position
                }
                metrics.stoppedByBudget = true
                if analyzeContent, !isDiscoveryWork { analysisSliceWasInterrupted = true }
                break
            }
            if !needsBodyRead, let previous {
                seenStableIDs.insert(previous.id)
                result.skippedSourceCount += 1
                continue
            }

            guard sourceBodyReadBudget.checkpoint() else {
                let stopReason = sourceBodyReadBudget.usage().stopReason
                metrics.sourceBodyReadStopReason = stopReason
                if isDiscoveryWork {
                    if stopReason == .deadlineExceeded {
                        didExhaustBodyDeadline = true
                        appendDeadlineDeferredCandidates(
                            candidates,
                            interruptedPosition: position,
                            to: &deferredCandidates,
                            didTruncate: &deferredCandidatesWereTruncated
                        )
                    } else {
                        appendBoundedDeferredCandidates(
                            candidates[position...],
                            to: &deferredCandidates,
                            didTruncate: &deferredCandidatesWereTruncated
                        )
                    }
                } else {
                    result.skippedSourceCount += candidates.count - position
                }
                metrics.stoppedByBudget = true
                if analyzeContent, !isDiscoveryWork { analysisSliceWasInterrupted = true }
                break
            }

            remainingSourceBodyReads -= 1
            result.scannedSourceCount += 1
            metrics.sourceBodyReadCount += 1
            do {
                var record = try session.read(
                    candidate: candidate,
                    previous: previous,
                    maximumBytes: configuration.maximumFileBytes,
                    analyzeContent: shouldAnalyzeContent
                        && (workAnalysisDay == nil || isRelevantDay),
                    analysisInterval: workAnalysisDay.flatMap {
                        Calendar.current.dateInterval(of: .day, for: $0)
                    },
                    observedAt: observedAt
                )
                unavailableRetryByEntryID.removeValue(forKey: record.id)
                if record.isAnalyzed {
                    record.index.conversationStartedAt =
                        record.summary.startedAt
                        ?? record.index.conversationStartedAt
                    record.index.conversationEndedAt =
                        record.summary.endedAt
                        ?? record.index.conversationEndedAt
                }
                if let stablePrevious = knownByID[record.id] {
                    record.index.firstIndexedAt = stablePrevious.firstIndexedAt
                    record.index.conversationStartedAt =
                        record.index.conversationStartedAt
                        ?? stablePrevious.conversationStartedAt
                    record.index.conversationEndedAt =
                        record.index.conversationEndedAt
                        ?? stablePrevious.conversationEndedAt
                }
                guard seenStableIDs.insert(record.id).inserted else {
                    result.skippedSourceCount += 1
                    continue
                }
                let retainFullSummary =
                    record.isAnalyzed
                    && retainedFullSummaryCount < Self.maximumReturnedCaptures
                if retainFullSummary { retainedFullSummaryCount += 1 }
                if record.isAnalyzed, !retainFullSummary {
                    record.summary = compactAnalysisMetrics(record.summary)
                }
                preparedCaptures.append(
                    AgentPreparedCapture(record: record, retainFullSummary: retainFullSummary)
                )
            } catch let interruption as AgentSourceBodyReadInterrupted {
                metrics.stoppedByBudget = true
                metrics.sourceBodyReadStopReason = interruption.reason
                if analyzeContent, !isDiscoveryWork { analysisSliceWasInterrupted = true }
                if interruption.reason == .byteLimit {
                    // A candidate that cannot fit the remaining byte allowance must not
                    // starve smaller candidates later in the same bounded batch.
                    if isDiscoveryWork {
                        appendBoundedDeferredCandidates(
                            CollectionOfOne(candidate),
                            to: &deferredCandidates,
                            didTruncate: &deferredCandidatesWereTruncated
                        )
                    } else {
                        result.skippedSourceCount += 1
                    }
                    continue
                }
                if interruption.reason == .deadlineExceeded {
                    didExhaustBodyDeadline = true
                }
                if isDiscoveryWork {
                    if interruption.reason == .deadlineExceeded {
                        appendDeadlineDeferredCandidates(
                            candidates,
                            interruptedPosition: position,
                            to: &deferredCandidates,
                            didTruncate: &deferredCandidatesWereTruncated
                        )
                    } else {
                        appendBoundedDeferredCandidates(
                            candidates[position...],
                            to: &deferredCandidates,
                            didTruncate: &deferredCandidatesWereTruncated
                        )
                    }
                } else {
                    result.skippedSourceCount += candidates.count - position
                }
                break
            } catch {
                if let sourceError = error as? AgentSourceReadError,
                    case .fileTooLarge = sourceError
                {
                    result.skippedSourceCount += 1
                }
                if let previous {
                    recordUnavailableRetry(entryID: previous.id, at: observedAt)
                    seenStableIDs.insert(previous.id)
                    availabilityUpdates.append(
                        AgentAvailabilityObservation(
                            entryID: previous.id,
                            availability: availability(for: error),
                            detail: error.localizedDescription,
                            observedAt: observedAt,
                            expectedReference: previous.reference
                        )
                    )
                } else {
                    let placeholder = unavailableRecord(
                        candidate: candidate,
                        folder: folder,
                        error: error,
                        observedAt: observedAt
                    )
                    seenStableIDs.insert(placeholder.id)
                    preparedCaptures.append(
                        AgentPreparedCapture(record: placeholder, retainFullSummary: false)
                    )
                }
                appendFailure("\(candidate.reference.path): \(error.localizedDescription)", result: &result)
            }
        }

        do {
            try session.verifyOpenCodeSourcesUnchanged()
        } catch let interruption as AgentSourceBodyReadInterrupted {
            preparedCaptures.removeAll(keepingCapacity: true)
            availabilityUpdates.removeAll(keepingCapacity: true)
            seenStableIDs = seenStableIDsBeforeCurrentBatch
            if isDiscoveryWork { deferredCandidates = candidates }
            metrics.stoppedByBudget = true
            metrics.sourceBodyReadStopReason = interruption.reason
            if analyzeContent, !isDiscoveryWork { analysisSliceWasInterrupted = true }
            if interruption.reason == .deadlineExceeded { didExhaustBodyDeadline = true }
        } catch {
            preparedCaptures.removeAll(keepingCapacity: true)
            availabilityUpdates.removeAll(keepingCapacity: true)
            seenStableIDs = seenStableIDsBeforeCurrentBatch
            if isDiscoveryWork { deferredCandidates = candidates }
            if analyzeContent, !isDiscoveryWork { analysisSliceWasInterrupted = true }
            appendFailure("\(folder.path): \(error.localizedDescription)", result: &result)
        }

        let discoveryTraversalFinished =
            pendingDiscovery?.incompleteReason == nil
            || pendingDiscovery?.incompleteReason == .candidateLimit
        let requiresRediscoveryAfterDrain = pendingDiscovery?.requiresRediscoveryAfterDrain ?? false
        let discoveryCursorHasMore = pendingDiscovery?.discoveryCursor != nil
        let discoverySucceeded =
            isDiscoveryWork
            && deferredCandidates.isEmpty
            && !discoveryCursorHasMore
            && discoveryTraversalFinished
            && !requiresRediscoveryAfterDrain
            && !didExhaustBodyDeadline
        if var pendingDiscovery {
            pendingDiscovery.candidates = deferredCandidates
            pendingDiscovery.seenStableIDs = seenStableIDs
            if deferredCandidatesWereTruncated {
                // The in-memory continuation uses the same byte ceiling as the complete on-disk
                // index. If an inventory cannot fit, keep a deterministic newest projection and
                // report that capacity state instead of rereading and re-evicting forever.
                pendingDiscovery.incompleteReason = .candidateLimit
                pendingDiscovery.requiresRediscoveryAfterDrain = false
            }
            if didExhaustBodyDeadline {
                pendingDiscovery.bodyDeadlineExhaustionCount = max(
                    pendingDiscovery.bodyDeadlineExhaustionCount + 1,
                    store.fullDiscoveryFailureCount(folderID: folder.id) + 1
                )
            }
            let abandonDeadlineBlockedInventory =
                didExhaustBodyDeadline
                && pendingDiscovery.bodyDeadlineExhaustionCount
                    >= Self.maximumPendingBodyDeadlineExhaustions
            if discoverySucceeded {
                if pendingDiscovery.incompleteReason == .candidateLimit {
                    result.capacityLimitedFolderCount += 1
                }
                for entry in pendingDiscovery.potentiallyMissingEntries
                where !seenStableIDs.contains(entry.id) {
                    availabilityUpdates.append(
                        AgentAvailabilityObservation(
                            entryID: entry.id,
                            availability: .missing,
                            detail: "The provider no longer reports this original conversation source.",
                            observedAt: observedAt,
                            expectedReference: entry.reference
                        )
                    )
                }
            }
            if (deferredCandidates.isEmpty && pendingDiscovery.discoveryCursor == nil)
                || abandonDeadlineBlockedInventory
            {
                // Empty and repeatedly deadline-blocked inventories must be retried from their
                // original source later; retaining either here would monopolize global discovery.
                pendingDiscoveryByFolderID.removeValue(forKey: folder.id)
                if requiresRediscoveryAfterDrain && !abandonDeadlineBlockedInventory {
                    rediscoveryFolderIDs.insert(folder.id)
                } else {
                    rediscoveryFolderIDs.remove(folder.id)
                }
            } else {
                pendingDiscoveryByFolderID[folder.id] = boundedPendingDiscovery(pendingDiscovery)
            }
        }

        completed =
            commitFolderScan(
                folder: folder,
                preparedCaptures: preparedCaptures,
                availabilityObservations: availabilityUpdates,
                maximumEntries: configuration.maximumIndexEntries,
                discoveryAttempt: isDiscoveryWork
                    ? AgentFolderDiscoveryAttempt(
                        folderID: folder.id,
                        observedAt: observedAt,
                        succeeded: discoverySucceeded
                    )
                    : nil,
                result: &result
            ) && completed
        if analyzeContent {
            if isDiscoveryWork {
                analysisPassCompletedFolderIDs.remove(folder.id)
                analysisRemainingVisitsByFolderID.removeValue(forKey: folder.id)
            } else if !analysisSliceWasInterrupted,
                let remaining = analysisRemainingVisitsByFolderID[folder.id]
            {
                let nextRemaining = max(0, remaining - analysisSliceVisitCount)
                if nextRemaining == 0 {
                    completeAnalysisPass(for: folder.id)
                } else {
                    analysisRemainingVisitsByFolderID[folder.id] = nextRemaining
                }
            }
        }
        if discoverySucceeded { rotatingCursorByFolderID[folder.id] = 0 }
        return FolderScanOutcome(
            completed: completed,
            performedFullDiscovery: isDiscoveryWork,
            discoverySucceeded: discoverySucceeded && completed
        )
    }

    private func fullDiscoveryBackoffHasElapsed(
        folderID: String,
        configuration: AgentActivityConfiguration,
        force: Bool,
        at observedAt: Date
    ) -> Bool {
        if force { return true }
        guard let lastAttempt = store.lastFullDiscoveryAttempt(folderID: folderID) else { return true }
        let failures = store.fullDiscoveryFailureCount(folderID: folderID)
        let exponent = max(0, min(failures - 1, 8))
        let failureDelay = Self.unavailableSourceRetrySeconds * pow(2, Double(exponent))
        let delay =
            failures > 0
            ? min(configuration.fullDiscoveryIntervalSeconds, failureDelay)
            : Self.unavailableSourceRetrySeconds
        return observedAt.timeIntervalSince(lastAttempt) >= delay
    }

    /// Lower values run first. Discovery continuations and provider signals must not sit behind a
    /// large normal index slice, while ordinary folders retain their rotating relative order.
    private func discoveryPriority(
        folder: AgentWatchedFolder,
        forceFullDiscovery: Bool,
        fullDiscoveryInterval: TimeInterval,
        pendingSignals: [AgentProvider: AgentHookSignal],
        observedAt: Date
    ) -> Int {
        if pendingDiscoveryByFolderID[folder.id] != nil { return 0 }
        if let signal = pendingSignals[folder.provider] {
            let progress = signalProgressByProvider[folder.provider]
            if progress?.signaledAt != signal.signaledAt
                || progress?.satisfiedFolderIDs.contains(folder.id) != true
            {
                return 1
            }
        }
        if forceFullDiscovery { return 2 }
        if rediscoveryFolderIDs.contains(folder.id) { return 3 }
        let lastFull = store.lastFullDiscovery(folderID: folder.id) ?? .distantPast
        if observedAt.timeIntervalSince(lastFull) >= fullDiscoveryInterval { return 4 }
        return 10
    }

    private func beginAnalysisPassIfNeeded() {
        guard !analysisPassIsActive else { return }
        analysisPassIsActive = true
        analysisPassCompletedFolderIDs.removeAll(keepingCapacity: true)
        analysisRemainingVisitsByFolderID.removeAll(keepingCapacity: true)
    }

    private func completeAnalysisPass(for folderID: String) {
        analysisRemainingVisitsByFolderID.removeValue(forKey: folderID)
        analysisPassCompletedFolderIDs.insert(folderID)
    }

    private func finishAnalysisPass() {
        analysisPassIsActive = false
        analysisPassCompletedFolderIDs.removeAll(keepingCapacity: true)
        analysisRemainingVisitsByFolderID.removeAll(keepingCapacity: true)
    }

    private func shouldRetry(entry: AgentSourceIndexEntry, at observedAt: Date) -> Bool {
        guard entry.availability != .available else { return true }
        return observedAt.timeIntervalSince(entry.lastObservedAt) >= Self.unavailableSourceRetrySeconds
            && retryIsAllowed(unavailableRetryByEntryID[entry.id], at: observedAt)
    }

    private func retryIsAllowed(_ state: AgentUnavailableRetryState?, at observedAt: Date) -> Bool {
        guard let state else { return true }
        return observedAt >= state.nextRetryAt
    }

    private func recordUnavailableRetry(folderID: String, at observedAt: Date) {
        unavailableRetryByFolderID[folderID] = nextRetryState(
            after: unavailableRetryByFolderID[folderID],
            observedAt: observedAt
        )
    }

    private func recordUnavailableRetry(entryID: String, at observedAt: Date) {
        unavailableRetryByEntryID[entryID] = nextRetryState(
            after: unavailableRetryByEntryID[entryID],
            observedAt: observedAt
        )
        if unavailableRetryByEntryID.count > Self.maximumUnavailableRetryStates,
            let earliest = unavailableRetryByEntryID.min(by: {
                $0.value.nextRetryAt < $1.value.nextRetryAt
            })?.key
        {
            unavailableRetryByEntryID.removeValue(forKey: earliest)
        }
    }

    private func nextRetryState(
        after prior: AgentUnavailableRetryState?,
        observedAt: Date
    ) -> AgentUnavailableRetryState {
        let failureCount = min((prior?.failureCount ?? 0) + 1, 30)
        let exponent = min(max(failureCount - 1, 0), 8)
        let delay = min(
            Self.maximumUnavailableRetrySeconds,
            Self.unavailableSourceRetrySeconds * pow(2, Double(exponent))
        )
        return AgentUnavailableRetryState(
            failureCount: failureCount,
            nextRetryAt: observedAt.addingTimeInterval(delay)
        )
    }

    private func appendBoundedDeferredCandidates<S: Sequence>(
        _ candidates: S,
        to deferred: inout [AgentSourceCandidate],
        didTruncate: inout Bool
    ) where S.Element == AgentSourceCandidate {
        var estimatedBytes = deferred.reduce(0) { $0 + estimatedPendingBytes(for: $1) }
        for candidate in candidates {
            guard deferred.count < Self.maximumPendingDiscoveryEntries else {
                didTruncate = true
                break
            }
            let candidateBytes = estimatedPendingBytes(for: candidate)
            guard candidateBytes <= Self.maximumPendingDiscoveryBytes - estimatedBytes else {
                didTruncate = true
                break
            }
            deferred.append(candidate)
            estimatedBytes += candidateBytes
        }
    }

    private func appendDeadlineDeferredCandidates(
        _ candidates: [AgentSourceCandidate],
        interruptedPosition: Int,
        to deferred: inout [AgentSourceCandidate],
        didTruncate: inout Bool
    ) {
        let nextPosition = interruptedPosition + 1
        if nextPosition < candidates.count {
            appendBoundedDeferredCandidates(
                candidates[nextPosition...],
                to: &deferred,
                didTruncate: &didTruncate
            )
        }
        appendBoundedDeferredCandidates(
            CollectionOfOne(candidates[interruptedPosition]),
            to: &deferred,
            didTruncate: &didTruncate
        )
    }

    private func boundedPendingDiscovery(_ pending: AgentPendingDiscovery) -> AgentPendingDiscovery {
        let estimatedCandidateBytes = pending.candidates.reduce(0) {
            $0 + estimatedPendingBytes(for: $1)
        }
        let estimatedMissingBytes = pending.potentiallyMissingEntries.reduce(0) {
            $0 + estimatedPendingBytes(for: $1)
        }
        let estimatedSeenBytes = pending.seenStableIDs.reduce(0) {
            $0 + min($1.utf8.count + 32, 8_224)
        }
        let entryCount =
            pending.candidates.count + pending.potentiallyMissingEntries.count
            + pending.seenStableIDs.count
            + (pending.discoveryCursor?.retainedCandidateCount ?? 0)
        guard
            entryCount > Self.maximumPendingDiscoveryEntries
                || estimatedCandidateBytes + estimatedMissingBytes + estimatedSeenBytes
                    + (pending.discoveryCursor?.retainedEstimatedBytes ?? 0)
                    > Self.maximumPendingDiscoveryBytes
        else { return pending }

        var output = pending
        output.incompleteReason = output.incompleteReason ?? .candidateLimit
        output.requiresRediscoveryAfterDrain = false
        output.discoveryCursor = nil
        // A truncated inventory cannot safely prove absence. Drop reconciliation-only
        // state and retain a bounded newest projection. Reopening the same oversized root after
        // every drain would only reread and re-evict metadata beyond the fixed index ceiling.
        output.potentiallyMissingEntries.removeAll(keepingCapacity: false)
        output.seenStableIDs.removeAll(keepingCapacity: false)
        output.candidates.removeAll(keepingCapacity: true)
        var didTruncate = false
        appendBoundedDeferredCandidates(
            pending.candidates,
            to: &output.candidates,
            didTruncate: &didTruncate
        )
        _ = didTruncate
        return output
    }

    private func estimatedPendingBytes(for candidate: AgentSourceCandidate) -> Int {
        let referenceBytes =
            candidate.reference.path.utf8.count
            + (candidate.reference.locator?.utf8.count ?? 0)
        let identityBytes =
            candidate.relativePath.utf8.count
            + (candidate.stableConversationID?.utf8.count ?? 0)
        let providerBytes =
            (candidate.openCodeMetadata?.title.utf8.count ?? 0)
            + (candidate.openCodeMetadata?.directory.utf8.count ?? 0)
        return min(64 * 1_024, 192 + referenceBytes + identityBytes + providerBytes)
    }

    private func estimatedPendingBytes(for entry: AgentSourceIndexEntry) -> Int {
        let identityBytes = entry.id.utf8.count + entry.stableConversationID.utf8.count
        let referenceBytes =
            entry.reference.path.utf8.count
            + (entry.reference.locator?.utf8.count ?? 0)
        return min(64 * 1_024, 256 + identityBytes + referenceBytes + entry.relativePath.utf8.count)
    }

    private func rootObservationIfChanged(
        folder: AgentWatchedFolder,
        availability: AgentSourceAvailability,
        observedAt: Date
    ) -> AgentFolderRootObservation? {
        let pendingAvailability = pendingFolderMutations.reversed().lazy
            .filter { $0.folderID == folder.id }
            .compactMap { $0.rootObservation?.availability }
            .first
        let currentAvailability = pendingAvailability ?? store.rootStatus(folderID: folder.id)?.availability
        guard currentAvailability != availability else { return nil }
        return AgentFolderRootObservation(
            folderID: folder.id,
            availability: availability,
            observedAt: observedAt
        )
    }

    private func isProviderContainerFailure(
        _ error: AgentSourceReadError,
        for entry: AgentSourceIndexEntry
    ) -> Bool {
        guard entry.reference.kind == .sqliteConversation else { return false }
        switch error {
        case .missing(let source), .inaccessible(let source), .changedDuringRead(let source):
            return source == entry.reference.path
        case .fileTooLarge, .unsupported:
            return false
        }
    }

    private func queueRootObservationIfChanged(
        folder: AgentWatchedFolder,
        availability: AgentSourceAvailability,
        observedAt: Date,
        maximumEntries: Int
    ) {
        guard
            let observation = rootObservationIfChanged(
                folder: folder,
                availability: availability,
                observedAt: observedAt
            )
        else { return }
        pendingFolderMutations.append(
            AgentFolderScanMutation(
                folderID: folder.id,
                preparedCaptures: [],
                availabilityObservations: [],
                maximumEntries: maximumEntries,
                discoveryAttempt: nil,
                rootObservation: observation
            )
        )
    }

    @discardableResult
    private func commitFolderScan(
        folder: AgentWatchedFolder,
        preparedCaptures: [AgentPreparedCapture],
        availabilityObservations: [AgentAvailabilityObservation],
        maximumEntries: Int,
        discoveryAttempt: AgentFolderDiscoveryAttempt?,
        rootObservation: AgentFolderRootObservation? = nil,
        result: inout AgentScanResult
    ) -> Bool {
        guard
            !preparedCaptures.isEmpty || !availabilityObservations.isEmpty
                || discoveryAttempt != nil || rootObservation != nil
        else {
            return true
        }
        pendingFolderMutations.append(
            AgentFolderScanMutation(
                folderID: folder.id,
                preparedCaptures: preparedCaptures,
                availabilityObservations: availabilityObservations,
                maximumEntries: maximumEntries,
                discoveryAttempt: discoveryAttempt,
                rootObservation: rootObservation
            )
        )
        _ = result
        return true
    }

    private func compactAnalysisMetrics(_ summary: AgentDocumentSummary) -> AgentDocumentSummary {
        AgentDocumentSummary(
            format: summary.format,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            messageCount: summary.messageCount,
            userMessageCount: summary.userMessageCount,
            assistantMessageCount: summary.assistantMessageCount,
            systemMessageCount: summary.systemMessageCount,
            toolCallCount: summary.toolCallCount,
            errorCount: summary.errorCount,
            subagentCount: summary.subagentCount
        )
    }

    private func unavailableRecord(
        candidate: AgentSourceCandidate,
        folder: AgentWatchedFolder,
        error: Error,
        observedAt: Date
    ) -> AgentCaptureRecord {
        let entry = AgentSourceIndexEntry(
            id: "",
            stableConversationID: candidate.stableConversationID ?? "source-" + referenceKey(candidate.reference),
            watchedFolderID: folder.id,
            watchedFolderName: folder.displayName,
            provider: folder.provider,
            reference: candidate.reference,
            relativePath: candidate.relativePath,
            sourceCreatedAt: candidate.sourceCreatedAt,
            sourceModifiedAt: candidate.sourceModifiedAt,
            firstIndexedAt: observedAt,
            lastObservedAt: observedAt,
            byteCount: max(0, candidate.byteCount ?? 0),
            sha256: "",
            availability: availability(for: error),
            statusDetail: error.localizedDescription
        )
        return AgentCaptureRecord(index: entry, isAnalyzed: false)
    }

    private func availabilityObservations(
        entries: [AgentSourceIndexEntry],
        availability: AgentSourceAvailability,
        error: Error,
        observedAt: Date
    ) -> [AgentAvailabilityObservation] {
        entries.compactMap {
            guard $0.availability != availability else { return nil }
            return AgentAvailabilityObservation(
                entryID: $0.id,
                availability: availability,
                detail: error.localizedDescription,
                observedAt: observedAt,
                expectedReference: $0.reference
            )
        }
    }

    private func candidatePriority(_ left: AgentSourceCandidate, _ right: AgentSourceCandidate) -> Bool {
        let leftDate = left.sourceModifiedAt ?? left.sourceCreatedAt ?? .distantPast
        let rightDate = right.sourceModifiedAt ?? right.sourceCreatedAt ?? .distantPast
        if leftDate == rightDate { return referenceKey(left) < referenceKey(right) }
        return leftDate > rightDate
    }

    private func metadataMatches(
        previous: AgentSourceIndexEntry,
        candidate: AgentSourceCandidate
    ) -> Bool {
        guard previous.availability == .available,
            datesMatch(previous.sourceCreatedAt, candidate.sourceCreatedAt),
            datesMatch(previous.sourceModifiedAt, candidate.sourceModifiedAt)
        else { return false }
        if let byteCount = candidate.byteCount, previous.byteCount != byteCount { return false }
        if let device = candidate.sourceDevice {
            guard previous.sourceDevice == device,
                previous.sourceInode == candidate.sourceInode,
                previous.sourceChangedSeconds == candidate.sourceChangedSeconds,
                previous.sourceChangedNanoseconds == candidate.sourceChangedNanoseconds
            else { return false }
        }
        if let containerByteCount = candidate.sourceContainerByteCount {
            guard previous.sourceContainerByteCount == containerByteCount,
                previous.sourceContainerModifiedSeconds
                    == candidate.sourceContainerModifiedSeconds,
                previous.sourceContainerModifiedNanoseconds
                    == candidate.sourceContainerModifiedNanoseconds
            else { return false }
        }
        return true
    }

    private func shouldDeferGrowingSourceRead(
        candidate: AgentSourceCandidate,
        previous: AgentSourceIndexEntry,
        analyzeContent: Bool,
        rehashUnchanged: Bool,
        observedAt: Date
    ) -> Bool {
        guard !analyzeContent, !rehashUnchanged,
            candidate.reference.kind == .file,
            previous.availability == .available,
            let currentByteCount = candidate.byteCount,
            currentByteCount > previous.byteCount,
            let currentDevice = candidate.sourceDevice,
            let currentInode = candidate.sourceInode,
            previous.sourceDevice == currentDevice,
            previous.sourceInode == currentInode,
            let modifiedAt = candidate.sourceModifiedAt
        else { return false }

        let quietSeconds = observedAt.timeIntervalSince(modifiedAt)
        return quietSeconds >= 0
            && quietSeconds < Self.growingSourceQuiescenceSeconds
    }

    /// The persisted index uses ISO-8601 dates, whose Foundation encoder rounds
    /// filesystem timestamps to whole seconds. Treat sub-second drift as the
    /// same metadata after a restart. Body hashes are recomputed only when source metadata
    /// changes or a direct read is explicitly requested.
    private func datesMatch(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            return abs(left.timeIntervalSince(right)) < 1
        default:
            return false
        }
    }

    private func isRelevant(
        candidate: AgentSourceCandidate,
        previous: AgentSourceIndexEntry?,
        to analysisDay: Date?
    ) -> Bool {
        guard let analysisDay else { return true }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: analysisDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return true }

        let intervalStart = [
            previous?.conversationStartedAt,
            candidate.sourceCreatedAt,
            previous?.sourceCreatedAt,
        ].compactMap { $0 }.min()
        let intervalEnd = [
            previous?.conversationEndedAt,
            candidate.sourceModifiedAt,
            previous?.sourceModifiedAt,
        ].compactMap { $0 }.max()
        switch (intervalStart, intervalEnd) {
        case (let start?, let end?):
            return start < dayEnd && end >= dayStart
        case (let timestamp?, nil), (nil, let timestamp?):
            return timestamp >= dayStart && timestamp < dayEnd
        case (nil, nil):
            return true
        }
    }

    private func resetTransientAnalysesIfSelectionChanged(to analysisDay: Date?) {
        let normalized = analysisDay.map { Calendar.current.startOfDay(for: $0) }
        if hasAnalysisSelection, lastAnalysisDay != normalized {
            store.clearTransientAnalyses()
            finishAnalysisPass()
        }
        lastAnalysisDay = normalized
        hasAnalysisSelection = true
    }

    private func availability(for error: Error) -> AgentSourceAvailability {
        if let sourceError = error as? AgentSourceReadError,
            case .missing = sourceError
        {
            return .missing
        }
        return .inaccessible
    }

    private func appendFailure(_ failure: String, result: inout AgentScanResult) {
        if result.failures.count < 50 { result.failures.append(failure) }
    }

    private func referenceKey(_ candidate: AgentSourceCandidate) -> String {
        referenceKey(candidate.reference)
    }

    private func referenceKey(_ reference: AgentSourceReference) -> String {
        "\(reference.kind.rawValue)\u{0}\(reference.path)\u{0}\(reference.locator ?? "")"
    }
}

public enum AgentScannerPolicy {
    private static let allowedTranscriptExtensions: Set<String> = [
        "json", "jsonl", "ndjson", "md", "markdown", "txt", "log", "trace", "csv",
        "yaml", "yml", "toml", "session", "agent-event",
    ]

    private static let transcriptNameHints = [
        "agent", "chat", "conversation", "event", "history", "message", "prompt", "response",
        "session", "state", "thread", "tool", "trace", "transcript", "workspace",
    ]

    private static let skippedDirectories: Set<String> = [
        "git", "hg", "svn", "build", "deriveddata", "node_modules", "vendor",
        "cache", "caches", "code cache", "gpucache", "service worker", "crashpad", "tmp", "temp",
        "cacheddata", "cachedextensions", "extensions", "backups", "logs", "archive",
    ]

    private static let sensitiveNames: Set<String> = [
        "env", "env.local", "env.production", "auth.json", "credentials", "credentials.json",
        "cookies", "cookies-journal", "login data", "login data-journal", "local state",
        "network persistent state", "oauth.json", "secrets.json", "token.json", "tokens.json",
        "api_keys.json", "keychain.json", "master.key", "id_rsa", "id_ed25519",
    ]

    private static let sensitiveExtensions: Set<String> = ["pem", "key", "p12", "pfx", "cer", "crt"]
    private static let sensitiveFragments = [
        "apikey", "authtoken", "credential", "privatekey", "secret", "token", "backup",
        "cookie", "logindata", "localstate", "oauth", "keychain",
    ]
    private static let sensitivePathComponents: Set<String> = [
        "ssh", "aws", "gnupg", "keychain", "keychains", "credential", "credentials",
        "secret", "secrets", "token", "tokens", "backup", "backups",
    ]
    private static let providerRootsRequiringDedicatedAdapters: Set<String> = [
        "codex", "claude", "gemini", "opencode", "githubcopilotchat",
    ]

    public static func shouldSkipDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink != true
        else { return true }
        return shouldSkipCapabilityAuthorizedDirectory(url)
    }

    /// Path-only policy used after a descriptor-confined traversal has already proved that the
    /// item is a real directory beneath the pinned source root. Keeping this separate prevents
    /// URL resource lookups from reopening an absolute path after the capability was established.
    static func shouldSkipCapabilityAuthorizedDirectory(_ url: URL) -> Bool {
        let name = normalizedName(url.lastPathComponent)
        if skippedDirectories.contains(name) { return true }
        if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle") { return true }
        let securityName = securityKey(name)
        if sensitivePathComponents.contains(securityName) { return true }
        return false
    }

    public static func shouldIndex(
        _ url: URL,
        mode: AgentCaptureMode,
        sourceRoot: URL
    ) -> Bool {
        guard shouldIndexCapabilityAuthorized(url, mode: mode, sourceRoot: sourceRoot) else {
            return false
        }
        let standardized = url.standardizedFileURL
        let standardizedRoot = sourceRoot.standardizedFileURL
        if containsSymbolicLink(standardized, beneath: standardizedRoot) { return false }

        guard let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else { return false }
        return true
    }

    /// Path-only policy for a regular file reached exclusively through `openat`/`O_NOFOLLOW`.
    /// The caller supplies the filesystem proof; this method must never touch the path again.
    static func shouldIndexCapabilityAuthorized(
        _ url: URL,
        mode: AgentCaptureMode,
        sourceRoot: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let standardizedRoot = sourceRoot.standardizedFileURL
        let rootPath = standardizedRoot.path
        guard path.hasPrefix(rootPath + "/") || path == rootPath
        else { return false }

        let rawName = standardized.lastPathComponent.lowercased()
        let name = normalizedName(rawName)
        let nameSecurityKey = securityKey(name)
        if rawName == ".ds_store" || rawName.hasPrefix("._") { return false }
        if name == "env" || name.hasPrefix("env.") { return false }
        if sensitiveNames.contains(name)
            || sensitiveExtensions.contains(standardized.pathExtension.lowercased())
            || sensitiveFragments.contains(where: { nameSecurityKey.contains($0) })
        {
            return false
        }
        let pathKeys = path.split(separator: "/").map { securityKey(String($0)) }
        if pathKeys.contains(where: sensitivePathComponents.contains) {
            return false
        }
        if providerRootsRequiringDedicatedAdapters.contains(securityKey(standardizedRoot.lastPathComponent)) {
            return false
        }

        if mode == .everyFile { return true }
        let ext = standardized.pathExtension.lowercased()
        if ext == "json" {
            return transcriptNameHints.contains { name.contains($0) }
        }
        if allowedTranscriptExtensions.contains(ext) { return true }
        return transcriptNameHints.contains { name.contains($0) }
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
    }

    private static func securityKey(_ value: String) -> String {
        normalizedName(value).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func containsSymbolicLink(_ url: URL, beneath root: URL) -> Bool {
        var current = url
        while true {
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                values.isSymbolicLink != true
            else { return true }
            if current.path == root.path { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || !parent.path.hasPrefix(root.path) { return true }
            current = parent
        }
    }
}
