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
        let watch = Self.watchStores(of: model) { publications += 1 }
        defer { watch.forEach { $0.cancel() } }
        model.activitySearch = "safari"
        model.activityFilter = .flagged
        model.selectedSessionID = "session"
        XCTAssertEqual(publications, 0, "a property without reader published")
        model.selectSection(.screenTime)
        XCTAssertEqual(model.navigationStore.secondaryReturn?.section, .overview, "the origin of a secondary page is still kept")
        XCTAssertGreaterThan(publications, 0, "a section change still publishes")
    }

    /// Step 2: the 60 s pass publishes nothing on a quiet day (equal snapshot, every field compared), and exactly once
    /// when one deep field changed. The first read after the placeholder is always shown, even when empty.
    func testEqualSnapshotDoesNotPublish() throws {
        let model = try dashboardModel()
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertTrue(model.publishSnapshot(.empty(day: model.navigationStore.selectedDay)), "the first read is shown, even an empty one")
        XCTAssertTrue(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "a")))
        var publications = 0
        let watch = Self.watchStores(of: model) { publications += 1 }
        defer { watch.forEach { $0.cancel() } }
        let generation = model.snapshotStore.snapshotGeneration
        XCTAssertFalse(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "a")), "an equal read was shown")
        XCTAssertEqual(publications, 0, "an equal read published")
        XCTAssertEqual(model.snapshotStore.snapshotGeneration, generation)
        XCTAssertTrue(model.publishSnapshot(Self.snapshot(day: day, latestMessage: "b")), "a changed message was dropped")
        XCTAssertEqual(publications, 1, "a changed read publishes exactly once")
        XCTAssertEqual(model.snapshotStore.snapshotGeneration, generation &+ 1)
        XCTAssertEqual(model.snapshotStore.snapshot.sessions.first?.latestMessage, "b")
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

    /// Step 4: the alert lives in its own object; clearing an absent alert publishes nothing, a new one publishes.
    func testAlertCenterPublishesOnlyAChange() throws {
        let model = try dashboardModel()
        var publications = 0
        let watch = model.alertStore.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.alertStore.alert = nil
        XCTAssertEqual(publications, 0, "nil over nil published")
        model.alertStore.alert = DashboardAlert(kind: .error, title: "R14b", message: "test")
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.alertStore.alert?.title, "R14b")
    }

    /// Step 5: navigation lives in its own object; it publishes on a click, never on the same value again.
    func testNavigationPublishesOnlyAChange() throws {
        let model = try dashboardModel()
        var publications = 0
        let watch = model.navigationStore.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.selectSection(model.navigationStore.selectedSection)
        model.selectDay(model.navigationStore.selectedDay)
        XCTAssertEqual(publications, 0, "the same page or day published")
        model.selectDay(Calendar.current.date(byAdding: .day, value: -1, to: model.navigationStore.selectedDay)!)
        XCTAssertEqual(publications, 1, "a new day publishes once")
        XCTAssertFalse(model.navigationStore.isTodaySelected)
    }

    /// Step 6: the settings live in their own object; re-reading an unchanged config.json publishes nothing.
    func testSettingsPublishOnlyAChange() throws {
        let model = try dashboardModel()
        var publications = 0
        let watch = model.settingsStore.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.refreshConfigStatus()
        model.configurationDidChange()
        model.settingsStore.settingsDraft = model.settingsStore.settingsDraft
        XCTAssertEqual(publications, 0, "an unchanged config published")
        XCTAssertFalse(model.settingsStore.settingsHaveChanges)
        model.settingsStore.usageSearch = "safari"
        XCTAssertEqual(publications, 1)
    }

    /// Step 7: the runtime and the day's data publish only a change. Free space publishes only a change the user can
    /// see, but the exact value is always kept; the placeholder of a hidden window is not published twice.
    func testRuntimeAndSnapshotStoresPublishOnlyAChange() {
        let runtime = DashboardRuntimeState()
        var runtimePublications = 0
        let watchRuntime = runtime.objectWillChange.sink { runtimePublications += 1 }
        defer { watchRuntime.cancel() }
        runtime.setRuntime(.unavailable)
        runtime.setDashboardVisible(false)
        runtime.setStatusVisible(false)
        XCTAssertEqual(runtimePublications, 0, "an equal runtime published")
        runtime.setFreeDiskBytes(100_000_000_000)
        XCTAssertEqual(runtimePublications, 1, "the first free space was not published")
        runtime.setFreeDiskBytes(100_000_004_096)
        XCTAssertEqual(runtimePublications, 1, "a free space with the same text published")
        XCTAssertEqual(runtime.freeDiskBytes, 100_000_004_096, "the exact free space was dropped")
        runtime.setFreeDiskBytes(1_000_000)
        XCTAssertEqual(runtimePublications, 2, "a low free space was not published")
        runtime.setDashboardVisible(true)
        XCTAssertEqual(runtimePublications, 3)
        XCTAssertTrue(runtime.recordingStatusIsLive)

        let day = Calendar.current.startOfDay(for: Date())
        let snapshots = DashboardSnapshotStore(day: day)
        var snapshotPublications = 0
        let watchSnapshots = snapshots.objectWillChange.sink { snapshotPublications += 1 }
        defer { watchSnapshots.cancel() }
        snapshots.discard(day: day)
        snapshots.setRefreshing(false)
        XCTAssertEqual(snapshotPublications, 0, "the placeholder or an equal spinner published")
        XCTAssertTrue(snapshots.show(.empty(day: day)), "the first read is shown, even an empty one")
        XCTAssertFalse(snapshots.show(.empty(day: day)))
        XCTAssertEqual(snapshotPublications, 1)
        snapshots.discard(day: day)
        XCTAssertEqual(snapshotPublications, 2, "hiding the window must drop the day shown")
        XCTAssertEqual(snapshots.snapshotGeneration, 2)
    }

    /// Review point 3: hiding the window drops the day shown for a placeholder (R13: never stale on return). The
    /// placeholder publishes once, a second hide publishes nothing, and the first read on return is shown even when it
    /// equals the placeholder or the day dropped.
    func testHiddenWindowShowsAPlaceholderThenTheFirstReadOnReturn() throws {
        let model = try dashboardModel()
        let store = model.snapshotStore
        model.dashboardDidBecomeVisible()
        defer { model.dashboardDidBecomeHidden() }
        try waitForRead(model, after: 0)
        let day = model.navigationStore.selectedDay
        let read = Self.snapshot(day: day, latestMessage: "r14b")
        model.publishSnapshot(read)
        XCTAssertFalse(model.publishSnapshot(read), "an equal read was shown")
        var publications = 0
        let watch = store.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }

        let shown = store.snapshotGeneration
        model.dashboardDidBecomeHidden()
        XCTAssertFalse(model.runtimeStore.dashboardIsVisible)
        XCTAssertEqual(store.snapshot, .empty(day: day), "the hidden window kept the day shown")
        XCTAssertEqual(store.snapshotGeneration, shown + 1, "the placeholder must move the generation once")
        let afterHide = publications
        XCTAssertGreaterThanOrEqual(afterHide, 1, "the placeholder was not published")
        model.dashboardDidBecomeHidden()
        XCTAssertEqual(publications, afterHide, "a second hide published the placeholder again")
        XCTAssertEqual(store.snapshotGeneration, shown + 1)

        // The first read on return, equal to the day dropped: shown once, then the same read is silent again.
        publications = 0
        XCTAssertTrue(model.publishSnapshot(read), "the first read after the placeholder was dropped")
        XCTAssertEqual(store.snapshot, read)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(model.publishSnapshot(read))
        XCTAssertEqual(publications, 1)

        // The real path: hidden, then shown again; the reader's first read (an empty day here, equal to the
        // placeholder) is shown, so a page tells it from the placeholder by its generation.
        model.dashboardDidBecomeHidden()
        let placeholder = store.snapshotGeneration
        XCTAssertEqual(store.snapshot, .empty(day: model.navigationStore.selectedDay))
        model.dashboardDidBecomeVisible()
        try waitForRead(model, after: placeholder)
        XCTAssertFalse(model.publishSnapshot(store.snapshot), "the read on return was not taken as read")
    }

    /// Review point 4: the analysis sheet reads the conversation folders through its own observation. A folder added,
    /// then disabled, while the sheet is open shows up, then goes, without reopening it. Off screen: the gallery's
    /// window, never ordered in, so nothing is shown and nothing takes the focus.
    func testAnalysisSheetFollowsTheConversationFoldersWhileOpen() throws {
        let model = try dashboardModel()
        let name = "r14b-sheet-folder"
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var selection = GoalongAnalysisSelection()
        selection.conversations = true
        let sheet = NSHostingView(rootView: GoalongAnalysisSelectionSheet(model: model, selection: selection) { _ in })
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 1600),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sheet
        defer { window.contentView = nil; window.close() }
        func turn() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); sheet.layoutSubtreeIfNeeded(); sheet.displayIfNeeded() }
        func spin(until condition: () -> Bool, _ message: String) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { turn() }
            XCTAssertTrue(condition(), message)
        }
        let row: (String) -> Bool = { $0.hasSuffix(", \(name)") }
        let empty: (String) -> Bool = { $0.hasPrefix("Aucun dossier activé") }
        // The sheet's own loads end first (its save button turns on), so only the folder change can redraw it.
        spin(until: { Self.texts(of: sheet, enabledOnly: true).contains("analysis-save-selection") }, "the sheet never loaded")
        for _ in 0..<20 { turn() }
        XCTAssertTrue(Self.texts(of: sheet).contains(where: empty), "no folder yet")
        XCTAssertFalse(Self.texts(of: sheet).contains(where: row))

        model.agentActivityRuntime.addFolder(folder, provider: .codex)
        spin(until: { let seen = Self.texts(of: sheet); return seen.contains(where: row) && !seen.contains(where: empty) },
             "a folder added while the sheet is open is not listed")
        let id = try XCTUnwrap(model.agentActivityRuntime.configuration.watchedFolders.first { $0.displayName == name }?.id)
        model.agentActivityRuntime.setFolderEnabled(false, id: id)
        spin(until: { let seen = Self.texts(of: sheet); return !seen.contains(where: row) && seen.contains(where: empty) },
             "a folder disabled while the sheet is open is still listed")
    }

    // MARK: Helpers

    /// Every store of the model: all a view can observe (the model itself is no longer observable).
    static func watchStores(of model: DashboardViewModel, _ count: @escaping () -> Void) -> [AnyCancellable] {
        let stores: [ObservableObjectPublisher] = [model.deviceStore.objectWillChange, model.alertStore.objectWillChange,
            model.navigationStore.objectWillChange, model.settingsStore.objectWillChange,
            model.runtimeStore.objectWillChange, model.snapshotStore.objectWillChange]
        return stores.map { $0.sink { _ in count() } }
    }

    /// Every identifier, label, title and value of a view's accessibility tree (only enabled elements if asked).
    static func texts(of view: NSView, enabledOnly: Bool = false) -> [String] {
        // The tree is built only while it is asked for, as in `ViewSwitchAX.first`.
        let before = NSApplication.shared.accessibilityAttributeValue(ViewSwitchAX.enhancedUI)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: ViewSwitchAX.enhancedUI)
        defer { NSApplication.shared.accessibilitySetValue(before ?? false, forAttribute: ViewSwitchAX.enhancedUI) }
        var found: [String] = [], pending: [Any] = [view], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 20_000 {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if !enabledOnly || ViewSwitchAX.flag(object, "isAccessibilityEnabled") != false {
                for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    if let text = ViewSwitchAX.read(object, name) as? String, !text.isEmpty { found.append(text) }
                }
            }
            pending.append(contentsOf: ViewSwitchAX.read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    /// Waits until the reader's first read after generation `after` is shown (10 s at most).
    func waitForRead(_ model: DashboardViewModel, after generation: UInt64) throws {
        let deadline = Date().addingTimeInterval(10)
        while model.snapshotStore.snapshotGeneration <= generation || model.snapshotStore.isRefreshing, Date() < deadline {
            model.waitForPendingWorkForTesting()
        }
        XCTAssertGreaterThan(model.snapshotStore.snapshotGeneration, generation, "the reader never showed its read")
        for _ in 0..<5 { model.waitForPendingWorkForTesting() }  // the names and icons pass that follows a read
    }

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
