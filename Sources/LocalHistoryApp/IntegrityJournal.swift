#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import Security

    final class IntegrityJournal {
        private let stateStore: IntegrityStateStore
        private let encoder: JSONEncoder
        private let lock = NSLock()

        init(stateStore: IntegrityStateStore) {
            self.stateStore = stateStore
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }

        /// Builds a chained event without advancing the cursor. The recorder calls
        /// `commitPersisted` only after the complete JSONL row has been written.
        func prepare(_ baseEvent: HistoryEvent) -> HistoryEvent {
            lock.lock()
            defer { lock.unlock() }

            let position = stateStore.takeEventPosition()
            let classification = baseEvent.classification ?? LocalClassifier.classify(
                app: baseEvent.app,
                url: baseEvent.url,
                suppressionReason: baseEvent.suppressionReason
            )
            let event = HistoryEvent(
                schemaVersion: max(5, baseEvent.schemaVersion),
                id: baseEvent.id,
                sessionID: baseEvent.sessionID,
                timestamp: baseEvent.timestamp,
                kind: baseEvent.kind,
                app: baseEvent.app,
                window: baseEvent.window,
                element: baseEvent.element,
                url: baseEvent.url,
                pointer: baseEvent.pointer,
                keyboard: baseEvent.keyboard,
                scroll: baseEvent.scroll,
                inputOrigin: baseEvent.inputOrigin,
                semanticContext: baseEvent.semanticContext,
                classification: classification,
                suppressionReason: baseEvent.suppressionReason,
                message: baseEvent.message,
                metadata: baseEvent.metadata,
                integrity: nil
            )

            let fieldOrder = IntegrityDomains.eventFieldOrder(for: event.schemaVersion)
            let rawEventDigest = (try? encoder.encode(event.replacingIntegrity(nil)))
                .map(SHA256Digest.hashHex) ?? "encoding-error"
            let fields = EventIntegrityMaterial.makeFieldCommitments(
                for: event,
                salts: fieldOrder.map { _ in Self.randomBytes(count: 32) },
                rawEventDigest: rawEventDigest
            )
            let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.commitmentHex) })
            let leaves = fieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            let eventRoot = MerkleTree.root(labeledHexValues: leaves)
            let eventHash = ChainHash.event(
                sequence: position.sequence,
                previous: position.previousHash,
                eventRoot: eventRoot
            )
            let integrity = EventIntegrity(
                sequence: position.sequence,
                previousEventHash: position.previousHash,
                eventRoot: eventRoot,
                eventHash: eventHash,
                fieldCommitments: fields,
                storageFormat: .compactSalts
            )
            return event.replacingIntegrity(integrity)
        }

        func commitPersisted(_ event: HistoryEvent) throws {
            guard let integrity = event.integrity else {
                throw IntegrityJournalError.missingIntegrity
            }
            try stateStore.commitPersistedEvent(
                sequence: integrity.sequence,
                eventHash: integrity.eventHash
            )
        }

        func checkpointPersistedEvents() throws {
            try stateStore.checkpointPersistedEvents()
        }

        @discardableResult
        func reconcilePersistedTail(_ event: HistoryEvent) throws -> Bool {
            guard let integrity = event.integrity else {
                throw IntegrityJournalError.missingIntegrity
            }
            return try stateStore.reconcilePersistedEventTail(
                sequence: integrity.sequence,
                eventHash: integrity.eventHash
            )
        }

        private static func randomBytes(count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            if status == errSecSuccess { return Data(bytes) }
            // This branch is only a last-resort failure mode. It is recorded diagnostically.
            Diagnostics.write("SecRandomCopyBytes failed with status \(status)")
            return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
        }

    }

    private enum IntegrityJournalError: LocalizedError {
        case missingIntegrity

        var errorDescription: String? {
            "A persisted history event is missing its integrity envelope."
        }
    }
#endif
