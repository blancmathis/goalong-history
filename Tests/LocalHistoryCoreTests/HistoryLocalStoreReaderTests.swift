import XCTest
@testable import LocalHistoryCore

final class HistoryLocalStoreReaderTests: XCTestCase {
    func testReaderLoadsSeparateDataAndSurfacesMalformedRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = root.appendingPathComponent("events", isDirectory: true)
        let memories = root.appendingPathComponent("memories", isDirectory: true)
        let semantic = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: semantic, withIntermediateDirectories: true)

        let payload = fixtureSemanticPayload()
        let event = fixtureEvent(
            id: "semantic-event",
            sequence: 1,
            offset: 0,
            kind: .semanticSnapshot,
            semanticContext: payload.reference
        )
        let memory = try DeterministicActivitySummarizer().summarize(
            ActivitySummaryInput(events: [event], semanticSnapshots: [payload.id: payload])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        var eventData = try encoder.encode(event)
        eventData.append(0x0A)
        eventData.append(Data("not-json\n".utf8))
        try eventData.write(to: events.appendingPathComponent("2027-01-15.jsonl"))
        try encoder.encode(memory).write(to: memories.appendingPathComponent("2027-01-15.memory.json"))
        var semanticData = try encoder.encode(payload)
        semanticData.append(0x0A)
        try semanticData.write(to: semantic.appendingPathComponent("2027-01-15.jsonl"))

        let health = fixtureHealth(callback: fixtureStart)
        try encoder.encode(health).write(to: root.appendingPathComponent("capture-health.json"))

        let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
        XCTAssertEqual(loaded.events.map(\.id), ["semantic-event"])
        XCTAssertEqual(loaded.memories.map(\.id), [memory.id])
        XCTAssertEqual(loaded.semanticSnapshots[payload.id], payload)
        XCTAssertEqual(loaded.captureHealth, health)
        XCTAssertEqual(loaded.issues.count, 1)
        XCTAssertEqual(loaded.issues.first?.line, 2)
    }
}
