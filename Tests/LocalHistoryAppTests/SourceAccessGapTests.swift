#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class SourceAccessGapTests: XCTestCase {
    private func store() throws -> GoalongCapabilityConsentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
    }

    func testStatusFlagsAndTitlesMatchTheRecoveryStep() {
        let all: [SourceAccessStatus] = [.ready, .accessibility, .inputMonitoring, .fullDiskAccess, .screenTimeSetup, .unavailable("x")]
        XCTAssertEqual(all.filter(\.isMacPermission), [.accessibility, .inputMonitoring, .fullDiskAccess])
        XCTAssertEqual(all.filter(\.hasSettingsAction), [.accessibility, .inputMonitoring, .fullDiskAccess, .screenTimeSetup])
        XCTAssertEqual(SourceAccessStatus.ready.actionTitle, "Réessayer")
        XCTAssertEqual(SourceAccessStatus.unavailable("x").actionTitle, "Réessayer")
        XCTAssertEqual(SourceAccessStatus.screenTimeSetup.actionTitle, "Ouvrir Temps d’écran")
        XCTAssertEqual(SourceAccessStatus.unavailable("Panne précise").message, "Panne précise")
        for status in all { XCTAssertFalse(status.message.isEmpty) }
    }

    func testPresentationKeepsUsablePagesVisibleAndNeverInventsAnIssue() {
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: false, checking: true, result: .accessibility), .content, "disabled source: nothing to gate")
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: true, result: .ready), .content, "no flash while revalidating")
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: true, result: .fullDiskAccess), .loading)
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: false, result: .fullDiskAccess), .issue(.fullDiskAccess))
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: false, result: nil), .loading, "no result yet is not a pass")
    }

    func testPassiveValidationNeverRunsForADisabledSourceAndDropsStaleAnswers() throws {
        let consent = try store()
        let validation = SourceAccessValidation(store: consent)
        var calls = 0
        validation.validate(.appleScreenTime, check: { _, _ in calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(validation.checking)
        XCTAssertNil(validation.result)

        XCTAssertTrue(consent.set(.appleScreenTime, enabled: true, surface: .settings))
        var first: ((SourceAccessStatus) -> Void)?
        validation.validate(.appleScreenTime, check: { _, done in first = done })
        XCTAssertTrue(validation.checking)
        var second: ((SourceAccessStatus) -> Void)?
        validation.validate(.appleScreenTime, check: { _, done in second = done })
        first?(.fullDiskAccess)
        XCTAssertTrue(validation.checking, "an older answer must not finish a newer check")
        XCTAssertNil(validation.result)
        second?(.screenTimeSetup)
        XCTAssertFalse(validation.checking)
        XCTAssertEqual(validation.result, .screenTimeSetup)
    }

    func testAnswerArrivingAfterTheSourceWasTurnedOffIsDiscardedAndReportOverrides() throws {
        let consent = try store()
        XCTAssertTrue(consent.set(.localComputerHistory, enabled: true, surface: .settings))
        let validation = SourceAccessValidation(store: consent)
        var finish: ((SourceAccessStatus) -> Void)?
        validation.validate(.localComputerHistory, check: { _, done in finish = done })
        XCTAssertTrue(consent.set(.localComputerHistory, enabled: false, surface: .settings))
        finish?(.accessibility)
        XCTAssertNil(validation.result)

        validation.validate(.localComputerHistory, check: { _, _ in })
        XCTAssertNil(validation.result)
        validation.report(.inputMonitoring)
        XCTAssertEqual(validation.result, .inputMonitoring)
        XCTAssertFalse(validation.checking)
    }

    func testStuckCheckTimesOutWithoutEnablingAnything() throws {
        let consent = try store()
        let flow = SourceActivationFlow(store: consent, check: { _, _ in }, checkTimeout: 0.05)
        flow.checkAndEnable(.appleScreenTime, surface: .settings) { XCTFail("Nothing to prepare") }
        XCTAssertTrue(flow.checking)
        let done = expectation(description: "timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(flow.checking)
        XCTAssertEqual(flow.completedCheckCount, 1)
        XCTAssertTrue(flow.feedback?.contains("Rien n’a été activé") == true)
        guard case .unavailable? = flow.result else { return XCTFail("a timeout is reported as unavailable") }
        XCTAssertFalse(flow.completed)
        XCTAssertFalse(consent.isEnabled(.appleScreenTime))
    }

    func testFailedPreparationKeepsTheSourceOffAndExplainsWhy() throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disque plein" } }
        let consent = try store()
        let flow = SourceActivationFlow(store: consent, check: { _, done in done(.ready) })
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { throw Boom() }
        XCTAssertFalse(consent.isEnabled(.localComputerHistory))
        XCTAssertFalse(flow.completed)
        XCTAssertEqual(flow.result, .unavailable("Les réglages n’ont pas pu être enregistrés : disque plein"))
    }

    func testInspectChecksWithoutEnablingAndFeedbackNamesTheCheckNumber() throws {
        let consent = try store()
        var status: SourceAccessStatus = .accessibility
        let flow = SourceActivationFlow(store: consent, check: { _, done in done(status) })
        flow.inspect(.localComputerHistory)
        XCTAssertTrue(flow.feedback?.hasPrefix("Vérification 1") == true)
        XCTAssertTrue(flow.feedback?.contains("pas encore confirmé") == true)
        status = .ready
        flow.inspect(.localComputerHistory)
        XCTAssertEqual(flow.result, .ready)
        XCTAssertFalse(consent.isEnabled(.localComputerHistory), "inspect never grants consent")
        XCTAssertFalse(flow.completed)
    }

    func testComputerHistoryAccessKeepsAFailedInputPathRepairable() {
        let granted = PermissionStatus.resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: false)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(granted, inputTapCreationFailed: true), .inputMonitoring,
                       "a failed input path stays repairable")
        let direct = PermissionStatus.resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: true)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(direct, inputTapCreationFailed: true), .ready)
    }
}
#endif
