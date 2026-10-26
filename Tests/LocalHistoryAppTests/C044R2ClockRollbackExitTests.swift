#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// T-044 tour 2: after `missed`, the joker and « J'ai tenu » exits close at the end of the settle day
/// (docs/CONCENTRATION.md § Result). Setting the Mac clock back must not reopen them (same family as C1-02).
final class C044R2ClockRollbackExitTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }
    @MainActor private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/c044r2-exit-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    @MainActor func testClockSetBackDoesNotReopenAClosedExit() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: day, kind: .plan, target: 1)
        now = date("2026-10-05"); c.refresh(); c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.commitments.first?.result?.outcome, .missed)
        now = date("2026-10-07"); c.refresh()
        XCTAssertThrowsError(try c.declareCommitmentHeld(period: day))   // closed, as designed
        XCTAssertThrowsError(try c.useCommitmentJoker(period: day))
        now = date("2026-10-05", 12); c.refresh()                        // the user sets the Mac clock back 2 days
        XCTAssertThrowsError(try c.declareCommitmentHeld(period: day), "clock rollback reopened « J'ai tenu »")
        XCTAssertThrowsError(try c.useCommitmentJoker(period: day), "clock rollback reopened the joker")
        XCTAssertEqual(c.commitments.first?.result?.outcome, .missed, "a closed missed day became held after a clock rollback")
    }

    /// Same family: a clock set back in the same boot must not let a commitment be created for a day that
    /// is already over in real time (it would then settle `held` from known statuses and inflate the series).
    @MainActor func testClockSetBackDoesNotAllowAPastCommitment() throws {
        let s = try store(); var now = date("2026-10-04"), uptime = 1_000.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot-a" })
        _ = try c.setCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .plan, target: 1)
        now = date("2026-10-07"); uptime += 3 * 86_400; c.refresh()
        now = date("2026-10-05", 12); uptime += 3_600                    // the user sets the Mac clock back
        XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-05"), kind: .plan, target: 1),
                             "clock rollback created a commitment for a day already over")
        XCTAssertNoThrow(try c.setCommitment(period: .init(kind: .day, key: "2026-10-07"), kind: .plan, target: 1))
        let rebooted = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { 5 }, boot: { "boot-b" })
        XCTAssertNoThrow(try rebooted.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .plan, target: 1),
                         "another boot falls back to the wall clock (L-05 limit)")
    }
    /// The exit also closes by continuous time since settle in the same boot, with no refresh at the deadline.
    @MainActor func testExitClosesByContinuousTimeWithoutRefresh() throws {
        let s = try store(); var now = date("2026-10-04"), uptime = 1_000.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot-a" })
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: day, kind: .plan, target: 1)
        now = date("2026-10-05"); uptime += 86_400; c.refresh(); c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.commitments.first?.result?.outcome, .missed)
        now = date("2026-10-05", 12); uptime += 2 * 86_400                // 2 real days later, the wall clock was set back
        XCTAssertThrowsError(try c.declareCommitmentHeld(period: day), "continuous time since settle did not close the exit")
    }
}
#endif
