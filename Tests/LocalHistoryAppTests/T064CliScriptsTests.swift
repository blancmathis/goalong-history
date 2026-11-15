#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class T064CliScriptsTests: XCTestCase {
    func testLegacyMigratorOnlyRemovesCopiesNotNewerThanCurrent() {
        typealias M = LegacyInstallationMigrator
        XCTAssertTrue(M.isNotNewer(candidate: "30000000.1.5", than: "30000000.1.5"))
        XCTAssertTrue(M.isNotNewer(candidate: "30000000.1.4", than: "30000000.1.5"))
        XCTAssertTrue(M.isNotNewer(candidate: "9", than: "30000000.1.5"))
        XCTAssertFalse(M.isNotNewer(candidate: "30000000.1.6", than: "30000000.1.5"))
        XCTAssertFalse(M.isNotNewer(candidate: "30000000.2", than: "30000000.1.5"))
        XCTAssertFalse(M.isNotNewer(candidate: nil, than: "1.0"))
        XCTAssertFalse(M.isNotNewer(candidate: "1.0", than: nil))
        XCTAssertFalse(M.isNotNewer(candidate: "1.x", than: "2.0"))
    }

    func testDeleteAllRemovesOrphanDeleteTemporaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t064-semantic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(".2026-11-01.semantic.jsonl.delete-\(UUID().uuidString).tmp")
        let kept = root.appendingPathComponent("notes.txt")
        try Data("secret".utf8).write(to: orphan)
        try Data("other".utf8).write(to: kept)
        let store = SemanticContextStore(semanticDirectory: root, secureInputEnabled: { false })
        let done = expectation(description: "deleteAll")
        store.deleteAll { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }
}
#endif
