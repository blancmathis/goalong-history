import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryReadinessTests: XCTestCase {
    func testRichContextConsentAloneNeverClaimsReadiness() {
        let result = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: CaptureHealthAssessment(
                state: .awaitingInputEvidence,
                detail: "No real callback reached this launch.",
                captureProven: false
            ),
            captureHealthSnapshot: snapshot(signature: .developerID),
            coverage: coverage(actions: 4, interactions: 4, pairs: 4)
        )

        XCTAssertEqual(result.state, .inputCaptureUnproven)
        XCTAssertFalse(result.captureProven)
    }

    func testReadyRequiresProvenInputAndNinetyPercentSemanticPairs() {
        let result = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: provenHealth,
            captureHealthSnapshot: snapshot(signature: .developerID),
            coverage: coverage(actions: 10, interactions: 10, pairs: 9)
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.semanticPairRatio, 0.9, accuracy: 0.0001)
        XCTAssertEqual(result.stablePermissionIdentity, true)
    }

    func testLowPairCoverageIsPresentedAsPartial() {
        let result = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: provenHealth,
            captureHealthSnapshot: snapshot(signature: .developerID),
            coverage: coverage(actions: 10, interactions: 10, pairs: 4)
        )

        XCTAssertEqual(result.state, .partialSemanticCoverage)
        XCTAssertEqual(result.semanticPairRatio, 0.4, accuracy: 0.0001)
        XCTAssertTrue(result.detail.contains("40%"))
    }

    func testMetadataOnlyAndMissingPermissionsRemainExplicit() {
        let metadata = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: false,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: provenHealth,
            captureHealthSnapshot: snapshot(signature: .developerID),
            coverage: coverage(actions: 10, interactions: 10, pairs: 10)
        )
        XCTAssertEqual(metadata.state, .metadataOnly)

        let missing = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: true,
            accessibilityGranted: false,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: provenHealth,
            captureHealthSnapshot: snapshot(signature: .developerID),
            coverage: coverage(actions: 10, interactions: 10, pairs: 10)
        )
        XCTAssertEqual(missing.state, .permissionRequired)
        XCTAssertTrue(missing.detail.contains("Accessibility"))
    }

    func testAdHocIdentityIsNeverPresentedAsStableAcrossUpdates() {
        let result = ComputerHistoryReadinessAssessment.assess(
            richContextEnabled: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            eventTapRunning: true,
            captureHealth: provenHealth,
            captureHealthSnapshot: snapshot(signature: .adHoc),
            coverage: coverage(actions: 10, interactions: 10, pairs: 10)
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.stablePermissionIdentity, false)
        XCTAssertTrue(result.limitations.contains(where: { $0.contains("stable across updates") }))
    }

    private var provenHealth: CaptureHealthAssessment {
        CaptureHealthAssessment(
            state: .ready,
            detail: "A real callback and AX context were observed.",
            captureProven: true
        )
    }

    private func coverage(
        actions: Int,
        interactions: Int,
        pairs: Int
    ) -> ComputerHistoryCoverage {
        ComputerHistoryCoverage(
            sourceEventCount: max(actions, interactions),
            actionEventCount: actions,
            semanticSnapshotCount: pairs * 2,
            linkedInteractionCount: interactions,
            interactionsWithBeforeAndAfterContext: pairs,
            resourceCount: 1,
            episodeCount: 1,
            suppressedEventCount: 0,
            firstSourceSequence: 1,
            lastSourceSequence: UInt64(max(1, actions)),
            lastSourceEventHash: nil
        )
    }

    private func snapshot(signature: BuildSignatureKind) -> CaptureHealthSnapshot {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let build = CaptureBuildIdentity(
            bundleIdentifier: "ai.goalong.localhistory",
            displayVersion: "0.5.1",
            buildNumber: "1",
            executablePath: "/Applications/Goalong History.app/Contents/MacOS/GoalongHistory",
            signatureKind: signature,
            signingIdentifier: signature == .developerID ? "ai.goalong.localhistory" : nil,
            teamIdentifier: signature == .developerID ? "TEAMID1234" : nil,
            codeDirectoryHash: signature == .adHoc ? "adhoc-cdhash" : "developer-cdhash",
            designatedRequirement: nil
        )
        return CaptureHealthSnapshot(
            generatedAt: now,
            launchedAt: now.addingTimeInterval(-60),
            build: build,
            lastKnownWorkingBuild: build,
            permissions: CapturePermissionObservation(
                accessibilityPreflight: true,
                accessibilityFunctionalProbe: true,
                inputMonitoringPreflight: true,
                observedAt: now
            ),
            eventTapLifecycle: .createdEnabled,
            eventTapLastError: nil,
            eventTapLastEnabledAt: now,
            eventTapLastDisabledAt: nil,
            lastCallbackAt: now,
            lastInputEventAt: now,
            lastClickAt: now,
            lastTypingBurstAt: nil,
            lastScrollAt: nil,
            lastShortcutAt: nil,
            lastAXContextSuccessAt: now,
            lastAXContextFailureAt: nil,
            lastURLDetectedAt: nil,
            lastSuppressionAt: nil,
            lastSuppressionReason: nil,
            currentSuppressionReason: nil,
            isManuallyPaused: false,
            recentCounters: CaptureRecentCounters(
                byEventKind: [EventKind.mouseClick.rawValue: 1]
            ),
            expectedInputAfter: nil,
            inputCallbackObservedThisLaunch: true
        )
    }
}
