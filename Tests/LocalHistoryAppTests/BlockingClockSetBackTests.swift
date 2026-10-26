#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// A Mac clock set back by hand in the same boot (T-044 C4-01, C4-02): protected blocks may get longer,
/// never shorter or paused (spec K §4), and an unreadable address still fails closed.
final class BlockingClockSetBackTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }

    /// C4-02: locked block on youtube.com, started 2 h ago; the browser address is unreadable. Without a clock
    /// change the browser is covered after 3 s (`.unsupportedBrowser`). With the clock set back 1 h, the
    /// unreadable window must not wait for the wall clock to catch up with its first read.
    @MainActor func testClockSetBackKeepsUnreadableAddressFailClosed() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = SetBackBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(4 * 3_600), lock: .locked)
            c.refresh()
            now = now.addingTimeInterval(2 * 3_600); uptime += 2 * 3_600; c.refresh()       // the block started 2 h ago
            var t = BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                                        isBrowser: true, url: nil, privateWindow: false, at: now)
            c.observe(t)
            if rollback { now = now.addingTimeInterval(-3_600); uptime += 1; c.refresh() }   // the user sets the Mac clock back 1 h
            XCTAssertFalse(c.activeBlocks.filter { $0.start <= now && $0.end > now }.isEmpty, "locked block must stay active (L-05)")
            for _ in 0..<10 { now = now.addingTimeInterval(1); uptime += 1; t.at = now; c.observe(t) }
            guard case .unsupportedBrowser? = backend.lastReason else {
                XCTFail("rollback=\(rollback): unreadable browser not covered after 10 s, reason \(String(describing: backend.lastReason))"); continue
            }
        }
    }

    /// C4-01: same set-back, readable address: the locked block keeps covering youtube.com.
    @MainActor func testClockSetBackKeepsALockedBlockActive() {
        for rollback in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = SetBackBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.start(listIDs: [list.id], until: now.addingTimeInterval(7_200), lock: .locked)
            c.refresh()
            if rollback { now = now.addingTimeInterval(-3_600); uptime += 1; c.refresh() }   // the user sets the Mac clock back 1 h
            now = now.addingTimeInterval(1); uptime += 1
            c.observe(BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                                          isBrowser: true, url: "https://youtube.com/shorts/x", privateWindow: false, at: now))
            XCTAssertNotNil(backend.lastReason, "rollback=\(rollback): youtube.com not covered by the locked block")
            XCTAssertFalse(c.activeBlocks.isEmpty, "rollback=\(rollback): no active block")
        }
    }

    /// C4-01: the end does not move with the set-back; setting the clock forward again is not compensated twice.
    @MainActor func testClockSetBackKeepsTheWallEndOfALockedBlock() {
        var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
        let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
        let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: SetBackBackend(),
                                   calendar: calendar, continuous: { uptime }, boot: { "test" })
        let end = now.addingTimeInterval(7_200)
        c.start(listIDs: [list.id], until: end, lock: .locked); c.refresh()
        now = now.addingTimeInterval(-3_600); uptime += 1; c.refresh()
        XCTAssertEqual(c.activeBlocks.map(\.end), [end])
        now = now.addingTimeInterval(3_600); uptime += 1; c.refresh()
        XCTAssertEqual(c.activeBlocks.map(\.end), [end])
    }
}

@MainActor private final class SetBackBackend: BlockingEnforcementBackend {
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
