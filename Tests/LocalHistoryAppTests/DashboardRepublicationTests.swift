import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// R14b: the dashboard model publishes only what a view reads, and only when it changes.
@MainActor
final class DashboardRepublicationTests: XCTestCase {
    /// Step 1: the properties no view reads do not publish.
    func testPropertiesWithoutReaderDoNotPublish() throws {
        let model = try dashboardModel()
        var publications = 0
        let watch = model.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.activitySearch = "safari"
        model.activityFilter = .flagged
        model.selectedSessionID = "session"
        XCTAssertEqual(publications, 0, "a property without reader published")
        model.selectSection(.screenTime)
        XCTAssertEqual(model.secondaryReturn?.section, .overview, "the origin of a secondary page is still kept")
        XCTAssertGreaterThan(publications, 0, "a section change still publishes")
    }

    // MARK: Helpers

    func dashboardModel() throws -> DashboardViewModel {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check (writes fixtures under Application Support)")
        }
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/r14b-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "r14b-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
    }
}
