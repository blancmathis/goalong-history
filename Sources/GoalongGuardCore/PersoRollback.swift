import Foundation

/// The relauncher's perso rollback, in an order the tests can see (L1L2-03, L1L2-06):
/// 1. settle any open request still in flight, so a late launch cannot appear after the scan;
/// 2. stop every candidate running from the target and confirm none is left (several empty scans in a row);
/// 3. only then restore the old bundle;
/// 4. a parent still alive keeps its accepted quit: report, then wait for its exit with no deadline;
/// 5. open the old app and confirm a live process that is not the parent (3 tries).
/// The lease covers the gap: it ends once the old app runs, or at once when the parent still lives.
public struct PersoRollback {
    public enum Outcome: Equatable {
        case reopened(Int32)
        case candidateSurvived
        case restoreFailed
        case openFailed
    }

    public var parentPID: Int32
    public var settleOpen: () -> Void = {}
    /// Live pids running from the target's executable (the parent excluded or not: it is filtered here).
    public var candidates: () -> [Int32]
    /// False when the lease could not be written: that candidate is not stopped on this scan (the guard would
    /// reopen it); it is tried again, and after `maximumScans` the rollback gives up (`candidateSurvived`).
    public var holdLease: (Int32) -> Bool
    public var terminate: (Int32) -> Void
    public var isAlive: (Int32) -> Bool
    public var restore: () -> Bool
    public var parentAlive: () -> Bool
    public var endLease: () -> Void
    /// `restored`: the old bundle is back in place.
    public var report: (_ restored: Bool) -> Void
    /// Opens the old app, reusing a running copy; returns its pid once it exists.
    public var open: () -> Int32?
    public var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Empty scans in a row that prove no candidate is left.
    public var quietScans = 3
    public var scanInterval: TimeInterval = 0.1
    /// Scans before giving up on a candidate that does not die.
    public var maximumScans = 100

    public init(parentPID: Int32, candidates: @escaping () -> [Int32], holdLease: @escaping (Int32) -> Bool,
                terminate: @escaping (Int32) -> Void, isAlive: @escaping (Int32) -> Bool, restore: @escaping () -> Bool,
                parentAlive: @escaping () -> Bool, endLease: @escaping () -> Void,
                report: @escaping (_ restored: Bool) -> Void, open: @escaping () -> Int32?) {
        self.parentPID = parentPID; self.candidates = candidates; self.holdLease = holdLease; self.terminate = terminate
        self.isAlive = isAlive; self.restore = restore; self.parentAlive = parentAlive; self.endLease = endLease
        self.report = report; self.open = open
    }

    public func run() -> Outcome {
        settleOpen()
        var quiet = 0, scans = 0
        while quiet < quietScans {
            let live = candidates().filter { $0 != parentPID && isAlive($0) }
            if live.isEmpty {
                quiet += 1
            } else {
                quiet = 0
                // The guard must not reopen the candidate we stop: the lease names it first.
                for pid in live where holdLease(pid) { terminate(pid) }
            }
            scans += 1
            if scans > maximumScans { endLease(); report(false); return .candidateSurvived }
            pause(scanInterval)
        }
        guard restore() else { endLease(); report(false); return .restoreFailed }
        if parentAlive() {
            // Its quit was accepted: when it ends, nothing else would bring Goalong back.
            endLease(); report(true)
            while parentAlive() { pause(0.25) }
            return reopen()
        }
        let outcome = reopen()
        endLease(); report(true)
        return outcome
    }

    private func reopen() -> Outcome {
        for attempt in 0..<3 {
            if let pid = open(), pid != parentPID, isAlive(pid) { return .reopened(pid) }
            if attempt < 2 { pause(1) }
        }
        return .openFailed
    }
}
