import XCTest
@testable import LocalHistoryCore

final class HistoryLocalStoreReaderTests: XCTestCase {
    func testFastCanonicalUTCParserMatchesFoundationAndRejectsInvalidDates() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for raw in [
            "1970-01-01T00:00:00.000Z",
            "2000-02-29T23:59:59.123Z",
            "2026-08-29T21:30:00.625Z",
            "2099-12-31T00:00:00.001Z",
        ] {
            let expected = try XCTUnwrap(formatter.date(from: raw))
            let parsed = try XCTUnwrap(FastISO8601DateParser.parseCanonicalUTC(raw))
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)
        }
        let precise = try XCTUnwrap(
            FastISO8601DateParser.parseCanonicalUTC("1970-01-01T00:00:00.123456789Z")
        )
        XCTAssertEqual(precise.timeIntervalSince1970, 0.123456789, accuracy: 0.000_001)
        XCTAssertNil(FastISO8601DateParser.parseCanonicalUTC("2026-02-29T00:00:00Z"))
        XCTAssertNil(FastISO8601DateParser.parseCanonicalUTC("2026-08-29T24:00:00Z"))
        XCTAssertNil(FastISO8601DateParser.parseCanonicalUTC("2026-08-29T21:30:00+02:00"))
    }

    func testCaptureHealthLoadDoesNotDecodeHistoryJournals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-health-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = root.appendingPathComponent("events", isDirectory: true)
        let memories = root.appendingPathComponent("memories", isDirectory: true)
        let semantic = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: semantic, withIntermediateDirectories: true)

        try Data("not-an-event\n".utf8).write(to: events.appendingPathComponent("2027-01-15.jsonl"))
        try Data("not-a-memory".utf8).write(to: memories.appendingPathComponent("2027-01-15.json"))
        try Data("not-a-snapshot\n".utf8).write(to: semantic.appendingPathComponent("2027-01-15.jsonl"))

        let health = fixtureHealth(callback: fixtureStart)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(health).write(to: root.appendingPathComponent("capture-health.json"))

        let loaded = HistoryLocalStoreReader(rootDirectory: root).loadCaptureHealth()
        XCTAssertEqual(loaded.snapshot, health)
        XCTAssertTrue(loaded.issues.isEmpty)
    }

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
