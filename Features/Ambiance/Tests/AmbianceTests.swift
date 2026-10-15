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
    @MainActor func testOwnFilesAndMissingFileStayListedWithoutCopying() async throws {
        let support = try root(), input = try root(), settings = AmbianceSettings(defaults: defaults())
        settings.isEnabled = true
        let file = input.appendingPathComponent("mon son.wav")
        try Data([1, 2, 3]).write(to: file)
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        await controller.addOwnFiles([input, file])?.value
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
    @MainActor func testFolderImportIncludesNestedAlbumWithoutCopying() async throws {
        let support = try root(), album = try root().appendingPathComponent("Artiste/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let file = album.appendingPathComponent("morceau.flac")
        try Data([1, 2]).write(to: file)
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        await controller.addOwnFiles([album.deletingLastPathComponent().deletingLastPathComponent()])?.value
        XCTAssertEqual(settings.ownFiles, [file.resolvingSymlinksInPath().path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Ambiance").path))
    }
    @MainActor func testFolderImportIsCappedAndNeverDuplicates() async throws {
        let support = try root(), folder = try root()
        let total = AmbianceController.ownFilesLimit + 5
        for index in 0..<total { try Data([1]).write(to: folder.appendingPathComponent(String(format: "morceau-%04d.flac", index))) }
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        await controller.addOwnFiles([folder])?.value
        XCTAssertEqual(settings.ownFiles.count, AmbianceController.ownFilesLimit)
        XCTAssertNotNil(controller.importNotice)
        let first = settings.ownFiles
        await controller.addOwnFiles([folder])?.value
        XCTAssertEqual(settings.ownFiles, first, "Importing the same folder again changes nothing")
        XCTAssertEqual(Set(settings.ownFiles).count, settings.ownFiles.count)
    }
    func testCollectAudioFilesReportsTruncationReason() throws {
        let folder = try root()
        for index in 0..<4 { try Data([1]).write(to: folder.appendingPathComponent("a\(index).wav")) }
        XCTAssertEqual(AmbianceController.collectAudioFiles([folder], existing: [], visitedLimit: 2).truncated, .walkCapped)
        XCTAssertEqual(AmbianceController.collectAudioFiles([folder], existing: [], limit: 1).truncated, .listFull)
        XCTAssertNil(AmbianceController.collectAudioFiles([folder], existing: []).truncated)
    }
    @MainActor func testMergeNoticeMatchesTruncationReason() throws {
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { try! self.root() }, controller = try XCTUnwrap(module.controller)
        controller.merge((paths: [], truncated: .walkCapped))
        XCTAssertEqual(controller.importNotice, "Dossier trop volumineux : seule une partie a été parcourue.")
        controller.merge((paths: [], truncated: .listFull))
        XCTAssertEqual(controller.importNotice, "La liste est pleine (\(AmbianceController.ownFilesLimit) fichiers).")
    }
    @MainActor func testShutdownCancelsFolderImport() async throws {
        let support = try root(), folder = try root()
        try Data([1]).write(to: folder.appendingPathComponent("a.wav"))
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        let task = controller.addOwnFiles([folder])
        controller.shutdown()
        await task?.value
        XCTAssertTrue(settings.ownFiles.isEmpty)
    }
    @MainActor func testTwoBackToBackFolderImportsBothMerge() async throws {
        let support = try root(), a = try root(), b = try root()
        try Data([1]).write(to: a.appendingPathComponent("a.wav"))
        try Data([1]).write(to: b.appendingPathComponent("b.wav"))
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        let first = controller.addOwnFiles([a]), second = controller.addOwnFiles([b])
        await first?.value; await second?.value
        XCTAssertEqual(settings.ownFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(), ["a.wav", "b.wav"])
    }
    @MainActor func testShutdownCancelsEveryConcurrentFolderImport() async throws {
        let support = try root(), a = try root(), b = try root()
        try Data([1]).write(to: a.appendingPathComponent("a.wav"))
        try Data([1]).write(to: b.appendingPathComponent("b.wav"))
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        let first = controller.addOwnFiles([a]), second = controller.addOwnFiles([b])
        controller.shutdown()
        await first?.value; await second?.value
        XCTAssertTrue(settings.ownFiles.isEmpty)
    }
    func testNetworkErrorsAreNotReportedAsInvalidPack() {
        for error in [AmbianceError.network, .serverUnavailable] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("Pack invalide"), text)
            XCTAssertFalse(text.contains("http"), text)
        }
        XCTAssertTrue(AmbianceError.network.localizedDescription.contains("Connexion"))
        XCTAssertTrue(AmbianceError.invalidPack("taille incorrecte").localizedDescription.contains("taille incorrecte"))
    }
    func testErrorBodyOf404IsServerUnavailableNotWrongSize() {
        let notFound = AmbiancePackDownloader.progressFailure(status: 404, written: 9, expected: 9, packBytes: 5000)
        XCTAssertEqual(notFound?.localizedDescription, AmbianceError.serverUnavailable.localizedDescription)
        let wrongSize = AmbiancePackDownloader.progressFailure(status: 200, written: 9, expected: 9, packBytes: 5000)
        XCTAssertTrue(wrongSize?.localizedDescription.contains("taille incorrecte") == true)
        XCTAssertNil(AmbiancePackDownloader.progressFailure(status: 200, written: 10, expected: 5000, packBytes: 5000))
    }
    func testRemoveOrphansKeepsPacksAndDoesNotFollowSymlinks() throws {
        let support = try root(), outside = try root()
        let store = AmbiancePackStore(supportDirectory: support)
        let fm = FileManager.default
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        let install = store.root.appendingPathComponent(".install-orchestra-\(UUID().uuidString)")
        let stale = store.root.appendingPathComponent(".stale-textures-\(UUID().uuidString)")
        for dir in [install, stale, store.root.appendingPathComponent("orchestra")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("f"))
        }
        try Data([1]).write(to: outside.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: store.root.appendingPathComponent(".install-textures-\(UUID().uuidString)"), withDestinationURL: outside)
        XCTAssertEqual(store.removeOrphans(), 3)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.root.path), ["orchestra"])
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("keep").path))
    }
    @MainActor func testFolderImportIsDiscardedWhenModuleTurnsOffMeanwhile() async throws {
        let support = try root(), folder = try root()
        try Data([1]).write(to: folder.appendingPathComponent("a.wav"))
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        let task = controller.addOwnFiles([folder])
        settings.isEnabled = false
        await task?.value
        XCTAssertTrue(settings.ownFiles.isEmpty)
    }
    @MainActor func testLocalDownloadAndRemovePublishCorrectPackState() async throws {
        guard ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_DIR"] != nil else { throw XCTSkip("Local dev archives required") }
        let support = try root(), settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let module = AmbianceModule(settings: settings) { support }, controller = try XCTUnwrap(module.controller)
        let installed = expectation(description: "complete pack installed")
        let token = controller.$packs.sink { values in
            if values.first(where: { $0.id == "orchestra" })?.status == .installed { installed.fulfill() }
        }
        controller.download("orchestra")
        await fulfillment(of: [installed], timeout: 30)
        token.cancel()
        XCTAssertTrue(controller.sources.contains { $0.kind == .focus && $0.isAvailable })
        controller.remove("orchestra")
        XCTAssertEqual(controller.packs.first { $0.id == "orchestra" }?.status, .notInstalled)
        XCTAssertFalse(controller.sources.contains { $0.kind == .focus && $0.isAvailable })
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
    func testInvalidLeftoverFolderIsReplacedByReinstall() throws {
        let support = try root(), fixture = try fixtureArchive(), store = AmbiancePackStore(supportDirectory: support)
        try store.install(fixture.pack, archive: fixture.url)
        let folder = store.directory(fixture.pack)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        XCTAssertFalse(store.isInstalled(fixture.pack))
        XCTAssertTrue(store.hasLeftovers(fixture.pack))
        try store.install(fixture.pack, archive: fixture.url)
        XCTAssertTrue(store.isInstalled(fixture.pack))
        XCTAssertFalse(store.hasLeftovers(fixture.pack))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), ["orchestra"])
        // A receipt that no longer matches the catalog is also repaired.
        let receipt = folder.appendingPathComponent(".installed.json")
        try Data(#"{"id":"orchestra","sha256":"old","bytes":1,"files":["LICENSE.txt"]}"#.utf8).write(to: receipt)
        XCTAssertFalse(store.isInstalled(fixture.pack))
        try store.install(fixture.pack, archive: fixture.url)
        XCTAssertTrue(store.isInstalled(fixture.pack))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), ["orchestra"])
    }
    func testSymlinkedPackFolderIsNeverReplacedNorFollowed() throws {
        let support = try root(), outside = try root(), fixture = try fixtureArchive()
        let store = AmbiancePackStore(supportDirectory: support)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt"); try Data([1]).write(to: marker)
        try FileManager.default.createSymbolicLink(at: store.directory(fixture.pack), withDestinationURL: outside)
        XCTAssertThrowsError(try store.install(fixture.pack, archive: fixture.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
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
    /// An orchestra folder that passes the catalog receipt check but holds an invalid manifest:
    /// play() reaches the off-main preparation and then fails, with no device audio.
    @MainActor private func controllerWithBrokenOrchestra() throws -> AmbianceController {
        let support = try root(), fixture = try fixtureArchive(), store = AmbiancePackStore(supportDirectory: support)
        try store.install(fixture.pack, archive: fixture.url)
        let catalog = try XCTUnwrap(AmbiancePackCatalog.packs.first { $0.id == "orchestra" })
        let receipt: [String: Any] = ["id": catalog.id, "sha256": catalog.sha256, "bytes": catalog.bytes,
                                      "files": ["LICENSE.txt", "manifest.json"]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: store.directory(catalog).appendingPathComponent(".installed.json"))
        let settings = AmbianceSettings(defaults: defaults()); settings.isEnabled = true
        let controller = try XCTUnwrap(AmbianceModule(settings: settings) { support }.controller)
        XCTAssertTrue(controller.sources.contains { $0.kind == .focus && $0.isAvailable })
        return controller
    }
    @MainActor func testOrchestraPlayShowsLoadingThenFailsHonestly() async throws {
        let controller = try controllerWithBrokenOrchestra()
        let source = try XCTUnwrap(controller.sources.first { $0.kind == .focus })
        controller.play(source)
        XCTAssertEqual(controller.state, .loading, "Preparation runs off the main actor")
        for _ in 0..<200 where controller.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .error = controller.state else { return XCTFail("Invalid bank must end in an error, got \(controller.state)") }
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
    }
    @MainActor func testStopDuringOrchestraLoadingStaysIdle() async throws {
        let controller = try controllerWithBrokenOrchestra()
        let source = try XCTUnwrap(controller.sources.first { $0.kind == .focus })
        controller.play(source); controller.stop()
        XCTAssertEqual(controller.state, .idle)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.state, .idle, "A stale load must not publish an error or start audio")
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
    }
    @MainActor func testSecondPlayDuringLoadingSupersedesTheFirst() async throws {
        let controller = try controllerWithBrokenOrchestra()
        let focus = controller.sources.filter { $0.kind == .focus }
        controller.play(focus[0]); controller.play(focus[1])
        XCTAssertEqual(controller.state, .loading)
        for _ in 0..<200 where controller.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .error = controller.state else { return XCTFail("Only the second play reports, got \(controller.state)") }
        XCTAssertFalse(controller.diagnostics.runtimeCreated)
    }
    private func installedOrchestra() throws -> (AmbiancePackStore, AmbiancePack) {
        guard let folder = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_DIR"] else {
            throw XCTSkip("Provide the locally built dev packs to exercise real acoustic rendering")
        }
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first { $0.id == "orchestra" })
        let store = AmbiancePackStore(supportDirectory: try root())
        try autoreleasepool { try store.install(pack, archive: URL(fileURLWithPath: folder).appendingPathComponent("orchestra.tar")) }
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
        if ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_DEVICE_TESTS"] == "1" {
            controller.volume = 0.01; controller.play(source)
            XCTAssertEqual(controller.state, .playing(source))
            XCTAssertTrue(controller.diagnostics.engineRunning)
            XCTAssertTrue(controller.diagnostics.runtimeCreated)
            XCTAssertThrowsError(try runtime.render(seconds: 0.1))
            module.setEnabled(false)
            XCTAssertFalse(controller.diagnostics.engineRunning)
            XCTAssertFalse(controller.diagnostics.runtimeCreated)
            XCTAssertEqual(controller.diagnostics.mappedBytes, 0)
            XCTAssertNil(module.controller)
        }
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
