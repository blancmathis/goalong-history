#if os(macOS)
import AppKit
import Foundation

/// Source of running applications for `RunningApplicationCatalog`. Membership must be cheap
/// (process identifiers only); `application(for:)` reads the properties that may call
/// LaunchServices (name, bundle identifier, launch date, activation policy).
protocol RunningApplicationSource: AnyObject {
    func currentProcessIdentifiers() -> [pid_t]
    func application(for processIdentifier: pid_t) -> ForegroundAXApplication?
    /// Calls `onChange` when the set of running applications changes, and `onActivate` with
    /// the process identifier of a newly activated application.
    func startObserving(onChange: @escaping () -> Void, onActivate: @escaping (pid_t) -> Void)
}

/// Catalogue of running applications kept for the capture path (T-057 §1). Before, every
/// capture built `ForegroundAXApplication` for all of `NSWorkspace.runningApplications` on the
/// main thread: 4 property reads per app, each able to wait on LaunchServices (8–25 s stalls at
/// night). The catalogue reads an application's properties once, when it appears, and again
/// when it is activated or seen frontmost; it drops it when it quits. Same values as a live read.
final class RunningApplicationCatalog {
    static let shared = RunningApplicationCatalog(source: WorkspaceRunningApplicationSource())

    private let source: RunningApplicationSource
    private let lock = NSLock()
    private var entries: [pid_t: ForegroundAXApplication] = [:]
    private var started = false
    private var membershipStale = true

    init(source: RunningApplicationSource) {
        self.source = source
    }

    /// The running applications by process identifier. `frontmost`, read live by the caller,
    /// replaces its cached entry (it is the freshest view of that application).
    func snapshot(frontmost: ForegroundAXApplication? = nil) -> [pid_t: ForegroundAXApplication] {
        startIfNeeded()
        lock.lock()
        let stale = membershipStale
        lock.unlock()
        if stale { reconcileMembership() }
        lock.lock()
        defer { lock.unlock() }
        if let frontmost, !frontmost.isTerminated {
            entries[frontmost.processIdentifier] = frontmost
        }
        return entries
    }

    private func startIfNeeded() {
        lock.lock()
        let shouldStart = !started
        started = true
        lock.unlock()
        guard shouldStart else { return }
        source.startObserving(
            onChange: { [weak self] in self?.markMembershipStale() },
            onActivate: { [weak self] in self?.refresh(processIdentifier: $0) }
        )
    }

    private func markMembershipStale() {
        lock.lock()
        membershipStale = true
        lock.unlock()
    }

    /// Reads properties only for applications that were not known yet.
    private func reconcileMembership() {
        let current = source.currentProcessIdentifiers()
        lock.lock()
        membershipStale = false
        let known = entries
        lock.unlock()
        var next: [pid_t: ForegroundAXApplication] = [:]
        next.reserveCapacity(current.count)
        for pid in current {
            if let existing = known[pid] {
                next[pid] = existing
            } else if let application = source.application(for: pid) {
                next[pid] = application
            }
        }
        lock.lock()
        entries = next
        lock.unlock()
    }

    private func refresh(processIdentifier pid: pid_t) {
        let application = source.application(for: pid)
        lock.lock()
        defer { lock.unlock() }
        if let application, !application.isTerminated {
            entries[pid] = application
        } else {
            entries.removeValue(forKey: pid)
        }
    }
}

/// `NSWorkspace.runningApplications` is KVO-observable and changes only when the main run loop
/// runs: the catalogue is told of launches and quits of every application (not only Dock apps).
final class WorkspaceRunningApplicationSource: RunningApplicationSource {
    private var applicationsByPID: [pid_t: NSRunningApplication] = [:]
    private let lock = NSLock()
    private var membershipObservation: NSKeyValueObservation?
    private var activationObserver: NSObjectProtocol?

    func currentProcessIdentifiers() -> [pid_t] {
        let applications = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(applications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { _, new in new })
        lock.lock()
        applicationsByPID = byPID
        lock.unlock()
        return applications.map(\.processIdentifier)
    }

    func application(for processIdentifier: pid_t) -> ForegroundAXApplication? {
        lock.lock()
        let known = applicationsByPID[processIdentifier]
        lock.unlock()
        return (known ?? NSRunningApplication(processIdentifier: processIdentifier)).map(ForegroundAXApplication.init)
    }

    func startObserving(onChange: @escaping () -> Void, onActivate: @escaping (pid_t) -> Void) {
        membershipObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { _, _ in
            onChange()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            onActivate(application.processIdentifier)
        }
    }
}
#endif
