#if os(macOS)
import BraiseCore
import Foundation
import GoalongGuardCore
import XCTest
@testable import LocalHistoryApp

/// T-048 B4 (point 8 of review B2): a protected red-screen range arms Goalong's guard exactly like a severe block.
/// Fake gamma and fake guard client: no colour change, no SMAppService, no launchd, no process started or killed.
@MainActor final class RedScreenGuardTests: XCTestCase {
    private final class FakeGuardClient: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = false
        var canRemove = true
        private(set) var updates: [Date?] = []
        func update(severeUntil: Date?) -> BlockingProtectionState.Component {
            updates.append(severeUntil); return severeUntil == nil ? .notInstalled : .running
        }
        func removeService() {}
    }
    /// Wall clock and continuous clock (`BlockingClock.continuous`), shared by the red screen and the blocks.
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000
        init(_ now: Date) { self.now = now }
        func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); up += seconds }
    }
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 22:00 in Paris.
    private let wednesday22h = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func defaults() throws -> UserDefaults {
        let name = "goalong-red-guard-" + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    private func redScreen(_ clocks: Clocks, root: URL) throws -> BraiseController {
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { clocks.now }, calendar: paris,
                                     continuous: { clocks.up }, boot: { "boot-1" }, hasPassword: { false })
        for range in c.ranges.program.ranges { try c.deleteRange(range.id) }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func blocking(_ clocks: Clocks, root: URL, client: FakeGuardClient) -> (BlockingController, GuardFiles) {
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        let c = BlockingController(clock: { clocks.now }, store: store, continuous: { clocks.up }, boot: { "boot-1" }, guardClient: client)
        c.refresh()
        return (c, GoalongGuardFiles.files(for: store.directory))
    }
    /// Wednesday (ISO 3) 21:00–23:00.
    private func evening(_ lock: BlockLock?) -> BlockProgramRange {
        BlockProgramRange(weekdays: [3], startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)
    }
    /// What the guard process decides from the marker alone, the app just killed (`GuardEngine`'s inputs).
    private func guardAction(_ files: GuardFiles, _ clocks: Clocks, arming: inout GuardArming, appAlive: Bool) -> GuardAction {
        arming.apply(files.readMarker(now: clocks.now), wall: clocks.now, continuous: clocks.up, appAlive: appAlive)
        var input = GuardInput()
        input.armed = arming.isArmed(continuous: clocks.up)
        input.death = .init(pid: 4242, at: clocks.now.timeIntervalSince1970)
        input.budgetDelay = RelaunchBudget().delay(at: clocks.up)
        input.now = clocks.now.timeIntervalSince1970
        return GuardDecision.decide(input)
    }

    /// Protected range without any block → the guard is armed until its end, and relaunches at once (budget 0 s).
    /// Range over → `guard-until` is gone, the client disarmed, and the guard ends.
    func testProtectedRangeWithoutBlockArmsTheGuardUntilItsEnd() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient()
        let (blocks, files) = blocking(clocks, root: root, client: client)
        let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { XCTFail("module on: no keeper"); return nil })
        let red = try redScreen(clocks, root: root)
        let braise = BraiseRuntime(registersShortcut: false, defaults: try defaults(), factory: { red })
        braise.guardSink = { runtime.setRedScreenGuard(until: $0) }
        braise.start()
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent, "nothing protected yet")
        try red.saveRange(evening(.locked), intensity: 0.8)
        braise.setRedScreenFollowsSchedule(true)

        let end = wednesday22h.addingTimeInterval(3_600)
        XCTAssertNil(blocks.severeUntil, "no block at all")
        XCTAssertEqual(red.guardUntil, end)
        XCTAssertEqual(blocks.guardUntil, end)
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(end))
        XCTAssertEqual(client.updates.last, .some(end))
        XCTAssertEqual(blocks.protection.guardian, .running)
        XCTAssertFalse(blocks.canRemoveGuard, "the remove button hides while the range arms the guard")
        var arming = GuardArming()
        XCTAssertEqual(guardAction(files, clocks, arming: &arming, appAlive: false), .relaunch(after: 0), "killed: reopened at once")

        clocks.pass(3_601); red.evaluate()
        XCTAssertNil(red.guardUntil)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent, "range over: marker removed")
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertEqual(guardAction(files, clocks, arming: &arming, appAlive: true), .exit(0), "range over: the guard ends")
    }

    /// A free range, the manual red and a « Difficile » range never arm the guard.
    func testFreeRangeAndManualRedArmNothing() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient()
        let (blocks, files) = blocking(clocks, root: root, client: client)
        let runtime = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
        let red = try redScreen(clocks, root: root)
        red.stateChanged = { runtime.setRedScreenGuard(until: red.guardUntil) }
        try red.saveRange(evening(nil), intensity: 1); red.setFollows(true); red.setManual(true)
        XCTAssertTrue(red.active); XCTAssertNil(red.guardUntil)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
        XCTAssertTrue(client.updates.allSatisfy { $0 == nil })
    }

    /// Relaunch by the guard: the blocking runtime starts before the red screen. Until the red screen reports, a marker
    /// its range left stays (no hole); the report then decides, as from the live app.
    func testMarkerLeftByARangeStaysUntilTheRedScreenReports() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient()
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        let files = GoalongGuardFiles.files(for: store.directory)
        let left = wednesday22h.addingTimeInterval(1_800)
        XCTAssertTrue(files.writeMarker(until: left))
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: { nil })
        XCTAssertEqual(runtime.redScreen, .unknown)
        // The first refresh runs inside init: the demand is given there, as `BlockingRuntime.apply` does.
        let blocks = BlockingController(clock: { clocks.now }, store: store, continuous: { clocks.up }, boot: { "boot-1" },
                                        guardClient: client, redScreen: runtime.redScreen)
        let live = BlockingRuntime(controller: blocks, redScreenKeeper: { nil })
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(left), "kept before the red screen reports")
        XCTAssertEqual(client.updates.last, .some(left))
        live.setRedScreenGuard(until: wednesday22h.addingTimeInterval(3_600))
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(wednesday22h.addingTimeInterval(3_600)), "the held range again")
        live.setRedScreenGuard(until: nil)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        // Without a red-screen demand, a known « none » still removes a marker a block ended early left (password).
        XCTAssertTrue(files.writeMarker(until: left)); blocks.refresh()
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
    }

    /// Module Blocage off: the keeper writes the same marker with the same client, then hands it to the controller.
    func testKeeperArmsTheGuardWhileTheBlockingModuleIsOff() throws {
        let root = try root(), clocks = Clocks(wednesday22h), client = FakeGuardClient()
        let files = GoalongGuardFiles.files(for: root.appendingPathComponent("Blocking", isDirectory: true))
        var made = 0
        let runtime = BlockingRuntime(controller: nil, redScreenKeeper: {
            made += 1; return RedScreenGuardKeeper(client: client, files: files, clock: { clocks.now })
        })
        runtime.setRedScreenGuard(until: nil)
        XCTAssertEqual(made, 0, "nothing protected: no keeper, no BTM call")
        let end = wednesday22h.addingTimeInterval(3_600)
        runtime.setRedScreenGuard(until: end)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(files.readMarker(now: clocks.now), .date(end))
        XCTAssertEqual(files.readHealth()?.pid, getpid(), "this process may lower or remove the marker")
        XCTAssertEqual(client.updates.last, .some(end))
        var arming = GuardArming()
        XCTAssertEqual(guardAction(files, clocks, arming: &arming, appAlive: false), .relaunch(after: 0))
        clocks.pass(3_601); runtime.setRedScreenGuard(until: nil)
        XCTAssertEqual(files.readMarker(now: clocks.now), .absent)
        XCTAssertEqual(client.updates.last, .some(nil))
        XCTAssertEqual(guardAction(files, clocks, arming: &arming, appAlive: true), .exit(0))
        XCTAssertTrue(runtime.redScreenKeeper?.adopt() === client, "the module switched on takes the same client")
    }
}
#endif
