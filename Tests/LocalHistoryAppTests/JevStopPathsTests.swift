#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 B1 correction 9: every free command that cuts Jev goes through the stop of what runs. Pure: no alert, no real
/// controller, no window. Paths that live in AppKit/SwiftUI actions (the page's stop, the pause, the key, the module
/// switch) are still checked in their source: they need the app or a view to run.
@MainActor final class JevStopPathsTests: XCTestCase {
    private func focus() throws -> ConcentrationController { try focusWithStore().1 }
    private func focusWithStore() throws -> (FocusStore, ConcentrationController) {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-jev-paths-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try store.saveSettings(settings)
        let now = Date(timeIntervalSince1970: 1_791_716_400)
        return (store, try ConcentrationController(store: store, clock: { now }))
    }

    /// `session stop` (CLI) and every caller that did not pass the stop are refused while the surveillance is protected.
    func testControllerRefusesAnUnconfirmedStopOfAProtectedSession() throws {
        let controller = try focus()
        var lock = BlockLock.typing
        controller.surveillanceLock = { _ in lock }
        try controller.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertThrowsError(try controller.stopSession()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertNotNil(controller.currentSession)
        try controller.stopSession(surveillanceConfirmed: true)
        XCTAssertNil(controller.currentSession)
        lock = .free
        try controller.startSession(intent: "Lire", mode: FocusMode(minutes: 5))
        XCTAssertNoThrow(try controller.stopSession(), "a free surveillance stops as before")
    }

    /// Point (d) and the CLI: with the module on, a protected session refuses `session stop`, deleting the data and the
    /// module switch; once the switch passed the stop, the module goes off.
    func testTheCLIDeletingAndTheModuleSwitchDoNotCutAProtectedSession() throws {
        let (focusStore, controller) = try focusWithStore()
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let modules = GoalongModuleStore(defaults: defaults)
        let runtime = ConcentrationRuntime(storeFactory: { focusStore }, factory: { _ in controller },
                                           blockingProvider: { nil }, presentsPanels: false)
        runtime.start(modules: modules)
        controller.surveillanceLock = { _ in .password }
        try controller.startSession(intent: "Écrire", mode: FocusMode(minutes: 5))
        XCTAssertThrowsError(try runtime.handle(.init(command: "session stop")))
        XCTAssertThrowsError(try runtime.deleteData())
        modules.setEnabled(.concentration, false)
        XCTAssertTrue(modules.isEnabled(.concentration)); XCTAssertNotNil(runtime.controller?.currentSession)
        runtime.surveillanceOffConfirmed = true
        modules.setEnabled(.concentration, false)
        XCTAssertFalse(modules.isEnabled(.concentration)); XCTAssertNil(runtime.controller)
    }

    /// Point (a): quitting asks the stop of what runs; « Verrouillé » refuses and says the window can be closed.
    func testQuittingAsksTheStopOfTheRunningSurveillance() throws {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-jev-quit-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
        XCTAssertTrue(consents.set(.jevMonitoring, enabled: true, surface: .settings))
        let d = defaults(), store = JevSurveillanceStore(defaults: d), now = Date()
        let monitor = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: d), surveillance: store, consents: consents,
                                 sessionProvider: { nil }, blocksProvider: { [] }, legacySettings: { JevInterventionSettings() },
                                 inbox: JevIngress(notificationCenter: NotificationCenter()), loadLocalSettings: false)
        XCTAssertEqual(JevStopGate.quitStep(JevStopGate.currentStep(monitor: monitor)), .allow, "nothing runs: quit as before")
        store.mark(own(.password, now: now), now: now, alive: JevRunningSessions())
        XCTAssertEqual(JevStopGate.quitStep(JevStopGate.currentStep(monitor: monitor)), .password)
        store.mark(own(.locked, now: now), now: now, alive: JevRunningSessions())
        XCTAssertEqual(JevStopGate.quitStep(JevStopGate.currentStep(monitor: monitor)), .refused(JevStopGate.quitLockedText))
        XCTAssertTrue(JevStopGate.quitLockedText.contains("fermer la fenêtre"))
        XCTAssertTrue(consents.set(.jevMonitoring, enabled: false, surface: .settings))
        XCTAssertEqual(JevStopGate.quitStep(JevStopGate.currentStep(monitor: monitor)), .allow, "Jev off: nothing to cut")
    }

    /// T-050 B2a: quitting during a « lists + Surveillance » rule in « Mot de passe » asks the password once. The
    /// lists' prompt took it: Jev's own step is then already met; « Verrouillé » still refuses.
    func testQuitAsksThePasswordOnceWhenTheListsTookIt() {
        XCTAssertEqual(JevStopGate.quitStep(.password, passwordGiven: true), .allow)
        XCTAssertEqual(JevStopGate.quitStep(.typing("abc"), passwordGiven: true), .allow)
        XCTAssertEqual(JevStopGate.quitStep(.password), .password, "no password given yet: Jev asks it")
        XCTAssertEqual(JevStopGate.quitStep(.refused(JevStopGate.lockedText), passwordGiven: true),
                       .refused(JevStopGate.quitLockedText))
    }

    /// Point (b): a red-screen-only session with « Mot de passe » has « Arrêter », which ends it only once its stop passed.
    func testAProtectedOwnSessionStopsThroughItsStop() {
        let store = JevSurveillanceStore(defaults: defaults()), now = Date()
        let mark = own(.password, now: now)
        store.mark(mark, now: now, alive: JevRunningSessions())
        XCTAssertTrue(BlocagesWatchLive.canStop(.password)); XCTAssertFalse(BlocagesWatchLive.canStop(.locked))
        var asked: [JevStopGate.Step] = []
        BlocagesWatchLive.stop(mark, store: store, now: now, jevEnabled: true) { asked.append($0); return false }
        XCTAssertEqual(asked, [.password]); XCTAssertNotNil(store.runningOwn(now: now), "refused: it keeps running")
        BlocagesWatchLive.stop(mark, store: store, now: now, jevEnabled: true) { _ in true }
        XCTAssertNil(store.runningOwn(now: now.addingTimeInterval(1)))
        let locked = own(.locked, now: now)
        store.mark(locked, now: now, alive: JevRunningSessions())
        BlocagesWatchLive.stop(locked, store: store, now: now, jevEnabled: true) { _ in XCTFail("never asked"); return true }
        XCTAssertNotNil(store.runningOwn(now: now))
    }

    /// Point (c): turning Blocage off asks only the stop of the blocks already started.
    func testOnlyStartedBlocksAskTheirStop() {
        let store = JevSurveillanceStore(defaults: defaults()), now = Date(), id = UUID()
        store.mark(JevSessionMark(id: id, kind: .block, on: true, lock: .password, settings: JevInterventionSettings()),
                   now: now, alive: JevRunningSessions(blocks: [id]))
        func block(startingIn seconds: TimeInterval) -> BlockingActiveBlock {
            BlockingActiveBlock(id: id, listIDs: [], start: now.addingTimeInterval(seconds), end: now.addingTimeInterval(3_600),
                                lock: .password, origin: .manual)
        }
        XCTAssertEqual(JevStopGate.blockStep(store: store, blocks: [block(startingIn: 600)], now: now, jevEnabled: true), .allow)
        XCTAssertEqual(JevStopGate.blockStep(store: store, blocks: [block(startingIn: -60)], now: now, jevEnabled: true), .password)
    }

    /// Point (e): a recording pause set before a protected surveillance began is lifted when it begins; a pause made
    /// through the stop while it runs, or found at launch, stays.
    func testAPauseSetBeforeAProtectedSurveillanceEndsWhenItBegins() {
        XCTAssertTrue(JevStopGate.liftsManualPause(paused: true, step: .password, wasProtected: false))
        XCTAssertTrue(JevStopGate.liftsManualPause(paused: true, step: .refused(JevStopGate.lockedText), wasProtected: false))
        XCTAssertFalse(JevStopGate.liftsManualPause(paused: true, step: .allow, wasProtected: false), "« Libre » or nothing runs")
        XCTAssertFalse(JevStopGate.liftsManualPause(paused: false, step: .password, wasProtected: false), "not paused")
        XCTAssertFalse(JevStopGate.liftsManualPause(paused: true, step: .password, wasProtected: true), "paused through the stop")
        XCTAssertFalse(JevStopGate.liftsManualPause(paused: true, step: .password, wasProtected: nil), "first look after launch")
    }

    func testConcentrationStopAsksTheSessionStop() throws {
        let page = try source("Concentration/ConcentrationPage.swift")
        XCTAssertTrue(page.contains("guard JevStopGate.confirm(action: \"Arrêter la séance\", step: JevStopGate.focusStep()) else { return }"))
        XCTAssertTrue(page.contains("act { try controller.stopSession(surveillanceConfirmed: true) }"))
    }

    /// Correction 1: the menu, the panel, the dashboard and ⌘P all pause through `toggleManualPause`, gated once.
    func testEveryManualPauseGoesThroughTheStop() throws {
        let delegate = try source("AppDelegate.swift")
        let pause = try XCTUnwrap(delegate.range(of: "func toggleManualPause()"))
        let body = String(delegate[pause.lowerBound...].prefix(2_500))
        let gate = try XCTUnwrap(body.range(of: "JevStopGate.confirm(action: \"Suspendre l’enregistrement\")"))
        let paused = try XCTUnwrap(body.range(of: "continuityPreferences.manuallyPaused = true"))
        XCTAssertLessThan(gate.lowerBound, paused.lowerBound, "asked before anything pauses")
        let menu = try source("MenuBarController.swift")
        XCTAssertFalse(menu.contains("JevStopGate.confirm(action: \"Mettre en pause\")"), "asked once, not twice")
        XCTAssertTrue(menu.contains("togglePause()"))
    }

    /// Correction 3: removing or replacing the key, and turning the local history consent off.
    func testKeyAndConsentAskTheStop() throws {
        let sheet = try source("JevConnectionSheet.swift")
        XCTAssertTrue(sheet.contains("guard JevStopGate.confirm(action: \"Supprimer la clé\") else { return }"))
        XCTAssertTrue(sheet.contains("if monitor.hasKey, !JevStopGate.confirm(action: \"Remplacer la clé\") { return }"))
        XCTAssertTrue(try source("SourceActivation.swift")
            .contains("capability != .localComputerHistory || JevStopGate.confirm(action: \"Désactiver l’enregistrement\")"))
    }

    func testTurningAModuleOffAsksItsSessionsStop() throws {
        let settings = try source("GoalongModulesSettings.swift")
        XCTAssertTrue(settings.contains("case .concentration: return JevStopGate.focusStep()"))
        XCTAssertTrue(settings.contains("case .blocking: return JevStopGate.blockStep()"))
        XCTAssertTrue(settings.contains("JevStopGate.confirm(action: \"Désactiver \\(module.title)\", step: stop)"))
    }

    func testTheMessagesSayTheWayOut() {
        XCTAssertTrue(JevStopGate.noBlockingText.contains("Réglages › Modules"))
        XCTAssertFalse(JevStopGate.lockedText.contains("avant sa fin"))
        XCTAssertEqual(JevStopGate.step(lock: .free, jevEnabled: true), .allow)
        XCTAssertEqual(JevStopGate.step(lock: .password, jevEnabled: true), .password)
        XCTAssertEqual(JevStopGate.step(lock: .password, jevEnabled: false), .allow)
    }

    private func defaults() -> UserDefaults {
        let name = "jev-paths-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func own(_ lock: BlockLock, now: Date) -> JevSessionMark {
        JevSessionMark(id: UUID(), kind: .own, on: true, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600),
                       lock: lock, settings: JevInterventionSettings())
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
