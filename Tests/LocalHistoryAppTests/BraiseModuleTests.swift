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
    private func defaults() throws -> UserDefaults {
        let name = "braise-runtime-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testNavigationAndDefaultOff() throws {
        XCTAssertFalse(try modules().isEnabled(.braise))
        XCTAssertFalse(DashboardSection.sidebarSections(modules: []).contains(.braise))
        // T-048 B2: the red screen lives in Garde-fous (the .blocking entry), not in Modules nor as its own entry.
        XCTAssertFalse(DashboardSection.sidebarSections(modules: [.braise]).contains(.braise))
        XCTAssertEqual(DashboardSection.sidebarSections(modules: [], showing: .braise).suffix(2), [.blocking, .settings])
        XCTAssertEqual(DashboardSection.blocking.title, "Garde-fous")
        XCTAssertFalse(GoalongModule.listed.contains(.braise))
        XCTAssertEqual(GoalongModule.braise.title, "Écran rouge")
    }
    @MainActor func testNeverUsedStartsNothingAndAFailedStartThrows() throws {
        var creations = 0
        let runtime = BraiseRuntime(registersShortcut: false, defaults: try defaults(), factory: { creations += 1; throw GoalongFocusError.storageFailed })
        runtime.start()
        XCTAssertNil(runtime.controller); XCTAssertEqual(creations, 0)
        _ = try runtime.handle(.init(command: "braise status")); _ = try runtime.handle(.init(command: "braise probe"))
        XCTAssertEqual(creations, 0)
        XCTAssertThrowsError(try runtime.handle(.init(command: "braise on"))); XCTAssertEqual(creations, 1)
        XCTAssertNotNil(runtime.error)
        runtime.shutdown(); XCTAssertEqual(creations, 1)
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
    func testMalformedOversizedAndSymlinkLegacySettingsAreNotImported() throws {
        let fm = FileManager.default
        let root = try root(), legacy = root.appendingPathComponent("legacy.json")
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: legacy)
        var imported = Preferences(); imported.mode = .on
        let real = root.appendingPathComponent("real.json"); try JSONEncoder().encode(imported).write(to: real)
        for write in [{ try Data("bad".utf8).write(to: legacy) }, { try Data(repeating: 32, count: 65_537).write(to: legacy) },
                      { try fm.createSymbolicLink(at: legacy, withDestinationURL: real) }] as [() throws -> Void] {
            try? fm.removeItem(at: legacy); try? fm.removeItem(at: store.settingsURL)
            try write()
            let loaded = try store.loadRecovering()
            XCTAssertEqual(loaded.preferences.mode, .off); XCTAssertNotNil(loaded.notice)
            XCTAssertTrue(fm.fileExists(atPath: store.settingsURL.path))
            XCTAssertNotNil(try? fm.attributesOfItem(atPath: legacy.path), "The legacy file is never moved")
        }
    }
    func testDamagedSettingsAreKeptAsideAndBraiseStartsWithDefaults() throws {
        let fm = FileManager.default
        let root = try root()
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        _ = try store.load()
        try Data("{\"mode\":\"auto\",\"rules\":[".utf8).write(to: store.settingsURL)
        let loaded = try store.loadRecovering()
        XCTAssertEqual(loaded.preferences.mode, .off)
        XCTAssertTrue(loaded.notice?.contains(store.directory.path) == true)
        let kept = try fm.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasPrefix("settings.damaged-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: store.directory.appendingPathComponent(kept[0]), encoding: .utf8), "{\"mode\":\"auto\",\"rules\":[")
        XCTAssertNil(try store.loadRecovering().notice)
        // An older file without some fields still opens as is.
        try Data("{\"mode\":\"auto\",\"intensity\":0.5}".utf8).write(to: store.settingsURL)
        let older = try store.loadRecovering()
        XCTAssertNil(older.notice); XCTAssertEqual(older.preferences.mode, .auto); XCTAssertEqual(older.preferences.intensity, 0.5)
    }
    @MainActor func testModesPauseEmergencyDisableAndCLIStayLocal() throws {
        let root = try root(), gamma = BraiseTestGamma(), defaults = try defaults()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try BraiseController(store: store, gamma: gamma, runsTimers: false, clock: { now }) })
        runtime.start(); XCTAssertNil(runtime.controller)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["enable"]))
        let controller = try XCTUnwrap(runtime.controller)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["on"])); XCTAssertTrue(controller.active)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["intensity", "65"])); XCTAssertEqual(controller.preferences.intensity, 0.65)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["brightness", "35"])); XCTAssertEqual(controller.preferences.brightness, 0.35)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["pause"])); XCTAssertFalse(controller.active)
        now = now.addingTimeInterval(15 * 60); controller.evaluate(); XCTAssertTrue(controller.active)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "add", "2,3", "21:30", "07:00"]))
        let count = controller.ranges.program.ranges.count
        let added = try XCTUnwrap(controller.ranges.program.ranges.last)
        XCTAssertEqual(added.weekdays, [1, 2], "Braise days (Monday = 2) become ISO days (Monday = 1)")
        XCTAssertEqual(added.startMinute, 21 * 60 + 30); XCTAssertEqual(added.endMinute, 7 * 60)
        let id = added.id.uuidString
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "disable", id])); XCTAssertTrue(controller.ranges.disabled.contains(added.id))
        _ = try runtime.handle(GoalongBraiseCLI.parse(["schedule", "remove", id])); XCTAssertEqual(controller.ranges.program.ranges.count, count - 1)
        var opened = false; runtime.onOpen = { opened = true }
        _ = try runtime.handle(GoalongBraiseCLI.parse(["show"])); XCTAssertTrue(opened)
        controller.emergencyOff(); XCTAssertFalse(controller.active); XCTAssertEqual(controller.preferences.mode, .off)
        _ = try runtime.handle(GoalongBraiseCLI.parse(["quit"])); XCTAssertNil(runtime.controller)
        XCTAssertFalse(defaults.bool(forKey: BraiseRuntime.armedKey)); XCTAssertGreaterThanOrEqual(gamma.restores, 2)
        let changes = gamma.changes.count; controller.evaluate(); XCTAssertEqual(gamma.changes.count, changes)
        // « on » needs no module: it starts the red screen again.
        _ = try runtime.handle(GoalongBraiseCLI.parse(["on"])); XCTAssertEqual(runtime.controller?.active, true)
        XCTAssertTrue(defaults.bool(forKey: BraiseRuntime.armedKey))
        runtime.shutdown(); XCTAssertNil(runtime.controller)
    }
    @MainActor func testDefaultCalendarFollowsATimeZoneChangeWhileRunning() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let root = try root(), gamma = BraiseTestGamma()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T20:00:00Z")) // 22:00 Paris, 16:00 New York
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: gamma, runsTimers: false, clock: { now })
        defer { controller.shutdown() }
        try controller.saveRange(BlockProgramRange(weekdays: Set(1...7), startMinute: 21 * 60, endMinute: 7 * 60, lock: nil), intensity: 1)
        controller.setFollows(true)
        XCTAssertTrue(controller.active)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        controller.evaluate()
        XCTAssertFalse(controller.active)
    }
    @MainActor func testUnsupportedDisplayFailsClosedAndSettingsArePreserved() throws {
        let root = try root(), gamma = BraiseTestGamma(); gamma.reject = true
        let store = BraiseStore(directory: root.appendingPathComponent("Braise"), legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: gamma, runsTimers: false)
        defer { controller.shutdown() }
        controller.setManual(true)
        XCTAssertFalse(controller.active); XCTAssertEqual(controller.preferences.mode, .off)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(try store.load().mode, .off)
        XCTAssertThrowsError(try controller.persistCommand())
    }
    /// T-045 BRS-01: on the macOS 15 runner « Braise n’a pas pu démarrer » on first enable and the folder was
    /// never created. The production folder URL ends with a slash; macOS 15 answers an absent folder without it.
    func testSymlinkGuardComparesPathsNotTrailingSlashes() throws {
        let wanted = URL(fileURLWithPath: "/private/tmp/goalong-braise-absent/Braise", isDirectory: true)
        XCTAssertTrue(BraiseStore.isFreeOfSymlinks(wanted, resolvedBy: { URL(fileURLWithPath: $0.path, isDirectory: false) }))
        XCTAssertFalse(BraiseStore.isFreeOfSymlinks(wanted, resolvedBy: { _ in URL(fileURLWithPath: "/private/tmp/elsewhere", isDirectory: true) }))
        let root = try root(), real = root.appendingPathComponent("real", isDirectory: true)
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        XCTAssertEqual(try store.load().mode, .off)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsURL.path))
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try BraiseStore(directory: link, legacySettings: root.appendingPathComponent("missing")).load())
    }
    /// T-045 review #195: an absent folder under a symlinked parent passed the first check; it is refused
    /// once created, so no settings file is written through the link.
    func testAbsentFolderUnderSymlinkedParentIsRefusedAndNothingIsWrittenThroughIt() throws {
        let root = try root(), real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = BraiseStore(directory: link.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("Braise/settings.json").path))
    }
    @MainActor func testStartFailureIsJournaledWithoutTextAndRetryRecovers() throws {
        let root = try root(), name = "braise-diagnostics-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let journal = SupportDiagnostics(root: root.appendingPathComponent("journal"), defaults: defaults)
        journal.start(); defer { journal.stop() }
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        var fails = true, attempts = 0
        defaults.set(true, forKey: BraiseRuntime.armedKey)
        let runtime = BraiseRuntime(registersShortcut: false, diagnostics: journal, defaults: defaults, factory: {
            attempts += 1
            if fails { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: store.directory.path]) }
            return try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false)
        })
        runtime.start(); defer { runtime.shutdown() }
        XCTAssertNil(runtime.controller); XCTAssertNotNil(runtime.error)
        let failure = try XCTUnwrap(journal.snapshot().records.first { $0.event == .operationFailed })
        XCTAssertEqual(failure.values["errorCode"], .count(CocoaError.fileWriteNoPermission.rawValue))
        let line = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
        XCTAssertFalse(line.contains(root.lastPathComponent)); XCTAssertFalse(line.contains("rouge n"))
        fails = false; runtime.retry()
        XCTAssertNotNil(runtime.controller); XCTAssertNil(runtime.error); XCTAssertEqual(attempts, 2)
    }
    func testUntrustedRecoveryTablesCannotBeWritten() {
        XCTAssertFalse(GammaTable(displayID: 0, red: [.nan, 1], green: [0, 1], blue: [0, 1]).isValid)
        XCTAssertFalse(GammaTable(displayID: 0, red: [0, 1], green: [0], blue: [0, 1]).isValid)
        XCTAssertFalse(GammaTable(displayID: 0, red: [0, 2], green: [0, 1], blue: [0, 1]).isValid)
    }
}
#endif
