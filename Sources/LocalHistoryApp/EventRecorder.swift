#if os(macOS)
    import Foundation
    import LocalHistoryCore

    struct EventRecorderPersistenceSnapshot: Equatable {
        let acceptedEventCount: UInt64
        let persistedEventCount: UInt64
        let droppedEventCount: UInt64
        let persistedObservationGapCount: UInt64
        let failureCount: UInt64
        let lastFailureOperation: String?
        let lastFailureDescription: String?
        let pendingEventCount: Int
        let writerQueueDepth: Int
        let writerQueueHighWaterMark: Int
        let writerQueueCapacity: Int
        var storageInterruptedSince: Date? = nil
        var storageFailureKind: CaptureStorageFailureKind? = nil
        var storageLostEventCount: UInt64 = 0
        var storageRecoveryCount: UInt64 = 0
    }

    enum EventRecorderPersistenceError: LocalizedError {
        case recorderClosed
        case writerCapacityExceeded(Int)
        case writerPoisoned(String)

        var errorDescription: String? {
            switch self {
            case .recorderClosed:
                return "The event recorder is closed."
            case .writerCapacityExceeded(let capacity):
                return "The event writer reached its bounded capacity of \(capacity) tasks."
            case .writerPoisoned(let reason):
                return "The event writer stopped after an integrity failure: \(reason)"
            }
        }
    }

    /// Serializes the complete integrity transaction:
    /// prepare -> append -> advance live state -> publish to sealer/health.
    /// No downstream observer can acknowledge an event that failed to append.
    final class EventRecorder {
        static let defaultWriterQueueCapacity = 256
        /// Delay before each new attempt after the journal refused a row. The next event
        /// retries at once (a one-off failure costs nothing); a persisting condition such
        /// as a full disk is then retried at most every five minutes, only when an event
        /// arrives.
        static let defaultStorageRetryDelays: [TimeInterval] = [0, 5, 15, 30, 60, 120, 300]

        /// Writer-queue confined: the journal refused rows and appends are suspended.
        private struct StorageInterruption {
            let since: Date
            var kind: CaptureStorageFailureKind
            var failedAttempts = 1
            var nextAttemptAt: Date
            var lostEventCount: UInt64 = 0
            var firstLostAt: Date?
            var lastLostAt: Date?

            mutating func recordLoss(at timestamp: Date) {
                lostEventCount = lostEventCount == .max ? .max : lostEventCount + 1
                firstLostAt = firstLostAt.map { min($0, timestamp) } ?? timestamp
                lastLostAt = lastLostAt.map { max($0, timestamp) } ?? timestamp
            }
        }

        private struct ObservationGap {
            var droppedEventCount: UInt64 = 0
            var firstDroppedAt: Date?
            var lastDroppedAt: Date?

            mutating func record(timestamp: Date) {
                let next = droppedEventCount.addingReportingOverflow(1)
                droppedEventCount = next.overflow ? .max : next.partialValue
                firstDroppedAt = firstDroppedAt.map { min($0, timestamp) } ?? timestamp
                lastDroppedAt = lastDroppedAt.map { max($0, timestamp) } ?? timestamp
            }

            mutating func take() -> ObservationGap? {
                guard droppedEventCount > 0,
                    firstDroppedAt != nil,
                    lastDroppedAt != nil
                else { return nil }
                let snapshot = self
                self = ObservationGap()
                return snapshot
            }
        }

        let sessionID: String
        private let eventIdentifier: () -> String
        private let captureMetrics: ((AXOperationMetric) -> Void)?
        private let captureClock: AXCaptureClock
        private let store: JSONLStore
        private let integrityJournal: IntegrityJournal
        private let minuteSealer: MinuteSealer
        private let captureHealth: CaptureHealthStore?
        private let persistenceFailureHandler: ((String, Error) -> Void)?
        private let writerQueueCapacity: Int
        private let isMainThread: () -> Bool
        private let beforePersist: ((HistoryEvent) -> Void)?
        private let clock: () -> Date
        private let storageRetryDelays: [TimeInterval]
        private var storageInterruption: StorageInterruption?

        private let writerQueue = DispatchQueue(
            label: "ai.goalong.localhistory.event-recorder",
            qos: .utility
        )
        private let writerQueueKey = DispatchSpecificKey<UInt8>()
        private let writerCondition = NSCondition()
        private var acceptingEvents = true
        private var writerTaskCount = 0
        private var pendingEventCount = 0
        private var writerQueueHighWaterMark = 0
        private var overflowEpisodeOpen = false
        private var orderedCommitDepth = 0 // writer-owned
        private var observationGap = ObservationGap()

        private let statusLock = NSLock()
        private var acceptedEventCount: UInt64 = 0
        private var persistedEventCount: UInt64 = 0
        private var droppedEventCount: UInt64 = 0
        private var persistedObservationGapCount: UInt64 = 0
        private var failureCount: UInt64 = 0
        private var lastFailureOperation: String?
        private var lastFailureDescription: String?
        private var writerPoisonReason: String?
        private var publishedStorageInterruption: (since: Date, kind: CaptureStorageFailureKind, lost: UInt64)?
        private var storageRecoveryCount: UInt64 = 0

        init(
            store: JSONLStore,
            integrityJournal: IntegrityJournal,
            minuteSealer: MinuteSealer,
            captureHealth: CaptureHealthStore? = nil,
            persistenceFailureHandler: ((String, Error) -> Void)? = nil,
            writerQueueCapacity: Int = EventRecorder.defaultWriterQueueCapacity,
            isMainThread: @escaping () -> Bool = { Thread.isMainThread },
            beforePersist: ((HistoryEvent) -> Void)? = nil,
            clock: @escaping () -> Date = Date.init,
            storageRetryDelays: [TimeInterval] = EventRecorder.defaultStorageRetryDelays,
            sessionID: String = UUID().uuidString,
            eventIdentifier: @escaping () -> String = { UUID().uuidString },
            captureClock: AXCaptureClock = AXCaptureClock(),
            captureMetrics: ((AXOperationMetric) -> Void)? = nil
        ) {
            precondition((2...512).contains(writerQueueCapacity))
            precondition(!storageRetryDelays.isEmpty)
            self.clock = clock
            self.sessionID = sessionID
            self.eventIdentifier = eventIdentifier
            self.captureClock = captureClock
            self.captureMetrics = captureMetrics
            self.storageRetryDelays = storageRetryDelays
            self.store = store
            self.integrityJournal = integrityJournal
            self.minuteSealer = minuteSealer
            self.captureHealth = captureHealth
            self.persistenceFailureHandler = persistenceFailureHandler
            self.writerQueueCapacity = writerQueueCapacity
            self.isMainThread = isMainThread
            self.beforePersist = beforePersist
            writerQueue.setSpecific(key: writerQueueKey, value: 1)

            // A seal is not allowed to become durable before every raw event already
            // handed to it has crossed the event-journal durability barrier.
            minuteSealer.setDurabilityBarrier { [weak store, weak integrityJournal] in
                guard let store, let integrityJournal else {
                    throw EventRecorderPersistenceError.recorderClosed
                }
                try store.flushAndWait()
                try integrityJournal.checkpointPersistedEvents()
            }

            do {
                if let tail = try store.latestPersistedEvent() {
                    try integrityJournal.reconcilePersistedTail(tail)
                }
            } catch {
                noteFailure(operation: "startup_recovery", error: error)
            }
        }

        @discardableResult
        func record(
            kind: EventKind,
            context: ContextSnapshot? = nil,
            element: ElementSnapshot? = nil,
            pointer: PointerSnapshot? = nil,
            keyboard: KeyboardSnapshot? = nil,
            scroll: ScrollSnapshot? = nil,
            inputOrigin: InputOriginSnapshot? = nil,
            semanticContext: SemanticContextReference? = nil,
            suppressionReason: SuppressionReason? = nil,
            message: String? = nil,
            metadata: [String: String]? = nil,
            timestamp: Date = Date(),
            identifier: String? = nil
        ) -> Bool {
            guard !GoalongGlobalPause.isPaused() else { return false }
            let pauseRevision = context?.globalPauseRevision ?? GoalongGlobalPause.load().revision
            let policyStamp = context?.privacyRevision
                ?? GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).revision
            let usageMetadata = Self.metadataForObservation(context: context, kind: kind,
                timestamp: timestamp, metadata: metadata, inputOrigin: inputOrigin)
            let base = HistoryEvent(
                schemaVersion: 4,
                id: identifier ?? eventIdentifier(),
                sessionID: sessionID,
                timestamp: timestamp,
                kind: kind,
                app: context?.app,
                window: context?.window,
                element: element ?? context?.focusedElement,
                url: context?.url,
                pointer: pointer,
                keyboard: keyboard,
                scroll: scroll,
                inputOrigin: inputOrigin,
                semanticContext: semanticContext,
                classification: LocalClassifier.classify(
                    app: context?.app,
                    url: context?.url,
                    suppressionReason: suppressionReason ?? context?.suppressionReason
                ),
                suppressionReason: suppressionReason ?? context?.suppressionReason,
                message: message,
                metadata: usageMetadata,
                integrity: nil
            )
            let violations = PrivacyBoundaryValidator.violations(in: base)
            guard violations.isEmpty else {
                Diagnostics.write(
                    "Refused unsafe event \(kind.rawValue): " + violations.map(\.rawValue).joined(separator: ",")
                )
                return false
            }

            if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
                return recordFromWriterQueue(base, privacyRevision: policyStamp, globalPauseRevision: pauseRevision)
            }

            let shouldWaitForCapacity = !isMainThread()
            let completion = shouldWaitForCapacity ? DispatchSemaphore(value: 0) : nil
            var overflowStarted = false

            writerCondition.lock()
            if shouldWaitForCapacity {
                while acceptingEvents,
                    overflowEpisodeOpen || writerTaskCount >= writerQueueCapacity - 1
                {
                    writerCondition.wait()
                }
            }
            guard acceptingEvents else {
                writerCondition.unlock()
                noteFailure(operation: "record", error: EventRecorderPersistenceError.recorderClosed)
                return false
            }

            if overflowEpisodeOpen || writerTaskCount >= writerQueueCapacity - 1 {
                overflowStarted = registerDroppedEventLocked(timestamp: timestamp)
                writerCondition.unlock()
                if overflowStarted {
                    noteFailure(
                        operation: "writer_overflow",
                        error: EventRecorderPersistenceError.writerCapacityExceeded(
                            writerQueueCapacity
                        )
                    )
                }
                return false
            }

            admitEventLocked(base, completion: completion, privacyRevision: policyStamp, globalPauseRevision: pauseRevision)
            writerCondition.unlock()
            completion?.wait()
            return true
        }

        static func metadataForObservation(context: ContextSnapshot?, kind: EventKind, timestamp: Date,
                                           metadata: [String: String]?, inputOrigin: InputOriginSnapshot?) -> [String: String]? {
            guard let context, context.suppressionReason == nil,
                  context.focusedElement?.isSecure != true, let observation = context.foregroundUsage else { return metadata }
            let inputKinds: Set<EventKind> = [.mouseClick, .keyPressed, .keyboardShortcut, .typingBurst, .scrollBurst]
            let directInput = inputKinds.contains(kind) && inputOrigin?.assessment != .softwareAttributed
            var result = metadata ?? [:]
            // Expired cached playback must not survive through an older caller's metadata.
            result.removeValue(forKey: ForegroundActivityEvidence.metadataKey)
            result.merge(observation.metadata(at: timestamp, directInput: directInput)) { _, current in current }
            return result
        }

        /// Main reserves the event's FIFO position before a semantic payload write.
        /// The existing bounded writer performs payload + reference together; AX
        /// readers and main never wait for this operation or its capacity.
        @discardableResult
        func performOrderedCommit(timestamp: Date, operation: @escaping (String) -> Void,
                                  completion: @escaping () -> Void) -> Bool {
            precondition(isMainThread())
            let identifier = eventIdentifier()
            writerCondition.lock()
            guard acceptingEvents else { writerCondition.unlock(); return false }
            guard !overflowEpisodeOpen, writerTaskCount < writerQueueCapacity - 1 else {
                let first = registerDroppedEventLocked(timestamp: timestamp)
                writerCondition.unlock()
                if first { noteFailure(operation: "writer_overflow", error: EventRecorderPersistenceError.writerCapacityExceeded(writerQueueCapacity)) }
                return false
            }
            pendingEventCount += 1
            writerTaskCount += 1
            writerQueueHighWaterMark = max(writerQueueHighWaterMark, writerTaskCount)
            writerQueue.async {
                self.orderedCommitDepth += 1
                operation(identifier)
                self.orderedCommitDepth -= 1
                self.finishEventTask()
                DispatchQueue.main.async { completion() }
            }
            writerCondition.unlock()
            return true
        }

        func flush() {
            do {
                try flushAndWait()
            } catch {
                noteFailure(operation: "flush", error: error)
            }
        }

        func flushAndWait() throws {
            try onWriterQueue {
                try self.store.flushAndWait()
                try self.integrityJournal.checkpointPersistedEvents()
            }
        }

        func close() {
            do {
                try closeAndWait()
            } catch {
                noteFailure(operation: "close", error: error)
            }
        }

        func closeAndWait() throws {
            writerCondition.lock()
            acceptingEvents = false
            writerCondition.broadcast()
            writerCondition.unlock()
            try onWriterQueue {
                try self.store.closeAndWait()
                try self.integrityJournal.checkpointPersistedEvents()
            }
        }

        var persistenceSnapshot: EventRecorderPersistenceSnapshot {
            writerCondition.lock()
            let pendingEventCount = pendingEventCount
            let writerQueueDepth = writerTaskCount
            let writerQueueHighWaterMark = writerQueueHighWaterMark
            writerCondition.unlock()

            statusLock.lock()
            defer { statusLock.unlock() }
            return EventRecorderPersistenceSnapshot(
                acceptedEventCount: acceptedEventCount,
                persistedEventCount: persistedEventCount,
                droppedEventCount: droppedEventCount,
                persistedObservationGapCount: persistedObservationGapCount,
                failureCount: failureCount,
                lastFailureOperation: lastFailureOperation,
                lastFailureDescription: lastFailureDescription,
                pendingEventCount: pendingEventCount,
                writerQueueDepth: writerQueueDepth,
                writerQueueHighWaterMark: writerQueueHighWaterMark,
                writerQueueCapacity: writerQueueCapacity,
                storageInterruptedSince: publishedStorageInterruption?.since,
                storageFailureKind: publishedStorageInterruption?.kind,
                storageLostEventCount: publishedStorageInterruption?.lost ?? 0,
                storageRecoveryCount: storageRecoveryCount
            )
        }

        private func recordFromWriterQueue(_ base: HistoryEvent, privacyRevision: String, globalPauseRevision: String) -> Bool {
            writerCondition.lock()
            guard acceptingEvents || orderedCommitDepth > 0 else {
                writerCondition.unlock()
                noteFailure(operation: "record", error: EventRecorderPersistenceError.recorderClosed)
                return false
            }
            guard !overflowEpisodeOpen || orderedCommitDepth > 0 else {
                _ = registerDroppedEventLocked(timestamp: base.timestamp)
                writerCondition.unlock()
                return false
            }
            mutateStatus { acceptedEventCount &+= 1 }
            writerCondition.unlock()
            // This path already owns the writer: report the persistence result,
            // so semantic deduplication is never promoted for a failed append.
            return persist(base, isObservationGap: false, privacyRevision: privacyRevision, globalPauseRevision: globalPauseRevision)
        }

        /// Called with `writerCondition` held. One task slot remains reserved for the
        /// continuity marker, so the serial DispatchQueue can never retain more than
        /// `writerQueueCapacity` EventRecorder work items.
        private func admitEventLocked(
            _ base: HistoryEvent,
            completion: DispatchSemaphore?,
            privacyRevision: String,
            globalPauseRevision: String
        ) {
            pendingEventCount += 1
            writerTaskCount += 1
            writerQueueHighWaterMark = max(writerQueueHighWaterMark, writerTaskCount)
            mutateStatus { acceptedEventCount &+= 1 }

            let admittedAt = captureMetrics.map { _ in captureClock.uptime() }
            writerQueue.async { [self] in
                defer {
                    finishEventTask()
                    completion?.signal()
                }
                if let admittedAt {
                    captureMetrics?(AXOperationMetric(requestID: base.id, stage: .waiting, operation: "writer",
                        duration: max(0, captureClock.uptime() - admittedAt), onMain: Thread.isMainThread, error: 0))
                }
                persist(base, isObservationGap: false, privacyRevision: privacyRevision, globalPauseRevision: globalPauseRevision)
            }
        }

        /// Called with `writerCondition` held. The first loss closes normal admission
        /// and appends exactly one reserved marker behind every previously admitted event.
        /// Further losses retain only count/time bounds until that marker starts.
        private func registerDroppedEventLocked(timestamp: Date) -> Bool {
            observationGap.record(timestamp: timestamp)
            mutateStatus {
                let next = droppedEventCount.addingReportingOverflow(1)
                droppedEventCount = next.overflow ? .max : next.partialValue
            }
            guard !overflowEpisodeOpen else { return false }

            overflowEpisodeOpen = true
            writerTaskCount += 1
            writerQueueHighWaterMark = max(writerQueueHighWaterMark, writerTaskCount)
            writerQueue.async { [self] in persistObservationGap() }
            return true
        }

        private func persistObservationGap() {
            writerCondition.lock()
            let gap = observationGap.take()
            // This task is now at the head of the serial queue. Re-open admission before
            // writing it: new events enqueue behind this marker, preserving chronology.
            overflowEpisodeOpen = false
            writerCondition.broadcast()
            writerCondition.unlock()

            if let gap {
                let event = HistoryEvent(
                    schemaVersion: 4,
                    sessionID: sessionID,
                    timestamp: gap.lastDroppedAt ?? Date(),
                    kind: .recorderHealth,
                    message: "Event persistence observation gap",
                    metadata: [
                        "observation_gap": "true",
                        "gap_reason": "writer_queue_capacity",
                        "dropped_event_count": String(gap.droppedEventCount),
                        "gap_first_unix_ms": Self.unixMilliseconds(gap.firstDroppedAt),
                        "gap_last_unix_ms": Self.unixMilliseconds(gap.lastDroppedAt),
                        "writer_queue_capacity": String(writerQueueCapacity),
                    ]
                )
                persist(event, isObservationGap: true)
            }

            writerCondition.lock()
            writerTaskCount -= 1
            writerCondition.broadcast()
            writerCondition.unlock()
        }

        private func finishEventTask() {
            writerCondition.lock()
            pendingEventCount -= 1
            writerTaskCount -= 1
            writerCondition.broadcast()
            writerCondition.unlock()
        }

        @discardableResult
        private func persist(
            _ base: HistoryEvent,
            isObservationGap: Bool,
            privacyRevision: String? = nil,
            globalPauseRevision: String? = nil,
            isStorageGap: Bool = false
        ) -> Bool {
            guard let captureMetrics else {
                return persistTransaction(base, isObservationGap: isObservationGap, privacyRevision: privacyRevision,
                                          globalPauseRevision: globalPauseRevision, isStorageGap: isStorageGap)
            }
            let start = captureClock.uptime()
            let outcome = persistTransaction(base, isObservationGap: isObservationGap, privacyRevision: privacyRevision,
                                             globalPauseRevision: globalPauseRevision, isStorageGap: isStorageGap)
            captureMetrics(AXOperationMetric(requestID: base.id, stage: .commit, operation: "writer",
                duration: max(0, captureClock.uptime() - start), onMain: Thread.isMainThread, error: outcome ? 0 : 1))
            return outcome
        }

        private func persistTransaction(
            _ base: HistoryEvent, isObservationGap: Bool, privacyRevision: String?,
            globalPauseRevision: String?, isStorageGap: Bool
        ) -> Bool {
            guard !GoalongGlobalPause.isPaused() else { return false }
            beforePersist?(base)
            guard !GoalongGlobalPause.isPaused() else { return false }
            if let globalPauseRevision {
                do { try GoalongGlobalPause.revalidate(globalPauseRevision) } catch {
                    SupportDiagnostics.shared.failure(error, component: .capture)
                return false }
            }
            if let writerPoisonReason {
                noteFailure(
                    operation: "append",
                    error: EventRecorderPersistenceError.writerPoisoned(writerPoisonReason)
                )
                return false
            }
            guard isStorageGap || resumeStorageIfPossible(before: base.timestamp) else {
                storageInterruption?.recordLoss(at: base.timestamp)
                publishStorageInterruption()
                return false
            }

            let privacy = GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory)
            let protected = privacy.eventForPersistence(base, expectedRevision: privacyRevision)
            let event = integrityJournal.prepare(protected)
            let outcome: JSONLAppendOutcome
            do {
                outcome = try store.appendAndWait(event)
            } catch {
                // The gap marker describes lost events; it is not one of them.
                handleStorageFailure(error, lostEventAt: isStorageGap ? nil : base.timestamp)
                return false
            }

            do {
                try integrityJournal.commitPersisted(event)
            } catch {
                // The row exists but the live cursor could not consume it. Continuing
                // would reuse a sequence, so poison this launch and recover from the
                // durable tail on restart.
                writerPoisonReason = error.localizedDescription
                noteFailure(operation: "integrity_commit", error: error)
                return false
            }

            mutateStatus {
                if isObservationGap {
                    persistedObservationGapCount &+= 1
                } else {
                    persistedEventCount &+= 1
                }
            }
            if let error = outcome.synchronizationError {
                noteFailure(operation: "journal_synchronize", error: error)
            } else if outcome.didSynchronize {
                do {
                    try integrityJournal.checkpointPersistedEvents()
                } catch {
                    // The JSONL journal is already synchronized. Tail recovery can
                    // rebuild this redundant checkpoint on the next launch.
                    noteFailure(operation: "state_checkpoint", error: error)
                }
            }

            JevIngress.shared.receive(event)
            minuteSealer.receive(event)
            captureHealth?.markRecordedEvent(event.kind, at: event.timestamp)
            return true
        }

        /// Returns true when appends may proceed. While the journal is refusing rows,
        /// events are counted rather than retried one by one; at the next due attempt the
        /// durable tail is reconciled in-process (what a restart used to do), the gap is
        /// recorded, and normal writing resumes without any user action.
        private func resumeStorageIfPossible(before eventTimestamp: Date) -> Bool {
            guard var interruption = storageInterruption else { return true }
            let now = clock()
            guard now >= interruption.nextAttemptAt else { return false }
            var uncertainRowWasComplete = false
            do {
                try store.recoverAfterUncertainWrite { [integrityJournal] tail in
                    guard let tail else { return }
                    do {
                        // True when the row that reported an error was in fact fully written.
                        uncertainRowWasComplete = try integrityJournal.reconcilePersistedTail(tail)
                    } catch IntegrityStateError.eventStateAheadOfJournal {
                        // Explicit deletion can remove the newest rows. Launch keeps the
                        // live cursor in this case; so does in-process recovery.
                    }
                }
            } catch {
                handleStorageFailure(error, lostEventAt: nil)
                return false
            }
            if uncertainRowWasComplete, interruption.lostEventCount > 0 {
                interruption.lostEventCount -= 1
                storageInterruption = interruption
            }

            // Dated like writer-overflow gaps: at the last lost observation, so the marker
            // sits in the same day journal as the events it accounts for.
            let gap = HistoryEvent(
                schemaVersion: 4,
                sessionID: sessionID,
                timestamp: interruption.lastLostAt ?? eventTimestamp,
                kind: .recorderHealth,
                message: "Event persistence observation gap",
                metadata: [
                    "observation_gap": "true",
                    "gap_reason": "storage_unavailable",
                    "storage_failure": interruption.kind.rawValue,
                    "dropped_event_count": String(interruption.lostEventCount),
                    "gap_first_unix_ms": Self.unixMilliseconds(interruption.firstLostAt ?? interruption.since),
                    "gap_last_unix_ms": Self.unixMilliseconds(interruption.lastLostAt ?? eventTimestamp),
                    "interrupted_since_unix_ms": Self.unixMilliseconds(interruption.since),
                ]
            )
            guard persist(gap, isObservationGap: true, isStorageGap: true) else { return false }

            storageInterruption = nil
            mutateStatus {
                storageRecoveryCount &+= 1
                publishedStorageInterruption = nil
            }
            captureHealth?.markStorageRestored()
            SupportDiagnostics.shared.record(.storageRecovered, component: .capture, values: [
                .lostEvents: .count(Int(clamping: interruption.lostEventCount)),
                .attempt: .count(interruption.failedAttempts),
                .durationMS: .number(max(0, now.timeIntervalSince(interruption.since)) * 1_000),
            ])
            return true
        }

        private func handleStorageFailure(_ error: Error, lostEventAt timestamp: Date?) {
            let kind = StorageHealth.failureKind(for: error)
            let now = clock()
            if var interruption = storageInterruption {
                interruption.kind = kind
                interruption.failedAttempts += 1
                let delay = storageRetryDelays[min(interruption.failedAttempts - 1, storageRetryDelays.count - 1)]
                interruption.nextAttemptAt = now.addingTimeInterval(delay)
                if let timestamp { interruption.recordLoss(at: timestamp) }
                storageInterruption = interruption
                SupportDiagnostics.shared.record(.storageRetryFailed, component: .capture, level: .warning,
                    values: SupportDiagnostics.errorValues(error).merging([
                        .attempt: .count(interruption.failedAttempts),
                        .state: .state(SupportState(rawValue: kind.rawValue) ?? .unavailable),
                    ]) { _, new in new })
            } else {
                var interruption = StorageInterruption(
                    since: now,
                    kind: kind,
                    nextAttemptAt: now.addingTimeInterval(storageRetryDelays[0])
                )
                if let timestamp { interruption.recordLoss(at: timestamp) }
                storageInterruption = interruption
                var values = SupportDiagnostics.errorValues(error)
                values[.state] = .state(SupportState(rawValue: kind.rawValue) ?? .unavailable)
                if let free = StorageHealth.availableBytes() { values[.freeSpaceMB] = .count(Int(free / 1_048_576)) }
                SupportDiagnostics.shared.record(.storageInterrupted, component: .capture, level: .error, values: values)
                noteFailure(operation: "append", error: error, reportToSupport: false)
            }
            publishStorageInterruption()
        }

        private func publishStorageInterruption() {
            guard let interruption = storageInterruption else { return }
            let changedKind = publishedStorageInterruption?.kind != interruption.kind
            mutateStatus {
                publishedStorageInterruption = (interruption.since, interruption.kind, interruption.lostEventCount)
            }
            if changedKind { captureHealth?.markStorageInterrupted(interruption.kind, at: interruption.since) }
        }

        private static func unixMilliseconds(_ date: Date?) -> String {
            guard let date else { return "0" }
            return String(Int64(date.timeIntervalSince1970 * 1_000))
        }

        private func onWriterQueue(_ operation: () throws -> Void) throws {
            if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
                try operation()
            } else {
                try writerQueue.sync(execute: operation)
            }
        }

        private func noteFailure(
            operation: String,
            error: Error,
            reportToSupport: Bool = true,
            file: StaticString = #fileID,
            line: UInt = #line
        ) {
            if reportToSupport {
                SupportDiagnostics.shared.failure(error, component: .capture, file: file, line: line)
            }
            mutateStatus {
                failureCount &+= 1
                lastFailureOperation = operation
                lastFailureDescription = error.localizedDescription
            }
            persistenceFailureHandler?(operation, error)
        }

        private func mutateStatus(_ mutation: () -> Void) {
            statusLock.lock()
            mutation()
            statusLock.unlock()
        }
    }
#endif
