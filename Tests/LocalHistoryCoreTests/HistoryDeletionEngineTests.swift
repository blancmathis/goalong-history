import Foundation
import XCTest
@testable import LocalHistoryCore

final class HistoryDeletionEngineTests: XCTestCase {
    private var root: URL!
    private var eventsDirectory: URL!
    private var semanticDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDeletionEngineTests-\(UUID().uuidString)", isDirectory: true)
        eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testIntervalDeletionExpandsToTheWholeCausalInteractionAndSemanticPayloads() throws {
        let day = date("2026-08-23T09:59:59Z")
        let interactionID = "interaction-save"
        let before = payload(
            id: "before-payload",
            at: day,
            text: "Draft before save"
        )
        let settled = payload(
            id: "settled-payload",
            at: day.addingTimeInterval(2),
            text: "Saved successfully"
        )
        let unrelated = payload(
            id: "unrelated-payload",
            at: day.addingTimeInterval(60),
            text: "Unrelated work"
        )

        try writeEvents([
            event(
                id: "before-event",
                at: day,
                kind: .semanticSnapshot,
                interactionID: interactionID,
                semantic: before.reference
            ),
            event(
                id: "action-event",
                at: day.addingTimeInterval(1),
                kind: .mouseClick,
                interactionID: interactionID
            ),
            event(
                id: "settled-event",
                at: day.addingTimeInterval(2),
                kind: .semanticSnapshot,
                interactionID: interactionID,
                semantic: settled.reference
            ),
            event(
                id: "unrelated-event",
                at: day.addingTimeInterval(60),
                kind: .mouseClick,
                interactionID: "unrelated"
            ),
        ])
        try writePayloads([before, settled, unrelated])

        let request = HistoryDeletionRequest(
            scope: .interval,
            start: day.addingTimeInterval(1),
            end: day.addingTimeInterval(1)
        )
        let eventResult = try HistoryJSONLDeletionEngine.deleteEvents(
            in: eventsDirectory,
            request: request,
            calendar: utcCalendar
        )
        let semanticResult = try HistoryJSONLDeletionEngine.deleteSemanticSnapshots(
            in: semanticDirectory,
            request: request,
            additionallyDeleting: eventResult.referencedSemanticSnapshotIDs,
            calendar: utcCalendar
        )

        XCTAssertEqual(eventResult.deletedEventCount, 3)
        XCTAssertEqual(
            Set(eventResult.deletedEventIDs),
            Set(["before-event", "action-event", "settled-event"])
        )
        XCTAssertEqual(
            Set(eventResult.referencedSemanticSnapshotIDs),
            Set(["before-payload", "settled-payload"])
        )
        XCTAssertEqual(semanticResult.deletedSnapshotCount, 2)
        XCTAssertEqual(try remainingEventIDs(), ["unrelated-event"])
        XCTAssertEqual(try remainingPayloadIDs(), ["unrelated-payload"])
    }

    func testTimelineEntryDeletionRemovesEveryEventWithTheSameInteractionID() throws {
        let start = date("2026-08-23T11:00:00Z")
        try writeEvents([
            event(
                id: "before",
                at: start,
                kind: .semanticSnapshot,
                interactionID: "shared"
            ),
            event(
                id: "action",
                at: start.addingTimeInterval(1),
                kind: .keyboardShortcut,
                interactionID: "shared"
            ),
            event(
                id: "after",
                at: start.addingTimeInterval(2),
                kind: .semanticSnapshot,
                interactionID: "shared"
            ),
            event(
                id: "keep",
                at: start.addingTimeInterval(3),
                kind: .mouseClick,
                interactionID: "other"
            ),
        ])

        let result = try HistoryJSONLDeletionEngine.deleteEvents(
            in: eventsDirectory,
            request: HistoryDeletionRequest(
                scope: .timelineEntry,
                timelineEntryID: "action"
            ),
            calendar: utcCalendar
        )

        XCTAssertEqual(result.deletedEventCount, 3)
        XCTAssertEqual(try remainingEventIDs(), ["keep"])
    }

