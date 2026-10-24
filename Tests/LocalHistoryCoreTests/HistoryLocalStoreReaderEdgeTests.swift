import Foundation
import XCTest

@testable import LocalHistoryCore

final class HistoryLocalStoreReaderEdgeTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-reader-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func testMissingCaptureHealthIsNeitherASnapshotNorAnIssue() throws {
        let load = HistoryLocalStoreReader(rootDirectory: try makeRoot()).loadCaptureHealth()
        XCTAssertNil(load.snapshot)
        XCTAssertTrue(load.issues.isEmpty)
    }

    func testUndecodableCaptureHealthSurfacesAnIssueInsteadOfASnapshot() throws {
        let root = try makeRoot()
        try Data("{\"not\":\"health\"}".utf8).write(to: root.appendingPathComponent("capture-health.json"))
        let load = HistoryLocalStoreReader(rootDirectory: root).loadCaptureHealth()
        XCTAssertNil(load.snapshot)
        XCTAssertEqual(load.issues.count, 1)
        XCTAssertTrue(load.issues[0].message.hasPrefix("Could not decode capture health"))
        XCTAssertTrue(load.issues[0].path.hasSuffix("capture-health.json"))
    }

    func testOversizedCaptureHealthIsRejectedWithoutDecoding() throws {
        let root = try makeRoot()
        let padding = Data(repeating: 0x20, count: 1_024 * 1_024 + 16)
        var payload = try encoder.encode(fixtureHealth(callback: fixtureStart))
        payload.append(padding)
        try payload.write(to: root.appendingPathComponent("capture-health.json"))
        let load = HistoryLocalStoreReader(rootDirectory: root).loadCaptureHealth()
        XCTAssertNil(load.snapshot)
        XCTAssertEqual(load.issues.count, 1)
        XCTAssertTrue(load.issues[0].message.contains("exceeds the 1048576-byte safety limit"), load.issues[0].message)
    }

    func testMemoryFileIssuesReadAsSentencesWithoutSwiftDumps() throws {
        let reader = HistoryLocalStoreReader(rootDirectory: try makeRoot())
        let memories = reader.memoriesDirectory
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 16 * 1_024 * 1_024 + 1).write(to: memories.appendingPathComponent("huge.json"))
        try Data("{\"truncated".utf8).write(to: memories.appendingPathComponent("broken.json"))
        let messages = reader.loadMemories().issues.map(\.message)
        XCTAssertEqual(messages.count, 2, "\(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("Could not decode JSON file: file exceeds the") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains("exceedsLimit(") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("The data is not readable") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains("DecodingError") || $0.contains("dataCorrupted") }, "\(messages)")
    }

    func testPresenceTimestampsKeepInputsAndBackdateIdleHeartbeatsInOrder() throws {
        let root = try makeRoot()
        let events = try makeDirectory("events", in: root)
        let rows: [HistoryEvent] = [
            fixtureEvent(
                id: "p-heartbeat", sequence: 1, offset: 300, kind: .heartbeat,
                metadata: ["idle_seconds": "120"]),
            fixtureEvent(
                id: "p-click", sequence: 2, offset: 100, kind: .mouseClick,
                pointer: PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1)),
            fixtureEvent(
                id: "p-negative-idle", sequence: 3, offset: 400, kind: .heartbeat,
                metadata: ["idle_seconds": "-5"]),
            fixtureEvent(
                id: "p-bad-idle", sequence: 4, offset: 410, kind: .heartbeat,
                metadata: ["idle_seconds": "soon"]),
            fixtureEvent(id: "p-plain", sequence: 5, offset: 420, kind: .heartbeat),
            fixtureEvent(
                id: "p-scroll", sequence: 6, offset: 500, kind: .scrollBurst,
                scroll: ScrollSnapshot(deltaX: 0, deltaY: -3, eventCount: 2)),
        ]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        try data.write(to: events.appendingPathComponent("2027-01-15.jsonl"))

        let times = HistoryLocalStoreReader(rootDirectory: root).loadPresenceTimestamps(
            start: fixtureStart, end: fixtureStart.addingTimeInterval(3_600))
        XCTAssertEqual(
            times,
            [
                fixtureStart.addingTimeInterval(100),
                fixtureStart.addingTimeInterval(180),
                fixtureStart.addingTimeInterval(500),
            ])
    }

    func testPresenceTimestampsAreEmptyWithoutAJournal() throws {
        let times = HistoryLocalStoreReader(rootDirectory: try makeRoot()).loadPresenceTimestamps(
            start: fixtureStart, end: fixtureStart.addingTimeInterval(60))
        XCTAssertTrue(times.isEmpty)
    }

    func testCurrentComputerHistoryMemoryIsAbsentWhenNoIndexExists() throws {
        let root = try makeRoot()
        _ = try makeDirectory("events", in: root)
        _ = try makeDirectory("computer-history", in: root)
        let load = HistoryLocalStoreReader(rootDirectory: root)
            .loadCurrentComputerHistoryMemory(day: fixtureStart)
        XCTAssertEqual(load.state, .absent)
        XCTAssertNil(load.memory)
        XCTAssertEqual(load.bytesRead, 0)
        XCTAssertTrue(load.issues.isEmpty)
    }

    func testCurrentComputerHistoryMemoryRejectsAnIndexMissingEpisodeShells() throws {
        let root = try makeRoot()
        let events = try makeDirectory("events", in: root)
        let memories = try makeDirectory("computer-history", in: root)
        let rows = [
            fixtureEvent(id: "m-app", sequence: 1, offset: 1, kind: .applicationActivated),
            fixtureEvent(
                id: "m-click", sequence: 2, offset: 2, kind: .mouseClick,
                pointer: PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1)),
        ]
        var journal = Data()
        for row in rows {
            journal.append(try encoder.encode(row))
            journal.append(0x0A)
        }
        try journal.write(to: events.appendingPathComponent("2027-01-15.jsonl"))
        let memory = ComputerHistoryEngine.analyze(
            events: rows, day: fixtureStart, generatedAt: Date().addingTimeInterval(60))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(memory)) as? [String: Any])
        var coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        coverage["episodeCount"] = (coverage["episodeCount"] as? Int ?? 0) + 3
        object["coverage"] = coverage
        try JSONSerialization.data(withJSONObject: object).write(
            to: memories.appendingPathComponent("2027-01-15.computer-history.json"))

        let load = HistoryLocalStoreReader(rootDirectory: root)
            .loadCurrentComputerHistoryMemory(day: fixtureStart)
        XCTAssertEqual(load.state, .incompleteProjection)
        XCTAssertNil(load.memory)
    }

    func testCurrentComputerHistoryMemoryIsInaccessibleWhenTheIndexIsGarbage() throws {
        let root = try makeRoot()
        let events = try makeDirectory("events", in: root)
        let memories = try makeDirectory("computer-history", in: root)
        try Data("{}\n".utf8).write(to: events.appendingPathComponent("2027-01-15.jsonl"))
        try Data("garbage".utf8).write(
            to: memories.appendingPathComponent("2027-01-15.computer-history.json"))
        let load = HistoryLocalStoreReader(rootDirectory: root)
            .loadCurrentComputerHistoryMemory(day: fixtureStart)
        XCTAssertEqual(load.state, .inaccessible)
        XCTAssertNil(load.memory)
        XCTAssertEqual(load.issues.count, 1)
        XCTAssertTrue(load.issues[0].message.contains("authoritative journal must be read instead"))
    }
}
