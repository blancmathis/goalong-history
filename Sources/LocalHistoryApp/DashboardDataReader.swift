#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    final class DashboardDataReader {
        struct Limits: Equatable {
            var maximumEventFiles = 4
            var maximumSealFiles = 4
            var maximumReceiptFiles = 32
            var maximumReceiptLookups = 4
            /// Receipt discovery is streamed and retained as a names-only inventory.
            /// These limits keep malformed or unexpectedly large directories from
            /// turning a dashboard refresh into an unbounded allocation or scan.
            var maximumReceiptDirectoryEntries = 4_096
            var maximumReceiptFilesPerLookup = 64
            var maximumReceiptDirectoryEnumerationSeconds: TimeInterval = 0.25
            var maximumDaySnapshots = 1
            /// One shared budget across events, seals, and receipts. Keeping this
            /// global prevents three independently full typed caches from retaining
            /// up to three times the intended dashboard working set.
            var maximumCachedRows = 100_000
            var maximumCachedEstimatedBytes: Int64 = 32 * 1_024 * 1_024
            /// Derived dashboard collections duplicate selected source fields. Keep
            /// their retained representation under a separate, smaller envelope.
            var maximumDerivedEstimatedBytes: Int64 = 8 * 1_024 * 1_024
            var metadataRefreshInterval: TimeInterval = 15 * 60
            var readChunkBytes = 64 * 1_024
            var maximumLineBytes = 8 * 1_024 * 1_024

            static let production = Limits()
        }

        enum JournalTransition: String, Equatable {
            case initial
            case unchanged
            case appended
            case replaced
            case truncated
            case rewritten
            case missing
            case unavailable
            case unstable
            case budgetExceeded
            case cancelled
        }

        enum BudgetLimit: String, Equatable {
            case retainedRows
            case retainedBytes
            case lineBytes
            case derivedBytes
            case directoryEntries
            case directoryTime
            case receiptFiles
        }

        enum SnapshotState: String, Equatable {
            case fresh
            case lastKnownGood
            case unavailable
            case budgetExceeded
            case cancelled
        }

        struct Diagnostics: Equatable {
            var bytesRead: Int64 = 0
            var rowsDecoded = 0
            var transitions: [String: JournalTransition] = [:]
            var cachedEventFiles = 0
            var cachedSealFiles = 0
            var cachedReceiptFiles = 0
            var cachedDaySnapshots = 0
            var cachedRows = 0
            var cachedEstimatedBytes: Int64 = 0
            var cachedDerivedEstimatedBytes: Int64 = 0
            var budgetExceeded: [String: BudgetLimit] = [:]
            var skippedOverBudgetRevisions = 0
            var appendCacheMutationCount = 0
            var receiptDirectoryScanCount = 0
            var receiptFilesExamined = 0
            var cachedReceiptDirectoryEntries = 0
            var cachedReceiptDirectoryEstimatedBytes: Int64 = 0
            var snapshotState: SnapshotState = .fresh
            var partialSourcePaths: Set<String> = []
            var storageScanCount = 0
        }

        private struct FileIdentity: Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modifiedNanoseconds: Int64
            let changedNanoseconds: Int64
        }

        private struct JournalCacheEntry<Value> {
            var identity: FileIdentity
            var offset: Int64
            var values: [Value]
            var estimatedBytes: Int64
            var tailFingerprint: String
            var lastAccess: UInt64
        }

        private struct MetadataSnapshot {
            var storageBytes: Int64 = 0
            var availableDays: [Date] = []
            var refreshedAt: Date?
            var scanCount = 0
        }

        private struct DaySnapshotCacheEntry {
            var revision: String
            var snapshot: DashboardDaySnapshot
            var estimatedBytes: Int64
            var lastAccess: UInt64
        }

        private struct ReceiptLookupCacheEntry {
            var directoryRevision: String
            var matches: Set<UInt64>
            var watchedFiles: [String: FileIdentity]
            var lookupRevision: String
            var budgetLimit: BudgetLimit?
            var estimatedBytes: Int64
            var lastAccess: UInt64
        }

        private struct ReceiptDirectoryInventory {
            var identity: FileIdentity
            var files: [URL]
            var revision: String
            var estimatedBytes: Int64
        }

        private struct ReceiptDirectoryBudgetFailure {
            var identity: FileIdentity
            var limit: BudgetLimit
            var retryAfter: TimeInterval
        }

        private struct JournalBudgetFailure {
            var identity: FileIdentity
            var limit: BudgetLimit
            var lastAccess: UInt64
        }

        private struct DayBudgetFailure {
            var revision: String
            var limit: BudgetLimit
            var lastAccess: UInt64
        }

        private struct DerivedBudget {
            let maximumBytes: Int64
            private(set) var usedBytes: Int64 = 0

            mutating func reserve(_ requestedBytes: Int64) throws {
                let bounded = max(0, requestedBytes)
                guard bounded <= maximumBytes - usedBytes else {
                    throw JournalReadError.budgetExceeded(
                        .derivedBytes,
                        bytesRead: 0,
                        rowsDecoded: 0
                    )
                }
                usedBytes += bounded
            }
        }

        private enum JournalReadError: Error {
            case cancelled
            case unavailable
            case unstable
            case budgetExceeded(BudgetLimit, bytesRead: Int64, rowsDecoded: Int)
        }

        private let fileManager: FileManager
        private let rootDirectory: URL
        private let eventsDirectory: URL
        private let sealsDirectory: URL
        private let receiptsDirectory: URL
        private let limits: Limits
        private let now: () -> Date
        private let monotonicNow: () -> TimeInterval
        private let afterJournalReadForTesting: ((URL) -> Void)?
        private let cacheLock = NSLock()
        private let metadataLock = NSLock()

        private var eventCache: [String: JournalCacheEntry<HistoryEvent>] = [:]
        private var sealCache: [String: JournalCacheEntry<LocalMinuteSeal>] = [:]
        private var receiptCache: [String: JournalCacheEntry<UInt64>] = [:]
        private var receiptLookupCache: [String: ReceiptLookupCacheEntry] = [:]
        private var receiptDirectoryInventory: ReceiptDirectoryInventory?
        private var receiptDirectoryBudgetFailure: ReceiptDirectoryBudgetFailure?
        private var daySnapshotCache: [String: DaySnapshotCacheEntry] = [:]
        private var journalBudgetFailures: [String: JournalBudgetFailure] = [:]
        private var dayBudgetFailures: [String: DayBudgetFailure] = [:]
        private var latestReceiptDirectoryRevision = "none"
        private var latestReceiptLookupRevision = "none"
        private var accessSequence: UInt64 = 0
        private var metadata = MetadataSnapshot()
        private var metadataRefreshInProgress = false
        private var latestDiagnostics = Diagnostics()

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            limits: Limits = .production,
            fileManager: FileManager = .default,
            now: @escaping () -> Date = Date.init,
            monotonicNow: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            },
            afterJournalReadForTesting: ((URL) -> Void)? = nil
        ) {
            precondition(limits.maximumEventFiles >= 0)
            precondition(limits.maximumSealFiles >= 0)
            precondition(limits.maximumReceiptFiles >= 0)
            precondition(limits.maximumReceiptLookups >= 0)
            precondition(limits.maximumReceiptDirectoryEntries >= 0)
            precondition(limits.maximumReceiptFilesPerLookup >= 0)
            precondition(limits.maximumReceiptDirectoryEnumerationSeconds >= 0)
            precondition(limits.maximumDaySnapshots >= 0)
            precondition(limits.maximumCachedRows >= 0)
            precondition(limits.maximumCachedEstimatedBytes >= 0)
            precondition(limits.maximumDerivedEstimatedBytes >= 0)
            precondition(limits.metadataRefreshInterval >= 0)
            precondition(limits.readChunkBytes > 0)
            precondition(limits.maximumLineBytes > 0)
            self.rootDirectory = rootDirectory.standardizedFileURL
            eventsDirectory = self.rootDirectory.appendingPathComponent("events", isDirectory: true)
            sealsDirectory = self.rootDirectory.appendingPathComponent("seals", isDirectory: true)
            receiptsDirectory = self.rootDirectory.appendingPathComponent("receipts", isDirectory: true)
            self.limits = limits
            self.fileManager = fileManager
            self.now = now
            self.monotonicNow = monotonicNow
            self.afterJournalReadForTesting = afterJournalReadForTesting
        }

        var diagnostics: Diagnostics {
            let cacheDiagnostics = withCacheLock {
                var result = latestDiagnostics
                result.cachedEventFiles = eventCache.count
                result.cachedSealFiles = sealCache.count
                result.cachedReceiptFiles = receiptCache.count
                result.cachedDaySnapshots = daySnapshotCache.count
                result.cachedRows = cachedRowCount
                result.cachedEstimatedBytes = cachedEstimatedByteCount
                result.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
                result.cachedReceiptDirectoryEntries = receiptDirectoryInventory?.files.count ?? 0
                result.cachedReceiptDirectoryEstimatedBytes =
                    receiptDirectoryInventory?.estimatedBytes ?? 0
                return result
            }
            return withMetadataLock {
                var result = cacheDiagnostics
                result.storageScanCount = metadata.scanCount
                return result
            }
        }

        func snapshot(for day: Date) -> DashboardDaySnapshot {
            snapshot(for: day, cancellation: { false }) ?? .empty(day: day)
        }

        func snapshot(
            for day: Date,
            cancellation: @escaping () -> Bool
        ) -> DashboardDaySnapshot? {
            cacheLock.lock()
            defer { cacheLock.unlock() }

            var operation = Diagnostics(
                storageScanCount: withMetadataLock { metadata.scanCount }
            )
            guard !cancellation() else {
                operation.transitions["snapshot"] = .cancelled
                operation.snapshotState = .cancelled
                latestDiagnostics = operation
                return nil
            }

            guard let loadedEvents = loadEvents(for: day, cancellation: cancellation, diagnostics: &operation),
                let loadedSeals = loadSeals(for: day, cancellation: cancellation, diagnostics: &operation)
            else {
                if !operation.budgetExceeded.isEmpty {
                    operation.snapshotState = .budgetExceeded
                } else {
                    operation.snapshotState =
                        operation.transitions.values.contains(.cancelled)
                        ? .cancelled : .unavailable
                }
                latestDiagnostics = operation
                return nil
            }
            var events = loadedEvents
            if zip(events, events.dropFirst()).contains(where: {
                $0.0.timestamp > $0.1.timestamp
            }) {
                events.sort { $0.timestamp < $1.timestamp }
            }
            var seals = loadedSeals
            if zip(seals, seals.dropFirst()).contains(where: {
                $0.0.anchorSequence > $0.1.anchorSequence
            }) {
                seals.sort { $0.anchorSequence < $1.anchorSequence }
            }
            let snapshotKey = dayKey(for: day)
            let eventPath = eventsDirectory.appendingPathComponent(snapshotKey + ".jsonl").path
            let sealPath = sealsDirectory.appendingPathComponent(snapshotKey + ".seals.jsonl").path
            if hasPartialSource(in: operation) {
                return recordPartialSource(
                    snapshotKey: snapshotKey,
                    operation: &operation
                )
            }
            var derivedBudget = DerivedBudget(
                maximumBytes: limits.maximumDerivedEstimatedBytes
            )
            var targetReceiptSequences = Set<UInt64>()
            do {
                for seal in seals where !targetReceiptSequences.contains(seal.anchorSequence) {
                    try derivedBudget.reserve(16)
                    targetReceiptSequences.insert(seal.anchorSequence)
                }
            } catch let JournalReadError.budgetExceeded(limit, _, _) {
                let preliminaryRevision = revision(
                    eventPath: eventPath,
                    sealPath: sealPath,
                    diagnostics: operation
                )
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: preliminaryRevision,
                    limit: limit,
                    operation: &operation
                )
            } catch {
                operation.transitions["snapshot"] = .unavailable
                latestDiagnostics = operation
                return nil
            }
            guard
                let receiptSequences = loadReceiptSequences(
                    matching: targetReceiptSequences,
                    for: day,
                    cancellation: cancellation,
                    diagnostics: &operation
                )
            else {
                if let limit = operation.budgetExceeded.values.first {
                    let preliminaryRevision = revision(
                        eventPath: eventPath,
                        sealPath: sealPath,
                        diagnostics: operation
                    )
                    return recordDayBudgetFailure(
                        snapshotKey: snapshotKey,
                        revision: preliminaryRevision,
                        limit: limit,
                        operation: &operation
                    )
                }
                if hasPartialSource(in: operation) {
                    return recordPartialSource(
                        snapshotKey: snapshotKey,
                        operation: &operation
                    )
                }
                operation.snapshotState =
                    operation.transitions.values.contains(.cancelled)
                    ? .cancelled : .unavailable
                latestDiagnostics = operation
                return nil
            }
            if hasPartialSource(in: operation) {
                return recordPartialSource(
                    snapshotKey: snapshotKey,
                    operation: &operation
                )
            }
            do {
                try derivedBudget.reserve(Int64(receiptSequences.count) * 16)
            } catch let JournalReadError.budgetExceeded(limit, _, _) {
                let preliminaryRevision = revision(
                    eventPath: eventPath,
                    sealPath: sealPath,
                    diagnostics: operation
                )
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: preliminaryRevision,
                    limit: limit,
                    operation: &operation
                )
            } catch {
                operation.transitions["snapshot"] = .unavailable
                latestDiagnostics = operation
                return nil
            }
            let sourceRevision = revision(
                eventPath: eventPath,
                sealPath: sealPath,
                diagnostics: operation
            )
            if let sourceLimit = operation.budgetExceeded.values.first {
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: sourceRevision,
                    limit: sourceLimit,
                    operation: &operation
                )
            }
            if var cached = daySnapshotCache[snapshotKey], cached.revision == sourceRevision {
                accessSequence &+= 1
                cached.lastAccess = accessSequence
                daySnapshotCache[snapshotKey] = cached
                operation.cachedEventFiles = eventCache.count
                operation.cachedSealFiles = sealCache.count
                operation.cachedReceiptFiles = receiptCache.count
                operation.cachedDaySnapshots = daySnapshotCache.count
                operation.cachedRows = cachedRowCount
                operation.cachedEstimatedBytes = cachedEstimatedByteCount
                operation.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
                latestDiagnostics = operation
                return applyingCachedMetadata(to: cached.snapshot)
            }
            if var failure = dayBudgetFailures[snapshotKey], failure.revision == sourceRevision {
                accessSequence &+= 1
                failure.lastAccess = accessSequence
                dayBudgetFailures[snapshotKey] = failure
                operation.transitions["snapshot"] = .budgetExceeded
                operation.budgetExceeded["snapshot"] = failure.limit
                operation.skippedOverBudgetRevisions += 1
                operation.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
                operation.snapshotState =
                    daySnapshotCache[snapshotKey] == nil
                    ? .budgetExceeded : .lastKnownGood
                latestDiagnostics = operation
                return daySnapshotCache[snapshotKey].map {
                    applyingCachedMetadata(to: $0.snapshot)
                }
            }
            dayBudgetFailures.removeValue(forKey: snapshotKey)
            guard !cancellation() else {
                operation.transitions["snapshot"] = .cancelled
                operation.snapshotState = .cancelled
                latestDiagnostics = operation
                return nil
            }

            var activeMinuteKeys = Set<Int64>()
            var workMinuteKeys = Set<Int64>()
            var privateMinuteKeys = Set<Int64>()
            var sealedMinuteKeys = Set<Int64>()
            var liveAnchoredMinuteKeys = Set<Int64>()
            var softwareAttributedEvents = 0
            do {
                for event in events {
                    let minute = Self.minuteKey(event.timestamp)
                    if Self.isActivityEvent(event) {
                        if !activeMinuteKeys.contains(minute) {
                            try derivedBudget.reserve(16)
                            activeMinuteKeys.insert(minute)
                        }
                        if event.classification?.isWork == true,
                            !workMinuteKeys.contains(minute)
                        {
                            try derivedBudget.reserve(16)
                            workMinuteKeys.insert(minute)
                        }
                    }
                    if event.suppressionReason != nil,
                        !privateMinuteKeys.contains(minute)
                    {
                        try derivedBudget.reserve(16)
                        privateMinuteKeys.insert(minute)
                    }
                    if event.inputOrigin?.assessment == .softwareAttributed {
                        softwareAttributedEvents += 1
                    }
                }
                for seal in seals {
                    let minute = Self.minuteKey(seal.minuteStart)
                    if !sealedMinuteKeys.contains(minute) {
                        try derivedBudget.reserve(16)
                        sealedMinuteKeys.insert(minute)
                    }
                    if receiptSequences.contains(seal.anchorSequence),
                        !liveAnchoredMinuteKeys.contains(minute)
                    {
                        try derivedBudget.reserve(16)
                        liveAnchoredMinuteKeys.insert(minute)
                    }
                    let states = coverageStates(for: seal)
                    if states.contains(where: { $0 != "captured" }),
                        !privateMinuteKeys.contains(minute)
                    {
                        try derivedBudget.reserve(16)
                        privateMinuteKeys.insert(minute)
                    }
                }
            } catch let JournalReadError.budgetExceeded(limit, _, _) {
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: sourceRevision,
                    limit: limit,
                    operation: &operation
                )
            } catch {
                operation.transitions["snapshot"] = .unavailable
                latestDiagnostics = operation
                return nil
            }

            let sessions: [ActivitySession]
            let trackedUsage: [TrackedUsageItem]
            do {
                sessions = try buildSessions(from: events, budget: &derivedBudget)
                trackedUsage = try buildTrackedUsage(
                    from: events,
                    day: day,
                    budget: &derivedBudget
                )
            } catch let JournalReadError.budgetExceeded(limit, _, _) {
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: sourceRevision,
                    limit: limit,
                    operation: &operation
                )
            } catch {
                operation.transitions["snapshot"] = .unavailable
                latestDiagnostics = operation
                return nil
            }
            guard !cancellation() else {
                operation.transitions["snapshot"] = .cancelled
                operation.snapshotState = .cancelled
                latestDiagnostics = operation
                return nil
            }
            var appUsage: [AppUsage] = []
            do {
                for item in trackedUsage
                where item.kind == .application && item.foregroundSeconds > 0 {
                    let value = AppUsage(
                        appName: item.name,
                        bundleIdentifier: item.bundleIdentifier,
                        activeMinutes: Int(ceil(item.foregroundSeconds / 60)),
                        eventCount: item.eventCount
                    )
                    try derivedBudget.reserve(
                        64 + estimatedStringBytes(value.appName)
                            + estimatedStringBytes(value.bundleIdentifier)
                    )
                    appUsage.append(value)
                }
                try derivedBudget.reserve(96 * 64)
            } catch let JournalReadError.budgetExceeded(limit, _, _) {
                return recordDayBudgetFailure(
                    snapshotKey: snapshotKey,
                    revision: sourceRevision,
                    limit: limit,
                    operation: &operation
                )
            } catch {
                operation.transitions["snapshot"] = .unavailable
                latestDiagnostics = operation
                return nil
            }
            let timeline = buildTimeline(
                for: day,
                activeMinuteKeys: activeMinuteKeys,
                workMinuteKeys: workMinuteKeys,
                privateMinuteKeys: privateMinuteKeys,
                sealedMinuteKeys: sealedMinuteKeys
            )
            guard !cancellation() else {
                operation.transitions["snapshot"] = .cancelled
                operation.snapshotState = .cancelled
                latestDiagnostics = operation
                return nil
            }
            operation.cachedEventFiles = eventCache.count
            operation.cachedSealFiles = sealCache.count
            operation.cachedReceiptFiles = receiptCache.count
            operation.cachedDaySnapshots = daySnapshotCache.count
            operation.cachedRows = cachedRowCount
            operation.cachedEstimatedBytes = cachedEstimatedByteCount
            let cachedMetadata = withMetadataLock { metadata }
            let result = DashboardDaySnapshot(
                day: day,
                eventCount: events.count,
                activeMinutes: activeMinuteKeys.count,
                workMinutes: workMinuteKeys.count,
                sealedMinutes: sealedMinuteKeys.count,
                liveAnchoredMinutes: liveAnchoredMinuteKeys.count,
                privateMinutes: privateMinuteKeys.count,
                softwareAttributedEvents: softwareAttributedEvents,
                sessions: sessions,
                appUsage: appUsage,
                trackedUsage: trackedUsage,
                timeline: timeline,
                storageBytes: cachedMetadata.storageBytes,
                availableDays: cachedMetadata.availableDays
            )
            if limits.maximumDaySnapshots > 0 {
                let estimatedSnapshotBytes = estimateSnapshotBytes(result)
                guard estimatedSnapshotBytes <= limits.maximumDerivedEstimatedBytes else {
                    return recordDayBudgetFailure(
                        snapshotKey: snapshotKey,
                        revision: sourceRevision,
                        limit: .derivedBytes,
                        operation: &operation
                    )
                }
                accessSequence &+= 1
                daySnapshotCache[snapshotKey] = DaySnapshotCacheEntry(
                    revision: sourceRevision,
                    snapshot: result,
                    estimatedBytes: estimatedSnapshotBytes,
                    lastAccess: accessSequence
                )
                while daySnapshotCache.count > limits.maximumDaySnapshots {
                    guard
                        let oldest = daySnapshotCache.min(by: {
                            $0.value.lastAccess < $1.value.lastAccess
                        })?.key
                    else { break }
                    daySnapshotCache.removeValue(forKey: oldest)
                }
                trimDerivedCachesToBudget()
            }
            operation.cachedDaySnapshots = daySnapshotCache.count
            operation.cachedEstimatedBytes = cachedEstimatedByteCount
            operation.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
            latestDiagnostics = operation
            return result
        }

        func metadataNeedsRefresh(force: Bool = false) -> Bool {
            withMetadataLock {
                if metadataRefreshInProgress { return false }
                if force || metadata.refreshedAt == nil { return true }
                return now().timeIntervalSince(metadata.refreshedAt ?? .distantPast)
                    >= limits.metadataRefreshInterval
            }
        }

        @discardableResult
        func refreshMetadataIfNeeded(
            force: Bool = false,
            cancellation: @escaping () -> Bool = { false }
        ) -> Bool {
            let shouldStart = withMetadataLock { () -> Bool in
                if metadataRefreshInProgress { return false }
                if !force, let refreshedAt = metadata.refreshedAt,
                    now().timeIntervalSince(refreshedAt) < limits.metadataRefreshInterval
                {
                    return false
                }
                metadataRefreshInProgress = true
                return true
            }
            guard shouldStart else { return false }
            var committed = false
            defer {
                if !committed {
                    withMetadataLock { metadataRefreshInProgress = false }
                }
            }
            guard !cancellation(),
                let storageBytes = calculateStorageBytes(cancellation: cancellation),
                let availableDays = calculateAvailableDays(cancellation: cancellation),
                !cancellation()
            else { return false }
            withMetadataLock {
                metadata.storageBytes = storageBytes
                metadata.availableDays = availableDays
                metadata.refreshedAt = now()
                metadata.scanCount += 1
                metadataRefreshInProgress = false
            }
            committed = true
            return true
        }

        func applyingCachedMetadata(to snapshot: DashboardDaySnapshot) -> DashboardDaySnapshot {
            withMetadataLock {
                DashboardDaySnapshot(
                    day: snapshot.day,
                    eventCount: snapshot.eventCount,
                    activeMinutes: snapshot.activeMinutes,
                    workMinutes: snapshot.workMinutes,
                    sealedMinutes: snapshot.sealedMinutes,
                    liveAnchoredMinutes: snapshot.liveAnchoredMinutes,
                    privateMinutes: snapshot.privateMinutes,
                    softwareAttributedEvents: snapshot.softwareAttributedEvents,
                    sessions: snapshot.sessions,
                    appUsage: snapshot.appUsage,
                    trackedUsage: snapshot.trackedUsage,
                    timeline: snapshot.timeline,
                    storageBytes: metadata.storageBytes,
                    availableDays: metadata.availableDays
                )
            }
        }

        /// The menu-bar app spends most of its life without a dashboard window.
        /// Release decoded rows and derived view data after close; cheap metadata is
        /// retained so reopening can still show storage/day navigation immediately.
        func discardTransientCaches() {
            withCacheLock {
                eventCache.removeAll(keepingCapacity: false)
                sealCache.removeAll(keepingCapacity: false)
                receiptCache.removeAll(keepingCapacity: false)
                receiptLookupCache.removeAll(keepingCapacity: false)
                receiptDirectoryInventory = nil
                receiptDirectoryBudgetFailure = nil
                daySnapshotCache.removeAll(keepingCapacity: false)
                latestReceiptDirectoryRevision = "none"
                latestReceiptLookupRevision = "none"
                latestDiagnostics = Diagnostics(
                    storageScanCount: withMetadataLock { metadata.scanCount }
                )
            }
        }

        private var cachedRowCount: Int {
            eventCache.values.reduce(0) { $0 + $1.values.count }
                + sealCache.values.reduce(0) { $0 + $1.values.count }
                + receiptCache.values.reduce(0) { $0 + $1.values.count }
        }

        private var cachedEstimatedByteCount: Int64 {
            eventCache.values.reduce(0) { $0 + $1.estimatedBytes }
                + sealCache.values.reduce(0) { $0 + $1.estimatedBytes }
                + receiptCache.values.reduce(0) { $0 + $1.estimatedBytes }
        }

        private var cachedDerivedEstimatedByteCount: Int64 {
            daySnapshotCache.values.reduce(0) { $0 + $1.estimatedBytes }
                + receiptLookupCache.values.reduce(0) { $0 + $1.estimatedBytes }
        }

        private func revision(
            eventPath: String,
            sealPath: String,
            diagnostics: Diagnostics
        ) -> String {
            func component<Value>(
                path: String,
                cache: [String: JournalCacheEntry<Value>]
            ) -> String {
                if let failure = journalBudgetFailures[path] {
                    return [
                        path,
                        "budget",
                        failure.limit.rawValue,
                        String(failure.identity.device),
                        String(failure.identity.inode),
                        String(failure.identity.size),
                        String(failure.identity.modifiedNanoseconds),
                        String(failure.identity.changedNanoseconds),
                    ].joined(separator: ":")
                }
                guard let entry = cache[path] else {
                    return "\(path)=\(diagnostics.transitions[path]?.rawValue ?? "none")"
                }
                return [
                    path,
                    String(entry.identity.device),
                    String(entry.identity.inode),
                    String(entry.identity.size),
                    String(entry.identity.modifiedNanoseconds),
                    String(entry.identity.changedNanoseconds),
                    String(entry.offset),
                    String(entry.values.count),
                    entry.tailFingerprint,
                ].joined(separator: ":")
            }

            var components = [
                component(path: eventPath, cache: eventCache),
                component(path: sealPath, cache: sealCache),
            ]
            components.append(
                contentsOf: receiptCache.keys.sorted().map {
                    component(path: $0, cache: receiptCache)
                })
            components.append("receipt-directory:\(latestReceiptDirectoryRevision)")
            components.append("receipt-lookup:\(latestReceiptLookupRevision)")
            return SHA256Digest.hashHex(components.joined(separator: "\n"))
        }

        private func loadEvents(
            for day: Date,
            cancellation: @escaping () -> Bool,
            diagnostics: inout Diagnostics
        ) -> [HistoryEvent]? {
            let url = eventsDirectory.appendingPathComponent(dayKey(for: day) + ".jsonl")
            let previous = eventCache[url.path]
            let events = loadJournal(
                HistoryEvent.self,
                at: url,
                cache: &eventCache,
                maximumFiles: limits.maximumEventFiles,
                reservedRows: max(0, cachedRowCount - (previous?.values.count ?? 0)),
                reservedEstimatedBytes: max(
                    0,
                    cachedEstimatedByteCount - (previous?.estimatedBytes ?? 0)
                ),
                cancellation: cancellation,
                transform: {
                    Self.compactEventForDashboard($0)
                },
                diagnostics: &diagnostics
            )
            trimJournalCachesToGlobalBudget()
            return events
        }

        private func loadSeals(
            for day: Date,
            cancellation: @escaping () -> Bool,
            diagnostics: inout Diagnostics
        ) -> [LocalMinuteSeal]? {
            let url = sealsDirectory.appendingPathComponent(dayKey(for: day) + ".seals.jsonl")
            let previous = sealCache[url.path]
            let seals = loadJournal(
                LocalMinuteSeal.self,
                at: url,
                cache: &sealCache,
                maximumFiles: limits.maximumSealFiles,
                reservedRows: max(0, cachedRowCount - (previous?.values.count ?? 0)),
                reservedEstimatedBytes: max(
                    0,
                    cachedEstimatedByteCount - (previous?.estimatedBytes ?? 0)
                ),
                cancellation: cancellation,
                transform: { $0 },
                diagnostics: &diagnostics
            )
            trimJournalCachesToGlobalBudget()
            return seals
        }

        private func loadReceiptSequences(
            matching targets: Set<UInt64>,
            for day: Date,
            cancellation: @escaping () -> Bool,
            diagnostics: inout Diagnostics
        ) -> Set<UInt64>? {
            guard !targets.isEmpty else {
                latestReceiptDirectoryRevision = "not-needed"
                latestReceiptLookupRevision = "no-targets"
                return []
            }
            let targetFingerprint = SHA256Digest.hashHex(
                ([dayKey(for: day)] + targets.sorted().map(String.init))
                    .joined(separator: ",")
            )
            guard
                let inventory = loadReceiptDirectoryInventory(
                    cancellation: cancellation,
                    diagnostics: &diagnostics
                )
            else { return nil }
            let directoryRevision = inventory.revision
            if var cached = receiptLookupCache[targetFingerprint],
                cached.directoryRevision == directoryRevision,
                receiptLookupIsCurrent(cached)
            {
                accessSequence &+= 1
                cached.lastAccess = accessSequence
                receiptLookupCache[targetFingerprint] = cached
                latestReceiptLookupRevision = cached.lookupRevision
                if let limit = cached.budgetLimit {
                    diagnostics.transitions[receiptsDirectory.path] = .budgetExceeded
                    diagnostics.budgetExceeded[receiptsDirectory.path] = limit
                    diagnostics.skippedOverBudgetRevisions += 1
                    return nil
                }
                diagnostics.transitions[receiptsDirectory.path] = .unchanged
                for path in receiptCache.keys {
                    diagnostics.transitions[path] = .unchanged
                }
                return cached.matches
            }
            receiptLookupCache.removeValue(forKey: targetFingerprint)
            let files = prioritizedReceiptFiles(in: inventory.files, for: day)
            var result = Set<UInt64>()
            var lookupIsComplete = true
            var examinedFiles = [String: FileIdentity]()
            var contributingPaths = Set<String>()
            var examinedCount = 0
            for file in files {
                guard examinedCount < limits.maximumReceiptFilesPerLookup else {
                    lookupIsComplete = false
                    break
                }
                guard !cancellation() else {
                    diagnostics.transitions[file.path] = .cancelled
                    return nil
                }
                examinedCount += 1
                diagnostics.receiptFilesExamined += 1
                let countBefore = result.count
                guard
                    let sequences = loadJournal(
                        AnchorReceipt.self,
                        at: file,
                        cache: &receiptCache,
                        maximumFiles: limits.maximumReceiptFiles,
                        reservedRows: 0,
                        reservedEstimatedBytes: 0,
                        cancellation: cancellation,
                        transform: { $0.anchorSequence },
                        diagnostics: &diagnostics
                    )
                else { return nil }
                trimJournalCachesToGlobalBudget()
                if diagnostics.transitions[file.path] == .unavailable
                    || diagnostics.transitions[file.path] == .unstable
                    || diagnostics.transitions[file.path] == .budgetExceeded
                    || diagnostics.transitions[file.path] == .missing
                {
                    lookupIsComplete = false
                }
                result.formUnion(sequences.lazy.filter(targets.contains))
                if result.count > countBefore {
                    contributingPaths.insert(file.path)
                }
                if let identity = receiptCache[file.path]?.identity
                    ?? uncheckedFileIdentity(at: file)
                {
                    examinedFiles[file.path] = identity
                }
                if result.count == targets.count { break }
            }

            if inventory.revision != "missing" {
                guard uncheckedDirectoryIdentity(at: receiptsDirectory) == inventory.identity else {
                    diagnostics.transitions[receiptsDirectory.path] = .unstable
                    return nil
                }
            }

            let watchedFiles = receiptWatchSet(
                files: files,
                day: day,
                contributingPaths: contributingPaths,
                examinedFiles: examinedFiles
            )
            if result.count < targets.count, examinedCount < files.count {
                let limit: BudgetLimit = .receiptFiles
                let lookupRevision = receiptLookupRevision(
                    targetFingerprint: targetFingerprint,
                    directoryRevision: directoryRevision,
                    matches: result,
                    watchedFiles: watchedFiles,
                    budgetLimit: limit
                )
                latestReceiptLookupRevision = lookupRevision
                cacheReceiptLookup(
                    targetFingerprint: targetFingerprint,
                    directoryRevision: directoryRevision,
                    matches: result,
                    watchedFiles: watchedFiles,
                    lookupRevision: lookupRevision,
                    budgetLimit: limit
                )
                diagnostics.transitions[receiptsDirectory.path] = .budgetExceeded
                diagnostics.budgetExceeded[receiptsDirectory.path] = limit
                return nil
            }

            let lookupRevision = receiptLookupRevision(
                targetFingerprint: targetFingerprint,
                directoryRevision: directoryRevision,
                matches: result,
                watchedFiles: watchedFiles,
                budgetLimit: nil
            )
            latestReceiptLookupRevision = lookupRevision
            if lookupIsComplete {
                cacheReceiptLookup(
                    targetFingerprint: targetFingerprint,
                    directoryRevision: directoryRevision,
                    matches: result,
                    watchedFiles: watchedFiles,
                    lookupRevision: lookupRevision,
                    budgetLimit: nil
                )
            }
            return result
        }

        private func loadReceiptDirectoryInventory(
            cancellation: @escaping () -> Bool,
            diagnostics: inout Diagnostics
        ) -> ReceiptDirectoryInventory? {
            guard let identity = directoryIdentity(at: receiptsDirectory, diagnostics: &diagnostics)
            else {
                if diagnostics.transitions[receiptsDirectory.path] == .missing {
                    receiptCache.removeAll(keepingCapacity: false)
                    receiptLookupCache.removeAll(keepingCapacity: false)
                    receiptDirectoryInventory = nil
                    receiptDirectoryBudgetFailure = nil
                    latestReceiptDirectoryRevision = "missing"
                    latestReceiptLookupRevision = "missing"
                    return ReceiptDirectoryInventory(
                        identity: FileIdentity(
                            device: 0,
                            inode: 0,
                            size: 0,
                            modifiedNanoseconds: 0,
                            changedNanoseconds: 0
                        ),
                        files: [],
                        revision: "missing",
                        estimatedBytes: 0
                    )
                }
                receiptDirectoryInventory = nil
                latestReceiptDirectoryRevision = "unavailable"
                latestReceiptLookupRevision = "unavailable"
                return nil
            }

            if let failure = receiptDirectoryBudgetFailure, failure.identity == identity,
                failure.limit != .directoryTime || monotonicNow() < failure.retryAfter
            {
                diagnostics.transitions[receiptsDirectory.path] = .budgetExceeded
                diagnostics.budgetExceeded[receiptsDirectory.path] = failure.limit
                diagnostics.skippedOverBudgetRevisions += 1
                latestReceiptDirectoryRevision = receiptDirectoryBudgetRevision(
                    identity: identity,
                    limit: failure.limit
                )
                latestReceiptLookupRevision = "directory-budget"
                return nil
            }
            receiptDirectoryBudgetFailure = nil

            if let cached = receiptDirectoryInventory, cached.identity == identity {
                diagnostics.transitions[receiptsDirectory.path] = .unchanged
                latestReceiptDirectoryRevision = cached.revision
                return cached
            }

            guard !cancellation() else {
                diagnostics.transitions[receiptsDirectory.path] = .cancelled
                return nil
            }
            diagnostics.receiptDirectoryScanCount += 1
            let startedAt = monotonicNow()
            var enumerationFailed = false
            guard
                let enumerator = fileManager.enumerator(
                    at: receiptsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                    errorHandler: { _, _ in
                        enumerationFailed = true
                        return false
                    }
                )
            else {
                receiptDirectoryInventory = nil
                diagnostics.transitions[receiptsDirectory.path] = .unavailable
                latestReceiptDirectoryRevision = "unavailable"
                latestReceiptLookupRevision = "unavailable"
                return nil
            }

            var entryCount = 0
            var files = [URL]()
            while let file = enumerator.nextObject() as? URL {
                guard !cancellation() else {
                    diagnostics.transitions[receiptsDirectory.path] = .cancelled
                    return nil
                }
                entryCount += 1
                guard entryCount <= limits.maximumReceiptDirectoryEntries else {
                    return recordReceiptDirectoryBudgetFailure(
                        identity: identity,
                        limit: .directoryEntries,
                        diagnostics: &diagnostics
                    )
                }
                if limits.maximumReceiptDirectoryEnumerationSeconds > 0,
                    monotonicNow() - startedAt
                        > limits.maximumReceiptDirectoryEnumerationSeconds
                {
                    return recordReceiptDirectoryBudgetFailure(
                        identity: identity,
                        limit: .directoryTime,
                        diagnostics: &diagnostics
                    )
                }
                if file.pathExtension == "jsonl" {
                    files.append(file.standardizedFileURL)
                }
            }
            guard !enumerationFailed else {
                receiptDirectoryInventory = nil
                diagnostics.transitions[receiptsDirectory.path] = .unavailable
                latestReceiptDirectoryRevision = "unavailable"
                latestReceiptLookupRevision = "unavailable"
                return nil
            }
            if limits.maximumReceiptDirectoryEnumerationSeconds > 0,
                monotonicNow() - startedAt > limits.maximumReceiptDirectoryEnumerationSeconds
            {
                return recordReceiptDirectoryBudgetFailure(
                    identity: identity,
                    limit: .directoryTime,
                    diagnostics: &diagnostics
                )
            }
            guard uncheckedDirectoryIdentity(at: receiptsDirectory) == identity else {
                receiptDirectoryInventory = nil
                diagnostics.transitions[receiptsDirectory.path] = .unstable
                latestReceiptDirectoryRevision = "unstable"
                latestReceiptLookupRevision = "unstable"
                return nil
            }

            files.sort { $0.lastPathComponent > $1.lastPathComponent }
            let revision = receiptDirectoryRevision(identity: identity, files: files)
            let estimatedBytes = files.reduce(Int64(128)) {
                $0 + 96 + Int64($1.path.utf8.count)
            }
            let inventory = ReceiptDirectoryInventory(
                identity: identity,
                files: files,
                revision: revision,
                estimatedBytes: estimatedBytes
            )
            let existingPaths = Set(files.map(\.path))
            receiptCache = receiptCache.filter { existingPaths.contains($0.key) }
            diagnostics.transitions[receiptsDirectory.path] =
                receiptDirectoryInventory == nil ? .initial : .rewritten
            receiptDirectoryInventory = inventory
            latestReceiptDirectoryRevision = revision
            return inventory
        }

        private func recordReceiptDirectoryBudgetFailure(
            identity: FileIdentity,
            limit: BudgetLimit,
            diagnostics: inout Diagnostics
        ) -> ReceiptDirectoryInventory? {
            receiptDirectoryInventory = nil
            receiptDirectoryBudgetFailure = ReceiptDirectoryBudgetFailure(
                identity: identity,
                limit: limit,
                retryAfter: limit == .directoryTime ? monotonicNow() + 60 : .greatestFiniteMagnitude
            )
            diagnostics.transitions[receiptsDirectory.path] = .budgetExceeded
            diagnostics.budgetExceeded[receiptsDirectory.path] = limit
            latestReceiptDirectoryRevision = receiptDirectoryBudgetRevision(
                identity: identity,
                limit: limit
            )
            latestReceiptLookupRevision = "directory-budget"
            return nil
        }

        private func prioritizedReceiptFiles(in files: [URL], for day: Date) -> [URL] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let targetDay = calendar.startOfDay(for: day)
            let ranked = files.map { file -> (file: URL, distance: Int?) in
                let bytes = Array(file.lastPathComponent.utf8.prefix(10))
                guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else {
                    return (file, nil)
                }
                var digits = [Int]()
                digits.reserveCapacity(8)
                for index in [0, 1, 2, 3, 5, 6, 8, 9] {
                    guard bytes[index] >= 0x30, bytes[index] <= 0x39 else {
                        return (file, nil)
                    }
                    digits.append(Int(bytes[index] - 0x30))
                }
                let components = DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: digits[0] * 1_000 + digits[1] * 100 + digits[2] * 10 + digits[3],
                    month: digits[4] * 10 + digits[5],
                    day: digits[6] * 10 + digits[7]
                )
                guard let sourceDay = calendar.date(from: components),
                    let signedDistance = calendar.dateComponents(
                        [.day],
                        from: targetDay,
                        to: calendar.startOfDay(for: sourceDay)
                    ).day
                else { return (file, nil) }
                return (file, abs(signedDistance))
            }
            return ranked.sorted { lhs, rhs in
                switch (lhs.distance, rhs.distance) {
                case (.some(let left), .some(let right)) where left != right:
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return lhs.file.lastPathComponent > rhs.file.lastPathComponent
                }
            }.map(\.file)
        }

        private func receiptWatchSet(
            files: [URL],
            day: Date,
            contributingPaths: Set<String>,
            examinedFiles: [String: FileIdentity]
        ) -> [String: FileIdentity] {
            var paths = contributingPaths
            if let first = files.first { paths.insert(first.path) }
            if let newest = files.max(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }) {
                paths.insert(newest.path)
            }
            let exactName = dayKey(for: day) + ".receipts.jsonl"
            if let exact = files.first(where: { $0.lastPathComponent == exactName }) {
                paths.insert(exact.path)
            }
            var watched = [String: FileIdentity]()
            for path in paths {
                if let identity = examinedFiles[path]
                    ?? uncheckedFileIdentity(at: URL(fileURLWithPath: path))
                {
                    watched[path] = identity
                }
            }
            return watched
        }

        private func receiptLookupIsCurrent(_ entry: ReceiptLookupCacheEntry) -> Bool {
            entry.watchedFiles.allSatisfy { path, identity in
                uncheckedFileIdentity(at: URL(fileURLWithPath: path)) == identity
            }
        }

        private func cacheReceiptLookup(
            targetFingerprint: String,
            directoryRevision: String,
            matches: Set<UInt64>,
            watchedFiles: [String: FileIdentity],
            lookupRevision: String,
            budgetLimit: BudgetLimit?
        ) {
            guard limits.maximumReceiptLookups > 0 else { return }
            accessSequence &+= 1
            receiptLookupCache[targetFingerprint] = ReceiptLookupCacheEntry(
                directoryRevision: directoryRevision,
                matches: matches,
                watchedFiles: watchedFiles,
                lookupRevision: lookupRevision,
                budgetLimit: budgetLimit,
                estimatedBytes: Int64(matches.count) * 16
                    + watchedFiles.keys.reduce(0) { $0 + 96 + Int64($1.utf8.count) },
                lastAccess: accessSequence
            )
            while receiptLookupCache.count > limits.maximumReceiptLookups {
                guard
                    let oldest = receiptLookupCache.min(by: {
                        $0.value.lastAccess < $1.value.lastAccess
                    })?.key
                else { break }
                receiptLookupCache.removeValue(forKey: oldest)
            }
            trimDerivedCachesToBudget()
        }

        private func receiptDirectoryRevision(identity: FileIdentity, files: [URL]) -> String {
            SHA256Digest.hashHex(
                ([
                    String(identity.device),
                    String(identity.inode),
                    String(identity.size),
                    String(identity.modifiedNanoseconds),
                    String(identity.changedNanoseconds),
                ] + files.map(\.lastPathComponent)).joined(separator: "\n")
            )
        }

        private func receiptDirectoryBudgetRevision(
            identity: FileIdentity,
            limit: BudgetLimit
        ) -> String {
            SHA256Digest.hashHex(
                [
                    "budget",
                    limit.rawValue,
                    String(identity.device),
                    String(identity.inode),
                    String(identity.size),
                    String(identity.modifiedNanoseconds),
                    String(identity.changedNanoseconds),
                ].joined(separator: ":")
            )
        }

        private func receiptLookupRevision(
            targetFingerprint: String,
            directoryRevision: String,
            matches: Set<UInt64>,
            watchedFiles: [String: FileIdentity],
            budgetLimit: BudgetLimit?
        ) -> String {
            let watched = watchedFiles.keys.sorted().map { path -> String in
                guard let identity = watchedFiles[path] else { return path }
                return [
                    path,
                    String(identity.device),
                    String(identity.inode),
                    String(identity.size),
                    String(identity.modifiedNanoseconds),
                    String(identity.changedNanoseconds),
                ].joined(separator: ":")
            }
            return SHA256Digest.hashHex(
                ([
                    targetFingerprint,
                    directoryRevision,
                    budgetLimit?.rawValue ?? "complete",
                    matches.sorted().map(String.init).joined(separator: ","),
                ] + watched).joined(separator: "\n")
            )
        }

        private func estimateSnapshotBytes(_ snapshot: DashboardDaySnapshot) -> Int64 {
            var result = Int64(1_024 + snapshot.timeline.count * 64)
            for session in snapshot.sessions {
                result += estimateSessionBytes(session)
            }
            for usage in snapshot.trackedUsage {
                result += estimateTrackedUsageBytes(usage)
            }
            for usage in snapshot.appUsage {
                result +=
                    64 + estimatedStringBytes(usage.appName)
                    + estimatedStringBytes(usage.bundleIdentifier)
            }
            return result
        }

        private func estimateSessionBytes(_ session: ActivitySession) -> Int64 {
            var result: Int64 = 192
            for value in [
                session.id,
                session.appName,
                session.bundleIdentifier,
                session.windowTitle,
                session.host,
                session.category,
                session.latestMessage,
            ] {
                result += estimatedStringBytes(value)
            }
            for (key, _) in session.kindCounts {
                result += 48 + estimatedStringBytes(key)
            }
            return result
        }

        private func estimateTrackedUsageBytes(_ usage: TrackedUsageItem) -> Int64 {
            var result: Int64 = 128
            for value in [
                usage.id,
                usage.name,
                usage.appName,
                usage.bundleIdentifier,
                usage.host,
                usage.category,
            ] {
                result += estimatedStringBytes(value)
            }
            return result
        }

        private func estimatedStringBytes(_ value: String?) -> Int64 {
            guard let value else { return 0 }
            return 24 + Int64(value.utf8.count)
        }

        private func loadJournal<Decoded: Decodable, Value: Encodable>(
            _ type: Decoded.Type,
            at url: URL,
            cache: inout [String: JournalCacheEntry<Value>],
            maximumFiles: Int,
            reservedRows: Int,
            reservedEstimatedBytes: Int64,
            cancellation: @escaping () -> Bool,
            transform: (Decoded) -> Value?,
            diagnostics: inout Diagnostics
        ) -> [Value]? {
            let path = url.path
            // Keep this mutable so the append path can release its local alias before
            // mutating the Array retained by the cache. Otherwise `var values = prefix`
            // leaves both the dictionary and the local entry owning the same COW buffer,
            // forcing a full-day copy for every tiny journal suffix.
            var previous = cache[path]
            guard let identity = fileIdentity(at: url, diagnostics: &diagnostics) else {
                if diagnostics.transitions[path] == .missing {
                    cache.removeValue(forKey: path)
                    return []
                }
                return previous?.values ?? []
            }

            if var failure = journalBudgetFailures[path], failure.identity == identity {
                accessSequence &+= 1
                failure.lastAccess = accessSequence
                journalBudgetFailures[path] = failure
                diagnostics.transitions[path] = .budgetExceeded
                diagnostics.budgetExceeded[path] = failure.limit
                diagnostics.skippedOverBudgetRevisions += 1
                return previous?.values
            }
            journalBudgetFailures.removeValue(forKey: path)

            accessSequence &+= 1
            let access = accessSequence
            let transition: JournalTransition
            let startOffset: Int64
            let initialRetainedRows: Int
            let initialRetainedBytes: Int64
            let expectedTailFingerprint: String?
            if let previous {
                if previous.identity.device != identity.device || previous.identity.inode != identity.inode {
                    transition = .replaced
                    startOffset = 0
                    initialRetainedRows = 0
                    initialRetainedBytes = 0
                    expectedTailFingerprint = nil
                } else if identity.size < previous.identity.size {
                    transition = .truncated
                    startOffset = 0
                    initialRetainedRows = 0
                    initialRetainedBytes = 0
                    expectedTailFingerprint = nil
                } else if identity.size == previous.identity.size {
                    if identity.modifiedNanoseconds == previous.identity.modifiedNanoseconds,
                        identity.changedNanoseconds == previous.identity.changedNanoseconds
                    {
                        var refreshed = previous
                        refreshed.identity = identity
                        refreshed.lastAccess = access
                        cache[path] = refreshed
                        diagnostics.transitions[path] = .unchanged
                        trimFileCache(&cache, maximumFiles: maximumFiles)
                        return refreshed.values
                    }
                    transition = .rewritten
                    startOffset = 0
                    initialRetainedRows = 0
                    initialRetainedBytes = 0
                    expectedTailFingerprint = nil
                } else {
                    transition = .appended
                    startOffset = previous.offset
                    initialRetainedRows = previous.values.count
                    initialRetainedBytes = previous.estimatedBytes
                    expectedTailFingerprint = previous.tailFingerprint
                }
            } else {
                transition = .initial
                startOffset = 0
                initialRetainedRows = 0
                initialRetainedBytes = 0
                expectedTailFingerprint = nil
            }

            guard !cancellation() else {
                diagnostics.transitions[path] = .cancelled
                return nil
            }
            let maximumRetainedRows = max(0, limits.maximumCachedRows - reservedRows)
            let maximumRetainedBytes = max(
                0,
                limits.maximumCachedEstimatedBytes - reservedEstimatedBytes
            )
            let read:
                (
                    values: [Value],
                    bytesRead: Int64,
                    rowsDecoded: Int,
                    committedOffset: Int64,
                    estimatedBytes: Int64,
                    tailFingerprint: String
                )
            do {
                read = try readRows(
                    type,
                    at: url,
                    expectedIdentity: identity,
                    expectedTailFingerprint: expectedTailFingerprint,
                    fromOffset: startOffset,
                    throughOffset: identity.size,
                    initialRetainedRows: initialRetainedRows,
                    initialRetainedBytes: initialRetainedBytes,
                    maximumRetainedRows: maximumRetainedRows,
                    maximumRetainedBytes: maximumRetainedBytes,
                    cancellation: cancellation,
                    transform: transform
                )
            } catch JournalReadError.cancelled {
                diagnostics.transitions[path] = .cancelled
                return nil
            } catch JournalReadError.unstable {
                diagnostics.transitions[path] = .unstable
                return previous?.values ?? []
            } catch let JournalReadError.budgetExceeded(limit, bytesRead, rowsDecoded) {
                accessSequence &+= 1
                journalBudgetFailures[path] = JournalBudgetFailure(
                    identity: identity,
                    limit: limit,
                    lastAccess: accessSequence
                )
                trimBudgetFailures()
                diagnostics.bytesRead += bytesRead
                diagnostics.rowsDecoded += rowsDecoded
                diagnostics.transitions[path] = .budgetExceeded
                diagnostics.budgetExceeded[path] = limit
                return previous?.values
            } catch {
                diagnostics.transitions[path] = .unavailable
                return previous?.values ?? []
            }

            diagnostics.bytesRead += read.bytesRead
            diagnostics.rowsDecoded += read.rowsDecoded
            diagnostics.transitions[path] = transition
            journalBudgetFailures.removeValue(forKey: path)

            if transition == .appended, cache[path] != nil {
                // Release the only local alias before entering Dictionary's modify
                // accessor. The cached Array can now grow geometrically in place instead
                // of cloning the complete prefix for every append.
                previous = nil
                cache[path]!.values.append(contentsOf: read.values)
                cache[path]!.identity = identity
                cache[path]!.offset = read.committedOffset
                cache[path]!.estimatedBytes += read.estimatedBytes
                cache[path]!.tailFingerprint = read.tailFingerprint
                cache[path]!.lastAccess = access
                diagnostics.appendCacheMutationCount += 1
                let values = cache[path]!.values
                trimFileCache(&cache, maximumFiles: maximumFiles)
                return values
            }

            let values = read.values
            let estimatedBytes = read.estimatedBytes

            if values.count <= limits.maximumCachedRows,
                estimatedBytes <= limits.maximumCachedEstimatedBytes,
                maximumFiles > 0
            {
                cache[path] = JournalCacheEntry(
                    identity: identity,
                    offset: read.committedOffset,
                    values: values,
                    estimatedBytes: estimatedBytes,
                    tailFingerprint: read.tailFingerprint,
                    lastAccess: access
                )
            } else {
                cache.removeValue(forKey: path)
            }
            trimFileCache(&cache, maximumFiles: maximumFiles)
            return values
        }

        private func trimFileCache<Value>(
            _ cache: inout [String: JournalCacheEntry<Value>],
            maximumFiles: Int
        ) {
            while cache.count > maximumFiles {
                guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
                else { break }
                cache.removeValue(forKey: oldest)
            }
        }

        private func trimBudgetFailures() {
            let maximumEntries = max(
                8,
                min(
                    256,
                    (limits.maximumEventFiles + limits.maximumSealFiles
                        + limits.maximumReceiptFiles + limits.maximumDaySnapshots) * 2
                )
            )
            while journalBudgetFailures.count + dayBudgetFailures.count > maximumEntries {
                let oldestJournal = journalBudgetFailures.min {
                    $0.value.lastAccess < $1.value.lastAccess
                }
                let oldestDay = dayBudgetFailures.min {
                    $0.value.lastAccess < $1.value.lastAccess
                }
                let oldestDayAccess = oldestDay?.value.lastAccess ?? UInt64.max
                if let journal = oldestJournal,
                    journal.value.lastAccess <= oldestDayAccess
                {
                    journalBudgetFailures.removeValue(forKey: journal.key)
                } else if let day = oldestDay {
                    dayBudgetFailures.removeValue(forKey: day.key)
                } else {
                    break
                }
            }
        }

        private func trimDerivedCachesToBudget() {
            while cachedDerivedEstimatedByteCount > limits.maximumDerivedEstimatedBytes {
                if let oldestReceiptLookup = receiptLookupCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    receiptLookupCache.removeValue(forKey: oldestReceiptLookup)
                    continue
                }
                if let oldestSnapshot = daySnapshotCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    daySnapshotCache.removeValue(forKey: oldestSnapshot)
                    continue
                }
                break
            }
        }

        private func recordDayBudgetFailure(
            snapshotKey: String,
            revision: String,
            limit: BudgetLimit,
            operation: inout Diagnostics
        ) -> DashboardDaySnapshot? {
            accessSequence &+= 1
            dayBudgetFailures[snapshotKey] = DayBudgetFailure(
                revision: revision,
                limit: limit,
                lastAccess: accessSequence
            )
            trimBudgetFailures()
            operation.transitions["snapshot"] = .budgetExceeded
            operation.budgetExceeded["snapshot"] = limit
            operation.cachedEventFiles = eventCache.count
            operation.cachedSealFiles = sealCache.count
            operation.cachedReceiptFiles = receiptCache.count
            operation.cachedDaySnapshots = daySnapshotCache.count
            operation.cachedRows = cachedRowCount
            operation.cachedEstimatedBytes = cachedEstimatedByteCount
            operation.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
            operation.snapshotState =
                daySnapshotCache[snapshotKey] == nil
                ? .budgetExceeded : .lastKnownGood
            latestDiagnostics = operation
            return daySnapshotCache[snapshotKey].map {
                applyingCachedMetadata(to: $0.snapshot)
            }
        }

        private func hasPartialSource(in diagnostics: Diagnostics) -> Bool {
            diagnostics.transitions.values.contains(.unavailable)
                || diagnostics.transitions.values.contains(.unstable)
        }

        private func recordPartialSource(
            snapshotKey: String,
            operation: inout Diagnostics
        ) -> DashboardDaySnapshot? {
            operation.partialSourcePaths = Set(
                operation.transitions.compactMap { path, transition in
                    transition == .unavailable || transition == .unstable ? path : nil
                }
            )
            operation.cachedEventFiles = eventCache.count
            operation.cachedSealFiles = sealCache.count
            operation.cachedReceiptFiles = receiptCache.count
            operation.cachedDaySnapshots = daySnapshotCache.count
            operation.cachedRows = cachedRowCount
            operation.cachedEstimatedBytes = cachedEstimatedByteCount
            operation.cachedDerivedEstimatedBytes = cachedDerivedEstimatedByteCount
            operation.snapshotState =
                daySnapshotCache[snapshotKey] == nil
                ? .unavailable : .lastKnownGood
            latestDiagnostics = operation
            return daySnapshotCache[snapshotKey].map {
                applyingCachedMetadata(to: $0.snapshot)
            }
        }

        /// Receipts are cheapest to reconstruct and successful lookups are retained
        /// separately, so evict them before seals and the current event journal. This
        /// keeps the high-value append cursor warm while enforcing one hard envelope.
        private func trimJournalCachesToGlobalBudget() {
            while cachedRowCount > limits.maximumCachedRows
                || cachedEstimatedByteCount > limits.maximumCachedEstimatedBytes
            {
                if let oldestReceipt = receiptCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    receiptCache.removeValue(forKey: oldestReceipt)
                    continue
                }
                if let oldestSeal = sealCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    sealCache.removeValue(forKey: oldestSeal)
                    continue
                }
                if let oldestEvent = eventCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    eventCache.removeValue(forKey: oldestEvent)
                    continue
                }
                break
            }
        }

        private func fileIdentity(
            at url: URL,
            diagnostics: inout Diagnostics
        ) -> FileIdentity? {
            var information = stat()
            guard lstat(url.path, &information) == 0 else {
                diagnostics.transitions[url.path] = errno == ENOENT ? .missing : .unavailable
                return nil
            }
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                diagnostics.transitions[url.path] = .unavailable
                return nil
            }
            return identity(from: information)
        }

        private func uncheckedFileIdentity(at url: URL) -> FileIdentity? {
            var information = stat()
            guard lstat(url.path, &information) == 0,
                (information.st_mode & S_IFMT) == S_IFREG
            else { return nil }
            return identity(from: information)
        }

        private func directoryIdentity(
            at url: URL,
            diagnostics: inout Diagnostics
        ) -> FileIdentity? {
            var information = stat()
            guard lstat(url.path, &information) == 0 else {
                diagnostics.transitions[url.path] = errno == ENOENT ? .missing : .unavailable
                return nil
            }
            guard (information.st_mode & S_IFMT) == S_IFDIR else {
                diagnostics.transitions[url.path] = .unavailable
                return nil
            }
            return identity(from: information)
        }

        private func uncheckedDirectoryIdentity(at url: URL) -> FileIdentity? {
            var information = stat()
            guard lstat(url.path, &information) == 0,
                (information.st_mode & S_IFMT) == S_IFDIR
            else { return nil }
            return identity(from: information)
        }

        private func readRows<Decoded: Decodable, Value: Encodable>(
            _ type: Decoded.Type,
            at url: URL,
            expectedIdentity: FileIdentity,
            expectedTailFingerprint: String?,
            fromOffset: Int64,
            throughOffset: Int64,
            initialRetainedRows: Int,
            initialRetainedBytes: Int64,
            maximumRetainedRows: Int,
            maximumRetainedBytes: Int64,
            cancellation: @escaping () -> Bool,
            transform: (Decoded) -> Value?
        ) throws -> (
            values: [Value],
            bytesRead: Int64,
            rowsDecoded: Int,
            committedOffset: Int64,
            estimatedBytes: Int64,
            tailFingerprint: String
        ) {
            guard throughOffset >= fromOffset else { throw JournalReadError.unstable }
            guard !cancellation() else { throw JournalReadError.cancelled }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw JournalReadError.unavailable }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }

            var openedInformation = stat()
            guard fstat(descriptor, &openedInformation) == 0 else {
                throw JournalReadError.unavailable
            }
            let openedIdentity = identity(from: openedInformation)
            guard openedIdentity.device == expectedIdentity.device,
                openedIdentity.inode == expectedIdentity.inode,
                openedIdentity.size >= throughOffset
            else { throw JournalReadError.unstable }
            if openedIdentity.size == expectedIdentity.size,
                openedIdentity.modifiedNanoseconds != expectedIdentity.modifiedNanoseconds
                    || openedIdentity.changedNanoseconds != expectedIdentity.changedNanoseconds
            {
                throw JournalReadError.unstable
            }

            var bytesRead: Int64 = 0
            if let expectedTailFingerprint {
                let prefix = try tailFingerprint(
                    descriptor: descriptor,
                    endingAt: fromOffset
                )
                bytesRead += prefix.bytesRead
                guard prefix.value == expectedTailFingerprint else {
                    throw JournalReadError.unstable
                }
            }
            do {
                try handle.seek(toOffset: UInt64(fromOffset))
            } catch {
                throw JournalReadError.unavailable
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sizingEncoder = JSONEncoder()
            sizingEncoder.dateEncodingStrategy = .iso8601
            var values: [Value] = []
            var pending = Data()
            pending.reserveCapacity(min(limits.readChunkBytes, limits.maximumLineBytes))
            var discardingOversizedLine = false
            var remaining = throughOffset - fromOffset
            var currentOffset = fromOffset
            var committedOffset = fromOffset
            var rowsDecoded = 0
            var estimatedBytes: Int64 = 0

            func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
                guard !discardingOversizedLine else { return }
                guard bytes.count <= limits.maximumLineBytes - pending.count else {
                    discardingOversizedLine = true
                    pending.removeAll(keepingCapacity: false)
                    throw JournalReadError.budgetExceeded(
                        .lineBytes,
                        bytesRead: bytesRead,
                        rowsDecoded: rowsDecoded
                    )
                }
                pending.append(contentsOf: bytes)
            }

            func finishLine() throws {
                defer {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                }
                guard !discardingOversizedLine, !pending.isEmpty else { return }
                rowsDecoded += 1
                let transformed = autoreleasepool { () -> Value? in
                    guard let decoded = try? decoder.decode(type, from: pending) else { return nil }
                    return transform(decoded)
                }
                guard let value = transformed else { return }
                guard initialRetainedRows + values.count < maximumRetainedRows else {
                    throw JournalReadError.budgetExceeded(
                        .retainedRows,
                        bytesRead: bytesRead,
                        rowsDecoded: rowsDecoded
                    )
                }
                let valueBytes = Int64(
                    (try? sizingEncoder.encode(value).count) ?? pending.count
                )
                guard valueBytes <= maximumRetainedBytes - initialRetainedBytes - estimatedBytes
                else {
                    throw JournalReadError.budgetExceeded(
                        .retainedBytes,
                        bytesRead: bytesRead,
                        rowsDecoded: rowsDecoded
                    )
                }
                values.append(value)
                estimatedBytes += valueBytes
            }

            while remaining > 0 {
                guard !cancellation() else { throw JournalReadError.cancelled }
                let requestCount = Int(min(Int64(limits.readChunkBytes), remaining))
                let chunk: Data
                do {
                    guard let next = try handle.read(upToCount: requestCount), !next.isEmpty else {
                        throw JournalReadError.unstable
                    }
                    chunk = next
                } catch let error as JournalReadError {
                    throw error
                } catch {
                    throw JournalReadError.unavailable
                }
                remaining -= Int64(chunk.count)
                bytesRead += Int64(chunk.count)
                let chunkStartOffset = currentOffset
                currentOffset += Int64(chunk.count)
                var segmentStart = chunk.startIndex
                while segmentStart < chunk.endIndex,
                    let newline = chunk[segmentStart...].firstIndex(of: 0x0A)
                {
                    try append(chunk[segmentStart..<newline])
                    try finishLine()
                    committedOffset =
                        chunkStartOffset
                        + Int64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
                    segmentStart = chunk.index(after: newline)
                }
                if segmentStart < chunk.endIndex {
                    try append(chunk[segmentStart..<chunk.endIndex])
                }
            }

            guard !cancellation() else { throw JournalReadError.cancelled }
            afterJournalReadForTesting?(url)
            var finalInformation = stat()
            guard fstat(descriptor, &finalInformation) == 0 else {
                throw JournalReadError.unavailable
            }
            let finalIdentity = identity(from: finalInformation)
            guard finalIdentity.device == expectedIdentity.device,
                finalIdentity.inode == expectedIdentity.inode,
                finalIdentity.size >= throughOffset
            else { throw JournalReadError.unstable }
            if finalIdentity.size == expectedIdentity.size,
                finalIdentity.modifiedNanoseconds != expectedIdentity.modifiedNanoseconds
                    || finalIdentity.changedNanoseconds != expectedIdentity.changedNanoseconds
            {
                throw JournalReadError.unstable
            }
            guard let currentIdentity = uncheckedFileIdentity(at: url),
                currentIdentity.device == expectedIdentity.device,
                currentIdentity.inode == expectedIdentity.inode,
                currentIdentity.size >= throughOffset
            else { throw JournalReadError.unstable }
            if currentIdentity.size == expectedIdentity.size,
                currentIdentity.modifiedNanoseconds != expectedIdentity.modifiedNanoseconds
                    || currentIdentity.changedNanoseconds != expectedIdentity.changedNanoseconds
            {
                throw JournalReadError.unstable
            }
            if let expectedTailFingerprint {
                let prefix = try tailFingerprint(
                    descriptor: descriptor,
                    endingAt: fromOffset
                )
                bytesRead += prefix.bytesRead
                guard prefix.value == expectedTailFingerprint else {
                    throw JournalReadError.unstable
                }
            }
            let tail = try tailFingerprint(
                descriptor: descriptor,
                endingAt: committedOffset
            )
            bytesRead += tail.bytesRead
            return (
                values,
                bytesRead,
                rowsDecoded,
                committedOffset,
                estimatedBytes,
                tail.value
            )
        }

        private func identity(from information: stat) -> FileIdentity {
            FileIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                size: max(0, Int64(information.st_size)),
                modifiedNanoseconds: Int64(information.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(information.st_mtimespec.tv_nsec),
                changedNanoseconds: Int64(information.st_ctimespec.tv_sec) * 1_000_000_000
                    + Int64(information.st_ctimespec.tv_nsec)
            )
        }

        private func tailFingerprint(
            descriptor: Int32,
            endingAt offset: Int64
        ) throws -> (value: String, bytesRead: Int64) {
            let byteCount = Int(min(256, max(0, offset)))
            guard byteCount > 0 else {
                return (SHA256Digest.hashHex(Data()), 0)
            }
            var data = Data(count: byteCount)
            let startOffset = offset - Int64(byteCount)
            let result = data.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return pread(descriptor, baseAddress, byteCount, off_t(startOffset))
            }
            guard result == byteCount else { throw JournalReadError.unstable }
            return (SHA256Digest.hashHex(data), Int64(byteCount))
        }

        private func coverageStates(for seal: LocalMinuteSeal) -> [String] {
            guard let field = seal.minuteFields.first(where: { $0.name == "coverage" }),
                let raw = field.opening.fields["states"]
            else { return [] }
            return raw.split(separator: ",").map(String.init)
        }

        private func buildTrackedUsage(
            from events: [HistoryEvent],
            day: Date,
            budget: inout DerivedBudget
        ) throws -> [TrackedUsageItem] {
            struct Counter {
                var kind: TrackedSubjectKind
                var name: String
                var appName: String?
                var bundleIdentifier: String?
                var host: String?
                var foregroundSeconds: TimeInterval = 0
                var activeMinuteKeys = Set<Int64>()
                var eventCount = 0
                var categories: [String: Int] = [:]
                var identityProofAvailable = true
            }

            var counters: [String: Counter] = [:]
            // `snapshot(for:)` supplies one timestamp-ordered array. Reusing it avoids
            // a second full-size allocation for large current-day journals.
            let ordered = events
            for (index, event) in ordered.enumerated() {
                guard event.kind != .agentArtifactCaptured,
                    event.suppressionReason == nil,
                    let app = event.app
                else { continue }

                let nextTimestamp: Date = {
                    if index + 1 < ordered.count { return ordered[index + 1].timestamp }
                    if Calendar.current.isDateInToday(day) { return Date() }
                    return event.timestamp.addingTimeInterval(60)
                }()
                let observedSeconds = min(75, max(0, nextTimestamp.timeIntervalSince(event.timestamp)))
                let isInput = event.pointer != nil || event.keyboard != nil || event.scroll != nil
                let minute = Self.minuteKey(event.timestamp)
                let category = event.classification?.category

                let appKey = SharingSubjectKey.application(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name
                )
                if counters[appKey] == nil {
                    try budget.reserve(
                        160 + estimatedStringBytes(appKey) + estimatedStringBytes(app.name)
                            + estimatedStringBytes(app.bundleIdentifier)
                    )
                }
                var appCounter =
                    counters[appKey]
                    ?? Counter(
                        kind: .application,
                        name: app.name,
                        appName: nil,
                        bundleIdentifier: app.bundleIdentifier,
                        host: nil
                    )
                appCounter.foregroundSeconds += observedSeconds
                appCounter.eventCount += 1
                if isInput, !appCounter.activeMinuteKeys.contains(minute) {
                    try budget.reserve(16)
                    appCounter.activeMinuteKeys.insert(minute)
                }
                if let category {
                    if appCounter.categories[category] == nil {
                        try budget.reserve(48 + estimatedStringBytes(category))
                    }
                    appCounter.categories[category, default: 0] += 1
                }
                counters[appKey] = appCounter

                guard let rawHost = event.url?.host else { continue }
                let host = SharingSubjectKey.normalizedHost(rawHost)
                guard !host.isEmpty else { continue }
                let siteKey = SharingSubjectKey.website(host: host)
                if counters[siteKey] == nil {
                    try budget.reserve(
                        192 + estimatedStringBytes(siteKey) + estimatedStringBytes(host)
                            + estimatedStringBytes(app.name)
                            + estimatedStringBytes(app.bundleIdentifier)
                    )
                }
                var siteCounter =
                    counters[siteKey]
                    ?? Counter(
                        kind: .website,
                        name: host,
                        appName: app.name,
                        bundleIdentifier: app.bundleIdentifier,
                        host: host
                    )
                siteCounter.foregroundSeconds += observedSeconds
                siteCounter.eventCount += 1
                if isInput, !siteCounter.activeMinuteKeys.contains(minute) {
                    try budget.reserve(16)
                    siteCounter.activeMinuteKeys.insert(minute)
                }
                if let category {
                    if siteCounter.categories[category] == nil {
                        try budget.reserve(48 + estimatedStringBytes(category))
                    }
                    siteCounter.categories[category, default: 0] += 1
                }
                if event.schemaVersion < 3 { siteCounter.identityProofAvailable = false }
                counters[siteKey] = siteCounter
            }

            var result: [TrackedUsageItem] = []
            result.reserveCapacity(counters.count)
            for (key, value) in counters {
                let category = value.categories.max { left, right in
                    if left.value == right.value { return left.key > right.key }
                    return left.value < right.value
                }?.key
                let item = TrackedUsageItem(
                    id: key,
                    kind: value.kind,
                    name: value.name,
                    appName: value.appName,
                    bundleIdentifier: value.bundleIdentifier,
                    host: value.host,
                    category: category,
                    foregroundSeconds: value.foregroundSeconds,
                    activeMinutes: value.activeMinuteKeys.count,
                    eventCount: value.eventCount,
                    identityProofAvailable: value.identityProofAvailable
                )
                guard item.foregroundSeconds > 0 || item.eventCount > 0 else { continue }
                try budget.reserve(estimateTrackedUsageBytes(item))
                result.append(item)
            }
            result.sort {
                if $0.kind != $1.kind { return $0.kind == .application }
                if $0.foregroundSeconds == $1.foregroundSeconds { return $0.name < $1.name }
                return $0.foregroundSeconds > $1.foregroundSeconds
            }
            return result
        }

        private func buildSessions(
            from events: [HistoryEvent],
            budget: inout DerivedBudget
        ) throws -> [ActivitySession] {
            struct Builder {
                let id: String
                var key: String
                var start: Date
                var end: Date
                var appName: String
                var bundleIdentifier: String?
                var windowTitle: String?
                var host: String?
                var category: String?
                var isWork: Bool?
                var confidence: Double?
                var suppressionReason: SuppressionReason?
                var eventCount: Int
                var inputEventCount: Int
                var softwareAttributedEventCount: Int
                var kindCounts: [String: Int]
                var latestMessage: String?

                mutating func add(_ event: HistoryEvent) {
                    end = max(end, event.timestamp)
                    eventCount += 1
                    kindCounts[event.kind.rawValue, default: 0] += 1
                    if event.pointer != nil || event.keyboard != nil || event.scroll != nil {
                        inputEventCount += 1
                    }
                    if event.inputOrigin?.assessment == .softwareAttributed {
                        softwareAttributedEventCount += 1
                    }
                    if let message = event.message, !message.isEmpty { latestMessage = message }
                    if windowTitle == nil { windowTitle = event.window?.title }
                    if host == nil { host = event.url?.host }
                    if category == nil { category = event.classification?.category }
                    if isWork == nil { isWork = event.classification?.isWork }
                    if confidence == nil { confidence = event.classification?.confidence }
                }

                func finish() -> ActivitySession {
                    ActivitySession(
                        id: id,
                        start: start,
                        end: end,
                        appName: appName,
                        bundleIdentifier: bundleIdentifier,
                        windowTitle: windowTitle,
                        host: host,
                        category: category,
                        isWork: isWork,
                        confidence: confidence,
                        suppressionReason: suppressionReason,
                        eventCount: eventCount,
                        inputEventCount: inputEventCount,
                        softwareAttributedEventCount: softwareAttributedEventCount,
                        kindCounts: kindCounts,
                        latestMessage: latestMessage
                    )
                }
            }

            var result: [ActivitySession] = []
            var current: Builder?

            for event in events where Self.isSessionEvent(event) {
                let appName = event.app?.name ?? Self.systemLabel(for: event)
                let bundleIdentifier = event.app?.bundleIdentifier
                let category = event.classification?.category
                let suppression = event.suppressionReason
                let key = Self.sessionSourceKey(for: event)

                let shouldMerge: Bool
                if let current {
                    let gap = event.timestamp.timeIntervalSince(current.end)
                    shouldMerge = current.key == key && gap >= 0 && gap <= 180
                } else {
                    shouldMerge = false
                }

                if shouldMerge {
                    current?.add(event)
                } else {
                    if let current {
                        let session = current.finish()
                        try budget.reserve(estimateSessionBytes(session))
                        result.append(session)
                    }
                    var builder = Builder(
                        id: event.id,
                        key: key,
                        start: event.timestamp,
                        end: event.timestamp,
                        appName: appName,
                        bundleIdentifier: bundleIdentifier,
                        windowTitle: event.window?.title,
                        host: event.url?.host,
                        category: category,
                        isWork: event.classification?.isWork,
                        confidence: event.classification?.confidence,
                        suppressionReason: suppression,
                        eventCount: 0,
                        inputEventCount: 0,
                        softwareAttributedEventCount: 0,
                        kindCounts: [:],
                        latestMessage: nil
                    )
                    builder.add(event)
                    current = builder
                }
            }

            if let current {
                let session = current.finish()
                try budget.reserve(estimateSessionBytes(session))
                result.append(session)
            }
            result.sort { $0.start > $1.start }
            return result
        }

        private func buildTimeline(
            for day: Date,
            activeMinuteKeys: Set<Int64>,
            workMinuteKeys: Set<Int64>,
            privateMinuteKeys: Set<Int64>,
            sealedMinuteKeys: Set<Int64>
        ) -> [TimelineBucket] {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: day)
            let today = calendar.isDateInToday(day)
            let now = Date()

            return (0..<96).map { bucketIndex in
                let start = startOfDay.addingTimeInterval(TimeInterval(bucketIndex * 15 * 60))
                let end = start.addingTimeInterval(15 * 60)
                let keys = (0..<15).map { minute in
                    Self.minuteKey(start.addingTimeInterval(TimeInterval(minute * 60)))
                }
                let active = keys.filter(activeMinuteKeys.contains).count
                let work = keys.filter(workMinuteKeys.contains).count
                let hidden = keys.filter(privateMinuteKeys.contains).count
                let sealed = keys.filter(sealedMinuteKeys.contains).count

                let kind: TimelineBucketKind
                if today && start > now {
                    kind = .future
                } else if active == 0 && hidden == 0 && sealed == 0 {
                    kind = .noData
                } else if hidden > 0 && hidden >= max(active, work) {
                    kind = .privateOrSuppressed
                } else if work > 0 {
                    kind = .work
                } else if active > 0 {
                    kind = .active
                } else {
                    kind = .sealed
                }

                return TimelineBucket(
                    start: start,
                    end: end,
                    kind: kind,
                    activeMinutes: active,
                    workMinutes: work,
                    privateMinutes: hidden,
                    sealedMinutes: sealed
                )
            }
        }

        private func calculateStorageBytes(
            cancellation: @escaping () -> Bool
        ) -> Int64? {
            guard
                let enumerator = fileManager.enumerator(
                    at: rootDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { return 0 }

            var total: Int64 = 0
            for case let url as URL in enumerator {
                guard !cancellation() else { return nil }
                guard
                    let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                    ),
                    values.isSymbolicLink != true,
                    values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }

        private func calculateAvailableDays(
            cancellation: @escaping () -> Bool
        ) -> [Date]? {
            var names = Set<String>()
            for directory in [eventsDirectory, sealsDirectory] {
                guard !cancellation() else { return nil }
                guard
                    let files = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                else { continue }
                for file in files {
                    guard !cancellation() else { return nil }
                    let name = file.lastPathComponent
                    if let match = name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                        names.insert(String(name[match]))
                    }
                }
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return names.compactMap(formatter.date(from:)).sorted(by: >)
        }

        private func dayKey(for date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        private func withCacheLock<T>(_ body: () -> T) -> T {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return body()
        }

        private func withMetadataLock<T>(_ body: () -> T) -> T {
            metadataLock.lock()
            defer { metadataLock.unlock() }
            return body()
        }

        private static func minuteKey(_ date: Date) -> Int64 {
            Int64(floor(date.timeIntervalSince1970 / 60.0))
        }

        /// The dashboard uses only presentation fields. Integrity commitments and
        /// recorder-only context remain authoritative in the source JSONL journal;
        /// dropping them from this transient projection is what keeps a full day
        /// inside the 32 MiB reader envelope without changing dashboard results.
        private static func compactEventForDashboard(_ event: HistoryEvent) -> HistoryEvent? {
            guard event.isDerivedAnalysisEvidence else { return nil }
            return HistoryEvent(
                schemaVersion: event.schemaVersion,
                id: event.id,
                sessionID: "",
                timestamp: event.timestamp,
                kind: event.kind,
                app: event.app.map {
                    AppSnapshot(
                        name: $0.name,
                        bundleIdentifier: $0.bundleIdentifier,
                        processIdentifier: 0
                    )
                },
                window: event.window.map {
                    WindowSnapshot(title: $0.title, role: nil, subrole: nil)
                },
                element: nil,
                url: event.url.map {
                    URLSnapshot(value: "", host: $0.host, redactionApplied: true)
                },
                pointer: event.pointer.map { _ in
                    PointerSnapshot(button: "", x: 0, y: 0, clickCount: 0)
                },
                keyboard: event.keyboard.map { _ in
                    KeyboardSnapshot(category: "", key: nil, modifiers: [], isRepeat: false)
                },
                scroll: event.scroll.map { _ in
                    ScrollSnapshot(deltaX: 0, deltaY: 0, eventCount: 0)
                },
                inputOrigin: event.inputOrigin.map {
                    InputOriginSnapshot(
                        sourceProcessIdentifier: nil,
                        sourceUserIdentifier: nil,
                        sourceStateID: nil,
                        sourceProcessName: nil,
                        sourceBundleIdentifier: nil,
                        assessment: $0.assessment
                    )
                },
                semanticContext: nil,
                classification: event.classification.map {
                    LocalClassification(
                        category: $0.category,
                        isWork: $0.isWork,
                        confidence: $0.confidence,
                        classifierVersion: ""
                    )
                },
                suppressionReason: event.suppressionReason,
                message: event.message,
                metadata: nil,
                integrity: nil
            )
        }

        private static func isActivityEvent(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .applicationActivated, .windowChanged, .urlChanged, .mouseClick,
                .keyboardShortcut, .keyPressed, .typingBurst, .scrollBurst:
                return event.suppressionReason == nil
            default:
                return false
            }
        }

        static func isSessionEvent(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .heartbeat, .focusChanged:
                return false
            default:
                return true
            }
        }

        static func sessionSourceKey(for event: HistoryEvent) -> String {
            let appName = event.app?.name ?? systemLabel(for: event)
            return [
                event.suppressionReason?.rawValue ?? "captured",
                event.app?.bundleIdentifier ?? appName,
                event.window?.title ?? "",
                event.url?.host ?? "",
                event.classification?.category ?? "",
            ].joined(separator: "|")
        }

        static func sessionSourceKey(for session: ActivitySession) -> String {
            [
                session.suppressionReason?.rawValue ?? "captured",
                session.bundleIdentifier ?? session.appName,
                session.windowTitle ?? "",
                session.host ?? "",
                session.category ?? "",
            ].joined(separator: "|")
        }

        private static func systemLabel(for event: HistoryEvent) -> String {
            switch event.kind {
            case .recordingPaused, .recordingResumed: return "Recording control"
            case .permissionStatus: return "Permissions"
            case .sessionLocked, .sessionUnlocked: return "Mac session"
            case .systemSleep, .systemWake: return "Mac power"
            case .historyCleared: return "Local data"
            default: return "Goalong History"
            }
        }
    }
#endif
