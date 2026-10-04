import Foundation
import XCTest
@testable import Ambiance

final class AmbianceAudioTests: XCTestCase {
    @MainActor func testPersonalPlaybackStopAndDisableReleaseOutput() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_DEVICE_TESTS"] == "1",
              let path = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PERSONAL_FILE"] else {
            throw XCTSkip("Explicit device playback and selected local audio file required")
        }
        let name = "goalong.ambiance.playback.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AmbianceSettings(defaults: defaults); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("unused") }
        let controller = try XCTUnwrap(module.controller)
        controller.addOwnFiles([URL(fileURLWithPath: path)])
        let source = try XCTUnwrap(controller.sources.first { $0.kind == .ownFile })
        controller.volume = 0.01; controller.play(source)
        XCTAssertEqual(controller.state, .playing(source)); XCTAssertTrue(controller.diagnostics.engineRunning)
        controller.volume = 0.02; controller.stop()
        XCTAssertFalse(controller.diagnostics.engineRunning); XCTAssertFalse(controller.diagnostics.runtimeCreated)
        controller.play(source); XCTAssertTrue(controller.diagnostics.engineRunning)
        module.setEnabled(false)
        XCTAssertFalse(controller.diagnostics.engineRunning); XCTAssertFalse(controller.diagnostics.runtimeCreated)
        XCTAssertNil(module.controller)
    }
    @MainActor func testInvalidPersonalAudioFailsWithoutKeepingRuntime() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ambiance-invalid-\(UUID()).wav")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let name = "goalong.ambiance.invalid.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AmbianceSettings(defaults: defaults); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { file.deletingLastPathComponent().appendingPathComponent("unused") }
        let controller = try XCTUnwrap(module.controller)
        controller.addOwnFiles([file]); controller.play(try XCTUnwrap(controller.sources.first { $0.kind == .ownFile }))
        if case .error = controller.state {} else { XCTFail("Invalid audio must fail honestly") }
        XCTAssertFalse(controller.diagnostics.engineRunning)
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
    }
}
