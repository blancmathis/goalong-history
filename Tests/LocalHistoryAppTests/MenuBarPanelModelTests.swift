#if os(macOS)
import Ambiance
import Combine
import Foundation
import LocalHistoryCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class MenuBarPanelModelTests: XCTestCase {
    @MainActor private final class Fixture {
        let name = "menubar-model-" + UUID().uuidString
        let root = URL(fileURLWithPath: "/private/tmp/menubar-model-" + UUID().uuidString)
        let defaults: UserDefaults
        let modules: GoalongModuleStore
        let ambiance: AmbianceModule
        let state = CaptureState(isGloballyPaused: { false })
        var now = Date(timeIntervalSince1970: 1791716400)
        var calendar: Calendar
        var focus: ConcentrationController?
        var blocking: BlockingController?
        var health: CaptureHealthState = .ready
        var globallyPaused = GoalongGlobalPause()
        var consent = true
        var pauseAccepted = true
        var opened: [DashboardSection] = []
        var openedPanes: [SettingsPane] = []
        var played: [AmbianceSource] = []
        var openedDay = false
        var openedClassicMenu = false

        init() {
            defaults = UserDefaults(suiteName: name)!
            modules = GoalongModuleStore(defaults: defaults)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            self.calendar = calendar
            let root = root
            ambiance = AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root })
        }

        func startFocusController() throws {
            modules.setEnabled(.concentration, true)
            let store = FocusStore(directory: root.appendingPathComponent("concentration"))
            var settings = FocusSettings()
            settings.morningPrompt = false; settings.eveningPrompt = false
            try store.saveSettings(settings)
            focus = try ConcentrationController(store: store, clock: { [unowned self] in self.now },
                calendar: calendar, blocking: { [unowned self] in self.blocking })
        }

        func model(loadDay: ((Date) async throws -> GoalongLocalAnalytics.Day)? = nil) -> MenuBarPanelModel {
            MenuBarPanelModel(state: state, modules: modules, concentration: { [unowned self] in self.focus },
                ambianceModule: ambiance, blocking: { [unowned self] in self.blocking },
                health: { [unowned self] in self.health }, localHistoryEnabled: { [unowned self] in self.consent },
                globalPause: { [unowned self] in self.globallyPaused }, clock: { [unowned self] in self.now },
                calendar: calendar, loadDay: loadDay,
                playAmbiance: { [unowned self] _, source in self.played.append(source) },
                onTogglePause: { [unowned self] in
                    if self.pauseAccepted { self.state.setManualPaused(!self.state.isManuallyPaused) }
                }, onOpenSection: { [unowned self] in self.opened.append($0) },
                onOpenSettingsPane: { [unowned self] in self.openedPanes.append($0) },
                onOpenDay: { [unowned self] in self.openedDay = true },
                onShowClassicMenu: { [unowned self] in self.openedClassicMenu = true })
        }
    }

    @MainActor private func fixture() -> Fixture {
        let value = Fixture()
        let root = value.root, defaults = value.defaults, name = value.name
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return value
    }

    @MainActor func testPauseUsesExistingActionAndHonorsCancellation() throws {
        let f = fixture(); try f.startFocusController()
        let model = f.model(); model.refreshRuntimeState()
        XCTAssertEqual(model.tracking, .active); XCTAssertTrue(model.focusAvailable)
        f.pauseAccepted = false; model.togglePause()
        XCTAssertEqual(model.tracking, .active); XCTAssertFalse(f.state.isManuallyPaused)
        f.pauseAccepted = true; model.togglePause()
        XCTAssertEqual(model.tracking, .paused(since: f.now)); XCTAssertFalse(model.focusAvailable)
        XCTAssertEqual(model.focusUnavailableReason, "Reprenez le suivi pour lancer une séance.")
        model.startFocus(); XCTAssertNil(f.focus?.currentSession)
        model.togglePause()
        XCTAssertEqual(model.tracking, .active); XCTAssertTrue(model.focusAvailable)
    }

    @MainActor func testGlobalPauseConsentAndCaptureFailuresRemainVisible() {
        let f = fixture(), model = f.model()
        f.globallyPaused.paused = true; f.globallyPaused.changedAt = f.now
        model.refreshRuntimeState(); XCTAssertEqual(model.tracking, .paused(since: f.now))
        f.globallyPaused.paused = false; f.consent = false
        model.refreshRuntimeState(); XCTAssertEqual(model.tracking, .attention("Enregistrement désactivé"))
        f.consent = true; f.health = .storageUnavailable
        model.refreshRuntimeState(); XCTAssertEqual(model.tracking, .attention(f.health.frenchTitle))
        f.health = .permissionRequired
        model.refreshRuntimeState(); XCTAssertEqual(model.tracking, .attention(f.health.frenchTitle))
        XCTAssertEqual(model.attentionTitle, f.health.frenchTitle)
        f.health = .ready; f.consent = false
        model.refreshRuntimeState(); XCTAssertEqual(model.attentionTitle, "Enregistrement désactivé")
        f.consent = true
        model.refreshRuntimeState(); XCTAssertNil(model.attentionTitle)
    }

    @MainActor func testAttentionAndUnavailableFocusOfferARepairAction() {
        let f = fixture(), model = f.model()
        f.health = .permissionRequired
        model.refreshRuntimeState()
        XCTAssertEqual(model.attentionFix, .permissions)
        model.perform(.permissions)
        XCTAssertEqual(f.openedPanes, [.permissions])
        f.health = .storageUnavailable; model.refreshRuntimeState()
        XCTAssertNil(model.attentionFix)
        f.health = .ready; model.refreshRuntimeState()
        XCTAssertNil(model.attentionFix)
        // Concentration is off: the reason names Réglages and the action opens the modules pane.
        XCTAssertEqual(model.focusUnavailableReason, "Activez Concentration dans Réglages.")
        XCTAssertEqual(model.focusUnavailableFix, .modules)
        model.perform(.modules); model.perform(.recording); model.perform(.app)
        XCTAssertEqual(f.openedPanes, [.permissions, .modules, .recording])
        XCTAssertEqual(f.opened, [.overview])
    }

    @MainActor func testConsentOffWinsOverTheManualPauseSetByProduction() {
        let f = fixture(), model = f.model()
        // applyCapabilityConsents sets the manual pause whenever consent is off.
        f.consent = false; f.state.setManualPaused(true)
        model.refreshRuntimeState()
        XCTAssertEqual(model.tracking, .attention("Enregistrement désactivé"))
        XCTAssertEqual(model.trackingDetail, "Activez l’enregistrement dans Réglages")
        f.globallyPaused.paused = true; f.globallyPaused.changedAt = f.now
        model.refreshRuntimeState()
        XCTAssertEqual(model.tracking, .paused(since: f.now), "The global pause still wins")
        f.globallyPaused.paused = false; f.consent = true
        model.refreshRuntimeState()
        guard case .paused = model.tracking else { return XCTFail("Manual pause shows once consent is back") }
    }

    @MainActor func testInactiveModuleCallsToActionOpenTheModulesPane() {
        let f = fixture(), model = f.model()
        model.enableAmbiance(); model.openModulesSettings()
        XCTAssertEqual(f.openedPanes, [.modules, .modules])
        XCTAssertTrue(f.opened.isEmpty)
        f.modules.setEnabled(.ambiance, true)
        model.enableAmbiance()
        XCTAssertEqual(f.opened, [.ambiance], "An enabled module still opens its own page")
    }

    @MainActor func testConcentrationOffExposesFlagAndStartOpensModulesPane() {
        let f = fixture(), model = f.model()
        model.refreshRuntimeState()
        XCTAssertFalse(model.concentrationEnabled)
        model.startFocus()
        XCTAssertEqual(f.openedPanes, [.modules]); XCTAssertTrue(f.opened.isEmpty)
        f.modules.setEnabled(.concentration, true); model.refreshRuntimeState()
        XCTAssertTrue(model.concentrationEnabled)
    }

    @MainActor func testGlobalPauseHeaderLabelSaysItOpensSettingsNotManualResume() {
        let f = fixture(), model = f.model()
        f.globallyPaused.paused = true; model.refreshRuntimeState()
        XCTAssertTrue(model.globalPaused)
        XCTAssertEqual(model.headerActionLabel, "\(GoalongGlobalPauseText.resume)…")
        XCTAssertNotEqual(model.headerActionLabel, "Reprendre le suivi")
        f.globallyPaused.paused = false; model.refreshRuntimeState()
        XCTAssertFalse(model.globalPaused)
        XCTAssertEqual(model.headerActionLabel, "Mettre le suivi en pause")
    }

    @MainActor func testConsentOffFlagIsSetOnlyForConsent() {
        let f = fixture(), model = f.model()
        f.consent = false; model.refreshRuntimeState(); XCTAssertTrue(model.consentOff)
        f.globallyPaused.paused = true; model.refreshRuntimeState(); XCTAssertFalse(model.consentOff)
        f.globallyPaused.paused = false; f.consent = true; model.refreshRuntimeState(); XCTAssertFalse(model.consentOff)
    }

    @MainActor func testWorkIsUnknownUntilVerdictsExistLikeTheActivityPage() {
        let f = fixture(), model = f.model(), day = f.calendar.startOfDay(for: f.now)
        func value(_ kind: GoalongLocalAnalytics.Kind) -> GoalongLocalAnalytics.Day {
            .init(date: day, end: day.addingTimeInterval(86400), state: .ready, segments: [
                .init(start: day, end: day.addingTimeInterval(3600), kind: kind, application: "A", bundleIdentifier: nil, host: nil)
            ], eventCount: 1, classifierVersions: [])
        }
        model.applyDay(value(.unclassified)); XCTAssertFalse(model.workKnown)
        model.applyDay(value(.work)); XCTAssertTrue(model.workKnown)
        model.applyDay(value(.other)); XCTAssertTrue(model.workKnown, "Mostly classified: work is a real zero")
    }

    @MainActor func testPomodoroAndFreeSessionsUseControllerAndRealPhaseClock() throws {
        let f = fixture(); try f.startFocusController()
        let model = f.model(); model.focusMinutes = 50; model.startFocus()
        XCTAssertEqual(f.focus?.currentSession?.mode.workMinutes, 50)
        XCTAssertEqual(model.focusRun?.remaining, 3000); XCTAssertEqual(model.focusRun?.cycles, 4)
        f.now = f.now.addingTimeInterval(1500); model.refreshRuntimeState()
        XCTAssertEqual(model.focusRun?.progress, 0.5); XCTAssertEqual(model.focusRun?.elapsed, 1500)
        let id = f.focus?.currentSession?.id
        model.pauseOrResumeFocus()
        XCTAssertEqual(f.opened.last, .concentration); XCTAssertEqual(f.focus?.currentSession?.id, id)
        XCTAssertEqual(model.focusRun?.isPaused, false)
        model.stopFocus(); XCTAssertNil(model.focusRun); XCTAssertNil(f.focus?.currentSession)
        model.focusKind = .free; model.startFocus()
        XCTAssertEqual(f.focus?.currentSession?.mode.kind, .free)
        XCTAssertNil(model.focusRun?.remaining); XCTAssertNil(model.focusRun?.progress)
        f.now = f.now.addingTimeInterval(37); model.refreshRuntimeState()
        XCTAssertEqual(model.focusRun?.elapsed, 37)
    }

    @MainActor func testLockedSessionStopCannotBypassController() throws {
        let f = fixture(), list = LocalHistoryApp.BlockList(name: "Protégée")
        f.blocking = BlockingController(document: BlockingDocument(lists: [list]), clock: { f.now },
            calendar: f.calendar, continuous: { f.now.timeIntervalSince1970 }, runningApps: { [] })
        try f.startFocusController()
        try f.focus!.startSession(intent: "Écrire", mode: FocusMode(minutes: 25), blockListIds: [list.id], lock: true)
        let model = f.model(); model.stopFocus()
        XCTAssertNotNil(f.focus?.currentSession); XCTAssertNotNil(model.focusRun)
        XCTAssertEqual(f.opened.last, .concentration)
        XCTAssertEqual(f.blocking?.activeBlocks.first?.lock, .locked)
    }

    @MainActor func testLockedListsCannotBeToggledAndStopOpensBlocking() {
        for lock: BlockLock in [.typing, .password, .locked] {
            let f = fixture(), list = LocalHistoryApp.BlockList(name: "Protégée")
            let session = BlockSession(listIDs: [list.id], start: f.now, end: f.now.addingTimeInterval(3600), lock: lock)
            f.blocking = BlockingController(document: BlockingDocument(lists: [list], sessions: [session]), clock: { f.now },
                calendar: f.calendar, continuous: { f.now.timeIntervalSince1970 }, runningApps: { [] })
            f.modules.setEnabled(.blocking, true)
            let model = f.model(); model.refreshRuntimeState()
            XCTAssertTrue(model.blockLists[0].isLocked)
            let before = f.blocking?.activeBlocks
            model.setBlockList(list.id.uuidString, active: false)
            model.setBlockList(list.id.uuidString, active: true)
            XCTAssertEqual(f.blocking?.activeBlocks, before)
            model.requestStopBlocking(list.id.uuidString)
            XCTAssertEqual(f.opened.last, .blocking); XCTAssertEqual(f.blocking?.activeBlocks, before)
        }
    }

    @MainActor func testFreeListToggleUsesDayEndAndDoesNotStopSharedSession() {
        let f = fixture(), first = LocalHistoryApp.BlockList(name: "Vidéo"), second = LocalHistoryApp.BlockList(name: "Sites")
        f.blocking = BlockingController(document: BlockingDocument(lists: [first, second]), clock: { f.now },
            calendar: f.calendar, continuous: { f.now.timeIntervalSince1970 }, runningApps: { [] })
        f.modules.setEnabled(.blocking, true)
        let model = f.model(); model.setBlockList(first.id.uuidString, active: true)
        XCTAssertEqual(f.blocking?.activeBlocks.first?.end,
            f.calendar.date(byAdding: .day, value: 1, to: f.calendar.startOfDay(for: f.now)))
        XCTAssertTrue(model.blockLists.first!.isActive)
        model.setBlockList(first.id.uuidString, active: false)
        XCTAssertFalse(model.blockLists.first!.isActive)
        f.blocking?.start(listIDs: [first.id, second.id], until: f.now.addingTimeInterval(3600), lock: .free)
        model.setBlockList(first.id.uuidString, active: false)
        XCTAssertEqual(f.opened.last, .blocking); XCTAssertEqual(f.blocking?.activeBlocks.count, 1)
    }

    @MainActor func testBlockListBindingHopsToMainActorBeforePublishing() async {
        let f = fixture(), list = LocalHistoryApp.BlockList(name: "Vidéo", sites: [.init(pattern: "example.invalid")])
        f.blocking = BlockingController(document: BlockingDocument(lists: [list]), clock: { f.now },
            calendar: f.calendar, continuous: { f.now.timeIntervalSince1970 }, runningApps: { [] })
        f.modules.setEnabled(.blocking, true)
        let model = f.model()
        let published = expectation(description: "Blocking activation is published")
        let subscription = f.blocking!.$activeBlocks.dropFirst().sink { blocks in
            guard !blocks.isEmpty else { return }
            XCTAssertTrue(Thread.isMainThread, "A SwiftUI binding must not enter the blocking engine off-main")
            published.fulfill()
        }
        defer { subscription.cancel() }
        let binding = Binding(get: { false }, set: { model.setBlockList(list.id.uuidString, active: $0) })
        await Task.detached { binding.wrappedValue = true }.value
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(model.blockLists.first?.isActive == true)
        XCTAssertEqual(f.blocking?.activeBlocks.first?.listIDs, [list.id])
    }

    @MainActor func testPlayNextStaysInCurrentFamilySkipsUnavailableAndWraps() throws {
        let f = fixture(); f.modules.setEnabled(.ambiance, true)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let first = f.root.appendingPathComponent("first.wav"), second = f.root.appendingPathComponent("second.wav")
        try Data().write(to: first); try Data().write(to: second)
        f.ambiance.settings.ownFiles = [first.path, f.root.appendingPathComponent("missing.wav").path, second.path]
        f.ambiance.settings.lastSource = "file:" + first.path
        let model = f.model(); model.playNext()
        XCTAssertEqual(f.played.last?.id, "file:" + second.path)
        XCTAssertEqual(f.played.last?.kind, .ownFile)
        f.ambiance.settings.lastSource = "file:" + second.path; model.playNext()
        XCTAssertEqual(f.played.last?.id, "file:" + first.path)
        f.ambiance.settings.lastSource = "ambre"; model.playNext()
        XCTAssertEqual(f.played.count, 2, "No installed focus source: never switch to another tab")
        XCTAssertTrue(model.ambianceSources.contains { $0.kind == .texture && !$0.isAvailable })
        model.ambianceVolume = 1.5
        XCTAssertEqual(f.ambiance.controller?.volume, 1); XCTAssertEqual(model.ambianceVolume, 1)
        model.ambianceVolume = .nan
        XCTAssertEqual(f.ambiance.controller?.volume, 0.5)
    }

    @MainActor func testDayProjectionPreservesTotalsAndLeavesCoverageGapsEmpty() {
        let f = fixture(), model = f.model(), day = f.calendar.startOfDay(for: f.now)
        let end = day.addingTimeInterval(86400)
        let value = GoalongLocalAnalytics.Day(date: day, end: end, state: .ready, segments: [
            .init(start: day, end: day.addingTimeInterval(3600), kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil),
            .init(start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200), kind: .work, application: "Editor", bundleIdentifier: nil, host: nil),
            .init(start: day.addingTimeInterval(7200), end: day.addingTimeInterval(7500), kind: .other, application: "Video", bundleIdentifier: nil, host: nil),
            .init(start: day.addingTimeInterval(7500), end: day.addingTimeInterval(7800), kind: .unclassified, application: "Notes", bundleIdentifier: nil, host: nil)
        ], eventCount: 4, classifierVersions: [])
        model.applyDay(value)
        XCTAssertEqual(model.workSeconds, 3600); XCTAssertEqual(model.otherSeconds, 300)
        XCTAssertEqual(model.segments.count, 3)
        XCTAssertEqual(model.segments.first?.start, 1.0 / 24)
        XCTAssertTrue(model.segments.allSatisfy { $0.start >= 0 && $0.end <= 1 && $0.end > $0.start })
        model.openDay(); model.openSettings(); model.showClassicMenu()
        XCTAssertTrue(f.openedDay); XCTAssertEqual(f.opened.last, .settings); XCTAssertTrue(f.openedClassicMenu)
    }

    @MainActor func testRefreshCoalescesAndCloseRejectsLateAnalytics() async {
        let f = fixture()
        var requests = 0
        var continuation: CheckedContinuation<GoalongLocalAnalytics.Day, Error>?
        let model = f.model(loadDay: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.refresh(); model.refresh()
        await Task.yield()
        XCTAssertEqual(requests, 1)
        model.stopRefreshing()
        let day = f.calendar.startOfDay(for: f.now)
        let value = GoalongLocalAnalytics.Day(date: day, end: day.addingTimeInterval(86400), state: .ready,
            segments: [.init(start: day, end: day.addingTimeInterval(600), kind: .work, application: "Editor", bundleIdentifier: nil, host: nil)],
            eventCount: 2, classifierVersions: [])
        continuation?.resume(returning: value)
        await Task.yield()
        XCTAssertEqual(model.workSeconds, 0)
    }
}
#endif
