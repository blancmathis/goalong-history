#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-06): a protected window held across a zone change still shows « En cours » until its real end.
final class HeldWindowRuleStateTests: XCTestCase {
    private func zone(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }

    @MainActor func testHeldWindowStaysRunningAfterZoneChange() throws {
        let paris = zone("Europe/Paris")
        let now = paris.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22, minute: 30))!   // Friday
        let end = paris.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 23))!
        for lock in [BlockLock.locked, .password] {
            var list = BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")])
            list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [5], startMinute: 1_260, endMinute: 1_380, lock: lock)])
            let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
            var current = paris
            let c = BlockingController(document: BlockingDocument(lists: [list], passwordLock: credential), clock: { now },
                                       calendarProvider: { current }, continuous: { now.timeIntervalSince1970 })
            current = zone("Europe/Athens"); c.refresh()                                  // 23:30 in Athens
            XCTAssertEqual(c.activeBlocks.first?.end, end, "\(lock): the engine holds the window")
            let rule = try XCTUnwrap(BlockRules.current(blocking: c, braise: nil, now: now, calendar: current).first)
            XCTAssertEqual(rule.state, .running(until: end), "\(lock): shown as running until 00:00 Athens")
            XCTAssertEqual(rule.lock, lock)
        }
    }
}
#endif
