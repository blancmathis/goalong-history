#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-045 H9: storage that cannot be prepared never makes Goalong record with default settings
/// in place of the user's config.json (exclusions).
final class T045H9ConfigTests: XCTestCase {
    func testPrepareFailureWithExistingConfigStaysFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h9-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("config.json")
        try RecorderConfig.default.write(to: file)
        let before = try Data(contentsOf: file)

        let manager = ConfigManager(fileURL: file, prepareStorage: { throw CocoaError(.fileWriteNoPermission) })

        XCTAssertTrue(manager.isFailClosed)
        XCTAssertThrowsError(try manager.save(.default))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testPrepareFailureWithoutConfigKeepsDefaults() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("t045h9-\(UUID().uuidString)/config.json")
        let manager = ConfigManager(fileURL: file, prepareStorage: { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(manager.isFailClosed)
    }
}
#endif
