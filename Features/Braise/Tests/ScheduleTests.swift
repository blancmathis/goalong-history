import XCTest
@testable import BraiseCore
final class ScheduleTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Europe/Paris")!; return c }
    func date(_ string: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from:string)! }
    func testNightUsesStartDay() {
        let r = ScheduleRule(weekdays:[2],startMinute:1320,endMinute:480)
        XCTAssertFalse(r.contains(date("2026-09-21T21:59:59+02:00"),calendar:cal))
        XCTAssertTrue(r.contains(date("2026-09-21T22:00:00+02:00"),calendar:cal))
        XCTAssertTrue(r.contains(date("2026-09-22T07:59:59+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-09-22T08:00:00+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-09-22T22:00:00+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-09-21T07:00:00+02:00"),calendar:cal))
    }
    func testSameDay() {
        let r = ScheduleRule(weekdays:[2],startMinute:600,endMinute:900)
        XCTAssertTrue(r.contains(date("2026-09-21T11:00:00+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-09-21T15:00:00+02:00"),calendar:cal))
    }
    func testDisabledEmptyAndZeroLength() {
        let now = date("2026-09-21T23:00:00+02:00")
        for rule in [ScheduleRule(enabled:false),ScheduleRule(weekdays:[]),ScheduleRule(startMinute:0,endMinute:0)] {
            XCTAssertFalse(rule.contains(now,calendar:cal))
            XCTAssertNil(ScheduleEngine.nextTransition([rule],after:now,calendar:cal))
        }
    }
    func testWeekRollover() {
        let r = ScheduleRule(weekdays:[1],startMinute:1320,endMinute:480)
        XCTAssertTrue(r.contains(date("2026-09-28T07:00:00+02:00"),calendar:cal))
        let next = ScheduleEngine.nextTransition([r],after:date("2026-09-28T09:00:00+02:00"),calendar:cal)
        XCTAssertEqual(next?.date,date("2026-10-04T22:00:00+02:00"))
        XCTAssertEqual(next?.active,true)
    }
    func testOverlapsAndAdjacentRanges() {
        let a = ScheduleRule(weekdays:[2],startMinute:600,endMinute:900)
        let b = ScheduleRule(weekdays:[2],startMinute:840,endMinute:1020)
        let c = ScheduleRule(weekdays:[2],startMinute:1020,endMinute:1080)
        let next = ScheduleEngine.nextTransition([a,b,c],after:date("2026-09-21T11:00:00+02:00"),calendar:cal)
        XCTAssertEqual(next?.date,date("2026-09-21T18:00:00+02:00"))
        XCTAssertEqual(next?.active,false)
    }
    func testSpringDST() {
        let r = ScheduleRule(weekdays:[7],startMinute:1320,endMinute:480)
        XCTAssertTrue(r.contains(date("2026-03-29T07:59:59+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-03-29T08:00:00+02:00"),calendar:cal))
        let next = ScheduleEngine.nextTransition([r],after:date("2026-03-28T23:00:00+01:00"),calendar:cal)
        XCTAssertEqual(next?.date,date("2026-03-29T08:00:00+02:00"))
    }
    func testAutumnDST() {
        let r = ScheduleRule(weekdays:[7],startMinute:1320,endMinute:480)
        let next = ScheduleEngine.nextTransition([r],after:date("2026-10-24T23:00:00+02:00"),calendar:cal)
        XCTAssertEqual(next?.date,date("2026-10-25T08:00:00+01:00"))
    }
    func testMissingDSTHour() {
        let r = ScheduleRule(weekdays:[1],startMinute:150,endMinute:240)
        XCTAssertTrue(r.contains(date("2026-03-29T03:15:00+02:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-03-29T04:00:00+02:00"),calendar:cal))
    }
    func testRepeatedDSTEndUsesLastOccurrence() {
        let r = ScheduleRule(weekdays:[1],startMinute:60,endMinute:150)
        XCTAssertTrue(r.contains(date("2026-10-25T02:15:00+01:00"),calendar:cal))
        XCTAssertFalse(r.contains(date("2026-10-25T02:30:00+01:00"),calendar:cal))
    }
    func testPureRed() {
        let g = ChannelGains(intensity:1,brightness:1)
        XCTAssertEqual(g.red,1); XCTAssertEqual(g.green,0); XCTAssertEqual(g.blue,0)
    }
    func testNeutralAndClamping() {
        XCTAssertEqual(ChannelGains(intensity:0,brightness:1),ChannelGains(intensity:-1,brightness:2))
        let g = ChannelGains(intensity:0,brightness:1)
        XCTAssertEqual(g.red,1); XCTAssertEqual(g.green,1); XCTAssertEqual(g.blue,1)
        XCTAssertEqual(ChannelGains(intensity:1,brightness:0).red,0.2)
    }
    func testPersistence() throws {
        var p = Preferences(); p.mode = .auto; p.rules = [ScheduleRule(weekdays:[2,4,6])]
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self,from:JSONEncoder().encode(p)),p)
    }
}
