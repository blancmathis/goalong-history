#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class ConcentrationEarnTests: XCTestCase {
    private func store() throws -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/concentration-earn-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false
        try store.saveSettings(settings); return store
    }
    @MainActor func testNormalTimedCompletionCreditsExactlyOnceAfterPersistence() throws {
        var now = Date(timeIntervalSince1970:1791453600)
        let list = BlockList(name:"Sites",quotaMinutesPerDay:10,earn:.init())
        let b = BlockingController(document:.init(lists:[list]),clock:{now},continuous:{now.timeIntervalSince1970})
        let s = try store(), c = try ConcentrationController(store:s,clock:{now},blocking:{b})
        try c.startSession(intent:"Travail",mode:FocusMode(minutes:25))
        let id = c.currentSession!.id
        now = now.addingTimeInterval(25 * 60); c.refresh(); c.refresh()
        XCTAssertNil(c.currentSession); XCTAssertEqual(b.earnedMinutesToday[list.id],5)
        let saved = try s.sessions(BlockingController.dayKey(now)).first { $0.id == id }
        XCTAssertEqual(saved?.events.last?.reason,.completed)
        XCTAssertEqual(b.snapshot.usage?.earnedSessionIDs,[id])
    }
    @MainActor func testManualStopAndModuleDisableEarnNothing() throws {
        var now = Date(timeIntervalSince1970:1791453600)
        let list = BlockList(name:"Sites",quotaMinutesPerDay:10,earn:.init())
        let b = BlockingController(document:.init(lists:[list]),clock:{now},continuous:{now.timeIntervalSince1970})
        let c = try ConcentrationController(store:store(),clock:{now},blocking:{b})
        try c.startSession(intent:"Travail",mode:FocusMode(minutes:60))
        now = now.addingTimeInterval(25 * 60); try c.stopSession()
        XCTAssertTrue(b.earnedMinutesToday.isEmpty)
        try c.startSession(intent:"Travail",mode:FocusMode(minutes:60))
        now = now.addingTimeInterval(25 * 60); c.shutdown()
        XCTAssertTrue(b.earnedMinutesToday.isEmpty)
    }
    @MainActor func testExplicitDoneFinishesOpenSessionNormallyAndReviewCannotRepay() throws {
        var now = Date(timeIntervalSince1970:1791453600)
        let list = BlockList(name:"Sites",quotaMinutesPerDay:10,earn:.init())
        let b = BlockingController(document:.init(lists:[list]),clock:{now},continuous:{now.timeIntervalSince1970})
        let c = try ConcentrationController(store:store(),clock:{now},blocking:{b})
        try c.startSession(intent:"Travail",mode:FocusMode(minutes:nil)); let id = c.currentSession!.id
        now = now.addingTimeInterval(50 * 60); try c.stopSession(outcome:.done)
        XCTAssertEqual(b.earnedMinutesToday[list.id],10)
        try c.recordOutcome(sessionID:id,outcome:.done); c.refresh()
        XCTAssertEqual(b.earnedMinutesToday[list.id],10)
    }
    @MainActor func testFocusPersistenceFailureCannotGrantReward() throws {
        var now = Date(timeIntervalSince1970:1791453600)
        let list = BlockList(name:"Sites",quotaMinutesPerDay:10,earn:.init())
        let b = BlockingController(document:.init(lists:[list]),clock:{now},continuous:{now.timeIntervalSince1970})
        let s = try store(), c = try ConcentrationController(store:s,clock:{now},blocking:{b})
        try c.startSession(intent:"Travail",mode:FocusMode(minutes:25))
        // A file in place of the session directory forces the owner-only store to refuse the finish.
        let sessionDirectory = s.directory.appendingPathComponent("sessions")
        try FileManager.default.removeItem(at:sessionDirectory)
        try Data("fixture".utf8).write(to:sessionDirectory)
        now = now.addingTimeInterval(25 * 60); c.refresh()
        XCTAssertNotNil(c.error); XCTAssertTrue(b.earnedMinutesToday.isEmpty)
    }
}
#endif
