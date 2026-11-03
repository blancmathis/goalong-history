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

    /// Step 2: the 60 s pass publishes nothing on a quiet day (equal snapshot, every field compared), and exactly once
    /// when one deep field changed. The first read after the placeholder is always shown, even when empty.
    func testEqualSnapshotDoesNotPublish() throws {
        let model = try dashboardModel()
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertTrue(model.publishSnapshot(.empty(day: model.selectedDay)), "the first read is shown, even an empty one")
        XCTAssertTrue(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "a")))
        var publications = 0
        let watch = model.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        let generation = model.snapshotGeneration
        XCTAssertFalse(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "a")), "an equal read was shown")
        XCTAssertEqual(publications, 0, "an equal read published")
        XCTAssertEqual(model.snapshotGeneration, generation)
        XCTAssertTrue(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "b")), "a changed message was dropped")
        XCTAssertEqual(publications, 1, "a changed read publishes exactly once")
        XCTAssertEqual(model.snapshotGeneration, generation &+ 1)
        XCTAssertEqual(model.snapshot.sessions.first?.latestMessage, "b")
    }

    static func snapshot(day: Date, latestMessage: String) -> DashboardDaySnapshot {
        let session = ActivitySession(id: "s1", start: day.addingTimeInterval(3600), end: day.addingTimeInterval(4200),
            appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Page", host: "example.org",
            category: nil, isWork: true, confidence: 0.9, suppressionReason: nil, eventCount: 12, inputEventCount: 10,
            softwareAttributedEventCount: 0, kindCounts: ["app": 12], latestMessage: latestMessage)
        return DashboardDaySnapshot(day: day, eventCount: 12, activeMinutes: 10, workMinutes: 10, sealedMinutes: 0,
            liveAnchoredMinutes: 0, privateMinutes: 0, softwareAttributedEvents: 0, sessions: [session],
            appUsage: [AppUsage(appName: "Safari", bundleIdentifier: "com.apple.Safari", eventCount: 12)],
            trackedUsage: [], timeline: [], storageBytes: 4096, availableDays: [day])
    }

    /// Step 3: the device identity lives in its own object; an unchanged identity publishes nothing.
    func testDeviceStorePublishesOnlyAChange() throws {
        let model = try dashboardModel()
        let info = DeviceIdentityInfo(deviceID: "r14b-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test")
        var publications = 0
        let watch = model.deviceStore.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.updateDeviceInfo(info)
        model.refreshTrustNotices()
        XCTAssertEqual(publications, 0, "an unchanged identity published")
        model.updateDeviceInfo(DeviceIdentityInfo(deviceID: "r14b-other", publicKeyBase64: "", trustTier: "test",
            algorithm: "test"))
        XCTAssertGreaterThan(publications, 0, "a new device ID did not publish")
        XCTAssertEqual(model.deviceStore.deviceID, "r14b-other")
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
