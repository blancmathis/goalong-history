#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-044 r5: clock-anchor.json (#119, C4-03) edges.
final class ConcentrationClockAnchorTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }

    private func focusStore(_ tag: String) throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/clock-anchor-\(tag)-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }

    /// Damaged anchor: Goalong still launches, today stays open, and the anchor is rewritten so a set-back
    /// relaunch is still caught.
    @MainActor func testCorruptClockAnchorIsReplaced() throws {
        let s = try focusStore("corrupt")
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: s.directory.appendingPathComponent("clock-anchor.json"))
        var now = FocusCalendar.dayInterval("2026-10-05", calendar: calendar)!.start.addingTimeInterval(8 * 3_600), uptime = 1_000.0
        let first = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        XCTAssertNoThrow(try first.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .work, target: 60))
        now = now.addingTimeInterval(-86_400); uptime += 10
        let relaunched = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "test" })
        XCTAssertThrowsError(try relaunched.setCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .work, target: 60))
    }

    /// Anchor from another boot is ignored: after a reboot today can be committed.
    @MainActor func testClockAnchorFromAnotherBootIsIgnored() throws {
        let s = try focusStore("boot")
        var now = FocusCalendar.dayInterval("2026-10-05", calendar: calendar)!.start.addingTimeInterval(8 * 3_600), uptime = 1_000.0
        _ = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot-a" })
        now = now.addingTimeInterval(-86_400); uptime = 50
        let rebooted = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { "boot-b" })
        XCTAssertNoThrow(try rebooted.setCommitment(period: .init(kind: .day, key: "2026-10-04"), kind: .work, target: 60))
    }
}
#endif
