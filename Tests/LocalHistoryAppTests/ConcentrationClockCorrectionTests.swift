#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 C5-05: a clock ahead at boot, set right soon after, must not close today until the next reboot.
final class ConcentrationClockCorrectionTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }

    private func focusStore(_ tag: String) throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/clock-correction-\(tag)-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    private func at(_ day: String, hour: Double) -> Date { FocusCalendar.dayInterval(day, calendar: calendar)!.start.addingTimeInterval(hour * 3_600) }

    /// Mac booted with its clock one day ahead; the network sets it right two minutes later. Today opens,
    /// with or without a relaunch of Goalong.
    @MainActor func testClockAheadAtBootThenSetRightOpensToday() throws {
        for relaunch in [false, true] {
            let s = try focusStore("ahead")
            var now = at("2026-10-06", hour: 8), uptime = 60.0
            var c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
            now = now.addingTimeInterval(-86_400 + 120); uptime += 120          // set right: 2026-10-05 08:02
            if relaunch { c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" }) }
            else { c.refresh() }
            XCTAssertNoThrow(try c.setCommitment(period: .init(kind: .day, key: "2026-10-05"), kind: .work, target: 60), "relaunch=\(relaunch)")
            // The new commitment is not settled at once by the old, ahead proof.
            XCTAssertNil(c.commitments.first { $0.period.key == "2026-10-05" }?.result, "relaunch=\(relaunch)")
            // A later relaunch, past the boot window, keeps the correction.
            now += 3_600; uptime += 3_600
            let later = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
            XCTAssertNil(later.commitments.first { $0.period.key == "2026-10-05" }?.result, "relaunch=\(relaunch)")
        }
    }

    /// Long after boot, a clock set back is still caught (#109, #119): the past day stays closed.
    @MainActor func testSetBackLongAfterBootStaysCaught() throws {
        for relaunch in [false, true] {
            let s = try focusStore("late")
            var now = at("2026-10-06", hour: 8), uptime = 5_000.0
            var c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
            now = now.addingTimeInterval(-86_400); uptime += 10
            if relaunch { c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" }) }
            else { c.refresh() }
            XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-05"), kind: .work, target: 60), "relaunch=\(relaunch)")
        }
    }

    /// A correction never reopens a commitment already locked: its free window stays closed.
    @MainActor func testCorrectionKeepsALockedCommitmentLocked() throws {
        let s = try focusStore("locked")
        var now = at("2026-10-06", hour: 23 + 55.0 / 60), uptime = 10.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        try c.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .work, target: 60)
        now += 360; uptime += 360; c.refresh()                                  // window closed at midnight
        now = now.addingTimeInterval(-86_400); uptime += 10; c.refresh()        // set back one day, within the boot window
        XCTAssertThrowsError(try c.deleteCommitment(period: .init(kind: .day, key: "2026-10-06")))
        XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .work, target: 30))
    }
}
#endif
