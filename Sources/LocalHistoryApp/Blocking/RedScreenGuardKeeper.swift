#if os(macOS)
import Foundation
import GoalongGuardCore

/// What a protected red-screen range asks of the guard (T-048 B4), in the wall frame.
enum RedScreenGuardDemand: Equatable {
    /// At launch, before the red screen has reported: a marker its range left must stay.
    case unknown
    /// The end of the protected ranges in progress (nil when none runs) and the strongest of their stop rules.
    case until(Date?, lock: BlockLock = .locked)
}

/// The one « protégé » predicate (T-048 B5): a severe block (locked or password, started) or a protected red-screen
/// range is running. The guard's arming, « Quitter » and SIGTERM all read it; nothing else decides it.
enum GoalongProtection {
    /// End of the protection, nil when nothing is protected. `redScreen` counts only when given.
    static func until(severe: Date?, redScreen: Date?, now: Date) -> Date? {
        [severe, redScreen].compactMap { $0 }.filter { $0 > now }.max()
    }

    /// What « Quitter » asks during a protection: the same rule for a block and a protected range.
    enum Quit: Equatable {
        case allowed
        /// A locked block, a locked program, a freeze or a locked range: Goalong stays open until the end.
        case locked(redScreen: Bool)
        /// A « Difficile » range: its text is typed on Garde-fous › Écran rouge, then Goalong may quit.
        case redScreenPage
        /// A password block or range: the blocking password approves this quit (the guard then lets it go).
        case password
    }
    /// Launch, before the red screen reports: a future `guard-until` later than the blocks' own end was left by a
    /// protected range. « Quitter » and SIGTERM hold it as a locked range, module Blocage on or off (T-048 B6).
    /// Wall frame; the marker is whole seconds rounded up, hence the second of margin over `severe`.
    static func kept(_ marker: GuardMarker?, now: Date, severe: Date?) -> Date? {
        guard case .date(let kept)? = marker, kept > now, kept > (severe ?? .distantPast).addingTimeInterval(1) else { return nil }
        return kept
    }

    static func quit(blocksLocked: Bool, blocksPassword: Bool, redScreenLock: BlockLock?) -> Quit {
        if blocksLocked { return .locked(redScreen: false) }
        switch redScreenLock {
        case .locked?: return .locked(redScreen: true)
        case .typing?: return .redScreenPage
        case .password?: return .password
        case .free?, nil: return blocksPassword ? .password : .allowed
        }
    }
}

/// Arms Goalong's guard for a protected red-screen range while the Blocage module is off (no `BlockingController`),
/// and holds the guard client for the reopening after a forced quit (T-059 lot 5) in that case.
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
    /// The module was switched off during a protected range: the controller's client carries on here (one client).
    static func standard(client: GoalongGuardClienting) -> RedScreenGuardKeeper? {
        guard GoalongGuardGate.isAllowed else { return nil }
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

    /// Writes the range's end (or removes it), then tells the client: armed exactly while a protected range runs and
    /// the member accepted `GuardConsent.text` (without it the range runs without a guard, T-048 B5).
    func update(until end: Date?) {
        guard let client else { return }
        let now = clock()
        until = client.hasConsent ? GoalongProtection.until(severe: nil, redScreen: end, now: now) : nil
        let wanted = until.map { GuardFiles.markerEnd($0, now: now) }
        if BlockingController.guardMarkerNeedsWrite(memo: memo, wanted: wanted, files: files, now: now),
           files.writeMarker(until: wanted) { memo = .some(wanted) }
        _ = client.update(severeUntil: wanted)
        schedule()
    }

    /// T-059 lot 5, module off: the client writes or removes `guard-continuity` and keeps the guard running, without
    /// touching `guard-until` (before the red screen reports, a marker its range left must stay).
    func refreshContinuity() {
        _ = client?.update(severeUntil: memo.flatMap { $0 })
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
