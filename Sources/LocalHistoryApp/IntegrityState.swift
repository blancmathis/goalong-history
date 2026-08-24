#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct PersistentIntegrityState: Codable, Equatable {
        var nextEventSequence: UInt64 = 1
        var previousEventHash: String = String(repeating: "0", count: 64)
        var nextAnchorSequence: UInt64 = 1
        var previousAnchorHash: String = String(repeating: "0", count: 64)
    }

    enum IntegrityStateError: LocalizedError {
        case unexpectedEventSequence(expected: UInt64, actual: UInt64)
        case unexpectedAnchorSequence(expected: UInt64, actual: UInt64)
        case eventStateAheadOfJournal(stateNext: UInt64, journalNext: UInt64)
        case anchorStateAheadOfJournal(stateNext: UInt64, journalNext: UInt64)

        var errorDescription: String? {
            switch self {
            case let .unexpectedEventSequence(expected, actual):
                return "Event integrity sequence mismatch: expected \(expected), received \(actual)."
            case let .unexpectedAnchorSequence(expected, actual):
                return "Anchor integrity sequence mismatch: expected \(expected), received \(actual)."
            case let .eventStateAheadOfJournal(stateNext, journalNext):
                return "Event integrity state is ahead of the durable journal (state \(stateNext), journal \(journalNext))."
            case let .anchorStateAheadOfJournal(stateNext, journalNext):
                return "Anchor integrity state is ahead of the durable seal journal (state \(stateNext), journal \(journalNext))."
            }
        }
    }

    /// Keeps the live chain cursor in memory and persists only a cursor known to be
    /// backed by a synchronized JSONL journal. The journals remain the recovery source
    /// of truth if a process exits between a durable append and this small checkpoint.
    final class IntegrityStateStore {
        typealias PersistenceWriter = (Data, URL) throws -> Void

        private let lock = NSLock()
        private let fileURL: URL
        private let persistenceWriter: PersistenceWriter
        private var state: PersistentIntegrityState
        private var checkpointedEventNextSequence: UInt64
        private var checkpointedPreviousEventHash: String
        private var loadedValidCheckpoint: Bool
        private var successfulPersistenceCount = 0

        init(
            fileURL: URL = AppPaths.integrityStateFile,
            prepareStorage: () throws -> Void = { try AppPaths.prepare() },
            persistenceWriter: PersistenceWriter? = nil
        ) {
            self.fileURL = fileURL
            self.persistenceWriter = persistenceWriter ?? Self.persistDurably
            try? prepareStorage()

            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(PersistentIntegrityState.self, from: data),
               Self.isValid(decoded)
            {
                state = decoded
                loadedValidCheckpoint = true
            } else {
                state = PersistentIntegrityState()
                loadedValidCheckpoint = false
            }
            checkpointedEventNextSequence = state.nextEventSequence
            checkpointedPreviousEventHash = state.previousEventHash
        }

        func takeEventPosition() -> (sequence: UInt64, previousHash: String) {
            lock.lock()
            defer { lock.unlock() }
            return (state.nextEventSequence, state.previousEventHash)
        }

        /// Advances only the live cursor. Callers must invoke this strictly after the
        /// complete event line was appended. Persistence is deliberately coalesced with
        /// a successful JSONL synchronization or explicit flush.
        func commitPersistedEvent(sequence: UInt64, eventHash: String) throws {
            lock.lock()
            defer { lock.unlock() }
            guard sequence == state.nextEventSequence else {
                throw IntegrityStateError.unexpectedEventSequence(
                    expected: state.nextEventSequence,
                    actual: sequence
                )
            }
            state.nextEventSequence = sequence &+ 1
            state.previousEventHash = eventHash
        }

        /// Persists the current event position after the raw event journal has reached
        /// its durability barrier. This replaces one atomic state rewrite per event with
        /// one checkpoint per group/flush without allowing state to get ahead of data.
        func checkpointPersistedEvents() throws {
            lock.lock()
            defer { lock.unlock() }
            guard checkpointedEventNextSequence != state.nextEventSequence
                || checkpointedPreviousEventHash != state.previousEventHash
            else { return }
            try persistLocked(state)
            checkpointedEventNextSequence = state.nextEventSequence
            checkpointedPreviousEventHash = state.previousEventHash
            loadedValidCheckpoint = true
        }

        func takeAnchorPosition() -> (sequence: UInt64, previousHash: String) {
            lock.lock()
            defer { lock.unlock() }
            return (state.nextAnchorSequence, state.previousAnchorHash)
        }

        /// The seal line is already synchronized when this is called. Therefore the
        /// in-memory anchor cursor advances even if its redundant checkpoint write fails;
        /// startup recovery from the seal tail prevents reusing the anchor sequence.
        func commitPersistedAnchor(sequence: UInt64, anchorHash: String) throws -> Error? {
            lock.lock()
            defer { lock.unlock() }
            guard sequence == state.nextAnchorSequence else {
                throw IntegrityStateError.unexpectedAnchorSequence(
                    expected: state.nextAnchorSequence,
                    actual: sequence
                )
            }

            state.nextAnchorSequence = sequence &+ 1
            state.previousAnchorHash = anchorHash
            var durableSnapshot = state
            durableSnapshot.nextEventSequence = checkpointedEventNextSequence
            durableSnapshot.previousEventHash = checkpointedPreviousEventHash
            do {
                try persistLocked(durableSnapshot)
                loadedValidCheckpoint = true
                return nil
            } catch {
                return error
            }
        }

        /// Replays a durable event tail when the checkpoint is missing or behind. An
        /// ahead checkpoint is never silently rewound because explicit history deletion
        /// may legitimately remove the latest raw lines.
        @discardableResult
        func reconcilePersistedEventTail(sequence: UInt64, eventHash: String) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let journalNext = sequence &+ 1
            if loadedValidCheckpoint, state.nextEventSequence > journalNext {
                throw IntegrityStateError.eventStateAheadOfJournal(
                    stateNext: state.nextEventSequence,
                    journalNext: journalNext
                )
            }
            guard !loadedValidCheckpoint
                || state.nextEventSequence != journalNext
                || state.previousEventHash != eventHash
            else { return false }

            state.nextEventSequence = journalNext
            state.previousEventHash = eventHash
            checkpointedEventNextSequence = journalNext
            checkpointedPreviousEventHash = eventHash
            try persistLocked(state)
            loadedValidCheckpoint = true
            return true
        }

        /// Mirrors event-tail recovery for a seal durably appended before its checkpoint.
        @discardableResult
        func reconcilePersistedAnchorTail(sequence: UInt64, anchorHash: String) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let journalNext = sequence &+ 1
            if loadedValidCheckpoint, state.nextAnchorSequence > journalNext {
                throw IntegrityStateError.anchorStateAheadOfJournal(
                    stateNext: state.nextAnchorSequence,
                    journalNext: journalNext
                )
            }
            guard !loadedValidCheckpoint
                || state.nextAnchorSequence != journalNext
                || state.previousAnchorHash != anchorHash
            else { return false }

            state.nextAnchorSequence = journalNext
            state.previousAnchorHash = anchorHash
            var durableSnapshot = state
            durableSnapshot.nextEventSequence = checkpointedEventNextSequence
            durableSnapshot.previousEventHash = checkpointedPreviousEventHash
            try persistLocked(durableSnapshot)
            loadedValidCheckpoint = true
            return true
        }

        var snapshot: PersistentIntegrityState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        var persistenceCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return successfulPersistenceCount
        }

        private func persistLocked(_ value: PersistentIntegrityState) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try persistenceWriter(data, fileURL)
            successfulPersistenceCount += 1
        }

        private static func persistDurably(_ data: Data, to fileURL: URL) throws {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )

            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // Make the atomic rename durable as well. Some filesystems do not support
            // fsync on directories; the data-file synchronization above remains required.
            let directoryDescriptor = fileURL.deletingLastPathComponent().path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                _ = Darwin.close(directoryDescriptor)
            }
        }

        private static func isValid(_ state: PersistentIntegrityState) -> Bool {
            state.nextEventSequence > 0
                && state.nextAnchorSequence > 0
                && isSHA256Hex(state.previousEventHash)
                && isSHA256Hex(state.previousAnchorHash)
        }

        private static func isSHA256Hex(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
        }
    }
#endif
