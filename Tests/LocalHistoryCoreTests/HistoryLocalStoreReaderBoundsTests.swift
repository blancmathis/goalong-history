import Darwin
import Foundation
import XCTest

@testable import LocalHistoryCore

final class HistoryLocalStoreReaderBoundsTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-reader-bounds-\(UUID().uuidString)", isDirectory: true)
        for name in ["events", "computer-history", "memories"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    func testCurrentMemoryLookupIsDirectAndIgnoresUnrelatedEntries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoryDirectory = root.appendingPathComponent("computer-history", isDirectory: true)
        let eventDirectory = root.appendingPathComponent("events", isDirectory: true)
        // More entries than the directory enumeration allows: a direct lookup must not care.
        for index in 0..<(4_096 + 100) {
            let name = String(format: "1999-01-%05d", index)
            try Data("{}".utf8).write(to: memoryDirectory.appendingPathComponent("\(name).computer-history.json"))
        }
        try FileManager.default.createSymbolicLink(
            atPath: eventDirectory.appendingPathComponent("1998-01-01.jsonl").path,
            withDestinationPath: "/dev/null"
        )
        let load = HistoryLocalStoreReader(rootDirectory: root).loadCurrentComputerHistoryMemory(day: fixtureStart)
        XCTAssertEqual(load.state, .absent)
        XCTAssertTrue(load.issues.isEmpty)
    }

    func testCurrentMemoryLookupStillRejectsASymlinkedDayFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "2027-01-15"
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("computer-history/\(key).computer-history.json").path,
            withDestinationPath: "/dev/null"
        )
        try Data().write(to: root.appendingPathComponent("events/\(key).jsonl"))
        let load = HistoryLocalStoreReader(rootDirectory: root).loadCurrentComputerHistoryMemory(day: fixtureStart)
        XCTAssertEqual(load.state, .inaccessible)
        XCTAssertNil(load.memory)
    }

    func testOversizedMemoryFileIsRejectedWithAnIssueInsteadOfBeingRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("memories/2027-01-15.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(17 * 1_024 * 1_024))
        try handle.close()
        let reader = HistoryLocalStoreReader(rootDirectory: root)
        for loaded in [reader.load(), reader.loadMemories()] {
            XCTAssertTrue(loaded.memories.isEmpty)
            XCTAssertTrue(loaded.issues.contains { $0.path.hasSuffix("memories/2027-01-15.json") })
        }
    }
}
