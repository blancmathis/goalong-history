#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r5 (C5-01..C5-04): within a boot, blocking decisions read a trusted "now" that a clock set back
/// never moves back, and a forward correction is compensated (spec K §4: protected blocks only lengthen).
final class BlockingTrustedClockTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func yt(_ at: Date) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                            isBrowser: true, url: "https://youtube.com/shorts/x", privateWindow: false, at: at)
    }

    /// 5 real minutes later, not 65.
    @MainActor func testClockSetBackDoesNotLengthenABreakInALockedBlock() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = TrustedClockBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], breaks: BlockBreaks(count: 1, minutes: 5))
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(4 * 3_600), lock: .locked); c.refresh()
            now += 60; uptime += 60; c.refresh()
            c.takeBreak(listID: list.id)
            XCTAssertNil(c.error)
            if rollback { now -= 3_600; uptime += 1; c.refresh() }     // the user sets the Mac clock back 1 h
            now += 6 * 60; uptime += 6 * 60; c.refresh()               // 6 real minutes later: the 5 min break is over
            backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "rollback=\(rollback): youtube.com still free 6 min after a 5 min break")
        }
    }


    /// (forward 1 h). The block must still last 2 real hours (spec K §4: changing the time changes nothing).
    @MainActor func testLockStartedWhileClockIsBackSurvivesSettingItRight() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = TrustedClockBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            if rollback { now -= 3_600; uptime += 1; c.refresh() }     // clock set back 1 h
            now += 60; uptime += 60; c.refresh()
            c.start(listIDs: [list.id], until: now.addingTimeInterval(7_200), lock: .locked); c.refresh()
            now += 60; uptime += 60; c.refresh()
            now += 3_600; uptime += 1; c.refresh()                     // clock set forward 1 h (right again, or ahead in the witness)
            now += 90 * 60; uptime += 90 * 60; c.refresh()             // 1 h 31 real minutes after the start
            backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "rollback=\(rollback): 2 h locked block over after 1 h 31 real minutes")
        }
    }


    /// C5-03: same path with a freeze (gel du Mac) started while the clock is back.
    @MainActor func testFreezeStartedWhileClockIsBackSurvivesSettingItRight() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let c = BlockingController(document: BlockingDocument(lists: []), clock: { now }, backend: TrustedClockBackend(),
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            if rollback { now -= 3_600; uptime += 1; c.refresh() }
            now += 60; uptime += 60; c.refresh()
            c.startFreeze(until: now.addingTimeInterval(7_200), mode: .shield, allowedApps: [])
            XCTAssertNotNil(c.freeze)
            now += 3_600; uptime += 1; c.refresh()
            now += 90 * 60; uptime += 90 * 60; c.refresh()
            XCTAssertNotNil(c.freeze, "rollback=\(rollback): 2 h freeze over after 1 h 30 real minutes")
        }
    }


    /// (2 days): the earlier day's unused quota must not reopen youtube.com.
    @MainActor func testClockSetBackToAnEarlierDayDoesNotRefillTheQuota() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = TrustedClockBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 10)
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(6 * 3_600), lock: .locked); c.refresh()
            for _ in 0..<50 { now += 15; uptime += 15; c.observe(yt(now)) }   // 12 min 30 on youtube.com: quota spent
            XCTAssertNotNil(backend.lastReason, "quota not spent")
            c.observe(BlockingObservation(bundleIdentifier: "com.apple.finder", pid: 1, windowFrame: .zero, isBrowser: false, url: nil, privateWindow: false, at: now))
            if rollback { now -= 2 * 86_400; uptime += 1; c.refresh() }       // the user sets the Mac clock back 2 days
            XCTAssertFalse(c.activeBlocks.isEmpty, "rollback=\(rollback): locked block lifted")
            now += 1; uptime += 1; backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "rollback=\(rollback): youtube.com free again after the daily quota was spent")
        }
    }
}

@MainActor private final class TrustedClockBackend: BlockingEnforcementBackend {
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
