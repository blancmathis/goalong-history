import AVFoundation
import CryptoKit
import Foundation
import OndeCore
import OndeDSP
import XCTest
@testable import Ambiance

final class AmbianceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "goalong.ambiance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-ambiance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    @MainActor func testDisabledGateDoesNotResolveStorageOrCreateController() throws {
        let settings = AmbianceSettings(defaults: defaults()), support = try root()
        var storageResolutions = 0
        let module = AmbianceModule(settings: settings) { storageResolutions += 1; return support }
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.volume, 0.5)
        XCTAssertTrue(settings.ownFiles.isEmpty)
        XCTAssertNil(module.controller)
        XCTAssertNil(module.controller)
        XCTAssertEqual(storageResolutions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Ambiance").path))
        module.setEnabled(true)
        let controller = try XCTUnwrap(module.controller)
        XCTAssertEqual(storageResolutions, 1)
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
        XCTAssertFalse(controller.diagnostics.engineRunning)
        XCTAssertEqual(controller.diagnostics.mappedBytes, 0)
        module.setEnabled(false)
        XCTAssertNil(module.controller)
        XCTAssertEqual(controller.state, .idle)
    }
    func testSettingsClampVolumeAndPersistPathsOnly() {
        let store = defaults(), settings = AmbianceSettings(defaults: store)
        settings.volume = -.infinity; XCTAssertEqual(settings.volume, 0.5)
        settings.volume = 2; XCTAssertEqual(settings.volume, 1)
        settings.volume = -1; XCTAssertEqual(settings.volume, 0)
        settings.ownFiles = ["/missing/member.wav"]
        settings.lastSource = "ambre"
        XCTAssertEqual(AmbianceSettings(defaults: store).ownFiles, ["/missing/member.wav"])
        XCTAssertEqual(AmbianceSettings(defaults: store).lastSource, "ambre")
    }
    @MainActor func testOwnFilesAndMissingFileStayListedWithoutCopying() throws {
        let support = try root(), input = try root(), settings = AmbianceSettings(defaults: defaults())
        settings.isEnabled = true
        let file = input.appendingPathComponent("mon son.wav")
        try Data([1, 2, 3]).write(to: file)
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        controller.addOwnFiles([input, file])
        XCTAssertEqual(settings.ownFiles, [file.resolvingSymlinksInPath().path])
        XCTAssertTrue(try XCTUnwrap(controller.sources.first { $0.kind == .ownFile }).isAvailable)
        try FileManager.default.removeItem(at: file); controller.refresh()
        let missing = try XCTUnwrap(controller.sources.first { $0.kind == .ownFile })
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(missing.title, "mon son.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Ambiance").path))
        controller.play(missing)
        guard case .error = controller.state else { return XCTFail("Missing source must fail honestly") }
        controller.removeOwnFile(missing); XCTAssertTrue(settings.ownFiles.isEmpty)
    }
    @MainActor func testMissingPackDoesNotPretendToPlay() throws {
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let support = try root(), module = AmbianceModule(settings: settings) { support }
        let controller = try XCTUnwrap(module.controller)
        XCTAssertEqual(controller.sources.count, FocusCompositions.profiles.count + RelaxCompositions.profiles.count)
        XCTAssertTrue(controller.sources.allSatisfy { !$0.isAvailable })
        controller.play(controller.sources[0])
        XCTAssertEqual(controller.state, .error(AmbianceError.unavailable.localizedDescription))
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
        XCTAssertEqual(controller.diagnostics.mappedBytes, 0)
    }
    func testPackRejectsSizeAndChecksumBeforeCreatingStorage() throws {
        let support = try root(), fixture = try fixtureArchive(), store = AmbiancePackStore(supportDirectory: support)
        let size = AmbiancePack(id: "orchestra", title: "test", bytes: fixture.pack.bytes + 1, url: fixture.pack.url, sha256: fixture.pack.sha256)
        let hash = AmbiancePack(id: "orchestra", title: "test", bytes: fixture.pack.bytes, url: fixture.pack.url, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try store.install(size, archive: fixture.url))
        XCTAssertThrowsError(try store.install(hash, archive: fixture.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
    func testPackPublishesAtomicallyAndRemoveDeletesFolder() throws {
        let support = try root(), fixture = try fixtureArchive(), store = AmbiancePackStore(supportDirectory: support)
        var finalProgress = 0.0
        try store.install(fixture.pack, archive: fixture.url) { progress in
            if progress < 1 { XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(fixture.pack).path)) }
            finalProgress = progress
        }
        XCTAssertEqual(finalProgress, 1)
        XCTAssertTrue(store.isInstalled(fixture.pack))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), ["orchestra"])
        XCTAssertThrowsError(try store.install(fixture.pack, archive: fixture.url))
        try store.remove(fixture.pack)
        XCTAssertFalse(store.isInstalled(fixture.pack))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(fixture.pack).path))
    }
    func testUnsafeTarEntriesLeaveNoPublishedOrStagingDirectory() throws {
        for (name, type) in [("../outside", UInt8(48)), ("note.wav", UInt8(50))] {
            let support = try root(), fixture = try fixtureArchive(extraName: name, type: type)
            let store = AmbiancePackStore(supportDirectory: support)
            XCTAssertThrowsError(try store.install(fixture.pack, archive: fixture.url))
            XCTAssertFalse(store.isInstalled(fixture.pack))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [])
        }
    }
    func testCancelledInstallDoesNotPublish() async throws {
        let fixture = try fixtureArchive(), store = AmbiancePackStore(supportDirectory: try root())
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try store.install(fixture.pack, archive: fixture.url)
        }
        do { try await task.value; XCTFail("Cancelled install must fail") } catch {}
        XCTAssertFalse(store.isInstalled(fixture.pack))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
    private func installedOrchestra() throws -> (AmbiancePackStore, AmbiancePack) {
        guard let folder = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_DIR"] else {
            throw XCTSkip("Provide the locally built dev packs to exercise real acoustic rendering")
        }
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first { $0.id == "orchestra" })
        let store = AmbiancePackStore(supportDirectory: try root())
        try store.install(pack, archive: URL(fileURLWithPath: folder).appendingPathComponent("orchestra.tar"))
        return (store, pack)
    }
    @MainActor func testFocusAndRelaxRenderNonSilentAndStopUnmaps() throws {
        let (store, pack) = try installedOrchestra()
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { store.root.deletingLastPathComponent() }
        let controller = try XCTUnwrap(module.controller)
        for source in controller.sources where source.kind == .focus || source.kind == .relax {
            let rendered = try controller.renderOffline(source, seconds: 4)
            XCTAssertGreaterThan(rendered.peak, 0.00001, source.id)
            XCTAssertGreaterThan(rendered.rms, 0.000001, source.id)
            XCTAssertEqual(controller.diagnostics.mappedBytes, 0)
            XCTAssertFalse(controller.diagnostics.runtimeCreated)
            XCTAssertFalse(controller.diagnostics.engineRunning)
        }
        let source = try XCTUnwrap(controller.sources.first { $0.id == "confluence" })
        let runtime = try AmbianceRuntime(source: source, orchestraDirectory: store.directory(pack))
        XCTAssertGreaterThan(runtime.diagnostics.mappedBytes, 0)
        XCTAssertEqual(runtime.diagnostics.copiedSampleBytes, 0)
        runtime.stop()
        XCTAssertEqual(runtime.diagnostics.mappedBytes, 0)
        XCTAssertFalse(runtime.diagnostics.runtimeCreated)
        controller.play(source)
        XCTAssertEqual(controller.state, .error(AmbianceError.audioBoundary.localizedDescription))
    }
    func testMappedPCM16MatchesOriginalDecodedSampler() throws {
        let (store, pack) = try installedOrchestra(), directory = store.directory(pack)
        let profile = try XCTUnwrap(FocusCompositions.profiles.first { $0.id == "ambre" })
        let mapped = try XCTUnwrap(onde_dsp_create(44_100, 0, profile.configuration.seed))
        let copied = try XCTUnwrap(onde_dsp_create(44_100, 0, profile.configuration.seed))
        defer { onde_dsp_destroy(mapped); onde_dsp_destroy(copied) }
        let bank = try OrchestraBank.load(into: mapped, required: true, directory: directory, configuration: profile.configuration)
        defer { withExtendedLifetime(bank) {} }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["samples"] as? [[String: Any]])
        for entry in entries where entry["instrument"] as? Int == 11 {
            try autoreleasepool {
                let name = try XCTUnwrap(entry["filename"] as? String)
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(name), commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                let data = try XCTUnwrap(buffer.floatChannelData)
                XCTAssertEqual(onde_dsp_add_sample(copied, 11, Int32(entry["root_midi"] as! Int), Int32(entry["round_robin"] as! Int), data[0], data[1], buffer.frameLength, file.processingFormat.sampleRate), 1)
            }
        }
        for dsp in [mapped, copied] {
            for (i, value) in profile.configuration.values.enumerated() { onde_dsp_set(dsp, GenerativeSettings.dspIndex(i), Float(value)) }
            onde_dsp_set(dsp, Int32(ONDE_GAIN), 1)
        }
        var a = [Float](repeating: 0, count: 1024), b = a, c = a, d = a
        // Ambre's acoustic piano answers enter after four bars; cover a full phrase.
        for _ in 0..<1300 {
            onde_dsp_render(mapped, &a, &b, 1024); onde_dsp_render(copied, &c, &d, 1024)
            XCTAssertEqual(a, c); XCTAssertEqual(b, d)
        }
        XCTAssertGreaterThan(onde_dsp_orchestra_events(mapped), 0)
    }
    @MainActor func testFiveMinuteFocusMeasures() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_MEASURE"] == "1" else { throw XCTSkip("Explicit five-minute measurement") }
        let (store, pack) = try installedOrchestra(), settings = AmbianceSettings(defaults: defaults())
        settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { store.root.deletingLastPathComponent() }
        let controller = try XCTUnwrap(module.controller)
        let source = try XCTUnwrap(controller.sources.first { $0.id == "confluence" })
        let idle = AmbianceRuntime.residentBytes()
        var runtime: AmbianceRuntime? = try AmbianceRuntime(source: source, orchestraDirectory: store.directory(pack))
        let prepared = runtime!.diagnostics
        let render = try runtime!.render(seconds: 300)
        let playing = AmbianceRuntime.residentBytes()
        runtime!.stop(); runtime = nil
        let stopped = AmbianceRuntime.residentBytes()
        let values: [String: Any] = ["mode": "offline-confluence", "audioSeconds": render.seconds,
            "renderWallSeconds": render.wallSeconds, "renderCPUSeconds": render.cpuSeconds,
            "percentOfOneCore": render.percentOfOneCore, "idleRSS": idle, "preparedRSS": prepared.residentBytes,
            "playingRSS": playing, "peakPlayingRSS": render.peakResidentBytes, "stoppedRSS": stopped,
            "mappedBytes": prepared.mappedBytes, "copiedSampleBytes": prepared.copiedSampleBytes,
            "peak": render.peak, "rms": render.rms]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("AMBIANCE_MEASURE " + String(decoding: data, as: UTF8.self))
        XCTAssertLessThanOrEqual(Int64(render.peakResidentBytes) - Int64(idle), 90_000_000)
        XCTAssertLessThanOrEqual(abs(Int64(stopped) - Int64(idle)), 5_000_000)
    }
    private func fixtureArchive(extraName: String? = nil, type: UInt8 = 48) throws -> (pack: AmbiancePack, url: URL) {
        var archive = Data()
        var entries = [("LICENSE.txt", Data("CC0".utf8), UInt8(48)), ("manifest.json", Data("{}".utf8), UInt8(48))]
        if let extraName { entries.append((extraName, Data([0]), type)) }
        for (name, data, type) in entries {
            var header = Data(repeating: 0, count: 512)
            func field(_ text: String, at offset: Int) { header.replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8) }
            field(name, at: 0); field("0000600", at: 100); field("0000000", at: 108); field("0000000", at: 116)
            field(String(format: "%011o", data.count), at: 124); field("00000000000", at: 136)
            field("        ", at: 148); header[156] = type; field("ustar", at: 257); field("00", at: 263)
            let checksum = header.reduce(0) { $0 + Int($1) }
            field(String(format: "%06o", checksum), at: 148); header[154] = 0; header[155] = 32
            archive.append(header); archive.append(data)
            archive.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
        }
        archive.append(Data(repeating: 0, count: 1024))
        let url = try root().appendingPathComponent("orchestra.tar"); try archive.write(to: url)
        return (AmbiancePack(id: "orchestra", title: "Test", bytes: Int64(archive.count), url: URL(string: "https://example.invalid/orchestra.tar")!,
                            sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()), url)
    }
}
