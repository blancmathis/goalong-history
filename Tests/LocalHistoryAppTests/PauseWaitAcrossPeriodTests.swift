#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-04): a wait before a pause, started before the period ends, is still valid after it.
final class PauseWaitAcrossPeriodTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Europe/Paris")!; return result
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func ask(_ policy: PausePolicy, _ usage: PauseUsage?, _ now: Date) -> (PauseDecision, PauseUsage) {
        PauseEngine.request(policy, usage: usage, lock: .locked, hasPassword: false, proof: .none, now: now, calendar: calendar)
    }

    func testWaitStartedBeforeMidnightIsHonouredAfterIt() {
        let policy = PausePolicy(budgetMinutes: 10, period: .day, gate: .wait(minutes: 10))
        let (first, usage) = ask(policy, nil, date(27, 23, 55))
        XCTAssertEqual(first, .waiting(until: date(28, 0, 5)))
        let (second, after) = ask(policy, usage, date(28, 0, 5))
        XCTAssertEqual(second, .granted(end: date(28, 0, 15), extra: false))
        XCTAssertEqual(after.count, 1)
    }

    func testDayLongWaitAndWeekBoundary() {
        let day = PausePolicy(budgetMinutes: 10, period: .day, gate: .wait(minutes: 1_440))
        let (_, usage) = ask(day, nil, date(27, 12, 0))
        guard case .granted = ask(day, usage, date(28, 12, 1)).0 else { return XCTFail("24 h wait lost at midnight") }
        // Sunday 29/11 23:55 → Monday 30/11 00:05: a new week.
        let week = PausePolicy(budgetMinutes: 10, period: .week, gate: .wait(minutes: 10))
        let (_, w) = ask(week, nil, date(29, 23, 55))
        guard case .granted = ask(week, w, date(30, 0, 5)).0 else { return XCTFail("wait lost at week boundary") }
    }

    func testStaleWaitStillRestarts() {
        let policy = PausePolicy(budgetMinutes: 10, period: .day, gate: .wait(minutes: 10))
        let (_, usage) = ask(policy, nil, date(27, 23, 50))
        // 00:20 is past 00:00 + 5 min claim window: the wait starts again.
        XCTAssertEqual(ask(policy, usage, date(28, 0, 20)).0, .waiting(until: date(28, 0, 30)))
    }
}
#endif
