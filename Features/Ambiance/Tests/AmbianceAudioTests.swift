import AVFoundation
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
    @MainActor func testOutputConfigurationChangeNotifiesOnlyWhilePlaying() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Explicit device playback required")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ambiance-config-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = 4_410
            try writer.write(from: buffer)
        }
        var calls = 0
        let output = try AmbianceAudioOutput(fileURL: file, looping: true) {}
        output.interrupted = { calls += 1 }
        do { try output.start(volume: 0) } catch { throw XCTSkip("No audio output device: \(error)") }
        let engine = try XCTUnwrap(output.engineForTesting)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls, 1)
        output.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testInterruptionOutsidePlaybackChangesNothing() throws {
        let name = "goalong.ambiance.interrupt.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AmbianceSettings(defaults: defaults); settings.isEnabled = true
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID())")
        let controller = try XCTUnwrap(AmbianceModule(settings: settings) { support }.controller)
        controller.outputInterrupted()
        XCTAssertEqual(controller.state, .idle)
    }
}
