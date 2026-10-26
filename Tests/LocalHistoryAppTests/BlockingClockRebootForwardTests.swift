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
            let program = (c.lists.first?.program.lockedUntil).map { $0.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(program, 7 * 86_400 - elapsed - slack, "cBehind=\(cBehind): program lock time left")
            let freeze = c.freeze.map { $0.end.timeIntervalSince(c.now) } ?? -1
            XCTAssertGreaterThan(freeze, 6 * 3_600 - elapsed - slack, "cBehind=\(cBehind): freeze time left")
        }
    }
}
#endif
