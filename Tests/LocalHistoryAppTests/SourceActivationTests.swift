#if os(macOS)
import Foundation
import AppKit
import XCTest
@testable import LocalHistoryApp

final class SourceActivationTests: XCTestCase {
    private func store() throws -> GoalongCapabilityConsentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
    }

    func testPermissionExplanationDoesNotBlockSystemRequestedTermination() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.preventsApplicationTerminationWhenModal = true
        window.contentView = PermissionSheetWindowView()
        XCTAssertFalse(window.preventsApplicationTerminationWhenModal)
        let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertTrue(unrelatedWindow.preventsApplicationTerminationWhenModal)
    }

    func testFunctionalReadDoesNotReplacePermissionAfterReset() {
        let reset = PermissionStatus.resolved(accessibilityPreflight: false,
            accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: false)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(reset), .accessibility)
    }

    func testGrantedAccessibilitySurvivesTemporaryWindowProbeFailure() {
        let granted = PermissionStatus.resolved(accessibilityPreflight: true,
            accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: true)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(granted), .ready)
        XCTAssertFalse(granted.accessibilityUsable, "Capture health must still report the failed live probe")
        let denied = PermissionStatus.resolved(accessibilityPreflight: false,
            accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: true)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(denied), .accessibility)
    }

    func testKnownMissingAccessRequestsSettingsImmediatelyAndWaitsForActualGrant() throws {
        let consent = try store()
        var access: SourceAccessStatus = .fullDiskAccess
        var requested: [SourceAccessStatus] = []
        let flow = SourceActivationFlow(store: consent, check: { _, done in done(access) }, initialStatus: access)
        flow.requestMissingAccess { requested.append($0) }
        XCTAssertEqual(requested, [.fullDiskAccess])
        XCTAssertFalse(consent.isEnabled(.appleScreenTime))
        flow.checkAndEnable(.appleScreenTime, surface: .settings) {}
        XCTAssertEqual(flow.result, .fullDiskAccess)
        XCTAssertFalse(flow.completed)
        access = .ready
        flow.checkAndEnable(.appleScreenTime, surface: .settings) {}
        XCTAssertTrue(consent.isEnabled(.appleScreenTime))
        XCTAssertTrue(flow.completed)
    }

    func testExistingAccessDoesNotRequestPermissionOrReconfigureEnabledCapture() throws {
        let consent = try store()
        XCTAssertTrue(consent.set(.localComputerHistory, enabled: true, surface: .settings))
        let flow = SourceActivationFlow(store: consent, check: { _, done in done(.ready) })
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { XCTFail("Existing settings must be preserved") }
        flow.requestMissingAccess { _ in XCTFail("No missing permission") }
        XCTAssertTrue(flow.completed)
    }

    func testDeniedAccessNeverPreparesOrEnablesAnySource() throws {
        for capability: GoalongCapability in [.localComputerHistory, .appleScreenTime, .aiConversations] {
            let consent = try store()
            var prepared = false
            let flow = SourceActivationFlow(store: consent, check: { _, finish in finish(.fullDiskAccess) })
            flow.checkAndEnable(capability, surface: .settings) { prepared = true }
            XCTAssertFalse(prepared)
            XCTAssertFalse(consent.isEnabled(capability))
            XCTAssertFalse(flow.completed)
            XCTAssertEqual(flow.result, .fullDiskAccess)
        }
    }

    func testCancelledCheckCannotEnableSourceWithLateSuccess() throws {
        let consent = try store()
        var finish: ((SourceAccessStatus) -> Void)?
        let flow = SourceActivationFlow(store: consent, check: { _, callback in finish = callback })
        flow.checkAndEnable(.appleScreenTime, surface: .settings) { XCTFail("Cancelled preparation") }
        XCTAssertTrue(flow.checking)
        flow.cancel()
        finish?(.ready)
        XCTAssertFalse(consent.isEnabled(.appleScreenTime))
        XCTAssertFalse(flow.completed)
    }

    func testOnlySuccessfulCheckPersistsAndPreparesOnce() throws {
        let consent = try store()
        var finish: ((SourceAccessStatus) -> Void)?
        var checks = 0
        var preparations = 0
        let flow = SourceActivationFlow(store: consent, check: { _, callback in checks += 1; finish = callback })
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { preparations += 1 }
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { preparations += 1 }
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(consent.isEnabled(.localComputerHistory))
        finish?(.ready)
        XCTAssertEqual(preparations, 1)
        XCTAssertTrue(consent.isEnabled(.localComputerHistory))
        XCTAssertTrue(flow.completed)
    }

    func testPreparationFailureKeepsSourceDisabled() throws {
        let consent = try store()
        let flow = SourceActivationFlow(store: consent, check: { _, finish in finish(.ready) })
        flow.checkAndEnable(.localComputerHistory, surface: .settings) { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(consent.isEnabled(.localComputerHistory))
        XCTAssertFalse(flow.completed)
        guard case .unavailable = flow.result else { return XCTFail("Missing recovery message") }
    }

    func testConsentWriteFailureDoesNotReportSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file, not directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let consent = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
        let flow = SourceActivationFlow(store: consent, check: { _, finish in finish(.ready) })
        flow.checkAndEnable(.aiConversations, surface: .settings) {}
        XCTAssertFalse(consent.isEnabled(.aiConversations))
        XCTAssertFalse(flow.completed)
        guard case .unavailable = flow.result else { return XCTFail("Missing save error") }
    }

    func testRetryAfterDeniedAccessCanEnable() throws {
        let consent = try store()
        var access: SourceAccessStatus = .accessibility
        let flow = SourceActivationFlow(store: consent, check: { _, finish in finish(access) })
        flow.checkAndEnable(.localComputerHistory, surface: .settings) {}
        XCTAssertFalse(consent.isEnabled(.localComputerHistory))
        access = .ready
        flow.checkAndEnable(.localComputerHistory, surface: .settings) {}
        XCTAssertTrue(consent.isEnabled(.localComputerHistory))
    }
}
#endif
