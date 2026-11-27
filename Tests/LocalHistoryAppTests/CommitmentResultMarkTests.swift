#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-03): a clock set back, in the same boot, below the end of a staked day commitment. The
/// settlement is dated at the period's end; the stake and the joker that follow must be saved too.
final class CommitmentResultMarkTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func date(_ key: String, _ hour: Double) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(hour * 3600) }

    @MainActor func testStakeAndJokerSavedAfterSetBackSettlement() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/commitment-mark-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let s = FocusStore(directory: dir)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        var now = date("2026-11-26", 9), uptime = 1_000.0
        let list = BlockList(name: "One")
        let b = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "b" })
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b }, continuous: { uptime }, boot: { "b" })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-11-26")
        _ = try c.setCommitment(period: period, kind: .plan, target: 1, stake: .init(listIds: [list.id]))
        // Real 00:01 on the 27th, wall clock set back one hour: 23:01 on the 26th.
        uptime += 15.0 * 3600 + 60; now = date("2026-11-26", 23 + 1.0 / 60)
        c.applyMeasurements([], hasDefinition: true); b.refresh()
        XCTAssertNil(c.error)
        let result = try XCTUnwrap(c.commitments.first?.result)
        XCTAssertEqual(result.stake.state, .applied)
        XCTAssertNotNil(result.stake.at, "the stake receipt is saved")
        XCTAssertEqual(b.activeBlocks.filter { $0.origin == .commitment(c.commitments[0].id) }.count, 1)
        // Reload the store between settlement and joker.
        uptime += 60; now += 60
        let c2 = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b }, continuous: { uptime }, boot: { "b" })
        XCTAssertNoThrow(try c2.useCommitmentJoker(period: period))
        XCTAssertNotNil(c2.commitments.first?.result?.jokerAt)
        XCTAssertEqual(c2.commitments.first?.result?.stake.state, .cancelled)
        b.refresh()
        XCTAssertTrue(b.activeBlocks.isEmpty, "the joker lifts the stake block")
    }
}
#endif
