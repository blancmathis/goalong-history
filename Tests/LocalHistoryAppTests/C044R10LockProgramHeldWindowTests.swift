#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r10 C10-01: a program lock set after a hold reaches the held window.
/// Each test loops over a witness (must pass) and the faulty case.
@MainActor final class C044R10LockProgramHeldWindowTests: XCTestCase {
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private func zone(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }
    /// 2026-10-05 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        zone("Europe/Paris").date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// docs/BLOCKING.md « Range lock »: while `program.lockedUntil > now`, every window of the program is
    /// `locked`. A window held by a zone change (#127: any non-free lock) keeps the range lock in
    /// `heldPrograms`; `programBlocks` skips held ranges, so `lockProgram` (#130) never reaches it: the
    /// block stays « Difficile », the typed text stops it and the skip removes the window until 17:00
    /// while the program is locked. Witness: same steps without the zone change.
    func testLockProgramAfterAZoneHoldLocksTheHeldWindow() {
        for zoneChange in [false, true] {
            var current = zone("Europe/Paris"), now = date(5, 10)
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: .typing)])
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendarProvider: { current },
                                       continuous: { now.timeIntervalSince1970 })
            XCTAssertEqual(c.activeBlocks.first?.lock, .typing)
            if zoneChange { current = zone("Europe/London"); now += 60; c.refresh() }   // 09:01 in London, same window
            XCTAssertEqual(c.activeBlocks.count, 1, "zoneChange=\(zoneChange)")
            c.lockProgram(listID: l.id, until: date(5, 17))
            XCTAssertTrue(c.quitIsLocked, "zoneChange=\(zoneChange)")
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked, "zoneChange=\(zoneChange): held window not locked by the program lock")
            guard let id = c.activeBlocks.first?.id else { XCTFail("no block"); continue }
            c.stop(id, typed: c.typingChallenge(for: id))
            now += 60; c.refresh()
            XCTAssertFalse(c.activeBlocks.isEmpty, "zoneChange=\(zoneChange): locked program window stopped by typed text")
        }
    }

    /// Same root, clock-jump hold: a reboot with the clock 1 h behind holds the « Mot de passe » window
    /// (same boot, `trusted` absorbs the jump: no hold, C10-32), then the program locked: the password no
    /// longer stops it.
    func testLockProgramAfterAClockJumpHoldBlocksThePasswordStop() throws {
        for jump in [false, true] {
            var now = date(5, 10), uptime = 50_000.0, boot = "a"
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: .password)])
            let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
            let c = BlockingController(document: BlockingDocument(lists: [l], passwordLock: credential), clock: { now }, calendar: zone("Europe/Paris"),
                                       continuous: { uptime }, boot: { boot })
            c.refresh()
            XCTAssertEqual(c.activeBlocks.first?.lock, .password)
            if jump { now -= 3_600; uptime = 10; boot = "b"; c.refresh() }   // reboot, clock 1 h behind: the window is held
            XCTAssertEqual(c.activeBlocks.count, 1, "jump=\(jump)")
            c.lockProgram(listID: l.id, until: now.addingTimeInterval(7_200))
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked, "jump=\(jump): held password window not locked by the program lock")
            guard let id = c.activeBlocks.first?.id else { XCTFail("no block"); continue }
            c.stop(id, password: "fixture")
            now += 60; uptime += 60; c.refresh()
            XCTAssertFalse(c.activeBlocks.isEmpty, "jump=\(jump): locked program window stopped by the password")
        }
    }

    /// C10-31 (#130 x hold): a typed stop of a zone-held window, then the program locked. #130 clears the
    /// skip, but the stop had dropped the window from `heldPrograms`; at 04:01 in New York no window is in
    /// progress, so nothing blocked until 15:00 Paris. The held window must block again until its end.
    func testLockProgramAfterAStopOfAZoneHeldWindowRevivesIt() {
        for zoneChange in [false, true] {
            var current = zone("Europe/Paris"), now = date(5, 10)
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: .typing)])
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendarProvider: { current },
                                       continuous: { now.timeIntervalSince1970 })
            c.refresh()
            if zoneChange { current = zone("America/New_York"); now += 60; c.refresh() }   // 04:01 in New York: no window there
            XCTAssertEqual(c.activeBlocks.count, 1, "zoneChange=\(zoneChange)")
            guard let id = c.activeBlocks.first?.id else { XCTFail("no block"); continue }
            c.stop(id, typed: c.typingChallenge(for: id))
            now += 60; c.refresh()
            XCTAssertTrue(c.activeBlocks.isEmpty, "zoneChange=\(zoneChange): typed stop works before the lock")
            c.lockProgram(listID: l.id, until: date(5, 17))
            now += 60; c.refresh()
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked, "zoneChange=\(zoneChange): program lock set later must win over the stop")
            XCTAssertEqual(c.activeBlocks.first?.end, date(5, 17), "zoneChange=\(zoneChange): window kept to its own end")
        }
    }
}
#endif
