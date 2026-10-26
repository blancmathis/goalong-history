#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r6 (PR #121 review): the exit of a running stake block compares its end and now in one frame.
final class ConcentrationStakeExitFrameTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }

    /// Clock set back 1 h while the stake block runs: the joker stays open until the block really ends.
    @MainActor func testSetBackKeepsStakeExitOpenUntilBlockEnd() throws {
        for setBack in [false, true] {
            let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/stake-exit-frame-" + UUID().uuidString))
            addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
            var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
            var now = date("2026-10-04"), uptime = 100.0
            let list = BlockList(name: "One")
            let b = BlockingController(document: .init(lists: [list]), clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
            let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, blocking: { b }, continuous: { uptime }, boot: { "test" })
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
            _ = try c.setCommitment(period: period, kind: .plan, target: 1, stake: .init(listIds: [list.id]))
            now = date("2026-10-05"); uptime += 86_400; c.applyMeasurements([], hasDefinition: true); b.refresh()
            let end = try XCTUnwrap(b.activeBlocks.first?.end)
            let step = end.timeIntervalSince(now) - 1_800
            XCTAssertGreaterThan(step, 3_600, "the block must outlast the set-back")
            now += step; uptime += step; b.refresh()
            if setBack { now -= 3_600; uptime += 1; b.refresh() }
            c.refresh()
            XCTAssertTrue(c.commitmentCards[0].canUseJoker, "setBack=\(setBack): exit closed 30 real minutes before the block end")
            XCTAssertNoThrow(try c.useCommitmentJoker(period: period), "setBack=\(setBack)")
            XCTAssertTrue(b.activeBlocks.isEmpty)
        }
    }
}
#endif
