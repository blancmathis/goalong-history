#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// T-044 C1-02: a manual clock rollback must not reopen a locked commitment.
final class C044ClockRollbackCommitmentTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }
    @MainActor private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/c044-rollback-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    @MainActor func testClockSetBackDoesNotReopenALockedCommitment() throws {
        let s = try store()
        var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: period, kind: .work, target: 180)
        now = now.addingTimeInterval(601); c.refresh()
        XCTAssertThrowsError(try c.deleteCommitment(period: period))   // locked, as designed
        now = date("2026-10-03", 23); c.refresh()                       // the user sets the Mac clock back 9 h
        XCTAssertThrowsError(try c.setCommitment(period: period, kind: .work, target: 30), "clock rollback lowered a locked commitment")
        XCTAssertThrowsError(try c.deleteCommitment(period: period), "clock rollback deleted a locked commitment")
        XCTAssertEqual(c.commitmentCards.first?.editMode, "harderOnly")
    }
    /// The app never saw the deadline (quit, or no refresh): continuous time since creation still closes the window.
    @MainActor func testContinuousTimeLocksWhenTheWallClockIsSetBackBeforeAnyRefresh() throws {
        let s = try store()
        var now = date("2026-10-04"), uptime = 1_000.0
        let make = { try ConcentrationController(store: s, clock: { now }, calendar: self.calendar, continuous: { uptime }, boot: { "boot-a" }) }
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try make().setCommitment(period: period, kind: .work, target: 180)
        uptime += 601; now = date("2026-10-04").addingTimeInterval(300)   // 10 min passed, clock set back to 08:05
        let c = try make()                                                // relaunch in the same boot
        XCTAssertThrowsError(try c.setCommitment(period: period, kind: .work, target: 30), "lower target")
        XCTAssertThrowsError(try c.deleteCommitment(period: period), "delete")
        XCTAssertEqual(c.setCommitmentOrNil(period: period, target: 240)?.target, 240, "harder stays allowed")
        XCTAssertEqual(c.commitmentCards.first?.editMode, "harderOnly")
        XCTAssertNotNil(try s.commitments().first?.lockedAt)
        uptime += 3600; now = date("2026-10-03", 23)                      // later, a reboot: the latch holds alone
        let rebooted = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { 5 }, boot: { "boot-b" })
        XCTAssertThrowsError(try rebooted.deleteCommitment(period: period), "latched lock reopened after a reboot")
    }
    /// Forward jumps: no lock before the wall or continuous deadline, and no global high-water mark.
    @MainActor func testForwardJumpsDoNotLockEarly() throws {
        let s = try store()
        var now = date("2026-10-04"), uptime = 50.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot-a" })
        let tomorrow = FocusCommitmentPeriod(kind: .day, key: "2026-10-05")
        _ = try c.setCommitment(period: tomorrow, kind: .work, target: 180)
        now = now.addingTimeInterval(3 * 3600); uptime += 30; c.refresh() // wall jumps 3 h ahead, still before 2026-10-05
        XCTAssertEqual(c.commitmentCards.first?.editMode, "free")
        XCTAssertNoThrow(try c.setCommitment(period: tomorrow, kind: .work, target: 60))
        now = date("2026-10-06"); uptime += 30; c.refresh()                // wall jumps past the deadline: stricter side, locks
        XCTAssertThrowsError(try c.deleteCommitment(period: tomorrow))
        now = date("2026-10-04", 9); uptime += 30; c.refresh()             // corrected back: stays locked, new ones stay free
        XCTAssertThrowsError(try c.deleteCommitment(period: tomorrow))
        let today = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: today, kind: .work, target: 180)
        now = now.addingTimeInterval(300); uptime += 300; c.refresh()
        XCTAssertEqual(c.commitmentCards.first { $0.commitment.period == today }?.editMode, "free")
        XCTAssertNoThrow(try c.deleteCommitment(period: today))
    }
    func testRuleIgnoresAnchorFromAnotherBootOrABackwardContinuousClock() {
        let created = date("2026-10-04")
        var value = FocusCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .work, target: 180, createdAt: created,
                                    createdClock: .init(wall: created, continuous: 1_000, boot: "a"))
        let rolledBack = date("2026-10-03", 23)
        func check(_ continuous: Double, _ boot: String) -> FocusCommitRule.Check {
            FocusCommitRule.check(old: value, new: nil, now: rolledBack, clock: .init(wall: rolledBack, continuous: continuous, boot: boot), calendar: calendar)
        }
        XCTAssertEqual(check(1_599, "a"), .free)
        guard case .locked = check(1_600, "a") else { return XCTFail("continuous deadline ignored") }
        XCTAssertEqual(check(9_999, "b"), .free)                          // another boot: continuous time says nothing
        XCTAssertEqual(check(10, "a"), .free)
        value.lockedAt = created.addingTimeInterval(600)
        guard case .locked = check(10, "b") else { return XCTFail("latched lock reopened") }
    }
}

private extension ConcentrationController {
    func setCommitmentOrNil(period: FocusCommitmentPeriod, target: Int) -> FocusCommitment? { try? setCommitment(period: period, kind: .work, target: target) }
}
#endif
