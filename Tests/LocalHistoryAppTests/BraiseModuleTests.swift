#if os(macOS)
import BraiseCore
import Foundation
import LocalHistoryQueryCLI
import XCTest
@testable import LocalHistoryApp

final class BraiseTestGamma: BraiseGammaDriving {
    var onError: ((String) -> Void)?
    var onDisplays: ((Int) -> Void)?
    var changes: [Bool] = []
    var restores = 0
    var reject = false
    func set(active: Bool, intensity: Double, brightness: Double, animated: Bool) {
        changes.append(active)
        if reject, active { onError?("Écran incompatible.") }
    }
    func restore() { restores += 1 }
    func checkAfterSystemChange() {}
}

final class BraiseModuleTests: XCTestCase {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-braise-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func modules() throws -> GoalongModuleStore {
        let name = "braise-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return GoalongModuleStore(defaults: defaults)
    }
    func testNavigationAndDefaultOff() throws {
        XCTAssertFalse(try modules().isEnabled(.braise))
        XCTAssertFalse(DashboardSection.sidebarSections(modules: []).contains(.braise))
        XCTAssertEqual(DashboardSection.sidebarSections(modules: [.braise]).suffix(2), [.braise, .settings])
    }
    @MainActor func testOffCreatesNothingAndForgedEnableDoesNotStartFactory() throws {
        var creations = 0
        let runtime = BraiseRuntime(presentsMenu: false, factory: { creations += 1; throw GoalongFocusError.storageFailed })
        let modules = try modules(); runtime.start(modules: modules)
        XCTAssertNil(runtime.controller); XCTAssertEqual(creations, 0)
        _ = try runtime.handle(.init(command: "braise status"))
        XCTAssertThrowsError(try runtime.handle(.init(command: "braise on")))
        XCTAssertThrowsError(try runtime.handle(.init(command: "braise enable", options: ["x": "y"])))
        runtime.shutdown(); XCTAssertEqual(creations, 0)
    }
    func testLegacySettingsImportedOnceReadOnlyAndOwnerPermissions() throws {
        let root = try root(), legacy = root.appendingPathComponent("legacy.json")
        var preferences = Preferences(); preferences.mode = .auto; preferences.intensity = 0.7
        preferences.brightness = 0.4; preferences.pauseUntil = Date(timeIntervalSince1970: 1_790_000_000)
        preferences.rules = [ScheduleRule(weekdays: [2, 4, 6])]
        let bytes = try JSONEncoder().encode(preferences); try bytes.write(to: legacy)
        let store = BraiseStore(directory: root.appendingPathComponent("GoalongBraise"), legacySettings: legacy)
        XCTAssertEqual(try store.load(), preferences)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        try Data("invalid".utf8).write(to: legacy)
        XCTAssertEqual(try store.load(), preferences)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.settingsURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testMalformedOversizedAndSymlinkSettingsAreRefused() throws {
        let root = try root(), legacy = root.appendingPathComponent("legacy.json")
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: legacy)
        try Data("bad".utf8).write(to: legacy); XCTAssertThrowsError(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
        try Data(repeating: 32, count: 65_537).write(to: legacy); XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: legacy)
        let real = root.appendingPathComponent("real.json"); try JSONEncoder().encode(Preferences()).write(to: real)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: real)
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }
    @MainActor func testModesPauseEmergencyDisableAndCLIStayLocal() throws {
        let root = try root(), gamma = BraiseTestGamma(), modules = try modules()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let runtime = BraiseRuntime(presentsMenu: false, factory: { try BraiseController(store: store, gamma: gamma, runsTimers: false, clock: { now }) })
        runtime.start(modules: modules)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["enable"]))
        let controller = try XCTUnwrap(runtime.controller)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["on"])); XCTAssertTrue(controller.active)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["intensity", "65"])); XCTAssertEqual(controller.preferences.intensity, 0.65)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["brightness", "35"])); XCTAssertEqual(controller.preferences.brightness, 0.35)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["pause"])); XCTAssertFalse(controller.active)
        now = now.addingTimeInterval(15 * 60); controller.evaluate(); XCTAssertTrue(controller.active)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "add", "2,3", "21:30", "07:00"]))
        let id = try XCTUnwrap(controller.preferences.rules.last?.id).uuidString
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "disable", id])); XCTAssertFalse(controller.preferences.rules.last!.enabled)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "remove", id])); XCTAssertEqual(controller.preferences.rules.count, 1)
        var opened = false; runtime.onOpen = { opened = true }
        _ = try runtime.handle(GoalongBraiseCLI.parse(["show"])); XCTAssertTrue(opened)
        controller.emergencyOff(); XCTAssertFalse(controller.active); XCTAssertEqual(controller.preferences.mode, .off)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["quit"])); XCTAssertNil(runtime.controller)
        XCTAssertFalse(modules.isEnabled(.braise)); XCTAssertGreaterThanOrEqual(gamma.restores, 2)
        let changes = gamma.changes.count; controller.evaluate(); XCTAssertEqual(gamma.changes.count, changes)
        XCTAssertThrowsError(try runtime.handle(GoalongBraiseCLI.parse(["on"])))
    }
    @MainActor func testUnsupportedDisplayFailsClosedAndSettingsArePreserved() throws {
        let root = try root(), gamma = BraiseTestGamma(); gamma.reject = true
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: gamma, runsTimers: false)
        defer { controller.shutdown() }
        controller.setMode(.on)
        XCTAssertFalse(controller.active); XCTAssertEqual(controller.preferences.mode, .off)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(try store.load().mode, .off)
        XCTAssertThrowsError(try controller.persistCommand())
    }
    func testUntrustedRecoveryTablesCannotBeWritten() {
        XCTAssertFalse(GammaTable(displayID: 0, red: [.nan, 1], green: [0, 1], blue: [0, 1]).isValid)
        XCTAssertFalse(GammaTable(displayID: 0, red: [0, 1], green: [0], blue: [0, 1]).isValid)
        XCTAssertFalse(GammaTable(displayID: 0, red: [0, 2], green: [0, 1], blue: [0, 1]).isValid)
    }
}
#endif
