#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-057 F2 (bugs-temps-01): a standalone « Surveillance » and a Jev pause follow continuous time, not a clock set by hand.
@MainActor final class JevClockAnchorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_770_000) // 27/11, 10:00 Paris
    private var continuous: Double = 1_000

    override func setUp() {
        super.setUp()
        let saved = JevSurveillanceStore.liveClock
        JevSurveillanceStore.liveClock = { [unowned self] in (self.continuous, "boot-a") }
        addTeardownBlock { @MainActor in JevSurveillanceStore.liveClock = saved }
    }

    func testALockedStandaloneWatchSurvivesAClockSetBackAndForward() {
        let store = JevSurveillanceStore(defaults: defaults()), id = UUID()
        store.mark(JevSessionMark(id: id, kind: .own, on: true, start: start, end: start.addingTimeInterval(1_800),
                                  lock: .locked, settings: JevInterventionSettings()),
                   now: start, alive: JevRunningSessions())

        // 10:05 real, clock set back to 09:55: still running, the stop stays refused.
        continuous += 300
        let back = start.addingTimeInterval(-300)
        let activity = store.active(sessions: JevRunningSessions(), now: back)
        XCTAssertEqual(activity.map(\.lock), [.locked])
        XCTAssertEqual(store.runningOwn(now: back)?.id, id)
        XCTAssertNotEqual(JevStopGate.step(activity, jevEnabled: true, challenge: { "" }), .allow)

        // Clock set forward past its end: it keeps running to its real end.
        let forward = start.addingTimeInterval(3_600)
        XCTAssertEqual(store.active(sessions: JevRunningSessions(), now: forward).map(\.lock), [.locked])
        XCTAssertEqual(JevSurveillanceStore.pruned(store.document.marks, now: forward, alive: JevRunningSessions(),
                                                   clock: JevSurveillanceStore.clockState(forward)).count, 1)

        // 30 real minutes later it ends, whatever the wall clock says.
        continuous = 1_000 + 1_800
        XCTAssertTrue(store.active(sessions: JevRunningSessions(), now: back).isEmpty)
        XCTAssertNil(store.runningOwn(now: back))
    }

    func testStoppingAWatchEndsItWithTheClockAhead() {
        let store = JevSurveillanceStore(defaults: defaults()), id = UUID()
        store.mark(JevSessionMark(id: id, kind: .own, on: true, start: start, end: start.addingTimeInterval(1_800),
                                  lock: .free, settings: JevInterventionSettings()),
                   now: start, alive: JevRunningSessions())
        continuous += 60
        let ahead = start.addingTimeInterval(900)
        store.endOwn(id, now: ahead)
        continuous += 1
        XCTAssertNil(store.runningOwn(now: ahead.addingTimeInterval(1)))
    }

    func testAPauseNeverOutlastsItsDurationAfterAClockSetBack() throws {
        let pause = try XCTUnwrap(JevTimedBreak(minutes: 10, now: start, continuous: 1_000, boot: "boot-a"))
        // 10:02 real, set back to 09:52; 10 real minutes later the wall says 10:00.
        let wall = start.addingTimeInterval(600 - 600)
        XCTAssertEqual(pause.remaining(at: wall, continuous: 1_600, boot: "boot-a"), 0)
        XCTAssertEqual(pause.remaining(at: start.addingTimeInterval(-480), continuous: 1_120, boot: "boot-a"), 480)
        // Another boot: the wall clock alone, as before.
        XCTAssertEqual(pause.remaining(at: wall, continuous: 5, boot: "boot-b"), 600)
        // An older file without anchor decodes and keeps the wall rule.
        let legacy = try JSONDecoder().decode(
            JevTimedBreak.self,
            from: Data(#"{"startedAt":0,"endsAt":600}"#.utf8))
        XCTAssertNil(legacy.startedContinuous)
        XCTAssertTrue(legacy.isValid)
        let decodedMark = try JSONDecoder().decode(
            JevSessionMark.self,
            from: JSONEncoder().encode(JevSessionMark(id: UUID(), kind: .own, on: true, lock: .free,
                                                      settings: JevInterventionSettings())))
        XCTAssertNil(decodedMark.clock)
    }

    private func defaults() -> UserDefaults {
        let name = "jev-clock-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
}
#endif
