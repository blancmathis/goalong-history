#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore
    import UniformTypeIdentifiers

    final class ShareWindowWorkCoordinator {
        typealias Scheduler = (@escaping () -> Void) -> Void

        private final class Token {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock()
                cancelled = true
                lock.unlock()
            }
        }

        private static let defaultQueue = DispatchQueue(
            label: "ai.goalong.localhistory.share-window-work",
            qos: .userInitiated
        )

        private let lock = NSLock()
        private let schedule: Scheduler
        private let deliver: Scheduler
        private var activeToken: Token?

        init(
            schedule: @escaping Scheduler = { work in defaultQueue.async(execute: work) },
            deliver: @escaping Scheduler = { work in DispatchQueue.main.async(execute: work) }
        ) {
            self.schedule = schedule
            self.deliver = deliver
        }

        @discardableResult
        func start<Output>(
            onStart: () -> Void = {},
            work: @escaping (_ cancellation: @escaping () -> Bool) throws -> Output,
            completion: @escaping (Result<Output, Error>) -> Void
        ) -> Bool {
            let token = replaceActiveToken()
            onStart()
            schedule { [weak self] in
                let result: Result<Output, Error>
                if token.isCancelled {
                    result = .failure(ShareBuildError.cancelled)
                } else {
                    result = Result { try work { token.isCancelled } }
                }
                self?.deliverResult(result, token: token, completion: completion)
            }
            return true
        }

        @discardableResult
        func startAfterChoosingDestination<Output>(
            chooseDestination: () -> URL?,
            onStart: () -> Void = {},
            work: @escaping (URL, _ cancellation: @escaping () -> Bool) throws -> Output,
            completion: @escaping (Result<Output, Error>) -> Void
        ) -> Bool {
            guard let destination = chooseDestination() else { return false }
            return start(
                onStart: onStart,
                work: { cancellation in
                    try work(destination, cancellation)
                },
                completion: completion
            )
        }

        func cancel() {
            lock.lock()
            let token = activeToken
            activeToken = nil
            lock.unlock()
            token?.cancel()
        }

        var hasActiveWork: Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeToken != nil
        }

        private func replaceActiveToken() -> Token {
            let token = Token()
            lock.lock()
            let previous = activeToken
            activeToken = token
            lock.unlock()
            previous?.cancel()
            return token
        }

        private func deliverResult<Output>(
            _ result: Result<Output, Error>,
            token: Token,
            completion: @escaping (Result<Output, Error>) -> Void
        ) {
            deliver { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.activeToken === token else {
                    self.lock.unlock()
                    return
                }
                self.activeToken = nil
                self.lock.unlock()
                completion(result)
            }
        }
    }
#endif
