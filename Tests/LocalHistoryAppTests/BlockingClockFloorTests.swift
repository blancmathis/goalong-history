#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-044 r7 (review of PR #122): a clock behind at boot, then stepped forward, lifts T up to the last
/// trusted time of the previous boot (already proven), and blocks made meanwhile keep their length.
@MainActor final class BlockingClockFloorTests: XCTestCase {
    private let list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
    private var paris: Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Paris")!; return cal }
    /// The last sample of the previous boot (« a »), taken `before` seconds before `real`.
    private func previousBoot(_ real: Date, before: Double) -> BlockingClockState {
        let wall = real.addingTimeInterval(-before)
        return BlockingClockState(wall: wall, continuous: 90_000, boot: "a", anchor: wall.timeIntervalSince1970 - 90_000, frame: BlockingClock.frame)
    }

    /// Restart at 09:55, clock 8 h behind at boot, NTP steps it to real time at 10:01. Locked program
    /// 09:00-17:00 every day: it must hold, and end near real 17:00. Witness: clock right at boot.
    func testClockBehindAtBootThenSteppedForwardKeepsProgramWindow() {
        let cal = paris
        let real = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10))!
        for behind in [0.0, 8 * 3_600.0] {
            var wall = real.addingTimeInterval(-behind), uptime = 50.0
            var l = list
            l.program = BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 540, endMinute: 1_020)],
                                     lockedUntil: real.addingTimeInterval(7 * 86_400))
            var document = BlockingDocument(lists: [l]); document.clock = previousBoot(real, before: 300)
            let c = BlockingController(document: document, clock: { wall }, calendar: cal,
                                       continuous: { uptime }, boot: { "b" })
            c.refresh()
            wall = real.addingTimeInterval(60); uptime += 60; c.refresh()   // NTP steps the clock to real time
            XCTAssertTrue(c.activeBlocks.contains { if case .program = $0.origin { return true }; return false },
                          "behind=\(behind): program window lost for the boot")
            if behind > 0 { XCTAssertEqual(c.now.timeIntervalSince(real), -300 + 1, accuracy: 2, "T lifted to the floor, no further") }
            wall += 7.5 * 3_600; uptime += 7.5 * 3_600; c.refresh()   // real 17:31: the window is over
            XCTAssertFalse(c.activeBlocks.contains { if case .program = $0.origin { return true }; return false },
                           "behind=\(behind): program window shifted into the evening")
        }
    }

    /// A 1 h locked block started while the clock was 8 h behind keeps its real hour after the step forward.
    /// The step beyond the floor stays out of T. Witness: no step.
    func testBlockStartedWhileBehindKeepsItsLengthAfterTheStep() {
        let real = Date(timeIntervalSince1970: 1_790_000_000)
        for step in [false, true] {
            var wall = real.addingTimeInterval(-8 * 3_600), uptime = 50.0
            var document = BlockingDocument(lists: [list]); document.clock = previousBoot(real, before: 600)
            let c = BlockingController(document: document, clock: { wall }, continuous: { uptime }, boot: { "b" })
            c.refresh()
            c.start(listIDs: [list.id], until: c.now.addingTimeInterval(3_600), lock: .locked); c.refresh()
            wall += 600; uptime += 600; c.refresh()
            if step { wall = real.addingTimeInterval(86_400); uptime += 1; c.refresh() }   // stepped past real time
            XCTAssertTrue(c.hasLocks, "step=\(step): block ended at the step")
            XCTAssertEqual(c.activeBlocks.first.map { $0.end.timeIntervalSince(c.now) } ?? 0, 3_000, accuracy: 3, "step=\(step)")
            if step { XCTAssertEqual(c.now.timeIntervalSince(real), -600 + 1, accuracy: 2, "T capped at the floor") }
            wall += 3_010; uptime += 3_010; c.refresh()
            XCTAssertFalse(c.hasLocks, "step=\(step): block outlived its hour")
        }
    }

    /// The first sample of a boot sets T to the wall clock: no protected end may move, not even by the
    /// rounding of wall − continuous (CI r7: a 1.2e-7 s lift made an unchanged lock read as « shortened »).
    func testFirstSampleOfABootMovesNoEnd() {
        for previous in [nil, previousBoot(Date(timeIntervalSinceReferenceDate: 811_692_800), before: 300)] {
            for i in 0..<200 {   // a real `Date()` lives in reference-date seconds: wall − continuous rounds
                let wall = Date(timeIntervalSinceReferenceDate: 811_692_800.123_456 + Double(i) * 0.000_731)
                var l = list; l.program.lockedUntil = wall.addingTimeInterval(600)
                var document = BlockingDocument(lists: [l]); document.clock = previous
                let uptime = 1_000 + Double(i) * 0.37
                let c = BlockingController(document: document, clock: { wall }, continuous: { uptime }, boot: { "b" })
                XCTAssertEqual(c.lists.first?.program.lockedUntil, l.program.lockedUntil, "previous=\(previous != nil) uptime=\(uptime)")
                XCTAssertEqual(c.editCheck(l), .allowed)
            }
        }
    }
}
#endif
