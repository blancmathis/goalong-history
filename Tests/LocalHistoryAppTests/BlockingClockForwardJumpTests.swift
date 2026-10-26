#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r6 (C6-01..03): in one boot a clock set forward stays out of the trusted now. Day keys
/// (quota, breaks) and program windows follow real time. Each test loops over a witness without a change.
final class BlockingClockForwardJumpTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func yt(_ at: Date) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                            isBrowser: true, url: "https://youtube.com/shorts/x", privateWindow: false, at: at)
    }
    private func finder(_ at: Date) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.apple.finder", pid: 1, windowFrame: .zero, isBrowser: false, url: nil, privateWindow: false, at: at)
    }

    /// C6-01: locked block, 10 min daily quota spent. Clock set forward to the next day (or 1 h across
    /// midnight): the next day's quota must not reopen youtube.com (mirror of C5-04).
    @MainActor func testClockSetForwardToNextDayDoesNotRefillTheQuota() {
        for (start, jump) in [(at(5, 12), 0.0), (at(5, 12), 86_400.0), (at(5, 23, 20), 0.0), (at(5, 23, 20), 3_600.0)] {
            var now = start, uptime = 1_000.0
            let backend = BlockingClockForwardJumpTestsBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 10)
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(6 * 3_600), lock: .locked); c.refresh()
            for _ in 0..<50 { now += 15; uptime += 15; c.observe(yt(now)) }   // 12 min 30 on youtube.com: quota spent
            XCTAssertNotNil(backend.lastReason, "quota not spent")
            c.observe(finder(now))
            if jump > 0 { now += jump; uptime += 1; c.refresh() }             // the user sets the Mac clock forward
            XCTAssertFalse(c.activeBlocks.isEmpty, "jump=\(jump): locked block lifted")
            now += 1; uptime += 1; backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "start=\(start) jump=\(jump): youtube.com free again after the daily quota was spent")
        }
    }

    /// C6-02: locked block, 1 break of 5 min a day, already taken. Clock set forward 1 day: no new break.
    @MainActor func testClockSetForwardToNextDayDoesNotRefillBreaks() {
        for jump in [0.0, 86_400.0] {
            var now = at(5, 12), uptime = 1_000.0
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], breaks: BlockBreaks(count: 1, minutes: 5))
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: BlockingClockForwardJumpTestsBackend(),
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(6 * 3_600), lock: .locked); c.refresh()
            c.takeBreak(listID: list.id); XCTAssertNil(c.error)
            now += 6 * 60; uptime += 6 * 60; c.refresh()                      // the break is over
            if jump > 0 { now += jump; uptime += 1; c.refresh() }
            c.error = nil
            c.takeBreak(listID: list.id)
            XCTAssertNotNil(c.error, "jump=\(jump): a second break of the day was granted")
        }
    }

    /// C6-03: locked list with a locked program 09:00-17:00 every day. At 08:50 the clock is set forward
    /// past 17:00: at 09:01 real time youtube.com must still be blocked.
    @MainActor func testClockSetForwardOverALockedProgramWindowDoesNotSkipIt() {
        for jump in [0.0, 8 * 3_600 + 20 * 60.0] {
            var now = at(5, 8, 50), uptime = 1_000.0
            let backend = BlockingClockForwardJumpTestsBackend()
            var list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 9 * 60, endMinute: 17 * 60, lock: .locked)],
                                        lockedUntil: now.addingTimeInterval(7 * 86_400))
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            if jump > 0 { now += jump; uptime += 1; c.refresh() }             // 08:50 → 17:10
            now += 11 * 60; uptime += 11 * 60; c.refresh()                    // 09:01 real time
            backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "jump=\(jump): locked program window skipped by setting the clock forward")
        }
    }

    /// Witnesses (sleep, reboot): continuous time runs during sleep; a reboot with S = 0 keeps the block.
    @MainActor func testSleepAndRebootKeepLockedBlockToItsEnd() {
        for reboot in [false, true] {
            var now = at(5, 12), uptime = 1_000.0, boot = "a"
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: BlockingClockForwardJumpTestsBackend(),
                                       calendar: calendar, continuous: { uptime }, boot: { boot })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(4 * 3_600), lock: .locked); c.refresh()
            if reboot { boot = "b"; uptime = 30 } else { uptime += 3 * 3_600 }
            now += 3 * 3_600; c.refresh()                                       // 3 h asleep or powered off
            XCTAssertFalse(c.activeBlocks.isEmpty, "reboot=\(reboot): block lifted 1 h early")
            now += 3_601; uptime += 3_601; c.refresh()
            XCTAssertTrue(c.activeBlocks.isEmpty, "reboot=\(reboot): block outlives its end")
        }
    }

    /// A forward jump stays out of the trusted now, so it must not lengthen a locked block either
    /// (#121 moved protected ends by the jump when T took it; now T ignores it: no second shift).
    @MainActor func testClockSetForwardKeepsLockedBlockToItsRealEnd() {
        for jump in [0.0, 3_600.0, 86_400.0] {
            var now = at(5, 12), uptime = 1_000.0
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: BlockingClockForwardJumpTestsBackend(),
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(3_600), lock: .locked); c.refresh()
            if jump > 0 { now += jump; uptime += 1; c.refresh() }
            now += 3_500; uptime += 3_500; c.refresh()
            XCTAssertFalse(c.activeBlocks.isEmpty, "jump=\(jump): block lifted early")
            now += 101; uptime += 101; c.refresh()
            XCTAssertTrue(c.activeBlocks.isEmpty, "jump=\(jump): block lengthened by the forward jump")
        }
    }

}

@MainActor private final class BlockingClockForwardJumpTestsBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    func observeBrowser(_ target: BlockingObservation) {}
    var canLockScreen = true
    var browsers: [BlockingBrowserSupport] = []
    var lastReason: BlockingVeilPresentation.Reason?
    func updateProtection(locked: Bool) -> BlockingProtectionState { BlockingProtectionState() }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {}
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) { lastReason = presentation.reason }
    func clearSite() {}
    func updateFreeze(_ freeze: BlockFreeze?) {}
    func returnToShield() {}
    func shutdown() {}
}
#endif
