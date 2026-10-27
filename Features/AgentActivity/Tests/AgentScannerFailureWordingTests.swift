import XCTest
@testable import AgentActivity

final class AgentScannerFailureWordingTests: XCTestCase {
    func testUnreadableFolderFailureIsAShortFrenchSentenceWithoutTheRawSystemError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-scanner-wording-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("a.txt"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = try AgentActivityStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)

        let folder = AgentWatchedFolder(id: "wording", displayName: "Wording", path: source.path, provider: .custom)
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true
        )

        let failure = try XCTUnwrap(result.failures.first, "no failure reported")
        XCTAssertFalse(failure.hasPrefix("\(source.path): "), failure)
        for raw in ["Operation", "permission", "couldn’t", "couldn't", "NSCocoa", "Error Domain"] {
            XCTAssertFalse(failure.contains(raw), failure)
        }
        XCTAssertEqual(failure.components(separatedBy: source.path).count - 1, 1, "path named once: \(failure)")
        XCTAssertTrue(failure.hasPrefix("La source"), failure)
    }
}
