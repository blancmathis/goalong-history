#if os(macOS)
import Foundation

/// Main-owned logical FIFO. Suspending an operation suspends its continuation,
/// never the main queue. Discrete inputs remain in the existing bounded ring.
final class AXContinuationQueue {
    private var jobs: [(@escaping () -> Void) -> Void] = []
    private var active = false
    private(set) var rejectedCount = 0
    private let capacity: Int

    init(capacity: Int = 256) { self.capacity = capacity }

    @discardableResult
    func enqueue(_ job: @escaping (@escaping () -> Void) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard jobs.count + (active ? 1 : 0) < capacity else {
            rejectedCount += 1
            return false
        }
        jobs.append(job)
        advance()
        return true
    }

    private func advance() {
        guard !active, !jobs.isEmpty else { return }
        active = true
        let job = jobs.removeFirst()
        var finished = false
        job { [weak self] in
            precondition(Thread.isMainThread)
            guard !finished else { return }
            finished = true
            self?.active = false
            // Yield after publication; the next reducer cannot overtake this one.
            DispatchQueue.main.async { self?.advance() }
        }
    }
}

/// Short, content-free revocation check, also used at the actual worker start.
/// No lock is held while an AX RPC or an append is in progress.
final class AXRequestPermit {
    private let lock = NSLock()
    private var valid = true
    private let validate: () -> Bool
    init(validate: @escaping () -> Bool = { true }) { self.validate = validate }
    var isValid: Bool {
        lock.lock(); let allowed = valid; lock.unlock()
        return allowed && validate()
    }
    func revoke() { lock.lock(); valid = false; lock.unlock() }
}
#endif
