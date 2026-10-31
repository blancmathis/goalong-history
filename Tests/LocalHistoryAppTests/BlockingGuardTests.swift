#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import ServiceManagement
import XCTest
@preconcurrency import XPC
@testable import LocalHistoryApp

/// Spec K, app side: which blocks arm the guard, the `guard-until` marker, the injected client, the gate,
/// the uninstall refusal and the copy. No SMAppService, no launchd, no process: the client is a fake.
@MainActor final class BlockingGuardTests: XCTestCase {
    private final class FakeGuardClient: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = true
        var canRemove = true
        var answer: BlockingProtectionState.Component = .running
        private(set) var updates: [Date?] = []
        private(set) var removals = 0
        func update(severeUntil: Date?) -> BlockingProtectionState.Component {
            updates.append(severeUntil)
            return severeUntil == nil ? .notInstalled : answer
        }
        func removeService() { removals += 1 }
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])

    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("blocking-guard-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    private func controller(_ document: BlockingDocument, clock: @escaping () -> Date) throws
        -> (BlockingController, FakeGuardClient, GuardFiles) {
        let store = try store()
        try store.save(document)
        let client = FakeGuardClient()
        let controller = BlockingController(clock: clock, store: store, continuous: { clock().timeIntervalSince1970 },
                                            guardClient: client)
        controller.refresh()
        return (controller, client, GoalongGuardFiles.files(for: store.directory))
    }

    private func session(_ lock: BlockLock, start: TimeInterval = 0, end: TimeInterval = 3600) -> BlockSession {
        BlockSession(listIDs: [list.id], start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), lock: lock)
    }

    /// R2: a free or « Difficile » block and a locked session that has not started arm nothing.
    func testOnlySevereBlocksArmTheGuard() throws {
        for document in [BlockingDocument(lists: [list]),
                         BlockingDocument(lists: [list], sessions: [session(.free)]),
                         BlockingDocument(lists: [list], sessions: [session(.typing)]),
                         BlockingDocument(lists: [list], sessions: [session(.locked, start: 600, end: 3600)])] {
            let (c, client, files) = try controller(document) { [now] in now }
            XCTAssertNil(c.severeUntil)
            XCTAssertEqual(files.readMarker(now: now), .absent)
            XCTAssertTrue(client.updates.allSatisfy { $0 == nil }, "nothing to register, nothing to ping")
            XCTAssertEqual(c.protection.guardian, .notInstalled)
            XCTAssertEqual(c.protection.level, .standard)
        }
    }

    func testLockedPasswordFreezeAndProgramWriteTheirEnd() throws {
        var program = list
        program.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)],
                                       lockedUntil: now.addingTimeInterval(7200))
        let end = now.addingTimeInterval(3600)
        let cases: [(String, BlockingDocument, Date)] = [
            ("locked", BlockingDocument(lists: [list], sessions: [session(.locked)]), end),
            ("password", BlockingDocument(lists: [list], sessions: [session(.password)]), end),
            ("freeze", BlockingDocument(lists: [list], freeze: BlockFreeze(start: now, end: end, mode: .shield)), end),
            ("program", BlockingDocument(lists: [program]), now.addingTimeInterval(7200)),
        ]
        for (name, document, expected) in cases {
            let (c, client, files) = try controller(document) { [now] in now }
            XCTAssertEqual(c.severeUntil, expected, name)
            XCTAssertEqual(files.readMarker(now: now), .date(expected), name)
            XCTAssertEqual(client.updates.last, .some(expected), name)
            XCTAssertEqual(c.protection.guardian, .running, name)
            XCTAssertEqual(c.protection.level, .strict, name)
            XCTAssertFalse(c.canRemoveGuard, "\(name): the remove button hides during a severe block")
        }
    }

    /// R5-garde-02: a planned locked block keeps the service: removed now, it would come back at the start.
    func testAPlannedLockedBlockHidesTheRemoveButton() throws {
        var clockNow = now
        let (c, client, _) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked, start: 600, end: 3600)])) { clockNow }
        XCTAssertNil(c.severeUntil, "nothing armed yet")
        XCTAssertFalse(c.canRemoveGuard)
        c.removeGuardService()
        XCTAssertEqual(client.removals, 0)
        clockNow = now.addingTimeInterval(3601); c.refresh()
        XCTAssertTrue(c.canRemoveGuard, "after the block, the button comes back")
    }

    /// B01-R1-01: a weekly locked or password range not started yet also keeps the service.
    func testAFutureLockedRangeHidesTheRemoveButton() throws {
        let weekday = Calendar.current.component(.weekday, from: now) % 7 + 1 // ISO weekday, never today
        for lock in [BlockLock.locked, .password] {
            var program = list
            program.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [weekday], startMinute: 540, endMinute: 720, lock: lock)])
            let (c, client, _) = try controller(BlockingDocument(lists: [program])) { [now] in now }
            XCTAssertNil(c.severeUntil, "\(lock): tomorrow's range arms nothing yet")
            XCTAssertFalse(c.canRemoveGuard, "\(lock)")
            c.removeGuardService()
            XCTAssertEqual(client.removals, 0, "\(lock)")
        }
        var free = list
        free.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [weekday], startMinute: 540, endMinute: 720, lock: .free)])
        let (c, _, _) = try controller(BlockingDocument(lists: [free])) { [now] in now }
        XCTAssertTrue(c.canRemoveGuard, "a free range keeps the button")
    }

    func testADeletedMarkerIsRewrittenAndTheEndRemovesIt() throws {
        var clockNow = now
        let (c, client, files) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked)])) { clockNow }
        XCTAssertTrue(files.writeMarker(until: nil))
        c.refresh()
        XCTAssertEqual(files.readMarker(now: now), .date(now.addingTimeInterval(3600)), "rewritten although the memo matched")
        client.answer = .awaitingApproval
        c.refresh()
        XCTAssertEqual(c.protection.guardian, .awaitingApproval)
        XCTAssertEqual(c.protection.level, .standard, "only a running guard makes the protection strict")
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(c.protection), "À autoriser")
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(c.protection), "Autorisez Goalong dans \(LoginItemsPanel.path).", "UI-12A: the path goes in the note")
        XCTAssertNil(c.error, "the guard never raises an error message")
        clockNow = now.addingTimeInterval(3601)
        c.refresh()
        XCTAssertEqual(files.readMarker(now: clockNow), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertTrue(c.canRemoveGuard)
        c.removeGuardService()
        XCTAssertEqual(client.removals, 1)
    }

    /// K1-kill-04: a modified marker is put right like a deleted one; a planted one is removed.
    func testAModifiedOrPlantedMarkerIsRewritten() throws {
        var clockNow = now
        let (c, _, files) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked)])) { clockNow }
        XCTAssertTrue(files.writeMarker(until: now.addingTimeInterval(1)))
        c.refresh()
        XCTAssertEqual(files.readMarker(now: now), .date(now.addingTimeInterval(3600)), "a lowered end does not stay")
        XCTAssertTrue(files.writeMarker(until: now.addingTimeInterval(86_400)))
        c.refresh()
        XCTAssertEqual(files.readMarker(now: now), .date(now.addingTimeInterval(3600)), "a raised end does not stay")
        clockNow = now.addingTimeInterval(3601)
        c.refresh()
        XCTAssertEqual(files.readMarker(now: clockNow), .absent)
        XCTAssertTrue(files.writeMarker(until: clockNow.addingTimeInterval(600)))
        c.refresh()
        XCTAssertEqual(files.readMarker(now: clockNow), .absent, "no severe block: a planted marker is removed")
    }

    /// K1-safe-03: a lock further than the guard accepts is written capped, so the guard stays armed.
    func testAFarLockIsCappedToWhatTheGuardAccepts() throws {
        var program = list
        program.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)],
                                       lockedUntil: now.addingTimeInterval(800 * 86_400))
        let (c, _, files) = try controller(BlockingDocument(lists: [program])) { [now] in now }
        XCTAssertEqual(c.severeUntil, now.addingTimeInterval(800 * 86_400))
        guard case .date(let written) = files.readMarker(now: now) else { return XCTFail("the guard must read a valid end") }
        XCTAssertLessThanOrEqual(written.timeIntervalSince(now), GuardFiles.maximumArming)
        XCTAssertGreaterThan(written.timeIntervalSince(now), GuardFiles.maximumArming - 3 * 86_400)
        XCTAssertEqual(GuardFiles.markerEnd(now.addingTimeInterval(10.2), now: now), Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 10.2).rounded(.up)))
        XCTAssertEqual(GuardFiles.markerEnd(now.addingTimeInterval(800 * 86_400), now: now),
                       GuardFiles.markerEnd(now.addingTimeInterval(900 * 86_400), now: now.addingTimeInterval(60)),
                       "whole days: the capped file does not change on every refresh")
    }

    /// K1-kill-05: the SIGTERM handler refreshes the live controller and reads `severeUntil`.
    func testSigtermHandlerReadsTheLiveController() throws {
        let (locked, _, _) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked, start: -60)])) { [now] in now }
        let (free, _, _) = try controller(BlockingDocument(lists: [list], sessions: [session(.free, start: -60)])) { [now] in now }
        XCTAssertFalse(AppDelegate.honoursTerminationSignal(controller: locked, sessionEnding: false, senderPID: 4242, installOverride: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(controller: free, sessionEnding: false, senderPID: 4242, installOverride: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(controller: nil, sessionEnding: false, senderPID: nil, installOverride: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(controller: locked, sessionEnding: true, senderPID: 4242, installOverride: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(controller: locked, sessionEnding: false, senderPID: 1, installOverride: false))
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(controller: locked, sessionEnding: false, senderPID: 4242, installOverride: true))
    }

    /// K1-safe-01 / K1-safe-05: the override token is fresh only briefly and written only during a severe block.
    func testOverrideTokenIsWrittenOnlyDuringASevereBlockAndExpires() throws {
        let root = try store().directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = GoalongGuardFiles.files(for: root)
        XCTAssertTrue(GuardUnregisterCommand.writesOverride(marker: .date(now.addingTimeInterval(60)), now: now))
        XCTAssertFalse(GuardUnregisterCommand.writesOverride(marker: .date(now.addingTimeInterval(-1)), now: now))
        XCTAssertFalse(GuardUnregisterCommand.writesOverride(marker: .absent, now: now))
        XCTAssertFalse(GoalongGuardFiles.overrideActive(files, now: now))
        XCTAssertTrue(files.writeOverride(GuardOverride(pid: 1, writtenAt: now.timeIntervalSince1970)))
        XCTAssertTrue(GoalongGuardFiles.overrideActive(files, now: now.addingTimeInterval(60)))
        XCTAssertFalse(GoalongGuardFiles.overrideActive(files, now: now.addingTimeInterval(GuardOverride.lifetime + 1)))
        XCTAssertFalse(GoalongGuardFiles.overrideActive(files, now: now.addingTimeInterval(-60)), "a token from the future is ignored")
    }

    /// L4: a guard that dies interrupts the connection, which stays alive with its handler: it is cancelled.
    func testOnlyAnInterruptedConnectionIsCancelledWhenDropped() {
        XCTAssertTrue(GoalongGuardClient.cancelsDroppedConnection(after: XPC_ERROR_CONNECTION_INTERRUPTED))
        XCTAssertFalse(GoalongGuardClient.cancelsDroppedConnection(after: XPC_ERROR_CONNECTION_INVALID))
        XCTAssertFalse(GoalongGuardClient.cancelsDroppedConnection(after: XPC_ERROR_TERMINATION_IMMINENT))
    }

    /// K1-kill-01: a stopped guard is resumed, but a reused pid that runs something else is never signalled.
    func testAStoppedGuardIsResumedOnlyWhenItIsTheGuard() throws {
        var resumed: [Int32] = []
        XCTAssertTrue(GoalongGuardClient.resumeStopped([10, 11, 12], isStopped: { $0 != 11 }, resume: { resumed.append($0) }))
        XCTAssertEqual(resumed, [10, 12])
        XCTAssertFalse(GoalongGuardClient.resumeStopped([11], isStopped: { _ in false }, resume: { _ in XCTFail("running") }))
        let guardPath = "/Applications/Goalong History.app/Contents/MacOS/goalong-blocking-guard"
        XCTAssertTrue(GoalongGuardClient.isGuardProcess(5, executable: guardPath, path: { _ in guardPath }))
        XCTAssertFalse(GoalongGuardClient.isGuardProcess(5, executable: guardPath, path: { _ in "/bin/zsh" }))
        XCTAssertFalse(GoalongGuardClient.isGuardProcess(5, executable: guardPath, path: { _ in nil }))
        // A real stopped process (it plays the guard).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL) }
        let pid = process.processIdentifier
        kill(pid, SIGSTOP)
        for _ in 0..<100 where !GuardProcesses.isStopped(pid) { usleep(10_000) }
        XCTAssertTrue(GuardProcesses.isStopped(pid))
        XCTAssertTrue(GoalongGuardClient.resumeStopped([pid]))
        for _ in 0..<100 where GuardProcesses.isStopped(pid) { usleep(10_000) }
        XCTAssertFalse(GuardProcesses.isStopped(pid))
    }

    /// K2-safe-02: `launchctl bootout` (spec §7) is an exit; a job missing from launchd is never re-registered.
    func testABootoutIsNeverUndoneByAReregister() {
        XCTAssertFalse(GoalongGuardClient.mayReregister(kickstartStatus: GoalongGuardClient.launchctlServiceNotFound))
        XCTAssertFalse(GoalongGuardClient.mayReregister(kickstartStatus: nil), "no kickstart in this round: no proof")
        XCTAssertTrue(GoalongGuardClient.mayReregister(kickstartStatus: 0), "loaded but unreachable: proven failure")
        XCTAssertEqual(GoalongGuardClient.launchctlServiceNotFound, 113)
    }

    /// Counts BTM calls; never registers anything. `.requiresApproval` keeps update() away from pings.
    private final class FakeService: GuardServiceControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0, registers = 0, unregisters = 0
        var current: SMAppService.Status = .requiresApproval
        /// unregister() throws and leaves the status; otherwise `removes` makes it `.notRegistered`.
        var unregisterFails = false, removes = false
        var statusReads: Int { lock.withLock { reads } }
        var registerCalls: Int { lock.withLock { registers } }
        var unregisterCalls: Int { lock.withLock { unregisters } }
        var status: SMAppService.Status { lock.withLock { reads += 1; return current } }
        func register() throws { lock.withLock { registers += 1 } }
        func unregister() throws {
            try lock.withLock {
                unregisters += 1
                if unregisterFails { throw CocoaError(.featureUnsupported) }
                if removes { current = .notRegistered }
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var stored = false
        var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    private func client(_ service: FakeService, override: Flag = Flag()) -> GoalongGuardClient {
        let identity = GuardIdentity(bundleIdentifier: "ai.goalong.localhistory.dev", channel: "dev")!
        let defaults = UserDefaults(suiteName: "goalong-guard-client-tests-" + UUID().uuidString)!
        return GoalongGuardClient(identity: identity, defaults: defaults, overrideActive: { override.value }, service: service)
    }

    /// Lets the client's queue answer and its main-queue hop run.
    private func settle(_ condition: () -> Bool) {
        for _ in 0..<200 where !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// K2-kill-03 / K3-kill-03: the 2 s SIGSTOP check runs exactly while armed and outside an override,
    /// wired through update(severeUntil:).
    func testTheStopCheckFollowsTheArmingThroughUpdate() {
        let service = FakeService(), override = Flag()
        let client = client(service, override: override)
        settle { client.canRemove }
        XCTAssertFalse(client.isWatchingForStop)
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        XCTAssertTrue(client.isWatchingForStop, "armed")
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        XCTAssertTrue(client.isWatchingForStop, "still armed on the next refresh")
        override.value = true
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        XCTAssertFalse(client.isWatchingForStop, "an installer override stops it")
        override.value = false
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        XCTAssertTrue(client.isWatchingForStop)
        _ = client.update(severeUntil: nil)
        XCTAssertFalse(client.isWatchingForStop, "block over")
        XCTAssertEqual(service.registerCalls, 0)
    }

    /// K2-safe-01 / K3-kill-03: outside a severe block the client reads the BTM status once at launch and
    /// once when a block ends, never on every refresh.
    func testIdleClientReadsTheStatusOnlyWhenABlockEnds() {
        let service = FakeService()
        let client = client(service)
        settle { client.canRemove }
        XCTAssertEqual(service.statusReads, 1, "the read at launch")
        for _ in 0..<3 { _ = client.update(severeUntil: nil) }
        settle { false }
        XCTAssertEqual(service.statusReads, 1, "idle refreshes read nothing")
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        let armedReads = service.statusReads
        _ = client.update(severeUntil: nil)
        settle { service.statusReads > armedReads }
        XCTAssertEqual(service.statusReads, armedReads + 1, "one read when the block ends")
        _ = client.update(severeUntil: nil)
        settle { false }
        XCTAssertEqual(service.statusReads, armedReads + 1)
    }

    /// Fake launchd side: the guard never answers; kickstart returns `kickstartResult`.
    private final class FakeLaunchd: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let kickstartResult: Int32
        init(kickstartResult: Int32) { self.kickstartResult = kickstartResult }
        var kickstarts: Int { lock.withLock { count } }
        var probes: GuardLaunchProbes {
            GuardLaunchProbes(ping: { .unreachable }, resumeStoppedGuards: { false },
                              kickstart: { self.lock.withLock { self.count += 1 }; return self.kickstartResult })
        }
    }

    /// Every update() of an armed client starts a round (ping interval 0); waits for that round's answer.
    private func armedClient(_ service: FakeService, _ launchd: FakeLaunchd) -> GoalongGuardClient {
        service.current = .enabled
        let identity = GuardIdentity(bundleIdentifier: "ai.goalong.localhistory.dev", channel: "dev")!
        let defaults = UserDefaults(suiteName: "goalong-guard-client-tests-" + UUID().uuidString)!
        let client = GoalongGuardClient(identity: identity, defaults: defaults, overrideActive: { false },
                                        service: service, probes: launchd.probes, pingInterval: 0)
        settle { client.canRemove }
        return client
    }

    /// One escalation round through update(), as the controller's refresh runs it.
    private func round(_ client: GoalongGuardClient, until end: Date) -> BlockingProtectionState.Component {
        _ = client.update(severeUntil: end)
        settle { !client.isWorking }
        return client.component
    }

    /// L-04 (K3-kill-03): the client's own wiring of a bootout. Kickstart 113 → "stopped until the next
    /// login" for every later round of this arming, no second kickstart, never a re-register; a new
    /// arming may kickstart once again.
    func testABootoutSeenThroughUpdateIsKeptForTheArming() {
        let service = FakeService(), launchd = FakeLaunchd(kickstartResult: GoalongGuardClient.launchctlServiceNotFound)
        let client = armedClient(service, launchd)
        let end = Date().addingTimeInterval(600)
        let stopped = BlockingProtectionState.Component.failed(GuardEscalation.stoppedUntilLogin)
        XCTAssertEqual(round(client, until: end), stopped)
        XCTAssertEqual(launchd.kickstarts, 1)
        for _ in 0..<3 { XCTAssertEqual(round(client, until: end), stopped, "the bootout is remembered") }
        XCTAssertEqual(launchd.kickstarts, 1, "one kickstart per arming")
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
        _ = client.update(severeUntil: nil)
        settle { !client.isWorking }
        XCTAssertEqual(round(client, until: end), stopped)
        XCTAssertEqual(launchd.kickstarts, 2, "a new arming kickstarts again")
        XCTAssertEqual(service.registerCalls, 0)
    }

    /// L-04 (K3-kill-03): a loaded guard that never answers is re-registered once per build, through the
    /// client's own claims, after one kickstart per arming.
    func testAnUnreachableGuardIsReregisteredOncePerBuildThroughUpdate() {
        let service = FakeService(), launchd = FakeLaunchd(kickstartResult: 0)
        let client = armedClient(service, launchd)
        let end = Date().addingTimeInterval(600)
        let unreachable = BlockingProtectionState.Component.failed(GuardEscalation.unreachable)
        XCTAssertEqual(round(client, until: end), unreachable)
        XCTAssertEqual(launchd.kickstarts, 1)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(round(client, until: end), unreachable)
        XCTAssertEqual(launchd.kickstarts, 1, "once per arming")
        XCTAssertEqual(service.registerCalls, 1, "once per build")
        _ = client.update(severeUntil: nil)
        settle { !client.isWorking }
        XCTAssertEqual(round(client, until: end), unreachable)
        XCTAssertEqual(launchd.kickstarts, 2)
        XCTAssertEqual(service.registerCalls, 1, "still once per build in a new arming")
    }

    /// One arming's escalation memory, shared by the rounds like the client's.
    private final class EscalationProbe {
        var status: SMAppService.Status = .enabled
        var pings: [GuardPingOutcome] = []
        var kickstartResult: Int32? = 113
        var kickstartUsed = false, bootedOut = false, reregisterUsed = false, override = false
        var kickstarts = 0, reregisters = 0, notArmed = 0

        func escalation() -> GuardEscalation {
            GuardEscalation(
                status: { self.status },
                ping: { self.pings.isEmpty ? .unreachable : self.pings.removeFirst() },
                resumeStoppedGuards: { false },
                overrideActive: { self.override },
                noteNotArmed: { self.notArmed += 1 },
                claimKickstart: { defer { self.kickstartUsed = true }; return !self.kickstartUsed },
                kickstart: { self.kickstarts += 1; return self.kickstartResult },
                bootedOut: { self.bootedOut },
                noteBootedOut: { self.bootedOut = true },
                claimReregister: { defer { self.reregisterUsed = true }; return !self.reregisterUsed },
                reregister: { self.reregisters += 1; return self.status })
        }
    }

    /// K2-safe-02 / K3-safe-04 / K3-kill-03: after a bootout (kickstart 113) no round re-registers, and the
    /// badge keeps saying "stopped until the next login" for the whole arming.
    func testABootoutIsNeverReregisteredAndItsMessageHolds() {
        let probe = EscalationProbe()
        let stopped = BlockingProtectionState.Component.failed(GuardEscalation.stoppedUntilLogin)
        XCTAssertEqual(probe.escalation().run().1, stopped)
        XCTAssertEqual(probe.kickstarts, 1)
        for _ in 0..<3 { XCTAssertEqual(probe.escalation().run().1, stopped, "later rounds, no kickstart left") }
        XCTAssertEqual(probe.kickstarts, 1)
        XCTAssertEqual(probe.reregisters, 0)
        probe.pings = [.running]
        XCTAssertEqual(probe.escalation().run().1, .running, "a guard that answers again wins")
    }

    /// K3-kill-03: a loaded guard that does not answer is re-registered once per build, after one kickstart.
    func testAnUnreachableLoadedGuardIsReregisteredOnce() {
        let probe = EscalationProbe()
        probe.kickstartResult = 0
        XCTAssertEqual(probe.escalation().run().1, .failed(GuardEscalation.unreachable))
        XCTAssertEqual(probe.kickstarts, 1)
        XCTAssertEqual(probe.reregisters, 1)
        XCTAssertEqual(probe.escalation().run().1, .failed(GuardEscalation.unreachable))
        XCTAssertEqual(probe.kickstarts, 1, "once per arming")
        XCTAssertEqual(probe.reregisters, 1, "once per build")
        XCTAssertFalse(probe.bootedOut)
    }

    /// Status first and the override: nothing is kicked or re-registered.
    func testEscalationRespectsTheStatusAndTheOverride() {
        let probe = EscalationProbe()
        probe.status = .notRegistered
        XCTAssertEqual(probe.escalation().run().1, .notInstalled)
        probe.status = .requiresApproval
        XCTAssertEqual(probe.escalation().run().1, .awaitingApproval)
        probe.status = .enabled; probe.override = true
        XCTAssertEqual(probe.escalation().run().1, .notInstalled)
        XCTAssertEqual(probe.kickstarts + probe.reregisters, 0)
        probe.override = false; probe.pings = [.notArmed]
        if case .failed = probe.escalation().run().1 {} else { XCTFail("not armed is reported") }
        XCTAssertEqual(probe.notArmed, 1)
    }

    /// K2-safe-05: a guard killed while armed keeps its memory in guard-state.json. After an early end by
    /// password (marker removed), a quit must still leave the user_quit token it will read.
    func testAQuitTokenIsDueWhileAKilledGuardsMemoryRemains() throws {
        let root = try store().directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = GoalongGuardFiles.files(for: root)
        XCTAssertFalse(GoalongGuardFiles.guardMayBeArmed(files), "no block, no guard: nothing to write")
        XCTAssertTrue(files.writeState(GuardState(build: "b", armed: false)))
        XCTAssertFalse(GoalongGuardFiles.guardMayBeArmed(files), "a guard that finished cleanly")
        XCTAssertTrue(files.writeState(GuardState(build: "b", armed: true, endContinuous: 500, markerDate: 1, bootTime: 2)))
        XCTAssertTrue(GoalongGuardFiles.guardMayBeArmed(files), "a guard killed while armed")
        XCTAssertTrue(files.writeState(GuardState(build: "b", armed: false)))
        XCTAssertTrue(files.writeMarker(until: now.addingTimeInterval(600)))
        XCTAssertTrue(GoalongGuardFiles.guardMayBeArmed(files))
    }

    func testStandardLevelIsSettledButAGuardWaitingIsNot() {
        var state = BlockingProtectionState()
        XCTAssertTrue(BlockingProtectionDetails.levelIsSettled(state))
        state.guardian = .awaitingApproval
        XCTAssertFalse(BlockingProtectionDetails.levelIsSettled(state))
        state.guardian = .failed("x")
        XCTAssertFalse(BlockingProtectionDetails.levelIsSettled(state))
    }

    func testStartHintSaysWhyTheButtonIsOff() {
        let hint = BlockingProtectionDetails.startHint
        XCTAssertNil(hint(false, false, true, true, false))
        XCTAssertEqual(hint(false, false, false, false, false), "Créez une liste, ou choisissez « Tout le Mac ».")
        XCTAssertEqual(hint(false, false, true, false, false), "Choisissez au moins une liste.")
        XCTAssertEqual(hint(false, false, true, true, true), "Choisissez d’abord un mot de passe de blocage.")
        XCTAssertEqual(hint(true, true, true, true, false), "Le Mac est déjà gelé.")
        XCTAssertNil(hint(true, false, true, false, false))
    }

    func testLevelLabels() {
        var state = BlockingProtectionState()
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Standard")
        XCTAssertNil(BlockingProtectionDetails.levelHelp(state))
        state.guardian = .failed(GuardEscalation.stoppedUntilLogin)
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Indisponible")
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(state), GuardEscalation.stoppedUntilLogin, "R5-garde-01: the cause under « Niveau »")
        state.guardian = .awaitingApproval
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "À autoriser")
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(state), "Autorisez Goalong dans \(LoginItemsPanel.path).")
        state.guardian = .running; state.level = .strict
        XCTAssertEqual(BlockingProtectionDetails.levelLabel(state), "Renforcé")
        XCTAssertNil(BlockingProtectionDetails.levelHelp(state))
    }

    func testConsentSentenceIsAddedOnlyBeforeTheFirstRegistration() {
        XCTAssertEqual(GuardConsent.message("Base.", needed: false), "Base.")
        XCTAssertEqual(GuardConsent.message("Base.", needed: true), "Base.\n\n" + GuardConsent.text)
        XCTAssertTrue(GuardConsent.text.contains("Aucun mot de passe"))
    }

    func testGateAllowsOnlyInstalledCopiesOfTheFamily() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let release: [String: Any] = ["CFBundleIdentifier": "ai.goalong.localhistory"]
        let dev: [String: Any] = ["CFBundleIdentifier": "ai.goalong.localhistory.dev", "GoalongBuildChannel": "dev"]
        func allowed(_ path: String, _ info: [String: Any]) -> Bool {
            GoalongGuardGate.isAllowed(bundleURL: URL(fileURLWithPath: path, isDirectory: true), info: info, home: home)
        }
        XCTAssertTrue(allowed("/Applications/Goalong History.app", release))
        XCTAssertTrue(allowed("/Users/someone/Applications/Goalong Dev.app", dev))
        XCTAssertFalse(allowed("/Users/someone/Developer/goalong/dist/Goalong History.app", release), "a build folder")
        XCTAssertFalse(allowed("/private/var/folders/x/AppTranslocation/y/d/Goalong History.app", release))
        XCTAssertFalse(allowed("/Applications/Other.app", ["CFBundleIdentifier": "com.example.other"]))
        XCTAssertFalse(allowed("/Applications/Goalong Dev.app", ["CFBundleIdentifier": "ai.goalong.localhistory.dev"]),
                       "the dev id without its channel would use the release data folder")
        XCTAssertFalse(allowed("/Applications/xctest", release))
        XCTAssertFalse(allowed("/Volumes/Goalong/Goalong History.app", release), "a disk image or an external volume")
        XCTAssertFalse(allowed("/Users/someone/Downloads/Goalong History.app", release))
    }

    /// H34-G2: a member's copy outside Applications has no guard. A severe block still starts; « Niveau »
    /// says why it would not survive a forced quit, never the banner.
    func testACopyOutsideApplicationsWarnsButStillLocks() throws {
        XCTAssertNil(GoalongGuardMissing.make(identity: nil), "a test runner or a foreign bundle: no guard at all")
        let identity = GuardIdentity(bundleIdentifier: "ai.goalong.localhistory", channel: nil)!
        let missing = try XCTUnwrap(GoalongGuardMissing.make(identity: identity))
        XCTAssertFalse(missing.needsConsent)
        XCTAssertFalse(missing.canRemove)
        let store = try store()
        try store.save(BlockingDocument(lists: [list], sessions: [session(.locked)]))
        let c = BlockingController(clock: { [now] in now }, store: store, continuous: { [now] in now.timeIntervalSince1970 },
                                   guardClient: missing)
        c.refresh()
        XCTAssertNotNil(c.severeUntil, "the lock is not refused")
        XCTAssertEqual(c.protection.guardian, .failed(GoalongGuardMissing.reason))
        XCTAssertEqual(c.protection.level, .standard)
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(c.protection), GoalongGuardMissing.reason)
        XCTAssertNil(c.error)
        XCTAssertEqual(missing.update(severeUntil: nil), .notInstalled, "nothing to say without a severe block")
    }

    /// H34-G1: the guard's own words stay under « Niveau » and go when it answers again.
    func testAGuardFailureNeverReachesTheBanner() throws {
        let (c, client, _) = try controller(BlockingDocument(lists: [list], sessions: [session(.locked)])) { [now] in now }
        client.answer = .failed(GuardEscalation.unreachable)
        c.refresh()
        XCTAssertEqual(BlockingProtectionDetails.levelHelp(c.protection), GuardEscalation.unreachable)
        XCTAssertNil(c.error)
        client.answer = .running
        c.refresh()
        XCTAssertNil(BlockingProtectionDetails.levelHelp(c.protection))
        XCTAssertNil(c.error)
    }

    /// H34-G3: a removal that leaves the service registered says so, under « Niveau »; a later success clears it.
    func testAFailedRemovalIsShownAndKeepsTheService() {
        let service = FakeService(); service.current = .enabled; service.unregisterFails = true
        let client = client(service)
        settle { client.canRemove }
        client.removeService()
        settle { !client.isWorking }
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertTrue(client.canRemove, "still registered")
        XCTAssertEqual(client.update(severeUntil: nil), .failed(GoalongGuardClient.removalFailed))
        service.unregisterFails = false; service.removes = true
        client.removeService()
        settle { !client.isWorking }
        XCTAssertFalse(client.canRemove)
        XCTAssertEqual(client.update(severeUntil: nil), .notInstalled)
    }

    /// H34-G3: a removal while a BTM call is in flight is ignored, never raced with it.
    func testARemovalDuringWorkIsIgnored() {
        let service = FakeService(); service.current = .enabled
        let client = client(service)
        XCTAssertTrue(client.isWorking, "the status read at launch")
        client.removeService()
        settle { client.canRemove }
        settle { false }
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    /// H34-G3: the block ends before a queued registration runs: nothing is registered.
    func testADisarmBeforeRegistrationRegistersNothing() {
        let service = FakeService(); service.current = .notRegistered
        let client = client(service)
        settle { !client.isWorking }
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        XCTAssertTrue(client.isWorking)
        _ = client.update(severeUntil: nil)  // the queue waits for the main thread: still before register()
        settle { !client.isWorking }
        settle { false }
        XCTAssertEqual(service.registerCalls, 0)
    }

    /// H34-G3: the block ends during the kickstart: the round never re-registers.
    func testADisarmDuringARoundNeverReregisters() {
        final class Holder: @unchecked Sendable { weak var client: GoalongGuardClient? }
        let service = FakeService(); service.current = .enabled
        let holder = Holder()
        let probes = GuardLaunchProbes(ping: { .unreachable }, resumeStoppedGuards: { false }, kickstart: {
            DispatchQueue.main.sync { MainActor.assumeIsolated { _ = holder.client?.update(severeUntil: nil) } }
            return 0
        })
        let identity = GuardIdentity(bundleIdentifier: "ai.goalong.localhistory.dev", channel: "dev")!
        let defaults = UserDefaults(suiteName: "goalong-guard-client-tests-" + UUID().uuidString)!
        let client = GoalongGuardClient(identity: identity, defaults: defaults, overrideActive: { false },
                                        service: service, probes: probes, pingInterval: 0)
        holder.client = client
        settle { client.canRemove }
        _ = client.update(severeUntil: Date().addingTimeInterval(600))
        settle { !client.isWorking }
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(service.registerCalls, 0)
    }

    /// H34-L2: `--unregister-guard` exits 0 only when the service is gone.
    func testUnregisterCommandReportsAServiceThatStays() {
        let stays = FakeService(); stays.current = .enabled; stays.unregisterFails = true
        XCTAssertEqual(GuardUnregisterCommand.unregister(stays), GuardUnregisterCommand.failedExitCode)
        let silent = FakeService(); silent.current = .enabled
        XCTAssertEqual(GuardUnregisterCommand.unregister(silent), GuardUnregisterCommand.failedExitCode, "no throw, still enabled")
        let gone = FakeService(); gone.current = .enabled; gone.removes = true
        XCTAssertEqual(GuardUnregisterCommand.unregister(gone), 0)
        let never = FakeService(); never.current = .notRegistered
        XCTAssertEqual(GuardUnregisterCommand.unregister(never), 0)
        XCTAssertEqual(never.unregisterCalls, 0)
        XCTAssertNotEqual(GuardUnregisterCommand.failedExitCode, 0)
        XCTAssertNotEqual(GuardUnregisterCommand.failedExitCode, GuardUnregisterCommand.refusedExitCode)
    }

    /// H34-L1 / L3: the consent does not promise a single notice; an unreachable guard says what to do.
    func testGuardCopyIsHonestAndActionable() {
        XCTAssertFalse(GuardConsent.text.contains("une fois"))
        XCTAssertTrue(GuardConsent.text.contains("peut l’annoncer de nouveau après une mise à jour"))
        XCTAssertTrue(GuardEscalation.unreachable.hasSuffix("Réessayez dans \(LoginItemsPanel.path)."))
    }

    func testUnregisterIsRefusedDuringASevereBlockUnlessOverridden() {
        let future = GuardMarker.date(now.addingTimeInterval(60))
        XCTAssertTrue(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: ["GOALONG_UNINSTALL_DURING_LOCK": "1"]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: future, now: now, environment: ["GOALONG_INSTALL_DURING_LOCK": "1"]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .date(now.addingTimeInterval(-1)), now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .absent, now: now, environment: [:]))
        XCTAssertFalse(GuardUnregisterCommand.isRefused(marker: .invalid, now: now, environment: [:]))
        XCTAssertEqual(GuardUnregisterCommand.refusedExitCode, 3)
    }

    func testLeaseIsWrittenOnlyWhileArmed() throws {
        let root = try store().directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = GoalongGuardFiles.files(for: root)
        GoalongGuardFiles.writeLease(GuardLease.update, seconds: 180, files: files)
        XCTAssertNil(files.readLease(), "no severe block: nothing written")
        XCTAssertTrue(files.writeMarker(until: Date().addingTimeInterval(600)))
        GoalongGuardFiles.writeLease(GuardLease.update, seconds: 180, files: files)
        XCTAssertEqual(files.readLease()?.reason, GuardLease.update)
        XCTAssertEqual(files.readLease()?.pid, getpid())
        GoalongGuardFiles.reportHealth(files)
        XCTAssertEqual(files.readHealth()?.pid, getpid())
        files.clearTokens()
        XCTAssertNil(files.readLease())
    }
}
#endif
