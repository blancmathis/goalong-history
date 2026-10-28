import Foundation
import XCTest
@testable import Ambiance

/// edge cases of the Ambiance module.
final class AmbianceFailureMessageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "goalong.ambiance.c044r12.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-c044r12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A member adds a file named .mp3 that is not audio (renamed document, broken download).
    /// Expected: a short French sentence; never a system debug string with a domain and a code.
    @MainActor func testUnreadableOwnFileShowsAFrenchMessageNotASystemCode() throws {
        let settings = AmbianceSettings(defaults: defaults()), support = try root()
        settings.isEnabled = true
        let file = support.appendingPathComponent("morceau.mp3")
        try Data("ceci n'est pas de l'audio".utf8).write(to: file)
        let controller = AmbianceController(settings: settings, supportDirectory: support)
        controller.addOwnFiles([file])
        let source = try XCTUnwrap(controller.sources.first { $0.kind == .ownFile })
        XCTAssertTrue(source.isAvailable)
        controller.play(source)
        guard case .error(let message) = controller.state else { return XCTFail("state \(controller.state)") }
        XCTAssertFalse(message.contains("com.apple"), "message: \(message)")
        XCTAssertFalse(message.contains("error"), "message: \(message)")
        XCTAssertFalse(message.contains("The operation"), "message: \(message)")
    }

    /// Disk full while a pack (77-83 MB) downloads: the download fails with "cannot write to file".
    /// Expected: the member is told about disk space, not asked to check Internet.
    func testDiskFullDuringPackDownloadIsNotReportedAsAConnectionProblem() {
        for code in [URLError.Code.cannotWriteToFile, .cannotCreateFile] {
            let message = AmbiancePackDownloader.transportFailure(URLError(code), bytesReceived: 40_000_000).errorDescription ?? ""
            XCTAssertNotEqual(message, AmbianceError.network.errorDescription, "code \(code.rawValue): \(message)")
            XCTAssertFalse(message.contains("Internet"), "code \(code.rawValue): \(message)")
        }
    }

    /// The figure comes from the pack being downloaded, never from a hard-coded number.
    func testDiskFullMessageUsesTheRealPackSize() {
        let message = AmbiancePackDownloader.transportFailure(URLError(.cannotWriteToFile), bytesReceived: 1, packBytes: 81_234_567).errorDescription ?? ""
        XCTAssertTrue(message.contains("environ 82 Mo"), message)
        XCTAssertFalse(message.contains("90"), message)
        let unknown = AmbiancePackDownloader.transportFailure(URLError(.cannotWriteToFile), bytesReceived: 1).errorDescription ?? ""
        XCTAssertFalse(unknown.contains(" Mo"), "no size claimed when it is unknown: \(unknown)")
        XCTAssertTrue(unknown.contains("Espace disque"), unknown)
    }
}
