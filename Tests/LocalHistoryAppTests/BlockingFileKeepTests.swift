#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 bugs-donnees-04 and -05: `blocking.json` keeps what a newer build wrote, and a set-aside copy is never replaced.
final class BlockingFileKeepTests: XCTestCase {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/blocking-keep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("Blocking")
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A rollback to this build re-saves the file: the keys of a newer build stay, unchanged; a known key is never
    /// overwritten by an unknown value.
    func testResaveKeepsTopLevelKeysOfANewerBuild() throws {
        let directory = try folder(), store = BlockingStore(directory: directory)
        try store.save(BlockingDocument())
        let file = directory.appendingPathComponent("blocking.json")
        var raw = try object(file)
        raw["futurePauses"] = ["4E1C8C9A-0000-4000-8000-000000000001": ["used": 2, "day": "2026-11-27", "at": 1.5]]
        raw["futureFlag"] = true
        raw["futureList"] = [1, "deux", NSNull()]
        // Non-atomic write keeps the file's 0600 mode, which the store requires.
        try JSONSerialization.data(withJSONObject: raw).write(to: file)

        var document = try store.load()
        XCTAssertEqual(document.unknownKeys?.keys.sorted(), ["futureFlag", "futureList", "futurePauses"])
        document.lists.append(BlockList(name: "Vidéo", sites: [BlockSiteRule(pattern: "youtube.com")]))
        document.unknownKeys?["lists"] = .array([])
        try store.save(document)

        let saved = try object(file)
        XCTAssertEqual(saved["futureFlag"] as? Bool, true)
        XCTAssertEqual(saved["futureList"] as? NSArray, [1, "deux", NSNull()] as NSArray)
        let pauses = try XCTUnwrap(saved["futurePauses"] as? [String: [String: Any]])
        XCTAssertEqual(pauses["4E1C8C9A-0000-4000-8000-000000000001"]?["used"] as? Int, 2)
        XCTAssertEqual(pauses["4E1C8C9A-0000-4000-8000-000000000001"]?["at"] as? Double, 1.5)
        XCTAssertEqual((saved["lists"] as? [Any])?.count, 1, "a known key wins over an unknown value")
        document.unknownKeys?["lists"] = nil
        XCTAssertEqual(try store.load(), document)
    }

    /// Two damages in a row: both changed files stay set aside, under distinct timestamped names.
    func testASecondDamageKeepsTheFirstSetAsideCopy() throws {
        let directory = try folder(), store = BlockingStore(directory: directory)
        try store.save(BlockingDocument())
        try store.replaceDamaged(with: BlockingDocument(lists: [BlockList(name: "Un")]))
        try store.replaceDamaged(with: BlockingDocument(lists: [BlockList(name: "Deux")]))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("damaged") }
        XCTAssertEqual(names.count, 2, "\(names)")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("blocking.damaged-") && $0.hasSuffix(".json") }, "\(names)")
        XCTAssertEqual(BlockingStore.setAsideStamp(Date(timeIntervalSince1970: 0)), "19700101-000000Z")
    }
}
#endif
