#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r6 (C6-04): earned time is credited to the usage day of the trusted now, whatever the wall clock.
final class BlockingEarnedTimeFrameTests: XCTestCase {
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

    /// C6-04: frames mixed in `creditEarnedTime` (stop.at wall vs today in T). Clock set back 1 h at 23:50:
    /// a session completed at 23:05 wall (00:05 trusted, the usage day of the quota) must credit today.
    /// Set forward 1 day: the session ends after the trusted now in the wall frame, yet it is earned.
    @MainActor func testEarnedTimeAfterSetBackCreditsTheQuotaDayInUse() throws {
        for shift in [0.0, -3_600.0, 86_400.0] {   // none, clock set back 1 h, set forward 1 day
            var now = at(5, 23, 50), uptime = 1_000.0
            let list = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")], quotaMinutesPerDay: 10, earn: .init())
            let c = BlockingController(document: BlockingDocument(lists: [list]), clock: { now }, backend: BlockingEarnedTimeFrameTestsBackend(),
                                       calendar: calendar, continuous: { uptime }, boot: { "test" })
            c.refresh()
            if shift != 0 { now += shift; uptime += 1; c.refresh() }
            now += 15 * 60; uptime += 15 * 60; c.refresh()                    // trusted day: 10-06
            let start = now.addingTimeInterval(-30 * 60)
            let session = FocusSession(intent: "Travail", mode: FocusMode(minutes: 30), startedAt: start,
                                       events: [.init(kind: .start, at: start), .init(kind: .stop, at: now, reason: .completed)])
            XCTAssertEqual(try c.creditEarnedTime(for: session), [list.id: 300], "shift=\(shift)")
            XCTAssertEqual(c.earnedMinutesToday[list.id], 5, "shift=\(shift): earned minutes credited to another day")
        }
    }

}

@MainActor private final class BlockingEarnedTimeFrameTestsBackend: BlockingEnforcementBackend {
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
