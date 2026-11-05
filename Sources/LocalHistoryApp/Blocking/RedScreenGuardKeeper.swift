#if os(macOS)
import Foundation
import GoalongGuardCore

/// What a protected red-screen range asks of the guard (T-048 B4), in the wall frame.
enum RedScreenGuardDemand: Equatable {
    /// At launch, before the red screen has reported: a marker its range left must stay.
    case unknown
    /// The end of the protected ranges in progress; nil when none runs.
    case until(Date?)
}

/// Arms Goalong's guard for a protected red-screen range while the Blocage module is off (no `BlockingController`).
/// Same marker (`guard-until`), same client, same relaunch policy as a severe block. With the module on, the
/// controller writes the marker itself and this keeper is not used.
@MainActor final class RedScreenGuardKeeper {
    /// Same period as the blocking controller's poll during a lock: a deleted marker is rewritten, the guard pinged.
    static let refreshInterval: TimeInterval = 15

    /// An installed copy only (`GoalongGuardGate`): a test runner or a build folder never arms a guard.
    static func standard() -> RedScreenGuardKeeper? {
        guard let client = GoalongGuardClient.standard() else { return nil }
        return RedScreenGuardKeeper(client: client, files: GoalongGuardFiles.standard, runsTimers: true)
    }

    private(set) var client: GoalongGuardClienting?
    private let files: GuardFiles
    private let clock: () -> Date
    private let runsTimers: Bool
    private var memo: Date?? = .none
    private var until: Date?
    private var timer: Timer?

    init(client: GoalongGuardClienting, files: GuardFiles, clock: @escaping () -> Date = Date.init, runsTimers: Bool = false) { // wall: the guard protocol is wall time (spec K §4)
        self.client = client; self.files = files; self.clock = clock; self.runsTimers = runsTimers
        // From now on this process may lower or remove `guard-until`.
        GoalongGuardFiles.reportHealth(files)
    }

    /// Writes the range's end (or removes it), then tells the client: armed exactly while a protected range runs.
    func update(until end: Date?) {
        guard let client else { return }
        let now = clock()
        until = end.flatMap { $0 > now ? $0 : nil }
        let wanted = until.map { GuardFiles.markerEnd($0, now: now) }
        if BlockingController.guardMarkerNeedsWrite(memo: memo, wanted: wanted, files: files, now: now),
           files.writeMarker(until: wanted) { memo = .some(wanted) }
        _ = client.update(severeUntil: wanted)
        schedule()
    }

    /// The module was switched on: its controller takes the client (and the marker) over.
    func adopt() -> GoalongGuardClienting? {
        timer?.invalidate(); timer = nil
        defer { client = nil }
        return client
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard runsTimers, let until else { return }
        let next = min(until, clock().addingTimeInterval(Self.refreshInterval))
        let value = Timer(timeInterval: max(0.05, next.timeIntervalSince(clock())), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.update(until: self.until) }
        }
        value.tolerance = 1
        RunLoop.main.add(value, forMode: .common); timer = value
    }
}
#endif
