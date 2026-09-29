import XCTest
@testable import LocalHistoryCore

final class PermissionIdentityRegressionTests: XCTestCase {
    func testSignedMigrationFromAdHocIsDiagnosedEvenWhenEveryPreflightDenies() {
        let snapshot = fixtureHealth(build: fixtureBuild(signature: .appleDevelopment, cdHash: "new", team: "TEAM"),
            lastWorking: fixtureBuild(cdHash: "old"), permissions: fixturePermissions(preflight: false, functional: false),
            suppression: .privateBrowserWindow)
        let result = CaptureHealthEvaluator.assess(snapshot, now: fixtureStart)
        XCTAssertEqual(result.state, .permissionAppearsEnabledButStaleForBuild)
        XCTAssertFalse(result.captureProven)
        XCTAssertTrue(result.detail.contains("not proof"))
    }
    func testDeniedPermissionIsNotHiddenByPrivateSecureOrExcludedContext() {
        for reason: SuppressionReason in [.privateBrowserWindow, .secureInput, .excludedApplication, .excludedDomain] {
            let snapshot = fixtureHealth(permissions: fixturePermissions(preflight: false, functional: false), suppression: reason)
            XCTAssertEqual(CaptureHealthEvaluator.assess(snapshot, now: fixtureStart).state, .permissionRequired)
        }
    }
    func testSignedRequirementChangeWithinSameTeamIsNotSilentlyAssumedIdentical() {
        let old = fixtureBuild(signature: .appleDevelopment, cdHash: "old", team: "TEAM")
        let new = CaptureBuildIdentity(bundleIdentifier: old.bundleIdentifier, displayVersion: "2.0", buildNumber: "2",
            executablePath: old.executablePath, signatureKind: old.signatureKind, signingIdentifier: old.signingIdentifier,
            teamIdentifier: old.teamIdentifier, codeDirectoryHash: "new", designatedRequirement: "different certificate requirement")
        XCTAssertFalse(old.hasSamePermissionIdentity(as: new))
    }
    func testExplicitDenialOverridesStalePositivePreflightInHealth() throws {
        let permissions = CapturePermissionObservation(accessibilityPreflight: true,
            accessibilityFunctionalProbe: false, inputMonitoringPreflight: false,
            observedAt: fixtureStart, accessibilityProbeDenied: true)
        XCTAssertFalse(permissions.accessibilityGranted)
        XCTAssertEqual(CaptureHealthEvaluator.assess(fixtureHealth(permissions: permissions), now: fixtureStart).state, .permissionRequired)
        let legacy = CapturePermissionObservation(accessibilityPreflight: true,
            accessibilityFunctionalProbe: true, inputMonitoringPreflight: true, observedAt: fixtureStart)
        let data = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(CapturePermissionObservation.self, from: data)
        XCTAssertNil(restored.accessibilityProbeDenied)
        XCTAssertTrue(restored.accessibilityGranted)
    }

    func testCallbackWithoutAXCannotReplaceLastWorkingIdentity() {
        let old = fixtureBuild(cdHash: "old"), new = fixtureBuild(signature: .appleDevelopment, cdHash: "new", team: "TEAM")
        let accumulator = CaptureHealthAccumulator(build: new, lastKnownWorkingBuild: old,
            permissions: fixturePermissions(preflight: false, functional: false))
        accumulator.markTapEnabled(); accumulator.markInputCallback()
        XCTAssertEqual(accumulator.snapshot().lastKnownWorkingBuild, old)
        accumulator.updatePermissions(fixturePermissions())
        accumulator.markInputCallback()
        XCTAssertEqual(accumulator.snapshot().lastKnownWorkingBuild, new)
    }
    func testHistoricalInputCannotInventWorkingIdentityOfFailedLaunch() {
        let old = fixtureHealth(callback: fixtureStart.addingTimeInterval(-30))
        let failed = CaptureHealthAccumulator(launchedAt: fixtureStart, build: fixtureBuild(cdHash: "failed"),
            permissions: fixturePermissions(preflight: false, functional: false), restoring: old)
        let restored = CaptureHealthAccumulator(launchedAt: fixtureStart.addingTimeInterval(10),
            build: fixtureBuild(cdHash: "new"), permissions: fixturePermissions(preflight: false, functional: false), restoring: failed.snapshot())
        XCTAssertNotEqual(restored.snapshot().lastKnownWorkingBuild?.codeDirectoryHash, "failed")
        XCTAssertFalse(restored.snapshot().inputCallbackObservedThisLaunch == true)
    }
    func testNormalSignedUpdateRemainsSameIdentityDespiteDifferentBinaryAndPath() {
        for signature: BuildSignatureKind in [.appleDevelopment, .developerID, .appStore] {
            let a = fixtureBuild(signature: signature, cdHash: "a", team: "TEAM")
            let b = fixtureBuild(signature: signature, cdHash: "b", team: "TEAM")
            XCTAssertTrue(a.hasSamePermissionIdentity(as: b))
        }
    }
}
