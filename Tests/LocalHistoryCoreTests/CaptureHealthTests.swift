import XCTest
@testable import LocalHistoryCore

final class CaptureHealthTests: XCTestCase {
    func testCreatedTapWithoutCallbackIsNotReady() {
        let snapshot = fixtureHealth(callback: nil)
        let assessment = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
        XCTAssertEqual(assessment.state, .awaitingInputEvidence)
        XCTAssertFalse(assessment.captureProven)
        XCTAssertTrue(assessment.limitations.contains { $0.contains("Tap creation") })
    }

    func testTapControlCallbackDoesNotProveInputCapture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accumulator = CaptureHealthAccumulator(
            launchedAt: now.addingTimeInterval(-10),
            build: fixtureBuild(cdHash: "same"),
            permissions: fixturePermissions(at: now)
        )
        accumulator.markTapEnabled(at: now.addingTimeInterval(-2))
        accumulator.markTapControlCallback(at: now.addingTimeInterval(-1))

        let assessment = CaptureHealthEvaluator.assess(accumulator.snapshot(now: now), now: now)
        XCTAssertEqual(assessment.state, .awaitingInputEvidence)
        XCTAssertFalse(assessment.captureProven)
        XCTAssertNotNil(accumulator.snapshot(now: now).lastCallbackAt)
        XCTAssertNil(accumulator.snapshot(now: now).lastInputEventAt)
    }

    func testRealCallbackMakesCaptureReady() {
        let snapshot = fixtureHealth(callback: fixtureStart.addingTimeInterval(-2))
        let assessment = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
        XCTAssertEqual(assessment.state, .ready)
        XCTAssertTrue(assessment.captureProven)
    }

    func testPreviouslyProvenCaptureCanBeHealthyButIdle() {
        let snapshot = fixtureHealth(callback: fixtureStart.addingTimeInterval(-500))
        let assessment = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart, inputIdleThreshold: 120)
        XCTAssertEqual(assessment.state, .healthyButIdle)
        XCTAssertTrue(assessment.captureProven)
    }

    func testPermissionAndFunctionalProbeAreDistinct() {
        let missing = fixtureHealth(permissions: fixturePermissions(preflight: false, functional: false))
        XCTAssertEqual(CaptureHealthEvaluator.assess(missing, now: fixtureStart).state, .permissionRequired)

        let unusable = fixtureHealth(permissions: fixturePermissions(preflight: true, functional: false))
        XCTAssertEqual(
            CaptureHealthEvaluator.assess(unusable, now: fixtureStart).state,
            .accessibilityContextUnavailable
        )
    }

    func testChangedAdHocBuildCanBeDiagnosedAsStale() {
        let oldBuild = fixtureBuild(cdHash: "old")
        let newBuild = fixtureBuild(cdHash: "new")
        let snapshot = fixtureHealth(
            build: newBuild,
            lastWorking: oldBuild,
            permissions: fixturePermissions(preflight: true, functional: false),
            callback: nil,
            expected: fixtureStart.addingTimeInterval(-20)
        )
        let assessment = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
        XCTAssertEqual(assessment.state, .permissionAppearsEnabledButStaleForBuild)
        XCTAssertFalse(assessment.captureProven)
    }

    func testDeveloperIDIdentityDoesNotUseCDHashAcrossUpdates() {
        let oldBuild = fixtureBuild(signature: .developerID, cdHash: "old", team: "TEAM123")
        let newBuild = fixtureBuild(signature: .developerID, cdHash: "new", team: "TEAM123")
        XCTAssertTrue(oldBuild.hasSamePermissionIdentity(as: newBuild))

        let snapshot = fixtureHealth(
            build: newBuild,
            lastWorking: oldBuild,
            callback: nil,
            expected: fixtureStart.addingTimeInterval(-20)
        )
        let assessment = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
        XCTAssertEqual(assessment.state, .inputTapUnavailable)
        XCTAssertNotEqual(assessment.state, .permissionAppearsEnabledButStaleForBuild)
    }

    func testPauseAndSuppressionAreExplicitStates() {
        XCTAssertEqual(
            CaptureHealthEvaluator.assess(fixtureHealth(paused: true), now: fixtureStart).state,
            .paused
        )
        XCTAssertEqual(
            CaptureHealthEvaluator.assess(
                fixtureHealth(suppression: .privateBrowserWindow),
                now: fixtureStart
            ).state,
            .excludedPrivateOrSecure
        )
    }

    func testRestoredHistoricalCallbackDoesNotProveNewProcess() {
        let previous = fixtureHealth(callback: fixtureStart.addingTimeInterval(-30))
        let accumulator = CaptureHealthAccumulator(
            launchedAt: fixtureStart,
            build: fixtureBuild(),
            permissions: fixturePermissions(),
            restoring: previous
        )
        accumulator.markTapEnabled(at: fixtureStart)

        let restored = accumulator.snapshot(now: fixtureStart)
        XCTAssertEqual(restored.lastInputEventAt, previous.lastInputEventAt)
        XCTAssertFalse(restored.inputCallbackObservedThisLaunch == true)
        XCTAssertEqual(
            CaptureHealthEvaluator.assess(restored, now: fixtureStart).state,
            .awaitingInputEvidence
        )

        accumulator.markInputCallback(at: fixtureStart.addingTimeInterval(1))
        let current = accumulator.snapshot(now: fixtureStart.addingTimeInterval(2))
        XCTAssertTrue(current.inputCallbackObservedThisLaunch == true)
        XCTAssertEqual(
            CaptureHealthEvaluator.assess(current, now: fixtureStart.addingTimeInterval(2)).state,
            .ready
        )
    }

    func testAccumulatorTracksLastEvidenceAndFiveMinuteCounters() {
        let accumulator = CaptureHealthAccumulator(
            launchedAt: fixtureStart,
            build: fixtureBuild(),
            permissions: fixturePermissions()
        )
        accumulator.markTapEnabled(at: fixtureStart)
        accumulator.markCallback(kind: .mouseClick, at: fixtureStart.addingTimeInterval(10))
        accumulator.markCallback(kind: .scrollBurst, at: fixtureStart.addingTimeInterval(20))
        accumulator.markCallback(kind: .typingBurst, at: fixtureStart.addingTimeInterval(400))
        accumulator.markAXSuccess(urlAvailable: true, at: fixtureStart.addingTimeInterval(401))

        let snapshot = accumulator.snapshot(now: fixtureStart.addingTimeInterval(410), windowSeconds: 300)
        XCTAssertEqual(snapshot.recentCounters[.mouseClick], 0)
        XCTAssertEqual(snapshot.recentCounters[.scrollBurst], 0)
        XCTAssertEqual(snapshot.recentCounters[.typingBurst], 1)
        XCTAssertEqual(snapshot.lastClickAt, fixtureStart.addingTimeInterval(10))
        XCTAssertEqual(snapshot.lastTypingBurstAt, fixtureStart.addingTimeInterval(400))
        XCTAssertEqual(snapshot.lastURLDetectedAt, fixtureStart.addingTimeInterval(401))
        XCTAssertEqual(snapshot.lastKnownWorkingBuild, fixtureBuild())
    }
}
