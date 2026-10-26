#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r9 volet C1: Blocage edge cases (lock set after « Arrêter », DST fall-back midnight range).
/// Each test loops over a witness (must pass) and the faulty case.
@MainActor final class C044R9C1EdgeTests: XCTestCase {
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private func zone(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }
    /// 2026-10-05 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        zone("Europe/Paris").date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// docs/BLOCKING.md « Range lock »: while `program.lockedUntil > now`, every window of the program
    /// is `locked`. A free window stopped with « Arrêter » gets a skip until its end; `lockProgram`
    /// afterwards does not bring it back (`programBlocks` reads the skip before `isLocked`).
    /// Witness: lockProgram without a prior skip gives a locked block.
    func testLockProgramAfterSkippingAFreeWindow() {
        for skipFirst in [false, true] {
            let now = date(5, 10)
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 540, endMinute: 1_020, lock: .free)])
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendarProvider: { self.zone("Europe/Paris") },
                                       continuous: { now.timeIntervalSince1970 })
            XCTAssertEqual(c.activeBlocks.count, 1)
            if skipFirst, let id = c.activeBlocks.first?.id { c.stop(id); XCTAssertTrue(c.activeBlocks.isEmpty) }
            c.lockProgram(listID: l.id, until: date(5, 17))
            c.refresh()
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked, "skipFirst=\(skipFirst): program locked but window not blocking")
        }
    }

    /// Range crossing midnight (22:00 → 02:00, Saturday) on the DST fall-back night 2026-10-25 in Paris.
    /// The window must end at 02:00 civil on Sunday and still block at 01:30. Witness: the week before.
    func testMidnightRangeOnFallBackNight() {
        for day in [17, 24] {
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [6], startMinute: 1_320, endMinute: 120, lock: .locked)])
            var now = date(day, 23)
            let c = BlockingController(document: BlockingDocument(lists: [l]), clock: { now }, calendarProvider: { self.zone("Europe/Paris") },
                                       continuous: { now.timeIntervalSince1970 })
            XCTAssertEqual(c.activeBlocks.first?.end, date(day + 1, 2), "day \(day)")
            now = date(day + 1, 1, 30); c.refresh()
            XCTAssertEqual(c.activeBlocks.first?.lock, .locked, "day \(day)")
            now = date(day + 1, 2, 1); c.refresh()
            XCTAssertTrue(c.activeBlocks.isEmpty, "day \(day)")
        }
    }
}
#endif
