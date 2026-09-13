#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class PermissionRecoveryTests: XCTestCase {
    private func consentStore() throws -> GoalongCapabilityConsentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
    }

    func testEveryPermissionCombinationSeparatesAuthorizationFromHealth() {
        for ax in [false, true] {
            for functional in [false, true] {
                for input in [false, true] {
                    let status = PermissionStatus.resolved(accessibilityPreflight: ax,
                        accessibilityFunctionalProbe: functional, inputMonitoringDirectlyGranted: input)
                    XCTAssertEqual(status.accessibility, ax)
                    XCTAssertEqual(status.isGranted(.accessibility), ax)
                    XCTAssertEqual(status.accessibilityUsable, ax && functional)
                    XCTAssertEqual(status.inputMonitoringDirectlyGranted, input)
                    XCTAssertEqual(status.inputMonitoringProvidedByAccessibility, ax && !input)
                    XCTAssertEqual(status.canAttemptInputTap, ax || input)
                    XCTAssertEqual(status.allGranted, ax)
                    XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), ax ? .ready : .accessibility)
                }
            }
        }
    }

    func testSelfWindowReadCannotAdvertiseEitherPermissionAfterRevocation() {
        let status = PermissionStatus.resolved(accessibilityPreflight: false,
            accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: false)
        XCTAssertFalse(status.accessibility)
        XCTAssertFalse(status.inputMonitoring)
        XCTAssertFalse(status.canAttemptInputTap)
        XCTAssertFalse(status.allGranted)
        XCTAssertEqual(status.inputMonitoringStatusLabel, "off")
        XCTAssertEqual(PermissionWatchdogPolicy.interval(status: status, eventTapRunning: true), 3)
    }

    func testTemporaryAXProbeFailureDoesNotRevokeAnActualGrant() {
        let status = PermissionStatus.resolved(accessibilityPreflight: true,
            accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false)
        XCTAssertTrue(status.accessibility)
        XCTAssertEqual(status.inputMonitoringStatusLabel, "via Accessibility")
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), .ready)
        XCTAssertFalse(status.accessibilityUsable)
        XCTAssertEqual(PermissionWatchdogPolicy.interval(status: status, eventTapRunning: true), 3)
    }

    func testExplicitInputRequestIsNotSuppressedByAccessibility() {
        var requests = 0
        let manager = PermissionManager(statusProbe: {
            .resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true,
                inputMonitoringDirectlyGranted: false)
        }, inputAccessRequest: { requests += 1; return false })
        XCTAssertFalse(manager.requestInputMonitoring())
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(manager.snapshot.inputMonitoringDirectlyGranted)
        XCTAssertEqual(manager.snapshot.inputMonitoringStatusLabel, "via Accessibility")
    }

    func testExplicitInputRequestSkipsSystemPromptWhenDirectGrantAlreadyExists() {
        let manager = PermissionManager(statusProbe: {
            .resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: true)
        }, inputAccessRequest: { XCTFail("No prompt for an existing direct grant"); return false })
        XCTAssertTrue(manager.requestInputMonitoring())
    }

    func testInputRequestRechecksRevocationInsteadOfTrustingCachedGrant() {
        var direct = true
        var requests = 0
        let manager = PermissionManager(statusProbe: {
            .resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true,
                inputMonitoringDirectlyGranted: direct)
        }, inputAccessRequest: { requests += 1; return false })
        direct = false
        XCTAssertTrue(manager.snapshot.inputMonitoringDirectlyGranted)
        XCTAssertFalse(manager.requestInputMonitoring())
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(manager.snapshot.inputMonitoringDirectlyGranted)
    }

    func testInputRequestResultCannotFabricateAConfirmedDirectGrant() {
        let manager = PermissionManager(statusProbe: {
            .resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: false)
        }, inputAccessRequest: { true })
        _ = manager.requestInputMonitoring()
        XCTAssertFalse(manager.snapshot.inputMonitoringDirectlyGranted)
        XCTAssertFalse(manager.snapshot.allGranted)
    }

    func testNewInputGrantIsVisibleAfterRequest() {
        var direct = false
        let manager = PermissionManager(statusProbe: {
            .resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: direct)
        }, inputAccessRequest: { direct = true; return true })
        XCTAssertTrue(manager.requestInputMonitoring())
        XCTAssertTrue(manager.snapshot.inputMonitoringDirectlyGranted)
        XCTAssertFalse(manager.snapshot.accessibility)
    }

    func testRepeatedDenialOffersRecoveryForEachPrivacyPermissionWithoutEnablingSource() throws {
        for (capability, denied): (GoalongCapability, SourceAccessStatus) in [
            (.localComputerHistory, .accessibility),
            (.localComputerHistory, .inputMonitoring),
            (.appleScreenTime, .fullDiskAccess),
            (.aiConversations, .fullDiskAccess),
        ] {
            let store = try consentStore()
            let flow = SourceActivationFlow(store: store, check: { _, done in done(denied) }, initialStatus: denied)
            XCTAssertNil(flow.recovery.recoveryStatus)
            flow.requestMissingAccess { XCTAssertEqual($0, denied) }
            for _ in 0..<3 {
                flow.checkAndEnable(capability, surface: .settings) { XCTFail("Denied access cannot prepare a source") }
                XCTAssertEqual(flow.recovery.recoveryStatus, denied)
                XCTAssertFalse(store.isEnabled(capability))
                XCTAssertFalse(flow.completed)
            }
        }
    }

    func testRecoveryClearsOnlyAfterActualSuccessfulCheck() throws {
        let store = try consentStore()
        var result: SourceAccessStatus = .accessibility
        let flow = SourceActivationFlow(store: store, check: { _, done in done(result) }, initialStatus: result)
        flow.requestMissingAccess { _ in }
        XCTAssertFalse(store.isEnabled(.localComputerHistory))
        flow.checkAndEnable(.localComputerHistory, surface: .settings) {}
        XCTAssertEqual(flow.recovery.recoveryStatus, .accessibility)
        result = .ready
        var preparations = 0
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { preparations += 1 }
        XCTAssertTrue(flow.completed)
        XCTAssertTrue(store.isEnabled(.localComputerHistory))
        XCTAssertEqual(flow.recovery, SourceAccessRecoveryState())
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { preparations += 1 }
        XCTAssertEqual(preparations, 1)
    }

    func testCancellationDuringRecoveryRejectsLateSuccess() throws {
        let store = try consentStore()
        var callback: ((SourceAccessStatus) -> Void)?
        let flow = SourceActivationFlow(store: store, check: { _, done in callback = done }, initialStatus: .fullDiskAccess)
        flow.requestMissingAccess { _ in }
        flow.checkAndEnable(.appleScreenTime, surface: .settings) { XCTFail("Cancelled source preparation") }
        flow.cancel()
        callback?(.ready)
        XCTAssertFalse(flow.completed)
        XCTAssertFalse(store.isEnabled(.appleScreenTime))
    }

    func testDifferentPermissionIsNotMisdiagnosedAsRepeatedDenial() {
        var state = SourceAccessRecoveryState()
        state.requested(.accessibility)
        state.checked(.inputMonitoring)
        XCTAssertNil(state.recoveryStatus)
        state.requested(.inputMonitoring)
        state.checked(.inputMonitoring)
        XCTAssertEqual(state.recoveryStatus, .inputMonitoring)
    }

    func testMissingDataAndUnavailableFoldersAreNotPermissionRepairRequests() {
        for status: SourceAccessStatus in [.screenTimeSetup, .unavailable("Folder moved")] {
            XCTAssertNil(status.privacyPermissionTitle)
            var state = SourceAccessRecoveryState()
            state.requested(status)
            state.checked(status)
            XCTAssertNil(state.recoveryStatus)
            XCTAssertNil(state.requestedStatus)
        }
    }

    func testPermissionRequestsRemainExplicitAndCheckAccessIsAlwaysAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let activation = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/SourceActivation.swift"))
        XCTAssertTrue(activation.contains("guard status.accessibilityPreflight else { return .accessibility }"))
        XCTAssertTrue(activation.contains("guard status == .ready else { return }"))
        XCTAssertTrue(activation.contains("PermissionRecoveryPanel(status: status"))
        XCTAssertFalse(activation.contains("if openedSettings {\n                        Button(\"Check access\")"))
        let recovery = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/PermissionRecovery.swift"))
        XCTAssertFalse(recovery.contains("tccutil"))
        XCTAssertFalse(recovery.contains("TCC.db"))
        XCTAssertFalse(recovery.contains("Process("))
        XCTAssertFalse(recovery.contains("enabled: true"))
    }
}
#endif
