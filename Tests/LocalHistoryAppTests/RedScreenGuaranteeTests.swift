#if os(macOS)
import Ambiance
import AppKit
import BraiseCore
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI
import XCTest
@testable import LocalHistoryApp

/// Fake screens for the gamma logic: per-screen original and current tables, no CoreGraphics call.
final class FakeGammaScreens: GammaDisplayDriving {
    private(set) var online: [UInt32]
    private(set) var original: [UInt32: GammaTable] = [:]
    private(set) var current: [UInt32: GammaTable] = [:]
    /// Table reads and writes, system restores and guardian starts: what touches a screen's colors.
    private(set) var gammaCalls = 0
    private(set) var guardians = 0
    private(set) var disarmed = 0
    /// Every table written, in order.
    private(set) var written: [GammaTable] = []
    /// Stable keys (vendor-model-serial); none by default.
    var keys: [UInt32: String] = [:]
    private final class Guardian: BraiseGuardian {
        let onDisarm: () -> Void
        init(_ onDisarm: @escaping () -> Void) { self.onDisarm = onDisarm }
        func disarm() { onDisarm() }
    }
    init(_ ids: [UInt32]) { online = []; ids.forEach(plug) }
    static func ramp(_ id: UInt32) -> GammaTable {
        let values = (0..<16).map { Float($0) / 15 }
        return GammaTable(displayID: id, red: values, green: values, blue: values)
    }
    func plug(_ id: UInt32) { online.append(id); original[id] = Self.ramp(id); current[id] = Self.ramp(id) }
    func unplug(_ id: UInt32) { online.removeAll { $0 == id } }
    /// The screen comes back (wake, cable) still showing the table it had when it left, under `newID` if given.
    func comeBack(_ id: UInt32, as newID: UInt32? = nil) {
        let target = newID ?? id
        if target != id {
            original[target] = original[id].map { GammaTable(displayID: target, red: $0.red, green: $0.green, blue: $0.blue) }
            current[target] = current[id].map { GammaTable(displayID: target, red: $0.red, green: $0.green, blue: $0.blue) }
            keys[target] = keys[id]
        }
        online.append(target)
    }
    func isNormal(_ id: UInt32) -> Bool { current[id] == original[id] }
    /// Green and blue lowered on this screen, red kept.
    func isRed(_ id: UInt32) -> Bool {
        guard let now = current[id], let base = original[id] else { return false }
        return now.red.last == base.red.last && (now.blue.last ?? 1) < (base.blue.last ?? 1) - 0.1
    }
    func resetCounters() { gammaCalls = 0; guardians = 0; disarmed = 0 }

    func displays() -> [UInt32] { online }
    func read(_ display: UInt32) throws -> GammaTable {
        gammaCalls += 1
        guard online.contains(display), let table = current[display] else { throw GammaError.unsupported }
        return table
    }
    func write(_ table: GammaTable) -> Bool {
        gammaCalls += 1
        guard online.contains(table.displayID) else { return false }
        current[table.displayID] = table; written.append(table); return true
    }
    func restoreSystemColors() { gammaCalls += 1; for id in online { current[id] = original[id] } }
    func startGuardian(recoveryURL: URL) throws -> BraiseGuardian {
        gammaCalls += 1; guardians += 1
        return Guardian { [weak self] in self?.disarmed += 1 }
    }
    func stableKey(_ display: UInt32) -> String? { keys[display] }
}

