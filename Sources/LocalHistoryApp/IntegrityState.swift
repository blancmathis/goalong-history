#if os(macOS)
    import Foundation
    import LocalHistoryCore

    struct PersistentIntegrityState: Codable {
        var nextEventSequence: UInt64 = 1
        var previousEventHash: String = String(repeating: "0", count: 64)
        var nextAnchorSequence: UInt64 = 1
        var previousAnchorHash: String = String(repeating: "0", count: 64)
    }

    final class IntegrityStateStore {
        private let lock = NSLock()
        private var state: PersistentIntegrityState

        init() {
            if let data = try? Data(contentsOf: AppPaths.integrityStateFile),
               let decoded = try? JSONDecoder().decode(PersistentIntegrityState.self, from: data)
            {
                state = decoded
            } else {
                state = PersistentIntegrityState()
            }
        }

        func takeEventPosition() -> (sequence: UInt64, previousHash: String) {
            lock.lock()
            defer { lock.unlock() }
            return (state.nextEventSequence, state.previousEventHash)
        }

        func commitEvent(sequence: UInt64, eventHash: String) {
            lock.lock()
            defer { lock.unlock() }
            guard sequence == state.nextEventSequence else { return }
            state.nextEventSequence &+= 1
            state.previousEventHash = eventHash
            persistLocked()
        }

        func takeAnchorPosition() -> (sequence: UInt64, previousHash: String) {
            lock.lock()
            defer { lock.unlock() }
            return (state.nextAnchorSequence, state.previousAnchorHash)
        }

        func commitAnchor(sequence: UInt64, anchorHash: String) {
            lock.lock()
            defer { lock.unlock() }
            guard sequence == state.nextAnchorSequence else { return }
            state.nextAnchorSequence &+= 1
            state.previousAnchorHash = anchorHash
            persistLocked()
        }

        private func persistLocked() {
            do {
                try AppPaths.prepare()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                let data = try encoder.encode(state)
                try data.write(to: AppPaths.integrityStateFile, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.integrityStateFile.path)
            } catch {
                Diagnostics.write("Failed to persist integrity state: \(error)")
            }
        }
    }
#endif
