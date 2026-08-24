import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryOversizedRowTests: XCTestCase {
    func testSelectedDayRejectsWholeProjectionForOversizedEventAndStaysReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-computer-history-selected-day-oversized-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let first = fixtureEvent(
            id: "selected-day-before-oversized",
            sequence: 1,
            offset: 1,
            kind: .applicationActivated
        )
        let last = fixtureEvent(
            id: "selected-day-after-oversized",
            sequence: 2,
            offset: 2,
            kind: .mouseClick,
            pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
        )
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.write(contentsOf: try encoder.encode(first))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.write(
            contentsOf: Data(
                repeating: 0x78,
                count: HistoryJSONLinesStreamReader.defaultMaximumLineBytes + 1
            )
        )
        try handle.write(contentsOf: Data([0x0A]))
        try handle.write(contentsOf: try encoder.encode(last))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        let sourceBytesBefore = try Data(contentsOf: sourceURL)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd
            )

        XCTAssertEqual(loaded.events, [])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.metrics.rawEventCount, 1)
        XCTAssertEqual(loaded.metrics.retainedEventCount, 0)
        XCTAssertEqual(loaded.metrics.retainedEventBytes, 0)
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(loaded.metrics.sourceChangedDuringRead)
        XCTAssertLessThanOrEqual(
            loaded.metrics.peakStreamBufferBytes,
            HistoryJSONLinesStreamReader.defaultMaximumLineBytes
                + HistoryJSONLinesStreamReader.defaultChunkSize
        )
        XCTAssertEqual(loaded.issues.count, 1)
        XCTAssertEqual(loaded.issues.first?.line, 2)
        XCTAssertTrue(
            loaded.issues.first?.message.contains("source content was incomplete") == true
        )
        XCTAssertTrue(
            loaded.issues.first?.message.contains("day projection was rejected") == true
        )
        XCTAssertTrue(
            loaded.issues.first?.message.contains(
                "row exceeds the \(HistoryJSONLinesStreamReader.defaultMaximumLineBytes)-byte safety limit"
            ) == true
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytesBefore)
    }
}
