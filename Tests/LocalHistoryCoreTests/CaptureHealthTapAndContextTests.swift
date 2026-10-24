import XCTest
@testable import LocalHistoryCore

/// Branches of the capture-health verdict that decide whether Goalong tells the user "recording works".
final class CaptureHealthTapAndContextTests: XCTestCase {
    private func assess(_ snapshot: CaptureHealthSnapshot) -> CaptureHealthAssessment {
        CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
    }

    func testTapCreationFailureReportsTheErrorAndProvesNothing() {
        let result = assess(fixtureHealth(lifecycle: .creationFailed, callback: fixtureStart.addingTimeInterval(-3)))
        XCTAssertEqual(result.state, .inputTapUnavailable)
        XCTAssertEqual(result.detail, "permission denied")
        XCTAssertFalse(result.captureProven, "A failed tap cannot be proven by an earlier callback")
    }

    func testDisabledTapKeepsEarlierProofOnlyWhenACallbackWasSeenThisLaunch() {
        let seen = assess(fixtureHealth(lifecycle: .createdDisabled, callback: fixtureStart.addingTimeInterval(-3)))
        XCTAssertEqual(seen.state, .inputTapUnavailable)
        XCTAssertEqual(seen.detail, "The Core Graphics event tap is disabled.")
        XCTAssertTrue(seen.captureProven)
        XCTAssertFalse(assess(fixtureHealth(lifecycle: .createdDisabled, callback: nil)).captureProven)
    }

    func testTapNeverAttemptedIsNotReady() {
        let result = assess(fixtureHealth(lifecycle: .neverAttempted))
        XCTAssertEqual(result.state, .inputTapUnavailable)
        XCTAssertTrue(result.detail.contains("not attempted"))
        XCTAssertFalse(result.captureProven)
    }

    func testRecentForegroundLookupFailureAfterLastSuccessIsReported() {
        let result = assess(fixtureHealth(
            callback: fixtureStart.addingTimeInterval(-3),
            AXSuccess: fixtureStart.addingTimeInterval(-60),
            AXFailure: fixtureStart.addingTimeInterval(-5)))
        XCTAssertEqual(result.state, .accessibilityContextUnavailable)
        XCTAssertTrue(result.captureProven)
    }

    func testStaleOrAlreadyRecoveredForegroundFailureIsIgnored() {
        let stale = assess(fixtureHealth(
            callback: fixtureStart.addingTimeInterval(-3),
            AXSuccess: fixtureStart.addingTimeInterval(-90),
            AXFailure: fixtureStart.addingTimeInterval(-60)))
        XCTAssertEqual(stale.state, .ready)
        let recovered = assess(fixtureHealth(
            callback: fixtureStart.addingTimeInterval(-3),
            AXSuccess: fixtureStart.addingTimeInterval(-2),
            AXFailure: fixtureStart.addingTimeInterval(-5)))
        XCTAssertEqual(recovered.state, .ready)
    }

    func testExpectedInputThatNeverArrivedIsFlaggedOnlyAfterTheGracePeriod() {
        let last = fixtureStart.addingTimeInterval(-100)
        let missed = assess(fixtureHealth(callback: last, expected: fixtureStart.addingTimeInterval(-30)))
        XCTAssertEqual(missed.state, .inputTapUnavailable)
        let withinGrace = assess(fixtureHealth(callback: last, expected: fixtureStart.addingTimeInterval(-3)))
        XCTAssertNotEqual(withinGrace.state, .inputTapUnavailable)
    }

    func testInputEventCountSumsOnlyUserInputKinds() {
        let counters = CaptureRecentCounters(byEventKind: [
            EventKind.mouseClick.rawValue: 2, EventKind.typingBurst.rawValue: 3,
            EventKind.scrollBurst.rawValue: 1, EventKind.keyboardShortcut.rawValue: 4,
            EventKind.keyPressed.rawValue: 5, EventKind.heartbeat.rawValue: 50,
        ])
        XCTAssertEqual(counters.inputEventCount, 15)
        XCTAssertEqual(CaptureRecentCounters(byEventKind: [:]).inputEventCount, 0)
    }

    func testAccumulatorRecordsTapCreationFailureAndForegroundFailure() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accumulator = CaptureHealthAccumulator(
            launchedAt: now.addingTimeInterval(-60),
            build: fixtureBuild(cdHash: "same"),
            permissions: fixturePermissions(at: now))
        accumulator.markTapCreationFailed("no tap", at: now.addingTimeInterval(-10))
        accumulator.markAXFailure(at: now.addingTimeInterval(-4))
        let snapshot = accumulator.snapshot(now: now)
        XCTAssertEqual(snapshot.eventTapLifecycle, .creationFailed)
        XCTAssertEqual(snapshot.eventTapLastError, "no tap")
        XCTAssertEqual(snapshot.lastAXContextFailureAt, now.addingTimeInterval(-4))
        XCTAssertEqual(CaptureHealthEvaluator.assess(snapshot, now: now).detail, "no tap")
    }
}