final class RedScreenGuaranteeTests: XCTestCase {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-red-screen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func defaults() throws -> UserDefaults {
        let name = "red-screen-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func store(_ root: URL) -> BraiseStore {
        BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
    }
    @MainActor private func controller(_ store: BraiseStore, _ screens: FakeGammaScreens) throws -> BraiseController {
        try BraiseController(store: store, gamma: GammaController(directory: store.directory, screens: screens), runsTimers: false)
    }
    private func recoveryFiles(_ store: BraiseStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).filter { $0.hasPrefix("display-recovery") }
    }

    @MainActor func testStopRestoresEveryScreenAndClosesTheGuardian() throws {
        let store = store(try root()), screens = FakeGammaScreens([1, 2])
        let controller = try controller(store, screens); defer { controller.shutdown() }
        controller.setManual(true)
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2))
        XCTAssertEqual(screens.guardians, 1); XCTAssertEqual(recoveryFiles(store).count, 1)
        controller.emergencyOff()
        XCTAssertTrue(screens.isNormal(1)); XCTAssertTrue(screens.isNormal(2))
        XCTAssertEqual(screens.disarmed, 1); XCTAssertEqual(recoveryFiles(store), [])
        XCTAssertEqual(try store.load().mode, .off)
    }

    @MainActor func testAppQuitRestoresColorsAndKeepsTheSetting() throws {
        let store = store(try root()), screens = FakeGammaScreens([1]), defaults = try defaults()
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(store, screens) })
        runtime.setRedScreen(true); XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(runtime.redScreen.on)
        runtime.shutdown() // applicationWillTerminate
        XCTAssertTrue(screens.isNormal(1)); XCTAssertEqual(recoveryFiles(store), []); XCTAssertNil(runtime.controller)
        XCTAssertTrue(defaults.bool(forKey: BraiseRuntime.armedKey)); XCTAssertEqual(try store.load().mode, .on)
    }

    /// SIGKILL: the guardian's pipe closes, it writes the saved tables back. Then the relaunch recovers any
    /// table left behind and turns red on again from the original colors, never from the red ones.
    @MainActor func testCrashGuardianThenRelaunchComeBackToNormal() throws {
        let store = store(try root()), screens = FakeGammaScreens([1, 2])
        let crashed = try controller(store, screens)
        crashed.setManual(true); crashed.saveNow()
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2))
        let saved = try XCTUnwrap(recoveryFiles(store).first)
        // The guardian, after the crash.
        GammaController.recover(from: store.directory.appendingPathComponent(saved), screens: screens)
        XCTAssertTrue(screens.isNormal(1)); XCTAssertTrue(screens.isNormal(2)); XCTAssertEqual(recoveryFiles(store), [])

        // A crash where the guardian died too: red stays on the screens and its file stays.
        let store2 = self.store(try root()), screens2 = FakeGammaScreens([1, 2])
        let stuck = try controller(store2, screens2); stuck.setManual(true); stuck.saveNow()
        XCTAssertTrue(screens2.isRed(1)); XCTAssertEqual(recoveryFiles(store2).count, 1)
        let relaunched = try controller(store2, screens2) // recoverPending first, then mode .on again
        defer { relaunched.shutdown() }
        XCTAssertTrue(screens2.isRed(1)); XCTAssertTrue(screens2.isRed(2)); XCTAssertEqual(recoveryFiles(store2).count, 1)
        relaunched.emergencyOff()
        XCTAssertTrue(screens2.isNormal(1)); XCTAssertTrue(screens2.isNormal(2), "the relaunch saved the original tables, not the red ones")
        XCTAssertEqual(recoveryFiles(store2), [])
    }

    @MainActor func testPluggedScreenTurnsRedAndUnpluggedScreenLeavesTheOthersRed() throws {
        let store = store(try root()), screens = FakeGammaScreens([1])
        let controller = try controller(store, screens); defer { controller.shutdown() }
        controller.setManual(true); XCTAssertTrue(screens.isRed(1))
        screens.plug(2); controller.handleSystemChange()
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2), "the new screen is red too")
        XCTAssertEqual(controller.displayCount, 2)
        let saved = try JSONDecoder().decode([GammaTable].self, from: Data(contentsOf: store.directory.appendingPathComponent(try XCTUnwrap(recoveryFiles(store).first))))
        XCTAssertEqual(Set(saved.map(\.displayID)), [1, 2]); let plugged = try XCTUnwrap(saved.first { $0.displayID == 2 }); XCTAssertEqual(plugged.unsure, true, "read while red: origin unsure")
        XCTAssertEqual([plugged.red, plugged.green, plugged.blue], { let r = FakeGammaScreens.ramp(2); return [r.red, r.green, r.blue] }())
        screens.unplug(1); controller.handleSystemChange()
        XCTAssertTrue(screens.isRed(2)); XCTAssertEqual(controller.displayCount, 1)
        controller.emergencyOff(); XCTAssertTrue(screens.isNormal(2))
        screens.plug(1); XCTAssertTrue(screens.isNormal(1))
    }

    @MainActor func testRedOffMakesNoGammaCallWhenScreensChange() throws {
        let store = store(try root()), screens = FakeGammaScreens([1])
        let controller = try controller(store, screens); defer { controller.shutdown() }
        XCTAssertEqual(screens.gammaCalls, 0, "a controller with red off reads no table")
        screens.plug(2); controller.handleSystemChange(); screens.unplug(1); controller.handleSystemChange()
        XCTAssertEqual(screens.gammaCalls, 0)
        controller.setManual(true); controller.emergencyOff(); screens.resetCounters()
        screens.plug(3); controller.handleSystemChange(); controller.evaluate()
        XCTAssertEqual(screens.gammaCalls, 0); XCTAssertEqual(screens.guardians, 0)
        XCTAssertTrue(screens.isNormal(2)); XCTAssertTrue(screens.isNormal(3))
    }

    @MainActor func testOnOffAndIntensitySurviveARestart() throws {
        let store = store(try root()), screens = FakeGammaScreens([1]), defaults = try defaults()
        func runtime() -> BraiseRuntime {
            BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(store, screens) })
        }
        let first = runtime(); first.start(); XCTAssertNil(first.controller)
        first.setRedScreen(true); first.setRedScreenIntensity(0.4); first.shutdown()
        XCTAssertTrue(screens.isNormal(1))

        let second = runtime(); second.start()
        XCTAssertTrue(second.redScreen.on); XCTAssertEqual(second.redScreen.intensity, 0.4, accuracy: 0.0001)
        XCTAssertTrue(screens.isRed(1)); XCTAssertEqual(second.controller?.preferences.intensity ?? 0, 0.4, accuracy: 0.0001)
        second.setRedScreen(false); XCTAssertTrue(screens.isNormal(1)); second.shutdown()

        let third = runtime(); third.start(); defer { third.shutdown() }
        XCTAssertNil(third.controller, "red off: nothing starts at launch"); XCTAssertFalse(third.redScreen.on)
        XCTAssertEqual(third.redScreen.intensity, 0.4, accuracy: 0.0001, "the slider keeps its place")
        XCTAssertEqual(third.factoryCalls, 0)
    }

    @MainActor func testNeverUsedCostsNothing() throws {
        let defaults = try defaults()
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: {
            XCTFail("no controller while red was never used"); throw GoalongFocusError.storageFailed
        })
        runtime.start(); runtime.restoreColors()
        let status = try JSONSerialization.jsonObject(with: runtime.handle(.init(command: "braise status"))) as? [String: Any]
        XCTAssertEqual(status?["enabled"] as? Bool, false)
        XCTAssertEqual(try runtime.handle(.init(command: "braise probe")), Data("[]".utf8))
        let menu = RedScreenMenu(control: runtime, onOpenSettings: {})
        menu.refresh(runtime.redScreen)
        XCTAssertEqual(menu.toggleItem.state, .off); XCTAssertFalse(menu.restoreItem.isEnabled)
        runtime.shutdown()
        XCTAssertNil(runtime.controller); XCTAssertEqual(runtime.factoryCalls, 0)
        XCTAssertNil(defaults.object(forKey: BraiseRuntime.armedKey))
    }

    @MainActor func testLegacyEnabledModuleIsMigratedOnce() throws {
        let store = store(try root()), screens = FakeGammaScreens([1]), defaults = try defaults()
        defaults.set(true, forKey: BraiseRuntime.legacyModuleKey)
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(store, screens) })
        runtime.start(); defer { runtime.shutdown() }
        XCTAssertNotNil(runtime.controller); XCTAssertNil(defaults.object(forKey: BraiseRuntime.legacyModuleKey))
        XCTAssertTrue(screens.isNormal(1), "mode off: an old enabled module does not turn red on")
    }

    @MainActor func testMenuItemsAndSliderActLive() throws {
        let store = store(try root()), screens = FakeGammaScreens([1, 2]), defaults = try defaults()
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(store, screens) })
        defer { runtime.shutdown() }
        var opened = 0
        let menu = RedScreenMenu(control: runtime, onOpenSettings: { opened += 1 })
        XCTAssertEqual(menu.toggleItem.title, "Écran rouge")
        XCTAssertEqual(menu.slider.subviews.compactMap { $0 as? NSSlider }.first?.accessibilityLabel(), "Intensité de l’écran rouge")
        func click(_ item: NSMenuItem) { _ = (item.target as? NSObject)?.perform(item.action, with: item) }
        click(menu.toggleItem)
        XCTAssertTrue(screens.isRed(1)); XCTAssertTrue(screens.isRed(2)); XCTAssertEqual(menu.toggleItem.state, .on)
        XCTAssertTrue(menu.restoreItem.isEnabled); XCTAssertEqual(menu.restoreItem.keyEquivalentModifierMask, [.control, .option, .command])
        let strong = try XCTUnwrap(screens.current[1]?.green.last)
        menu.slider.simulateDrag(to: 0.3) // live while dragging
        XCTAssertEqual(runtime.controller?.preferences.intensity ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(screens.current[1]?.green.last), strong, "lower intensity: more green, at once")
        // Digits only: the menu may store its own space before « % ».
        XCTAssertEqual(menu.intensityItem.submenu?.items.map { $0.title.filter(\.isNumber) }, ["25", "50", "75", "100"])
        click(try XCTUnwrap(menu.intensityItem.submenu?.items[1]))
        XCTAssertEqual(runtime.redScreen.intensity, 0.5, accuracy: 0.0001); XCTAssertEqual(menu.slider.value, 0.5, accuracy: 0.0001)
        click(menu.restoreItem)
        XCTAssertTrue(screens.isNormal(1)); XCTAssertTrue(screens.isNormal(2)); XCTAssertEqual(menu.toggleItem.state, .off)
        click(menu.settingsItem); XCTAssertEqual(opened, 1)
    }

    @MainActor func testPanelLineDrivesTheRedScreenLive() throws {
        let store = store(try root()), screens = FakeGammaScreens([1]), defaults = try defaults()
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.controller(store, screens) })
        defer { runtime.shutdown() }
        let root = try root()
        var opened: [DashboardSection] = []
        let model = MenuBarPanelModel(state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { opened.append($0) }, onOpenDay: {}, onShowClassicMenu: {},
            redScreen: runtime)
        XCTAssertTrue(model.hasRedScreen); XCTAssertFalse(model.redScreen.on); XCTAssertNil(runtime.controller)
        model.setRedScreen(true); XCTAssertTrue(model.redScreen.on); XCTAssertTrue(screens.isRed(1))
        model.setRedScreenIntensity(0.6); XCTAssertEqual(model.redScreen.intensity, 0.6, accuracy: 0.0001)
        model.setRedScreenIntensity(.nan); XCTAssertEqual(model.redScreen.intensity, 0.6, accuracy: 0.0001)
        model.setRedScreen(false); XCTAssertFalse(model.redScreen.on); XCTAssertTrue(screens.isNormal(1))
        model.openRedScreenSettings(); XCTAssertEqual(opened, [.braise])
    }

    func testRealDriverIsRefusedUnderTestsOutsideCI() {
        XCTAssertTrue(CoreGraphicsDisplays.refusesUnderTests(environment: [:], xctestLoaded: true))
        XCTAssertTrue(CoreGraphicsDisplays.refusesUnderTests(environment: ["XCTestConfigurationFilePath": "/x", "GITHUB_ACTIONS": "false"], xctestLoaded: false))
        XCTAssertFalse(CoreGraphicsDisplays.refusesUnderTests(environment: ["GITHUB_ACTIONS": "true"], xctestLoaded: true))
        XCTAssertFalse(CoreGraphicsDisplays.refusesUnderTests(environment: [:], xctestLoaded: false), "the app itself")
    }

    /// Building the real driver here fails the test (GoalongHeadlessTestSupport) and leaves it inert.
    func testBuildingTheRealDriverFailsTheTestOutsideCI() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true" else {
            throw XCTSkip("On CI the real driver may be built; this test checks the local refusal")
        }
        var driver: CoreGraphicsDisplays?
        XCTExpectFailure("the headless hook fails a test that builds the real gamma driver") { driver = CoreGraphicsDisplays() }
        XCTAssertEqual(driver?.displays(), [])
        XCTAssertThrowsError(try driver?.read(1))
        XCTAssertFalse(driver?.write(FakeGammaScreens.ramp(1)) ?? true)
        XCTAssertThrowsError(try driver?.startGuardian(recoveryURL: URL(fileURLWithPath: "/private/tmp/never")))
    }
}
#endif
