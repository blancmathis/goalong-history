#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r6 (PR #121 review): slow NTP drift of the wall clock behind continuous time.
final class BlockingClockDriftTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func yt(_ at: Date) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                            isBrowser: true, url: "https://youtube.com/shorts/x", privateWindow: false, at: at)
    }

    /// Normal user, no clock change: wall clock slews 0.5 s/day slower than continuous time (NTP).
    @MainActor func testSlowDriftShiftsQuotaDayRollover() {
        for drift in [false, true] {
            var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!, uptime = 1_000.0
            let backend = DriftBackend()
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 10)
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            for _ in 0..<(30 * 24) { now += 3_600 - (drift ? 0.5 / 24 : 0); uptime += 3_600; c.refresh() }
            let skew = c.now.timeIntervalSince(now)
            c.start(listIDs: [list.id], until: now.addingTimeInterval(16 * 3_600), lock: .locked); c.refresh()
            for _ in 0..<50 { now += 15; uptime += 15; c.observe(yt(now)) }
            XCTAssertNotNil(backend.lastReason, "quota not spent")
            c.observe(BlockingObservation(bundleIdentifier: "com.apple.finder", pid: 1, windowFrame: .zero, isBrowser: false, url: nil, privateWindow: false, at: now))
            let target = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 59, second: 52))!
            uptime += target.timeIntervalSince(now); now = target; c.refresh()
            backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "drift=\(drift) skew=\(skew)s: quota refilled before wall midnight")
        }
    }
}

@MainActor private final class DriftBackend: BlockingEnforcementBackend {
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
