#if os(macOS)
import AgentActivity
import AppleScreenTime
import Foundation
import XCTest
@testable import LocalHistoryApp

final class GoalongAnalyticsLoadRequestTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_035_200)

    private func request(preview: Bool, visible: Bool, count: Int = 7, revision: Int = 0) -> GoalongAnalyticsLoadRequest {
        .init(day: day, count: count, revision: revision, preview: preview, dashboardIsVisible: visible)
    }

    func testSyntheticPreviewLoadsWithoutKeyboardFocus() {
        XCTAssertTrue(request(preview: true, visible: false).permitsLoading)
        XCTAssertTrue(request(preview: true, visible: true).permitsLoading)
    }

    func testFocusChangesDoNotCancelOrRestartSyntheticPreview() {
        XCTAssertEqual(request(preview: true, visible: false), request(preview: true, visible: true))
        XCTAssertNotEqual(request(preview: false, visible: false), request(preview: false, visible: true))
    }

    func testRealPrivateReadsStillRequireTheFocusedDashboard() {
        XCTAssertFalse(request(preview: false, visible: false).permitsLoading)
        XCTAssertTrue(request(preview: false, visible: true).permitsLoading)
    }

    func testPeriodModeAndRefreshChangesProduceANewRequest() {
        let initial = request(preview: true, visible: true)
        XCTAssertNotEqual(initial, request(preview: false, visible: true))
        XCTAssertNotEqual(initial, request(preview: true, visible: true, count: 1))
        XCTAssertNotEqual(initial, request(preview: true, visible: true, count: 28))
        XCTAssertNotEqual(initial, request(preview: true, visible: true, revision: 1))
        XCTAssertEqual(request(preview: true, visible: true, count: 999).count, 7)
        XCTAssertEqual(initial.day, Calendar.current.startOfDay(for: day))
    }

    @MainActor func testInactiveRealRequestDoesNotStartAReader() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = GoalongAnalyticsModel(root: root)
        await model.load(request(preview: false, visible: false))
        XCTAssertNil(model.payload)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testUnfocusedPreviewProducesChartsForEveryPeriodWithoutAnArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = GoalongAnalyticsModel(root: root)
        for count in [1, 7, 28] {
            await model.load(request(preview: true, visible: false, count: count))
            let payload = try XCTUnwrap(model.payload)
            XCTAssertTrue(payload.isPreview)
            XCTAssertEqual(payload.current.days.count, count)
            XCTAssertGreaterThan(payload.current.observedSeconds, 0)
            XCTAssertGreaterThan(payload.current.activeSeconds, 0)
            XCTAssertFalse(payload.current.usage().isEmpty)
            XCTAssertFalse(payload.current.usage(websites: true).isEmpty)
            XCTAssertFalse(payload.cards.isEmpty)
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testReturningFromPreviewNeverUsesMocksAsRealData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = GoalongAnalyticsModel(root: root)
        await model.load(request(preview: true, visible: false))
        XCTAssertEqual(model.payload?.isPreview, true)
        await model.load(request(preview: false, visible: true))
        let payload = try XCTUnwrap(model.payload)
        XCTAssertFalse(payload.isPreview)
        XCTAssertEqual(payload.current.activeSeconds, 0)
        XCTAssertTrue(payload.cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testCancelledRequestDoesNotStartLoading() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = GoalongAnalyticsModel(root: root)
        let requested = request(preview: true, visible: false)
        let task = Task { await model.load(requested) }
        task.cancel()
        await task.value
        XCTAssertNil(model.payload)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

final class AgentConversationSourceHealthTests: XCTestCase {
    func testReadableIndexAndSuccessfulScanAreHealthy() {
        let health = AgentConversationSourceHealth(indexIsValid: true, scan: .init())
        XCTAssertEqual(health, .ready)
        XCTAssertFalse(health.hasReadFailure)
        XCTAssertNil(health.actionTitle)
        // The projection intentionally has no transcript errorCount input.
    }

    func testUnreadableIndexIsAnActualFailureEvenDuringPartialAnalysis() {
        let health = AgentConversationSourceHealth(indexIsValid: false,
            scan: .init(analysisIncomplete: true, capacityLimitedFolderCount: 3))
        XCTAssertEqual(health, .invalidIndex)
        XCTAssertTrue(health.hasReadFailure)
        XCTAssertEqual(health.actionTitle, "Retry")
    }

    func testActualSourceFailuresRemainVisibleWithoutLeakingRawSourcePaths() {
        let health = AgentConversationSourceHealth(indexIsValid: true,
            scan: .init(analysisIncomplete: true, capacityLimitedFolderCount: 2,
                failures: ["/private/fixture-one", "/private/fixture-two"]))
        XCTAssertEqual(health, .readFailures(2))
        XCTAssertTrue(health.hasReadFailure)
        XCTAssertTrue(health.message.contains("2 source-read"))
        XCTAssertFalse(health.message.contains("/private/"))
        XCTAssertEqual(health.actionTitle, "Retry")
    }

    func testBoundedAnalysisIsNotMisreportedAsUnavailable() {
        let health = AgentConversationSourceHealth(indexIsValid: true, scan: .init(analysisIncomplete: true))
        XCTAssertEqual(health, .analysisPending)
        XCTAssertFalse(health.hasReadFailure)
        XCTAssertEqual(health.actionTitle, "Resume analysis")
    }

    func testCapacityLimitDoesNotOfferAnIneffectiveRetry() {
        let health = AgentConversationSourceHealth(indexIsValid: true, scan: .init(capacityLimitedFolderCount: 2))
        XCTAssertEqual(health, .capacityLimited(2))
        XCTAssertFalse(health.hasReadFailure)
        XCTAssertNil(health.actionTitle)
        XCTAssertTrue(health.message.contains("2 folder(s)"))
        XCTAssertTrue(health.message.contains("retrying alone"))
    }

    func testSuccessfulRetryClearsTheFailureState() {
        let failed = AgentConversationSourceHealth(indexIsValid: true, scan: .init(failures: ["fixture"]))
        let recovered = AgentConversationSourceHealth(indexIsValid: true, scan: .init(scannedSourceCount: 1))
        XCTAssertTrue(failed.hasReadFailure)
        XCTAssertEqual(recovered, .ready)
    }
}

final class GoalongScreenTimeSourcePresentationTests: XCTestCase {
    func testReconstructionIsExplicitlyPartialAndNotAppleSettingsParity() {
        let value = GoalongScreenTimeSourcePresentation(assurance: .reconstructedAppleUsage)
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.title.contains("partielle"))
        XCTAssertTrue(value.detail.contains("peuvent différer"))
        XCTAssertTrue(value.detail.contains("pas à zéro"))
    }

    func testEverySourceRetainsItsOwnAssuranceInsteadOfAnAggregateBoolean() {
        let types: [AppleScreenTimeSourceAssurance] = [
            .appleSettingsObservablePresentation, .publicDeviceActivityExport,
            .privateAppleAggregateStore, .reconstructedAppleUsage
        ]
        let presentations = types.map { GoalongScreenTimeSourcePresentation(assurance: $0) }
        XCTAssertEqual(Set(presentations.map(\.title)).count, 4)
        XCTAssertEqual(presentations.filter(\.isPartial).count, 1)
        XCTAssertTrue(presentations.allSatisfy { !$0.detail.isEmpty })
    }

    func testPrivateAggregateDoesNotPromiseEqualityWithSettings() {
        let value = GoalongScreenTimeSourcePresentation(assurance: .privateAppleAggregateStore)
        XCTAssertFalse(value.isPartial)
        XCTAssertTrue(value.detail.contains("peuvent différer"))
    }
}
#endif
