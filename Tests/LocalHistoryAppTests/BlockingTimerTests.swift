#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Fixed fictitious data only; never the member's blocking.json.
final class BlockingTimerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 813_000_000)
    private let chess = BlockList(name: "Échecs", sites: [.init(pattern: "chess.com")], quotaMinutesPerDay: 60, breaks: .init(count: 2, minutes: 5))

    private func target(_ at: Date, url: String = "chess.com/play", idle: Double = 0) -> BlockingObservation {
        var value = BlockingObservation(bundleIdentifier: "browser", pid: 42_002, windowFrame: nil, isBrowser: true, url: url, privateWindow: false, at: at)
        value.idleSeconds = idle
        return value
    }
    private func block(_ lists: [BlockList]) -> BlockingActiveBlock {
        BlockingActiveBlock(id: UUID(), listIDs: lists.map(\.id), start: now.addingTimeInterval(-60), end: now.addingTimeInterval(7_200), lock: .free, origin: .manual)
    }
    private func input(used: Double = 0, target: BlockingObservation?, lists: [BlockList]? = nil,
                       configure: (inout BlockingTimerInput) -> Void = { _ in }) -> BlockingTimerInput {
        let lists = lists ?? [chess]
        var usage = BlockDayUsage(day: BlockingController.dayKey(now)); usage.quotaSecondsUsed[chess.id] = used
        var value = BlockingTimerInput(lists: lists, activeBlocks: [block(lists)], usage: usage, target: target)
        configure(&value)
        return value
    }

    func testQuotaCountsDownFromTheLastMeasure() throws {
        let timer = try XCTUnwrap(BlockingTimerSelection.select(input(used: 3_300, target: target(now)), at: now.addingTimeInterval(3)))
        XCTAssertEqual(timer.kind, .quota); XCTAssertTrue(timer.counting)
        XCTAssertEqual(timer.text, "Échecs · 4:57"); XCTAssertEqual(timer.urgency, .warning)
        // Never extrapolates past what the controller can credit between two samples.
        let stale = try XCTUnwrap(BlockingTimerSelection.select(input(used: 3_300, target: target(now)), at: now.addingTimeInterval(40)))
        XCTAssertEqual(stale.seconds, 285)
        XCTAssertEqual(BlockingTimerSelection.select(input(used: 1_800, target: target(now)), at: now)?.text, "Échecs · 30:00")
        var earned = input(used: 3_600, target: target(now)); earned.usage.earnedSeconds = [chess.id: 600]
        XCTAssertEqual(BlockingTimerSelection.select(earned, at: now)?.text, "Échecs · 10:00")
    }

    func testQuotaPausedWhenIdleOrPrivate() throws {
        let idle = try XCTUnwrap(BlockingTimerSelection.select(input(used: 3_000, target: target(now, idle: 200)), at: now.addingTimeInterval(5)))
        XCTAssertFalse(idle.counting); XCTAssertEqual(idle.text, "Échecs · 10:00")
        XCTAssertTrue(idle.accessibilityLabel.contains("en pause"))
        // A private window hides the address: a site list veils it (fail closed), an app rule keeps
        // the capsule but the controller does not charge the quota.
        var hidden = target(now); hidden.privateWindow = true
        XCTAssertNil(BlockingTimerSelection.select(input(used: 3_000, target: hidden), at: now.addingTimeInterval(5)))
        var browser = chess; browser.apps = [.init(bundleIdentifier: "browser", name: "Navigateur")]
        let app = BlockingTimerSelection.select(input(used: 3_000, target: hidden, lists: [browser]), at: now.addingTimeInterval(5))
        XCTAssertEqual(app?.counting, false); XCTAssertEqual(app?.text, "Échecs · 10:00")
    }

    func testBreakShowsWhateverTheForegroundApp() throws {
        let value = input(target: nil) { $0.usage.breakEnds[self.chess.id] = self.now.addingTimeInterval(90) }
        let timer = try XCTUnwrap(BlockingTimerSelection.select(value, at: now))
        XCTAssertEqual(timer.kind, .breakTime); XCTAssertEqual(timer.text, "Pause · Échecs · 1:30")
        // The quota does not count during a break, so it is not shown next to it.
        let both = input(used: 3_590, target: target(now)) { $0.usage.breakEnds[self.chess.id] = self.now.addingTimeInterval(240) }
        XCTAssertEqual(BlockingTimerSelection.select(both, at: now)?.kind, .breakTime)
    }

    func testSlowDownAllowance() throws {
        let slow = BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")], action: .slowDown, continueMinutes: 10)
        let video = target(now, url: "youtube.com/watch")
        let value = input(target: video, lists: [slow]) {
            $0.allowances[BlockingFrictionPresentation.key(video, listID: slow.id)] = self.now.addingTimeInterval(400)
        }
        let timer = try XCTUnwrap(BlockingTimerSelection.select(value, at: now))
        XCTAssertEqual(timer.kind, .slowDownAllowance); XCTAssertEqual(timer.text, "Vidéo · 6:40"); XCTAssertEqual(timer.urgency, .neutral)
        XCTAssertNil(BlockingTimerSelection.select(value, at: now.addingTimeInterval(401)))
    }

    func testMostUrgentWins() throws {
        let slow = BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")], action: .slowDown)
        let value = input(used: 3_000, target: target(now), lists: [chess, slow]) {
            $0.allowances[slow.id.uuidString + "|host:youtube.com"] = self.now.addingTimeInterval(120)
        }
        XCTAssertEqual(BlockingTimerSelection.select(value, at: now)?.kind, .slowDownAllowance)
        XCTAssertEqual(BlockingTimerSelection.select(value, at: now)?.urgency, .warning)
        var later = value; later.allowances = [slow.id.uuidString + "|host:youtube.com": now.addingTimeInterval(900)]
        XCTAssertEqual(BlockingTimerSelection.select(later, at: now)?.kind, .quota)
    }

    func testThresholdsAndClock() {
        XCTAssertEqual(BlockingVisibleTimer.Urgency(seconds: 301), .neutral)
        XCTAssertEqual(BlockingVisibleTimer.Urgency(seconds: 300), .warning)
        XCTAssertEqual(BlockingVisibleTimer.Urgency(seconds: 61), .warning)
        XCTAssertEqual(BlockingVisibleTimer.Urgency(seconds: 60), .critical)
        XCTAssertEqual(BlockingVisibleTimer.clock(0), "0:00")
        XCTAssertEqual(BlockingVisibleTimer.clock(3_599), "59:59")
        XCTAssertEqual(BlockingVisibleTimer.clock(3_661), "1:01:01")
        // Rounded up: 0.4 s left still reads 0:01 and is critical.
        let timer = BlockingVisibleTimer(kind: .quota, listID: chess.id, listName: "Échecs", remaining: 0.4)
        XCTAssertEqual(timer.clock, "0:01"); XCTAssertEqual(timer.urgency, .critical)
    }

    func testNothingToShow() {
        XCTAssertNil(BlockingTimerSelection.select(input(target: nil), at: now))
        XCTAssertNil(BlockingTimerSelection.select(input(target: target(now, url: "wikipedia.org/wiki")), at: now))
        // Quota used: the veil is shown, not a timer.
        XCTAssertNil(BlockingTimerSelection.select(input(used: 3_600, target: target(now)), at: now))
        var inactive = input(target: target(now)); inactive.activeBlocks = []
        XCTAssertNil(BlockingTimerSelection.select(inactive, at: now))
        // A hard list without quota already veils the target.
        let hard = BlockList(name: "Dur", sites: [.init(pattern: "chess.com")])
        XCTAssertNil(BlockingTimerSelection.select(input(target: target(now), lists: [chess, hard]), at: now))
    }

    func testUpcomingStartWithinTheObservationMinute() throws {
        let hard = BlockList(name: "Soir", sites: [.init(pattern: "chess.com")])
        var value = BlockingTimerInput(lists: [hard], usage: BlockDayUsage(day: BlockingController.dayKey(now)),
                                       upcomingStarts: [.init(listID: hard.id, date: now.addingTimeInterval(45))], target: target(now))
        XCTAssertEqual(BlockingTimerSelection.select(value, at: now)?.text, "Soir · 0:45")
        XCTAssertEqual(BlockingTimerSelection.select(value, at: now)?.kind, .upcomingStart)
        value.upcomingStarts = [.init(listID: hard.id, date: now.addingTimeInterval(120))]
        XCTAssertNil(BlockingTimerSelection.select(value, at: now))
        // A quota list with time left lets the target through at its start.
        value.lists = [chess]; value.upcomingStarts = [.init(listID: chess.id, date: now.addingTimeInterval(30))]
        XCTAssertNil(BlockingTimerSelection.select(value, at: now))
    }

    /// The veil falls within 2 s of the capsule reaching 0:00, with the real controller and samples.
    @MainActor func testVeilFallsWhenTheCapsuleReachesZero() throws {
        var clock = now
        let list = BlockList(name: "Échecs", sites: [.init(pattern: "chess.com")], quotaMinutesPerDay: 1)
        let backend = TimerBackend()
        let c = BlockingController(document: .init(lists: [list]), clock: { clock }, backend: backend, continuous: { clock.timeIntervalSince1970 })
        c.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        var changes = 0; c.onTimerInputChanged = { changes += 1 }
        var zeroAt: Date?, veiledAt: Date?
        for step in 0..<120 {
            clock = now.addingTimeInterval(Double(step) * 0.75)
            c.observe(target(clock))
            if backend.blocks > 0 { veiledAt = clock; break }
            let timer = try XCTUnwrap(BlockingTimerSelection.select(c.timerInput, at: clock))
            XCTAssertEqual(timer.kind, .quota); XCTAssertTrue(timer.counting)
            zeroAt = clock.addingTimeInterval(timer.remaining)
            // Between samples the capsule counts down on its own.
            let mid = try XCTUnwrap(BlockingTimerSelection.select(c.timerInput, at: clock.addingTimeInterval(0.5)))
            XCTAssertEqual(mid.remaining, timer.remaining - 0.5, accuracy: 0.001)
        }
        let veil = try XCTUnwrap(veiledAt), zero = try XCTUnwrap(zeroAt)
        XCTAssertGreaterThanOrEqual(veil.timeIntervalSince(zero), -0.001)
        XCTAssertLessThanOrEqual(veil.timeIntervalSince(zero), 2)
        XCTAssertNil(BlockingTimerSelection.select(c.timerInput, at: clock))
        XCTAssertGreaterThan(changes, 60)
    }

    @MainActor func testControllerPublishesBreakAndAllowance() throws {
        var clock = now
        let slow = BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")], breaks: .init(count: 1, minutes: 5), action: .slowDown, slowDownSeconds: 3, continueMinutes: 2)
        let c = BlockingController(document: .init(lists: [slow]), clock: { clock }, backend: TimerBackend(), continuous: { clock.timeIntervalSince1970 })
        c.start(listIDs: [slow.id], until: now.addingTimeInterval(3_600), lock: .free)
        c.observe(target(clock, url: "youtube.com/watch")); XCTAssertNotNil(c.friction)
        clock = clock.addingTimeInterval(3); c.continueFriction()
        XCTAssertEqual(BlockingTimerSelection.select(c.timerInput, at: clock)?.text, "Vidéo · 2:00")
        c.takeBreak(listID: slow.id)
        XCTAssertEqual(BlockingTimerSelection.select(c.timerInput, at: clock)?.text, "Pause · Vidéo · 5:00")
    }

    /// `GOALONG_TIMER_SNAPSHOTS=<dir> swift test --filter BlockingTimerTests/testRenderCapsules`
    @MainActor func testRenderCapsules() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_TIMER_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with fixed data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, BlockingVisibleTimer)] = [
            ("neutral", .init(kind: .quota, listID: chess.id, listName: "Échecs", remaining: 1_712)),
            ("amber", .init(kind: .quota, listID: chess.id, listName: "Échecs", remaining: 247)),
            ("red", .init(kind: .quota, listID: chess.id, listName: "Échecs", remaining: 42)),
            ("paused", .init(kind: .quota, listID: chess.id, listName: "Échecs", remaining: 1_712, counting: false)),
            ("break", .init(kind: .breakTime, listID: chess.id, listName: "Échecs", remaining: 268)),
        ]
        for (name, timer) in cases {
            let view = ZStack {
                LinearGradient(colors: [Color(white: 0.85), Color(red: 0.35, green: 0.45, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                BlockingTimerCapsule(timer: timer, pulse: 0)
            }.frame(width: 320, height: 64).environment(\.goalongReduceMotion, true)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("timer-\(name).png"))
            print("TIMER_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }
    }

    func testFrameSitsUnderTheSafeTop() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let frame = BlockingTimerHUD.frame(size: CGSize(width: 180, height: 36), screen: screen,
                                           visible: CGRect(x: 0, y: 0, width: 1_512, height: 944), safeTop: 32)
        XCTAssertEqual(frame.midX, 756); XCTAssertLessThanOrEqual(frame.maxY, 944)
        XCTAssertGreaterThan(frame.minY, screen.midY + 300)
    }
}

private final class TimerBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true; var canLockScreen = false; var browsers: [BlockingBrowserSupport] = []
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    var blocks = 0
    func observeBrowser(_ t: BlockingObservation) {}
    func updateProtection(locked: Bool) -> BlockingProtectionState { .init() }
    func blockApp(_ t: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) { blocks += 1 }
    func blockSite(_ t: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) { blocks += 1 }
    func clearSite() {}; func updateFreeze(_ f: BlockFreeze?) {}; func returnToShield() {}; func shutdown() {}
    func continueSlowDown(_ t: BlockingObservation) {}
}
#endif
