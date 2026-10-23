#if os(macOS)
import Ambiance
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// An unreadable config.json must never record with default exclusions, and must never
/// be overwritten silently.
final class ConfigManagerFailClosedTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("config.json", isDirectory: false) }
    private let broken = Data("{\"excludedDomains\": [\"private.example\"],}".utf8)

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/private/tmp/config-fail-closed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func manager() -> ConfigManager { ConfigManager(fileURL: file, prepareStorage: {}) }

    private func userConfig() -> RecorderConfig {
        var config = RecorderConfig.default
        config.excludedDomains = ["private.example"]
        return config.validated()
    }

    private func damagedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.damaged-") }
    }

    func testBrokenFileAtLaunchPausesRecordingRefusesSavesAndKeepsTheFile() throws {
        try broken.write(to: file)
        let manager = manager()

        XCTAssertTrue(manager.isFailClosed)
        XCTAssertEqual(manager.statusNotice, ConfigManager.failClosedNotice)
        // The central recording gate stays closed while the config is unreadable.
        let state = CaptureState(isGloballyPaused: { manager.isFailClosed })
        XCTAssertFalse(state.isCapturing)
        XCTAssertThrowsError(try manager.save(userConfig()))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        XCTAssertTrue(try damagedFiles().isEmpty)
    }

    func testReloadOfAFixedFileClearsTheState() throws {
        try broken.write(to: file)
        let manager = manager()
        let state = CaptureState(isGloballyPaused: { manager.isFailClosed })

        XCTAssertThrowsError(try manager.reload())
        XCTAssertTrue(manager.isFailClosed, "A failed reload keeps recording paused")

        try userConfig().write(to: file)
        try manager.reload()
        XCTAssertFalse(manager.isFailClosed)
        XCTAssertNil(manager.statusNotice)
        XCTAssertEqual(manager.config.excludedDomains, ["private.example"])
        XCTAssertTrue(state.isCapturing)
    }

    func testResetKeepsTheBrokenFileAsideAndWritesDefaults() throws {
        try broken.write(to: file)
        let manager = manager()

        let backup = try XCTUnwrap(try manager.resetToDefaults())
        XCTAssertTrue(backup.hasPrefix("config.damaged-"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(backup)), broken)
        XCTAssertEqual(try RecorderConfig.load(from: file), RecorderConfig.default.validated())
        XCTAssertFalse(manager.isFailClosed)
        XCTAssertNil(manager.statusNotice)
        XCTAssertNoThrow(try manager.save(userConfig()))
    }

    func testFailedReloadWithAValidConfigKeepsThePreviousSettings() throws {
        try userConfig().write(to: file)
        let manager = manager()
        XCTAssertFalse(manager.isFailClosed)

        try broken.write(to: file)
        XCTAssertThrowsError(try manager.reload())
        XCTAssertFalse(manager.isFailClosed, "The previous valid config stays active and recording")
        XCTAssertEqual(manager.config.excludedDomains, ["private.example"])
        XCTAssertEqual(manager.statusNotice, ConfigManager.reloadFailedNotice)

        // A later save keeps the user's unreadable edits aside before writing.
        try manager.save(manager.config)
        let damaged = try damagedFiles()
        XCTAssertEqual(damaged.count, 1)
        XCTAssertEqual(try Data(contentsOf: damaged[0]), broken)
        XCTAssertEqual(manager.lastDamagedBackupName, damaged[0].lastPathComponent)
        XCTAssertNil(manager.statusNotice)
    }

    func testMissingFileIsCreatedWithDefaultsAndDoesNotFailClosed() throws {
        let manager = manager()
        XCTAssertFalse(manager.isFailClosed)
        XCTAssertEqual(try RecorderConfig.load(from: file), RecorderConfig.default.validated())
    }

    @MainActor func testMenuPanelShowsTheUnreadableConfig() throws {
        let suite = "config-fail-closed-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = folder!
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { true }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil },
            ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, configUnreadable: { true }, globalPause: { GoalongGlobalPause() },
            onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        model.refreshRuntimeState()
        XCTAssertEqual(model.tracking, .attention("Réglages illisibles"))
        XCTAssertEqual(model.trackingDetail, ConfigManager.failClosedNotice)
    }
}
#endif
