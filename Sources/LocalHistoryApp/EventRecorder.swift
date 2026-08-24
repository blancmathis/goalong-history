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

        let sessionID = UUID().uuidString
        private let store: JSONLStore
        private let integrityJournal: IntegrityJournal
        private let minuteSealer: MinuteSealer
        private let captureHealth: CaptureHealthStore?
        private let persistenceFailureHandler: ((String, Error) -> Void)?
        private let writerQueueCapacity: Int
        private let isMainThread: () -> Bool
        private let beforePersist: ((HistoryEvent) -> Void)?

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

        init(
            store: JSONLStore,
            integrityJournal: IntegrityJournal,
            minuteSealer: MinuteSealer,
            captureHealth: CaptureHealthStore? = nil,
            persistenceFailureHandler: ((String, Error) -> Void)? = nil,
            writerQueueCapacity: Int = EventRecorder.defaultWriterQueueCapacity,
            isMainThread: @escaping () -> Bool = { Thread.isMainThread },
            beforePersist: ((HistoryEvent) -> Void)? = nil
        ) {
            precondition((2...512).contains(writerQueueCapacity))
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
            timestamp: Date = Date()
        ) -> Bool {
            let base = HistoryEvent(
                schemaVersion: 4,
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
                metadata: metadata,
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
                return recordFromWriterQueue(base)
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

            admitEventLocked(base, completion: completion)
            writerCondition.unlock()
            completion?.wait()
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
                writerQueueCapacity: writerQueueCapacity
            )
        }

        private func recordFromWriterQueue(_ base: HistoryEvent) -> Bool {
            writerCondition.lock()
            guard acceptingEvents else {
                writerCondition.unlock()
                noteFailure(operation: "record", error: EventRecorderPersistenceError.recorderClosed)
                return false
            }
            guard !overflowEpisodeOpen else {
                _ = registerDroppedEventLocked(timestamp: base.timestamp)
                writerCondition.unlock()
                return false
            }
            mutateStatus { acceptedEventCount &+= 1 }
            writerCondition.unlock()
            persist(base, isObservationGap: false)
            return true
        }

        /// Called with `writerCondition` held. One task slot remains reserved for the
        /// continuity marker, so the serial DispatchQueue can never retain more than
        /// `writerQueueCapacity` EventRecorder work items.
        private func admitEventLocked(
            _ base: HistoryEvent,
            completion: DispatchSemaphore?
        ) {
            pendingEventCount += 1
            writerTaskCount += 1
            writerQueueHighWaterMark = max(writerQueueHighWaterMark, writerTaskCount)
            mutateStatus { acceptedEventCount &+= 1 }

            writerQueue.async { [self] in
                defer {
                    finishEventTask()
                    completion?.signal()
                }
                persist(base, isObservationGap: false)
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

        private func persist(_ base: HistoryEvent, isObservationGap: Bool) {
            beforePersist?(base)
            if let writerPoisonReason {
                noteFailure(
                    operation: "append",
                    error: EventRecorderPersistenceError.writerPoisoned(writerPoisonReason)
                )
                return
            }

            let event = integrityJournal.prepare(base)
            let outcome: JSONLAppendOutcome
            do {
                outcome = try store.appendAndWait(event)
            } catch {
                noteFailure(operation: "append", error: error)
                return
            }

            do {
                try integrityJournal.commitPersisted(event)
            } catch {
                // The row exists but the live cursor could not consume it. Continuing
                // would reuse a sequence, so poison this launch and recover from the
                // durable tail on restart.
                writerPoisonReason = error.localizedDescription
                noteFailure(operation: "integrity_commit", error: error)
                return
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

            minuteSealer.receive(event)
            captureHealth?.markRecordedEvent(event.kind, at: event.timestamp)
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

        private func noteFailure(operation: String, error: Error) {
            mutateStatus {
                failureCount &+= 1
                lastFailureOperation = operation
                lastFailureDescription = error.localizedDescription
            }
            Diagnostics.write("Event recorder \(operation) failed: \(error)")
            persistenceFailureHandler?(operation, error)
        }

        private func mutateStatus(_ mutation: () -> Void) {
            statusLock.lock()
            mutation()
            statusLock.unlock()
        }
    }
#endif
