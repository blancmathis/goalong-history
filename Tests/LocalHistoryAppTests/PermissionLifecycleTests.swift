#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class PermissionLifecycleTests: XCTestCase {
    private var denied: PermissionStatus { .resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false) }
    private var granted: PermissionStatus { .resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: true) }
    private func defaults() -> UserDefaults {
        let suite = "goalong-permission-lifecycle-tests-" + UUID().uuidString
        let value = UserDefaults(suiteName: suite)!
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    func testAuthorizationMatrixNeverAcceptsGenericSelfReadOrPendingObservation() {
        for mask in 0..<64 {
            var value = PermissionStatus.resolved(accessibilityPreflight: mask & 1 != 0,
                accessibilityFunctionalProbe: mask & 2 != 0, inputMonitoringDirectlyGranted: mask & 4 != 0,
                accessibilityCrossProcessProbe: mask & 8 != 0)
            value.observationPending = mask & 16 != 0
            let failedTap = mask & 32 != 0
            let result = SourceAccessService.computerHistoryAccess(value, inputTapCreationFailed: failedTap)
            if value.observationPending {
                if case .unavailable = result {} else { XCTFail("Pending observation accepted: \(mask)") }
            } else if mask & 9 == 0 { XCTAssertEqual(result, .accessibility, "\(mask)") }
            else if failedTap && mask & 4 == 0 { XCTAssertEqual(result, .inputMonitoring, "\(mask)") }
            else { XCTAssertEqual(result, .ready, "\(mask)") }
        }
    }

    func testExplicitAPIDenialIsNotAWindowTimeoutAndCannotConfirmStalePreflight() {
        for error: Int32? in [nil, -25204, -25205, -25212, -25211] {
            let status = PermissionStatus.resolved(accessibilityPreflight: true,
                accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false,
                accessibilityProbeError: error)
            XCTAssertEqual(status.accessibility, error != -25211)
            XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), error == -25211 ? .accessibility : .ready)
        }
        let recovered = PermissionStatus.resolved(accessibilityPreflight: false,
            accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: false,
            accessibilityCrossProcessProbe: true)
        XCTAssertTrue(recovered.accessibility)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(recovered), .ready)
    }

    func testExternalAXEvidenceRequiresProtectedReadFromDifferentNonSystemPID() {
        for pid: Int32 in [-1, 0, 1, 42, 43] {
            for success in [false, true] {
                XCTAssertEqual(ContextProvider.provesExternalAX(pid: pid, ownPID: 42, protectedReadSucceeded: success), pid == 43 && success)
            }
        }
    }

    func testConcurrentRefreshJoinsNewObservationRatherThanReturningOldDenial() {
        let lock = NSLock(); var calls = 0
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let old = denied, new = granted
        let manager = PermissionManager(statusProbe: {
            lock.lock(); calls += 1; let count = calls; lock.unlock()
            if count == 1 { return old }
            if count == 2 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return new
        })
        let done = expectation(description: "fresh coalesced result"); done.expectedFulfillmentCount = 9
        DispatchQueue.global().async { XCTAssertEqual(manager.refresh(force: true), new); done.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<8 {
            DispatchQueue.global().async { XCTAssertEqual(manager.refresh(minimumInterval: 30), new); done.fulfill() }
        }
        release.signal()
        wait(for: [done], timeout: 4)
        XCTAssertEqual(manager.probeCount, 2)
    }

    func testInvalidationDiscardsPreResetGrantAndMainThreadDoesNotWait() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let old = denied, new = granted
        var calls = 0
        let manager = PermissionManager(statusProbe: {
            calls += 1
            if calls == 1 { return old }
            if calls == 2 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return new
        })
        let done = expectation(description: "pre-reset observation discarded")
        DispatchQueue.global().async {
            let value = manager.refresh(force: true)
            XCTAssertTrue(value.observationPending); XCTAssertFalse(value.accessibility)
            done.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        XCTAssertTrue(manager.refresh(force: true).observationPending)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        let before = manager.observationRevision
        manager.invalidate()
        XCTAssertNotEqual(manager.observationRevision, before)
        release.signal(); wait(for: [done], timeout: 4)
        XCTAssertTrue(manager.snapshot.observationPending)
        XCTAssertEqual(manager.refresh(force: true), new)
    }

    func testNoNewObservationCanConfirmAccessDuringReset() {
        let granted = self.granted
        let manager = PermissionManager(statusProbe: { granted })
        let originalRevision = manager.observationRevision
        manager.setRepairInProgress(true)
        XCTAssertTrue(manager.isRepairInProgress)
        for _ in 0..<20 {
            XCTAssertTrue(manager.refresh(force: true).observationPending)
            XCTAssertFalse(manager.snapshot.accessibility)
        }
        XCTAssertEqual(manager.probeCount, 1, "Do not repeatedly probe a service being reset")
        XCTAssertNotEqual(manager.observationRevision, originalRevision)
        let duringRepairRevision = manager.observationRevision
        manager.setRepairInProgress(false)
        XCTAssertFalse(manager.isRepairInProgress)
        XCTAssertNotEqual(manager.observationRevision, duringRepairRevision)
        XCTAssertTrue(manager.snapshot.observationPending)
        XCTAssertEqual(manager.refresh(force: true), granted)
        XCTAssertEqual(manager.probeCount, 2)
    }

    func testClockRollbackCannotFreezeCachedGrant() {
        var now = Date(timeIntervalSince1970: 1000), calls = 0
        let old = granted, new = denied
        let manager = PermissionManager(statusProbe: { calls += 1; return calls == 1 ? old : new }, clock: { now })
        now = now.addingTimeInterval(-3600)
        XCTAssertEqual(manager.refresh(), new)
    }

    func testRecoveryPersistsAndAdvancesWithoutImplicitPermission() {
        let d = defaults(), now = Date(timeIntervalSince1970: 1000)
        let scope = "test-installation-and-build"
        func advice(_ progress: PermissionRecoveryLedger.Progress) -> PermissionRecoveryAdvice {
            .resolve(accessAvailable: false, stableInstallation: true, signatureValid: true, runningCopies: 1, identityChanged: false, progress: progress)
        }
        XCTAssertEqual(advice(.init()), .grant)
        PermissionRecoveryLedger.record(.settingsOpened, for: .accessibility, defaults: d, now: now, scope: scope)
        XCTAssertEqual(advice(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: scope)), .relaunch)
        PermissionRecoveryLedger.record(.relaunchPrepared, for: .accessibility, defaults: d, now: now, scope: scope)
        XCTAssertEqual(advice(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: scope)), .repair)
        PermissionRecoveryLedger.record(.resetSucceeded, for: .accessibility, defaults: d, now: now, scope: scope)
        XCTAssertEqual(advice(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: scope)), .reauthorize)
        PermissionRecoveryLedger.record(.relaunchPrepared, for: .accessibility, defaults: d, now: now, scope: scope)
        let final = PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: scope)
        XCTAssertEqual(advice(final), .manualRepair)
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: true, stableInstallation: true, signatureValid: true, runningCopies: 1, identityChanged: true, progress: final), .available)
    }

    func testRecoveryRecordsAreScopedExpiringBoundedAndIndependent() {
        let d = defaults(), now = Date(timeIntervalSince1970: 1000)
        for _ in 0..<12 { PermissionRecoveryLedger.record(.relaunchPrepared, for: .accessibility, defaults: d, now: now, scope: "A") }
        XCTAssertEqual(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: "A").relaunches, 9)
        XCTAssertEqual(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: "B"), .init())
        XCTAssertEqual(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now.addingTimeInterval(86400), scope: "A"), .init())
        XCTAssertEqual(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now.addingTimeInterval(-1), scope: "A"), .init())
        XCTAssertEqual(PermissionRecoveryLedger.load(.inputMonitoring, defaults: d, now: now, scope: "A"), .init())
        PermissionRecoveryLedger.record(.settingsOpened, for: .fullDiskAccess, defaults: d, now: now, scope: "A")
        PermissionRecoveryLedger.clear(.accessibility, defaults: d)
        XCTAssertEqual(PermissionRecoveryLedger.load(.accessibility, defaults: d, now: now, scope: "A"), .init())
        XCTAssertEqual(PermissionRecoveryLedger.load(.fullDiskAccess, defaults: d, now: now, scope: "A").settingsVisits, 1)
    }

    func testNoRepairBeforeResolvingInstallationOrSignatureProblems() {
        let progress = PermissionRecoveryLedger.Progress(relaunches: 2)
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: false, stableInstallation: false, signatureValid: true, runningCopies: 1, identityChanged: true, progress: progress), .installStableCopy)
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: false, stableInstallation: true, signatureValid: false, runningCopies: 1, identityChanged: true, progress: progress), .replaceInvalidBuild)
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: false, stableInstallation: true, signatureValid: true, runningCopies: 2, identityChanged: true, progress: progress), .closeOtherCopy)
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: false, observationPending: true, stableInstallation: true, signatureValid: true, runningCopies: 1, identityChanged: true, progress: progress), .checking)
    }

    func testLegacyIdentityMigrationGoesStraightToExplicitRepairNotRepeatedRestart() {
        XCTAssertEqual(PermissionRecoveryAdvice.resolve(accessAvailable: false, stableInstallation: true, signatureValid: true, runningCopies: 1, identityChanged: true, progress: .init()), .repair)
    }

    func testRepairRejectsTemporaryAndPathTraversalLocations() {
        for path in ["/tmp/Goalong.app", "/Applications/../tmp/Goalong.app", "/ApplicationsFake/Goalong.app", "/Volumes/Goalong/Goalong.app"] {
            XCTAssertFalse(PermissionRepair.canResetInstallation(path: path), path)
        }
        XCTAssertTrue(PermissionRepair.canResetInstallation(path: "/Applications/Goalong History.app"))
    }

    func testSupportBuildNeverExportsPreviousPathsOrRequirementText() throws {
        let privateText = "private-user-and-email@example.invalid"
        let previous = CaptureBuildIdentity(bundleIdentifier: "ai.goalong.localhistory", displayVersion: privateText, buildNumber: "1",
            executablePath: "/Users/" + privateText, signatureKind: .adHoc, signingIdentifier: privateText,
            teamIdentifier: privateText, codeDirectoryHash: privateText, designatedRequirement: "identifier \"\(privateText)\"")
        let build = SupportBuild.current(previousWorkingBuild: previous)
        let encoded = String(decoding: try JSONEncoder().encode(build), as: UTF8.self)
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertNil(build.previousVersion)
        XCTAssertEqual(build.previousSignatureKind, .adHoc)
        XCTAssertNotNil(build.previousRequirementValidation)
        XCTAssertNil(BuildIdentityReader.evaluatePreviousRequirement(nil))
        XCTAssertNil(BuildIdentityReader.evaluatePreviousRequirement(String(repeating: "a", count: 8193)))
    }
}
#endif
