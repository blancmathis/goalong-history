#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class SemanticContextClearTests: XCTestCase {
        func testCutoffClearStreamsCandidateDaysAndRemovesUnreadableRows() throws {
            let directory = try makeDirectory()
            let store = SemanticContextStore(semanticDirectory: directory, secureInputEnabled: { false })
            let cutoff = date(day: 23, hour: 12)
            let old = directory.appendingPathComponent("2026-08-18.semantic.jsonl")
            let previous = directory.appendingPathComponent("2026-08-22.semantic.jsonl")
            let current = directory.appendingPathComponent("2026-08-23.semantic.jsonl")
            let oldData = try rows([payload("old", date(day: 18, hour: 9))])
            try oldData.write(to: old)
            let previousData = try rows([payload("previous", date(day: 22, hour: 9))])
            try previousData.write(to: previous)
            var currentData = try rows([payload("before", date(day: 23, hour: 9))])
            // A truncated row glued to a valid one, then a valid row and a torn tail.
            currentData.append(Data("{\"id\":\"torn".utf8))
            currentData.append(try rows([payload("after", date(day: 23, hour: 13))]))
            currentData.append(try rows([payload("later", date(day: 23, hour: 14))]))
            currentData.append(Data("{\"id\":\"tail".utf8))
            try currentData.write(to: current)

            XCTAssertEqual(try clear(store, since: cutoff).get(), 1)
            XCTAssertEqual(try ids(in: current), ["before"])
            XCTAssertEqual(try Data(contentsOf: old), oldData)
            XCTAssertEqual(try Data(contentsOf: previous), previousData)
            // The file several days before the cutoff is never read.
            XCTAssertEqual(
                store.deletionMetrics.bytesRead,
                Int64(previousData.count + currentData.count)
            )

            // A retry is idempotent.
            let cleared = try Data(contentsOf: current)
            XCTAssertEqual(try clear(store, since: cutoff).get(), 0)
            XCTAssertEqual(try Data(contentsOf: current), cleared)
        }

        func testCutoffClearRemovesAnOversizedRowWithBoundedMemory() throws {
            let directory = try makeDirectory()
            let store = SemanticContextStore(semanticDirectory: directory, secureInputEnabled: { false })
            let file = directory.appendingPathComponent("2026-08-23.semantic.jsonl")
            var data = try rows([payload("before", date(day: 23, hour: 9))])
            data.append(Data(repeating: UInt8(ascii: "x"), count: SemanticContextStore.maximumSemanticLineBytes + 10))
            data.append(0x0A)
            try data.write(to: file)

            XCTAssertEqual(try clear(store, since: date(day: 23, hour: 12)).get(), 0)
            XCTAssertEqual(try ids(in: file), ["before"])
            XCTAssertLessThanOrEqual(
                store.deletionMetrics.peakBufferedBytes,
                SemanticContextStore.maximumSemanticLineBytes + 2 * SemanticContextStore.deletionReadChunkBytes
            )
        }

        func testOneUnreadableFileDoesNotStopTheOtherFiles() throws {
            let directory = try makeDirectory()
            let store = SemanticContextStore(semanticDirectory: directory, secureInputEnabled: { false })
            let blocked = directory.appendingPathComponent("2026-08-23.semantic.jsonl")
            let next = directory.appendingPathComponent("2026-08-24.semantic.jsonl")
            try rows([payload("blocked", date(day: 23, hour: 13))]).write(to: blocked)
            try rows([payload("next", date(day: 24, hour: 9))]).write(to: next)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }

            XCTAssertThrowsError(try clear(store, since: date(day: 23, hour: 12)).get())
            XCTAssertFalse(FileManager.default.fileExists(atPath: next.path))
        }

        func testAppendCutsATornTailAndKeepsACompleteRowWithoutNewline() throws {
            let directory = try makeDirectory()
            let store = SemanticContextStore(semanticDirectory: directory, secureInputEnabled: { false })
            let now = Date()
            let file = directory.appendingPathComponent(AppPaths.localDayString(for: now) + ".semantic.jsonl")

            var torn = try rows([payload("kept", now.addingTimeInterval(-60))])
            torn.append(Data("{\"id\":\"torn".utf8))
            try torn.write(to: file)
            let first = try append(store, at: now)
            XCTAssertEqual(try ids(in: file), ["kept", first])

            var complete = try rows([payload("kept", now.addingTimeInterval(-60))])
            complete.removeLast()
            try complete.write(to: file)
            let second = try append(store, at: now.addingTimeInterval(1))
            XCTAssertEqual(try ids(in: file), ["kept", second])
            XCTAssertNoThrow(
                try store.preflightSnapshotDeletion(withIDs: ["kept"], on: [now])
            )
        }

        // MARK: - Helpers

        private func makeDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-semantic-clear-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            return directory
        }

        private func clear(_ store: SemanticContextStore, since cutoff: Date) -> Result<Int, Error> {
            let done = expectation(description: "semantic clear")
            var result: Result<Int, Error> = .success(-1)
            store.deleteEvents(since: cutoff) {
                result = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return result
        }

        private func append(_ store: SemanticContextStore, at timestamp: Date) throws -> String {
            try store.append(
                capture: AXRichContextCapture(
                    text: "Visible editor state \(timestamp.timeIntervalSince1970)",
                    source: "visible",
                    redacted: false,
                    truncated: false,
                    fingerprint: "fixture"
                ),
                context: ContextSnapshot(
                    app: AppSnapshot(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 42),
                    window: nil,
                    focusedElement: nil,
                    url: nil,
                    suppressionReason: nil
                ),
                timestamp: timestamp
            ).snapshotID
        }

        private func ids(in file: URL) throws -> [String] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: file)
            XCTAssertEqual(data.last, 0x0A)
            return try data.split(separator: 0x0A).map {
                try decoder.decode(SemanticContextPayload.self, from: Data($0)).id
            }
        }

        private func rows(_ payloads: [SemanticContextPayload]) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for payload in payloads {
                data.append(try encoder.encode(payload))
                data.append(0x0A)
            }
            return data
        }

        private func payload(_ id: String, _ timestamp: Date) -> SemanticContextPayload {
            let text = "semantic clear fixture"
            return SemanticContextPayload(
                id: id,
                capturedAt: timestamp,
                application: AppSnapshot(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 42),
                window: nil,
                url: nil,
                focusedRole: nil,
                source: .visibleText,
                text: text,
                contentSHA256: SHA256Digest.hashHex(text),
                redacted: false,
                truncated: false
            )
        }

        private func date(day: Int, hour: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
        }
    }
#endif
