#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 C7-02: a reboot with the clock behind moves a break in progress back with the other ends, and
/// leaves a midnight program window in progress held until its real end.
@MainActor final class BlockingClockRebootBreakTests: XCTestCase {
    private let real = Date(timeIntervalSince1970: 1_790_000_000)
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private var paris: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private final class Client: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = false, canRemove = true
        func update(severeUntil: Date?) -> BlockingProtectionState.Component { severeUntil == nil ? .notInstalled : .running }
        func removeService() {}
    }
    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("reboot-break-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    /// Locked 6 h block, 1 break of 5 min a day. At 14:00 the user takes the break, then reboots with the
    /// clock set back 8 h (06:01, same day): the block ends move back 8 h (L-05), the break must too.
    /// Witness: reboot with the clock right.
    func testBreakInProgressDoesNotOutliveARebootBehind() throws {
        let cal = paris
        let two = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14))!
        for behind in [0.0, 8 * 3_600.0] {
            let store = try store()
            var l = list; l.breaks = BlockBreaks(count: 1, minutes: 5)
            try store.save(BlockingDocument(lists: [l]))
            var wall = two, uptime = 1_000.0, boot = "a"
            let a = BlockingController(clock: { wall }, store: store, calendar: cal, continuous: { uptime }, boot: { boot }, guardClient: Client())
            a.refresh()
            a.start(listIDs: [l.id], until: two.addingTimeInterval(6 * 3_600), lock: .locked); a.refresh()
            a.takeBreak(listID: l.id); XCTAssertNil(a.error); a.refresh()
            wall += 60; uptime += 60; a.refresh()
            boot = "b"; uptime = 30; wall = two.addingTimeInterval(90 - behind)
            let b = BlockingController(clock: { wall }, store: store, calendar: cal, continuous: { uptime }, boot: { boot }, guardClient: Client())
            b.refresh()
            XCTAssertTrue(b.hasLocks, "behind=\(behind): block lost")
            let left = b.activeBlocks.first?.breakEnds[l.id].map { $0.timeIntervalSince(b.now) } ?? 0
            XCTAssertLessThan(left, 300, "behind=\(behind): break time left after the reboot")
            wall += 600; uptime += 600; b.refresh()   // real 14:11:30: the break is long over
            XCTAssertNil(b.activeBlocks.first?.breakEnds[l.id], "behind=\(behind): break still running 10 min later")
        }
    }

    /// Locked program 22:00-02:00 every day. Reboot at real 01:00 with the clock 8 h behind (17:00 the day
    /// before): the window in progress must hold until real 02:00. Witness: reboot with the clock right.
    func testRebootBehindInsideAMidnightProgramKeepsTheWindow() {
        let cal = paris
        let one = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 1))!
        for behind in [0.0, 8 * 3_600.0] {
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 1_320, endMinute: 120)],
                                     lockedUntil: one.addingTimeInterval(7 * 86_400))
            var document = BlockingDocument(lists: [l])
            document.clock = BlockingClockState(wall: one.addingTimeInterval(-60), continuous: 90_000, boot: "a",
                                                anchor: one.addingTimeInterval(-60).timeIntervalSince1970 - 90_000, frame: BlockingClock.frame)
            var wall = one.addingTimeInterval(-behind), uptime = 30.0
            let c = BlockingController(document: document, clock: { wall }, calendar: cal, continuous: { uptime }, boot: { "b" })
            c.refresh()
            XCTAssertTrue(c.hasLocks, "behind=\(behind): window lost at the reboot")
            wall += 50 * 60; uptime += 50 * 60; c.refresh()   // real 01:50
            XCTAssertTrue(c.hasLocks, "behind=\(behind): window lost before real 02:00")
        }
    }
}
#endif
