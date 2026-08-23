#if os(macOS)
    import Foundation
    import LocalHistoryCore

    /// Small UI-to-recorder bridge. The AppDelegate installs the only executor so every
    /// deletion first pauses capture, flushes pending bursts and closes the event file.
    /// Views never mutate history files directly.
    final class HistoryDeletionBridge {
        static let shared = HistoryDeletionBridge()

        private let lock = NSLock()
        private var executor: ((
            HistoryDeletionRequest,
            @escaping (Result<HistoryDeletionOutcome, Error>) -> Void
        ) -> Void)?

        private init() {}

        func install(
            _ executor: @escaping (
                HistoryDeletionRequest,
                @escaping (Result<HistoryDeletionOutcome, Error>) -> Void
            ) -> Void
        ) {
            lock.lock()
            self.executor = executor
            lock.unlock()
        }

        func execute(
            _ request: HistoryDeletionRequest,
            completion: @escaping (Result<HistoryDeletionOutcome, Error>) -> Void
        ) {
            lock.lock()
            let executor = self.executor
            lock.unlock()
            guard let executor else {
                completion(.failure(HistoryDeletionBridgeError.executorUnavailable))
                return
            }
            executor(request, completion)
        }
    }

    enum HistoryDeletionBridgeError: Error, LocalizedError {
        case executorUnavailable

        var errorDescription: String? {
            "The recorder is not ready to perform a coordinated history deletion."
        }
    }
#endif
