#if os(macOS)
import Foundation
import GoalongGuardCore
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 C7-01: a reboot with the clock behind moves the protected ends back (L-05); a later reboot with
/// the clock right (or less behind) moves them forward again, up to the proven floor.
@MainActor final class BlockingClockRebootForwardTests: XCTestCase {
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
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("reboot-forward-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    /// Boot a: clock right, 6 h locked block, list program locked 7 days, freeze 6 h.
    /// Reboot b: clock 8 h behind (RTC, or set back by hand): ends move back 8 h (L-05), floor = last T of a.
    /// Reboot c: clock right again (cBehind = 0) or half right (4 h behind), no NTP step needed.
    /// Witness: reboot c still 8 h behind, then NTP steps the clock in boot c (r7 floor step).
    /// Every end must keep its real time left.
    func testRebootBehindThenRebootRightKeepsLocks() throws {
        for cBehind in [8 * 3_600.0, 0, 4 * 3_600.0] {
            let store = try store()
            var l = list; l.program.lockedUntil = real.addingTimeInterval(7 * 86_400)
            try store.save(BlockingDocument(lists: [l]))
            var wall = real, uptime = 1_000.0, boot = "a"
            let a = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            a.refresh()
            a.start(listIDs: [l.id], until: real.addingTimeInterval(6 * 3_600), lock: .locked)
            a.startFreeze(until: real.addingTimeInterval(6 * 3_600), mode: .shield, allowedApps: [])
            a.refresh()
            wall += 600; uptime += 600; a.refresh()
            boot = "b"; uptime = 30; wall = real.addingTimeInterval(630 - 8 * 3_600)
            let b = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            b.refresh()
            wall += 600; uptime += 600; b.refresh()
            boot = "c"; uptime = 20; wall = real.addingTimeInterval(1_260 - cBehind)
            let c = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            c.refresh()
            wall = real.addingTimeInterval(1_320); uptime += 60; c.refresh()   // NTP (a no-op when the clock is right)
            let elapsed = 1_320.0, slack = 120.0
            XCTAssertTrue(c.hasLocks, "cBehind=\(cBehind): locked block lost")
            let left = c.activeBlocks.first.map { $0.end.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(left, 6 * 3_600 - elapsed - slack, "cBehind=\(cBehind): block time left")
            XCTAssertLessThan(left, 6 * 3_600 - elapsed + slack, "cBehind=\(cBehind): block longer than its real end")
            let program = (c.lists.first?.program.lockedUntil).map { $0.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(program, 7 * 86_400 - elapsed - slack, "cBehind=\(cBehind): program lock time left")
            XCTAssertLessThan(program, 7 * 86_400 - elapsed + slack, "cBehind=\(cBehind): program lock longer than its real end")
            let freeze = c.freeze.map { $0.end.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(freeze, 6 * 3_600 - elapsed - slack, "cBehind=\(cBehind): freeze time left")
            XCTAssertLessThan(freeze, 6 * 3_600 - elapsed + slack, "cBehind=\(cBehind): freeze longer than its real end")
        }
    }

    /// Boot a right, 6 h locked block. Boot b 8 h behind (10 min). Off 3 h. Boot c: right, or still 8 h behind
    /// (PR #124 review F2). Real time left at c = 6 h − 3 h − 21 min.
    /// Clock right: the block keeps its real end. Still behind: the boot cannot tell the downtime from a
    /// clock set forward (same inputs as the « 4 h behind » branch above), so the ends move forward by the
    /// wall step, never past the proven floor: at most the downtime added, never a lock shortened.
    func testRebootStillBehindAddsAtMostTheDowntimeToLocks() throws {
        let off = 3 * 3_600.0
        for cBehind in [0.0, 8 * 3_600.0] {
            let store = try store()
            try store.save(BlockingDocument(lists: [list]))
            var wall = real, uptime = 1_000.0, boot = "a"
            let a = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            a.refresh()
            a.start(listIDs: [list.id], until: real.addingTimeInterval(6 * 3_600), lock: .locked)
            a.startFreeze(until: real.addingTimeInterval(6 * 3_600), mode: .shield, allowedApps: [])
            a.refresh()
            wall += 600; uptime += 600; a.refresh()
            boot = "b"; uptime = 30; wall = real.addingTimeInterval(630 - 8 * 3_600)
            let b = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            b.refresh()
            wall += 600; uptime += 600; b.refresh()
            boot = "c"; uptime = 20; wall = real.addingTimeInterval(1_260 + off - cBehind)
            let c = BlockingController(clock: { wall }, store: store, continuous: { uptime }, boot: { boot }, guardClient: Client())
            c.refresh()
            let expected = 6 * 3_600 - off - 1_260, slack = 120.0, added = cBehind == 0 ? 0 : off
            let left = c.activeBlocks.first.map { $0.end.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(left, expected - slack, "cBehind=\(cBehind): block too short")
            XCTAssertLessThan(left, expected + added + slack, "cBehind=\(cBehind): block longer than its real end + downtime")
            let freeze = c.freeze.map { $0.end.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(freeze, expected - slack, "cBehind=\(cBehind): freeze too short")
            XCTAssertLessThan(freeze, expected + added + slack, "cBehind=\(cBehind): freeze longer than its real end + downtime")
        }
    }
}
#endif
