#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r8 C8-01..C8-03: a « Difficile » block survives a quit, a zone change holds every non-free
/// window and writes the hold at once. Each test loops over a witness and the case once broken.
@MainActor final class BlockingQuitAndZoneHoldTests: XCTestCase {
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private func zone(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }
    /// 2026-10-05 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        zone("Europe/Paris").date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func store() throws -> BlockingStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("blocking-quit-zone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BlockingStore(directory: root.appendingPathComponent("Blocking"))
    }

    /// « Difficile » asks to retype 120 characters to stop. `shutdown` (module off; allowed: not a
    /// protecting lock) once deleted every started session when `hasLocks` was false, so the typing
    /// block was gone at relaunch, no text typed (C8-01). Witness: a locked block survives.
    func testQuitDuringATypingBlockDoesNotEndIt() throws {
        for lock in [BlockLock.locked, .typing] {
            let store = try store()
            try store.save(BlockingDocument(lists: [list]))
            var now = date(5, 10), uptime = 1_000.0
            let a = BlockingController(clock: { now }, store: store, continuous: { uptime }, boot: { "a" })
            a.start(listIDs: [list.id], until: date(5, 12), lock: lock)
            XCTAssertEqual(a.activeBlocks.first?.lock, lock)
            XCTAssertFalse(a.quitIsLocked && lock == .typing)
            a.shutdown()
            now += 30; uptime += 30
            let b = BlockingController(clock: { now }, store: store, continuous: { uptime }, boot: { "a" })
            XCTAssertEqual(b.activeBlocks.first?.lock, lock, "\(lock): block lost by quitting")
            XCTAssertEqual(b.activeBlocks.first?.end, date(5, 12), "\(lock)")
        }
    }

    /// docs/BLOCKING.md « Time zone »: a protected program window in progress (any lock except « Libre »)
    /// is held at its current end. `holdProgramWindows` once kept only `protectsLists` (password, locked):
    /// a « Difficile » range ended at once when the zone moved west (C8-02). Witness: a locked range.
    func testZoneChangeHoldsATypingProgramWindow() {
        for lock in [BlockLock.locked, .typing] {
            var current = zone("Europe/Paris"), now = date(5, 10)
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: lock)])
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendarProvider: { current },
                                       continuous: { now.timeIntervalSince1970 })
            XCTAssertEqual(c.activeBlocks.first?.end, date(5, 17))
            current = zone("Pacific/Honolulu"); c.refresh()   // 22:00 on Sunday in Honolulu
            XCTAssertEqual(c.activeBlocks.first?.end, date(5, 17), "\(lock): window not held")
            XCTAssertEqual(c.activeBlocks.first?.lock, lock, "\(lock)")
            now = date(5, 16, 59); c.refresh(); XCTAssertFalse(c.activeBlocks.isEmpty, "\(lock)")
        }
    }

    /// The hold of a zone change lives in `document.heldPrograms`; `refresh` once wrote it only when the
    /// last save was 60 s old, so a kill (guard reopens Goalong, Strict) within that minute lost the
    /// locked window (C8-03). Witness: the zone change 61 s after the last save.
    func testZoneChangeHoldSurvivesAKillWithinAMinute() throws {
        for delay in [61.0, 10] {
            let store = try store()
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: .locked)])
            try store.save(BlockingDocument(lists: [l]))
            var current = zone("Europe/Paris"), now = date(5, 10), uptime = 1_000.0
            let a = BlockingController(clock: { now }, store: store, calendarProvider: { current }, continuous: { uptime }, boot: { "a" })
            XCTAssertEqual(a.activeBlocks.first?.lock, .locked)
            now += delay; uptime += delay
            current = zone("Pacific/Honolulu"); a.refresh()
            XCTAssertEqual(a.activeBlocks.first?.end, date(5, 17), "delay=\(delay): held in memory")
            // kill -9: no shutdown. Relaunch a few seconds later, same boot, new zone.
            now += 5; uptime += 5
            let b = BlockingController(clock: { now }, store: store, calendarProvider: { current }, continuous: { uptime }, boot: { "a" })
            XCTAssertEqual(b.activeBlocks.first?.end, date(5, 17), "delay=\(delay): locked window lost after a kill")
            XCTAssertTrue(b.hasLocks, "delay=\(delay)")
        }
    }
}
#endif
