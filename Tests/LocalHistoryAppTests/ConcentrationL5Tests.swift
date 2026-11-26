#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// T-057 L5: concentration-01 (one decision time for a settlement), -02 (file day fixed per session), -03 (events in order
/// after a clock set back).
final class ConcentrationL5Tests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; c.locale = Locale(identifier: "en_US"); return c
    }
    @MainActor private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/focus-l5-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }

    /// concentration-02: a free session started 00:30 Paris on 26 Nov; zone changed to Vancouver (its start is now the 25th).
    @MainActor func testSessionKeepsItsFileDayAfterAZoneChange() throws {
        let s = try store(), paris = calendar("Europe/Paris"), vancouver = calendar("America/Vancouver")
        var now = paris.date(from: .init(year: 2026, month: 11, day: 26, hour: 0, minute: 30))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: paris)
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil))
        let id = c.currentSession!.id
        XCTAssertEqual(try s.sessionDays(), ["2026-11-26"])
        now = now.addingTimeInterval(1800)
        let moved = try ConcentrationController(store: s, clock: { now }, calendar: vancouver)
        XCTAssertEqual(moved.currentSession?.id, id)
        try moved.stopSession()
        XCTAssertEqual(try s.sessionDays(), ["2026-11-26"], "no copy in the 25th")
        XCTAssertEqual(try s.sessions("2026-11-26").filter { $0.id == id }.count, 1)
        XCTAssertNotNil(try s.sessions("2026-11-26").first?.endedAt)
        XCTAssertNil(try ConcentrationController(store: s, clock: { now }, calendar: vancouver).currentSession, "not resurrected")
    }

    /// concentration-02: copies already written in two files by the old code are repaired at launch (the closed one stays).
    @MainActor func testDuplicateCopiesAreRepairedAtLaunch() throws {
        let s = try store(), cal = calendar("UTC")
        let start = cal.date(from: .init(year: 2026, month: 11, day: 26, hour: 8))!
        var open = FocusSession(intent: "Lire", mode: FocusMode(minutes: nil), startedAt: start, events: [.init(kind: .start, at: start)])
        try s.saveSessions([open], day: "2026-11-26")
        open.events.append(.init(kind: .stop, at: start.addingTimeInterval(600), reason: .member))
        try s.saveSessions([open], day: "2026-11-25")
        // The open copy has to be rewritten as open for the other file.
        var stillOpen = open; stillOpen.events.removeLast()
        try s.saveSessions([stillOpen], day: "2026-11-26")
        let c = try ConcentrationController(store: s, clock: { start.addingTimeInterval(900) }, calendar: cal)
        XCTAssertNil(c.currentSession)
        let all = try s.sessionDays().flatMap { try s.sessions($0) }.filter { $0.id == open.id }
        XCTAssertEqual(all.count, 1); XCTAssertNotNil(all.first?.endedAt)
    }

    /// concentration-03: the wall clock goes back before the start: « Arrêter » still works, events stay in order.
    @MainActor func testStopAndSkipWorkAfterTheClockIsSetBack() throws {
        let s = try store(), cal = calendar("UTC")
        var now = cal.date(from: .init(year: 2026, month: 11, day: 26, hour: 12))!
        let c = try ConcentrationController(store: s, clock: { now }, calendar: cal)
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil))
        now = now.addingTimeInterval(-3600)
        try c.stopSession()
        XCTAssertNil(c.currentSession)
        let saved = try XCTUnwrap(try s.sessions("2026-11-26").first)
        XCTAssertNotNil(saved.endedAt)
        XCTAssertTrue(saved.valid)
        XCTAssertNil(try ConcentrationController(store: s, clock: { now }, calendar: cal).currentSession)

        let p = try ConcentrationController(store: try store(), clock: { now }, calendar: cal)
        try p.startSession(intent: "Pomodoro", mode: FocusMode(kind: .pomodoro))
        now = now.addingTimeInterval(600)
        try p.skipPhase()
        now = now.addingTimeInterval(-7200)
        XCTAssertNoThrow(try p.skipPhase(), "a skip older than the last event is refused by the file")
        XCTAssertTrue(p.currentSession?.valid ?? false)
    }

    /// concentration-01: wall clock set back below the end of a day commitment while continuous time proves it ended.
    @MainActor func testSettlementIsPublishedOnlyWithAResultAfterAClockSetBack() throws {
        let s = try store(), cal = calendar("Europe/Paris")
        var now = FocusCalendar.dayInterval("2026-10-04", calendar: cal)!.start.addingTimeInterval(9 * 3600)
        var uptime = 5_000.0
        let c = try ConcentrationController(store: s, clock: { now }, calendar: cal, continuous: { uptime }, boot: { "b" })
        let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: period, kind: .work, target: 180)
        now = FocusCalendar.dayInterval("2026-10-04", calendar: cal)!.start.addingTimeInterval(23 * 3600 + 300)
        uptime += 15.5 * 3600                      // proven: 00:30 the next day; wall: 23:05
        c.refresh()
        let settled = c.commitments.first { $0.period == period }
        XCTAssertNotNil(settled?.result, "settled with a real result, not published empty")
        c.refresh()
        XCTAssertEqual(c.commitments.filter { $0.result != nil }.count, 1)
    }
}
#endif