    func testMissingTimelineEntryFailsInsteadOfReportingSuccess() throws {
        try writeEvents([
            event(
                id: "keep",
                at: date("2026-08-23T12:00:00Z"),
                kind: .mouseClick,
                interactionID: "keep"
            )
        ])

        XCTAssertThrowsError(
            try HistoryJSONLDeletionEngine.deleteEvents(
                in: eventsDirectory,
                request: HistoryDeletionRequest(
                    scope: .timelineEntry,
                    timelineEntryID: "missing"
                ),
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(
                error as? HistoryDeletionExecutionError,
                .timelineEntryNotFound("missing")
            )
        }
        XCTAssertEqual(try remainingEventIDs(), ["keep"])
    }

    func testPartialDeletionRefusesUndecodableRowsWithoutMutatingTheFile() throws {
        let file = eventsDirectory.appendingPathComponent("2026-08-23.jsonl")
        let valid = try encode(
            event(
                id: "valid",
                at: date("2026-08-23T13:00:00Z"),
                kind: .mouseClick,
                interactionID: "valid"
            )
        )
        var data = Data()
        data.append(valid)
        data.append(0x0A)
        data.append(Data("{not-json}\n".utf8))
        try data.write(to: file)
        let original = try Data(contentsOf: file)

        XCTAssertThrowsError(
            try HistoryJSONLDeletionEngine.deleteEvents(
                in: eventsDirectory,
                request: HistoryDeletionRequest(
                    scope: .interval,
                    start: date("2026-08-23T12:59:00Z"),
                    end: date("2026-08-23T13:01:00Z")
                ),
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(
                error as? HistoryDeletionExecutionError,
                .undecodableEvent(path: file.path, line: 2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testWholeDetailedStoreDeletionRemovesUndecodableRowsToo() throws {
        let file = eventsDirectory.appendingPathComponent("2026-08-23.jsonl")
        try Data("{not-json}\n".utf8).write(to: file)
        let semanticFile = semanticDirectory.appendingPathComponent("2026-08-23.semantic.jsonl")
        try Data("{also-not-json}\n".utf8).write(to: semanticFile)
        let request = HistoryDeletionRequest(scope: .allDetailedData)

        let events = try HistoryJSONLDeletionEngine.deleteEvents(
            in: eventsDirectory,
            request: request,
            calendar: utcCalendar
        )
        let semantic = try HistoryJSONLDeletionEngine.deleteSemanticSnapshots(
            in: semanticDirectory,
            request: request,
            calendar: utcCalendar
        )

        XCTAssertEqual(events.deletedEventCount, 1)
        XCTAssertEqual(semantic.deletedSnapshotCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: semanticFile.path))
    }

    private func event(
        id: String,
        at timestamp: Date,
        kind: EventKind,
        interactionID: String,
        semantic: SemanticContextReference? = nil
    ) -> HistoryEvent {
        HistoryEvent(
            schemaVersion: 4,
            id: id,
            sessionID: "deletion-engine-tests",
            timestamp: timestamp,
            kind: kind,
            app: AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            ),
            window: WindowSnapshot(
                title: "Deletion fixture",
                role: "AXWindow",
                subrole: nil
            ),
            element: ElementSnapshot(
                role: "AXButton",
                subrole: nil,
                title: "Save",
                label: "Save",
                identifier: "save",
                isSecure: false
            ),
            pointer: kind == .mouseClick
                ? PointerSnapshot(button: "left", x: 1, y: 2, clickCount: 1)
                : nil,
            semanticContext: semantic,
            metadata: [ComputerHistoryMetadata.interactionID: interactionID],
            integrity: fixtureIntegrity(UInt64(abs(id.hashValue % 10_000) + 1))
        )
    }

    private func payload(
        id: String,
        at timestamp: Date,
        text: String
    ) -> SemanticContextPayload {
        SemanticContextPayload(
            id: id,
            capturedAt: timestamp,
            application: AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            ),
            window: WindowSnapshot(
                title: "Deletion fixture",
                role: "AXWindow",
                subrole: nil
            ),
            url: nil,
            focusedRole: "AXTextArea",
            source: .visibleText,
            text: text,
            contentSHA256: SHA256Digest.hashHex(text),
            redacted: false,
            truncated: false
        )
    }

    private func writeEvents(_ events: [HistoryEvent]) throws {
        let file = eventsDirectory.appendingPathComponent("2026-08-23.jsonl")
        try write(events, to: file)
    }

    private func writePayloads(_ payloads: [SemanticContextPayload]) throws {
        let file = semanticDirectory.appendingPathComponent("2026-08-23.semantic.jsonl")
        try write(payloads, to: file)
    }

    private func write<T: Encodable>(_ values: [T], to URL: URL) throws {
        var data = Data()
        for value in values {
            data.append(try encode(value))
            data.append(0x0A)
        }
        try data.write(to: URL)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func remainingEventIDs() throws -> [String] {
        try decodeAll(HistoryEvent.self, in: eventsDirectory).map(\.id).sorted()
    }

    private func remainingPayloadIDs() throws -> [String] {
        try decodeAll(SemanticContextPayload.self, in: semanticDirectory).map(\.id).sorted()
    }

    private func decodeAll<T: Decodable>(
        _ type: T.Type,
        in directory: URL
    ) throws -> [T] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "jsonl" }
        .flatMap { URL in
            try Data(contentsOf: URL)
                .split(separator: 0x0A)
                .map { try decoder.decode(type, from: Data($0)) }
        }
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }
}
