#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 bugs-donnees: Focus/ storage recovery, read cost and status log.
final class FocusStorageRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18
    private func store() throws -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/focus-recovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        return s
    }
    private func session(on date: Date) -> FocusSession {
        var value = FocusSession(intent: "Lire", mode: FocusMode(minutes: 5), startedAt: date, events: [.init(kind: .start, at: date)])
        value.events.append(.init(kind: .stop, at: date.addingTimeInterval(300), reason: .member)); return value
    }
    private func names(_ s: FocusStore, _ area: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: s.directory.appendingPathComponent(area).path)) ?? []).sorted()
    }
    private func damage(_ s: FocusStore, _ path: String) {
        chmod(s.directory.appendingPathComponent(path).path, 0o644)
    }

    // bugs-donnees-01
    @MainActor func testRefusedPastDayIsSetAsideAndModuleStarts() throws {
        let s = try store(), old = now.addingTimeInterval(-40 * 86_400), day = FocusCalendar.dayKey(old, calendar: .current)
        try s.saveSessions([session(on: old)], day: day); damage(s, "sessions/\(day).json")
        try s.savePrompts(FocusPromptState(day: day)); damage(s, "prompts.json")
        let c = try ConcentrationController(store: s, clock: { self.now })
        XCTAssertEqual(c.error, ConcentrationController.setAsideNotice)
        XCTAssertTrue(FocusUIError.isReadableSentence(ConcentrationController.setAsideNotice))
        XCTAssertFalse(names(s, "sessions").contains(day + ".json"))
        XCTAssertTrue(names(s, "sessions").contains { $0.hasPrefix(day + ".damaged-") }, "moved aside, never deleted")
        XCTAssertTrue(names(s, "").contains { $0.hasPrefix("prompts.damaged-") })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertNotNil(c.currentSession)
    }
    @MainActor func testTodayYesterdayOrRunningSessionBlockStayStrict() throws {
        for offset in [0, -1] {
            let s = try store(), date = now.addingTimeInterval(Double(offset) * 86_400), day = FocusCalendar.dayKey(date, calendar: .current)
            try s.saveSessions([session(on: date.addingTimeInterval(-600))], day: day); damage(s, "sessions/\(day).json")
            XCTAssertThrowsError(try ConcentrationController(store: s, clock: { self.now }))
            XCTAssertTrue(names(s, "sessions").contains(day + ".json"))
        }
        let s = try store(), old = now.addingTimeInterval(-40 * 86_400), day = FocusCalendar.dayKey(old, calendar: .current)
        try s.saveSessions([session(on: old)], day: day); damage(s, "sessions/\(day).json")
        let list = BlockList(name: "Sites", sites: [.init(pattern: "example.org")])
        let b = BlockingController(document: BlockingDocument(lists: [list]), clock: { self.now }, continuous: { self.now.timeIntervalSince1970 })
        try b.startFocusBlock(id: UUID(), listIDs: [list.id], until: now.addingTimeInterval(600), lock: .locked)
        XCTAssertThrowsError(try ConcentrationController(store: s, clock: { self.now }, blocking: { b }), "a session block runs: its session may be in that file")
        XCTAssertTrue(names(s, "sessions").contains(day + ".json"))
    }

    // bugs-donnees-02
    @MainActor func testLaunchDecodesEachDayOnceAndANewSessionReadsNoPastDay() throws {
        final class Reads { var days: [String] = [] }
        let reads = Reads(); var s = try store()
        var oldest: FocusSession?
        for n in 2...61 {
            let date = now.addingTimeInterval(-Double(n) * 86_400), value = session(on: date)
            try s.saveSessions([value], day: FocusCalendar.dayKey(date, calendar: .current)); if n == 61 { oldest = value }
        }
        s.onSessionsRead = { reads.days.append($0) }
        let c = try ConcentrationController(store: s, clock: { self.now })
        let today = FocusCalendar.dayKey(now, calendar: .current)
        let pastReads = reads.days.filter { $0 != today }
        XCTAssertEqual(pastReads.count, 60, "one decode per past day at launch, not two")
        XCTAssertEqual(Set(pastReads).count, 60)
        reads.days.removeAll()
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertEqual(reads.days.filter { $0 != today }, [], "a new session scans no past day")
        try c.stopSession()
        reads.days.removeAll()
        let oldestDay = FocusCalendar.dayKey(oldest!.startedAt, calendar: .current)
        try c.recordOutcome(sessionID: oldest!.id, outcome: .done)
        XCTAssertEqual(Set(reads.days), [oldestDay], "the indexed day only")
        XCTAssertEqual(try s.sessions(oldestDay).first?.outcome, .done)
        XCTAssertEqual(try s.sessionDays().count, 61, "history is never purged")
    }
}
#endif
