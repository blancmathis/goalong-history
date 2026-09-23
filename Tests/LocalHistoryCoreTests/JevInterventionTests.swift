import Foundation
import XCTest
@testable import LocalHistoryCore

final class JevInterventionTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 1_700_000_000)
    private func accept(_ streak: inout JevStreak, _ index: Int, verdict: JevVerdict = .procrastination) -> Bool {
        streak.accept(verdict, start: zero.addingTimeInterval(Double(index * 15)),
                      end: zero.addingTimeInterval(Double((index + 1) * 15)))
    }
    func testCloseRearmsNextPositiveWithoutResettingDuration() {
        var streak = JevStreak()
        XCTAssertFalse(accept(&streak, 0)); XCTAssertTrue(accept(&streak, 1))
        XCTAssertEqual(streak.observedSeconds, 30); XCTAssertEqual(streak.appearanceCount, 1)
        streak.dismissWarning()
        XCTAssertFalse(accept(&streak, 1), "An old result cannot reopen the warning")
        XCTAssertTrue(accept(&streak, 2)); XCTAssertEqual(streak.observedSeconds, 45)
        XCTAssertEqual(streak.appearanceCount, 2)
        streak.dismissWarning()
        XCTAssertTrue(accept(&streak, 3)); XCTAssertEqual(streak.appearanceCount, 3)
        XCTAssertFalse(accept(&streak, 4)); XCTAssertEqual(streak.appearanceCount, 3)
    }
    func testContinuousDurationCrossesExactConfiguredBoundaries() {
        var streak = JevStreak(), settings = JevInterventionSettings()
        settings.effectsEnabled = true
        for index in 0..<40 {
            _ = accept(&streak, index)
            let seconds = (index + 1) * 15
            XCTAssertEqual(streak.observedSeconds, seconds)
            let expected: JevScreenEffect? = seconds < 120 ? nil : seconds < 300 ? .dim : seconds < 600 ? .red : .dimAndRed
            XCTAssertEqual(settings.stage(at: seconds)?.effect, expected)
        }
        XCTAssertEqual(streak.appearanceCount, 1, "A visible warning is updated, not duplicated")
    }
    func testEveryInterruptionClearsDurationAndAppearanceHistory() {
        for verdict in [JevVerdict.productive, .unknown] {
            var streak = JevStreak()
            for i in 0..<20 { _ = accept(&streak, i) }
            XCTAssertFalse(accept(&streak, 20, verdict: verdict))
            XCTAssertEqual(streak.observedSeconds, 0); XCTAssertEqual(streak.appearanceCount, 0)
            XCTAssertFalse(accept(&streak, 21)); XCTAssertTrue(accept(&streak, 22))
            XCTAssertEqual(streak.observedSeconds, 30)
        }
        var streak = JevStreak()
        for i in 0..<20 { _ = accept(&streak, i) }
        XCTAssertFalse(accept(&streak, 21)); XCTAssertEqual(streak.observedSeconds, 15)
        streak.reset(); XCTAssertEqual(streak.observedSeconds, 0); XCTAssertEqual(streak.appearanceCount, 0)
    }
    func testNonfiniteAndWrongDurationFailClosed() {
        var streak = JevStreak()
        _ = accept(&streak, 0)
        XCTAssertFalse(streak.accept(.procrastination, start: .init(timeIntervalSince1970: .nan), end: zero))
        XCTAssertEqual(streak.count, 0)
        XCTAssertFalse(streak.accept(.procrastination, start: zero, end: zero.addingTimeInterval(30)))
        XCTAssertEqual(streak.count, 0)
    }
    func testEffectsOffByDefaultAndDisabledStagesFallBackToPrevious() {
        var settings = JevInterventionSettings()
        XCTAssertTrue(settings.isValid); XCTAssertNil(settings.stage(at: 600))
        settings.effectsEnabled = true; settings.stages[1].enabled = false
        XCTAssertEqual(settings.stage(at: 300)?.effect, .dim)
        settings.stages[0].enabled = false
        XCTAssertNil(settings.stage(at: 599)); XCTAssertEqual(settings.stage(at: 600)?.effect, .dimAndRed)
        settings.stages[2].enabled = false; XCTAssertNil(settings.stage(at: Int.max))
    }
    func testInvalidConfigurationsNeverApplyEffects() throws {
        let edits: [(inout JevInterventionSettings) -> Void] = [
            { $0.schemaVersion = 2 }, { $0.stages = [] },
            { $0.stages[0].afterMinutes = 0 }, { $0.stages[2].afterMinutes = 61 },
            { $0.stages[1].afterMinutes = 2 }, { $0.stages[1].afterMinutes = 1 },
            { $0.stages[0].intensity = 9 }, { $0.stages[0].intensity = 100 },
        ]
        for edit in edits {
            var settings = JevInterventionSettings(); settings.effectsEnabled = true; edit(&settings)
            XCTAssertFalse(settings.isValid); XCTAssertNil(settings.stage(at: Int.max))
        }
        let original = JevInterventionSettings()
        XCTAssertEqual(try JSONDecoder().decode(JevInterventionSettings.self, from: JSONEncoder().encode(original)), original)
    }
    func testRandomPlacementStartsOnlyOnThirdAppearanceAndNeverRepeats() {
        var previous: JevWarningAnchor? = nil
        for appearance in 1...100 {
            let next = JevWarningAnchor.next(appearance: appearance, moving: true, previous: previous, sample: appearance)
            if appearance <= 2 { XCTAssertEqual(next, .topRight) }
            else { XCTAssertNotEqual(next, previous) }
            previous = next
        }
        XCTAssertEqual(JevWarningAnchor.next(appearance: 50, moving: false, previous: .topRight, sample: Int.min), .topRight)
        XCTAssertNotEqual(JevWarningAnchor.next(appearance: 3, moving: true, previous: .topRight, sample: Int.min), .topRight)
    }
    func testAlertDurations() {
        XCTAssertEqual(JevInterventionSettings.duration(30), "30 secondes")
        XCTAssertEqual(JevInterventionSettings.duration(45), "45 secondes")
        XCTAssertEqual(JevInterventionSettings.duration(120), "2 min")
        XCTAssertEqual(JevInterventionSettings.duration(315), "5 min 15 s")
    }
}
