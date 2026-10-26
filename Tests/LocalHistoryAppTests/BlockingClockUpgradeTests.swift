#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r6 (PR #121 review): first load of a document written before the trusted frame.
final class BlockingClockUpgradeTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func yt(_ at: Date) -> BlockingObservation {
        BlockingObservation(bundleIdentifier: "com.google.Chrome", pid: 42_000, windowFrame: CGRect(x: 1, y: 1, width: 800, height: 600),
                            isBrowser: true, url: "https://youtube.com/shorts/x", privateWindow: false, at: at)
    }

    /// Update from #119/#120 in the same boot after a set-back: a wall-frame block made after the set-back.
    @MainActor func testUpgradeAfterSetBackKeepsBlockMadeAfterIt() {
        for setBack in [false, true] {
            let real = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
            var uptime = 2_000.0
            var now = setBack ? real.addingTimeInterval(-3_600) : real
            // #119 stored the anchor of before the set-back (no compensation of a backward step).
            var stored = BlockingClockState(wall: now, continuous: uptime, boot: "test")
            stored.anchor = real.timeIntervalSince1970 - uptime
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
            let session = BlockSession(listIDs: [list.id], start: now, end: now.addingTimeInterval(7_200), lock: .locked)
            let backend = UpgradeBackend()
            let c = BlockingController(document: BlockingDocument(lists: [list], sessions: [session], clock: stored), clock: { now }, backend: backend,
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            now += 61 * 60; uptime += 61 * 60; c.refresh()
            backend.lastReason = nil
            c.observe(yt(now))
            XCTAssertNotNil(backend.lastReason, "setBack=\(setBack): 2 h locked block over after 61 real minutes")
        }
    }
}

@MainActor private final class UpgradeBackend: BlockingEnforcementBackend {
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
