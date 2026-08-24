import Darwin
import Foundation
import XCTest

@testable import LocalHistoryCore

final class HistoryLocalStoreReaderStreamingTests: XCTestCase {
    func testProductionComputerHistoryEvidenceBudgetIsSixtyFourMiB() {
        XCTAssertEqual(
            ComputerHistoryEvidenceLoadLimits.production.maximumRetainedBytes,
            64 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ComputerHistoryEvidenceLoadLimits.production.maximumRetainedRows,
            32_768
        )
    }

    func testTransientComputerHistoryProjectionPreservesExactComputerHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-computer-history-integrity-compaction-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let commitments = (0..<64).map { index in
            LocalFieldCommitment(
                name: "field-\(index)",
                commitmentHex: String(repeating: "a", count: 64),
                opening: CommitmentOpening(
                    domain: "event-field:field-\(index)",
                    fields: ["value": String(repeating: "x", count: 192)],
                    saltBase64: Data(repeating: UInt8(index), count: 32).base64EncodedString()
                )
            )
        }
        let fullEvents = [
            fixtureEvent(
                id: "compact-app",
                sequence: 1,
                offset: 1,
                kind: .applicationActivated
            ),
            fixtureEvent(
                id: "compact-click",
                sequence: 2,
                offset: 2,
                kind: .mouseClick,
                pointer: PointerSnapshot(button: "left", x: 20, y: 30, clickCount: 1)
            ),
            fixtureEvent(
                id: "compact-gap",
                sequence: 3,
                offset: 3,
                kind: .captureSuppressed,
                suppression: .manualPause
            ),
        ].map { event in
            let integrity = try! XCTUnwrap(event.integrity)
            return event.replacingIntegrity(
                EventIntegrity(
                    sequence: integrity.sequence,
                    previousEventHash: integrity.previousEventHash,
                    eventRoot: integrity.eventRoot,
                    eventHash: integrity.eventHash,
                    fieldCommitments: commitments
                )
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines(
            fullEvents,
            encoder: encoder,
            to: sourceURL
        )
        let sourceBytesBefore = try Data(contentsOf: sourceURL)

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let loaded = HistoryLocalStoreReader(rootDirectory: root).loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd
        )

        XCTAssertEqual(loaded.events.count, fullEvents.count)
        for (full, compact) in zip(fullEvents, loaded.events) {
            XCTAssertEqual(compact.id, full.id)
            XCTAssertEqual(compact.sessionID, "")
            XCTAssertNil(compact.inputOrigin)
            XCTAssertNil(compact.classification)
            XCTAssertEqual(compact.integrity?.sequence, full.integrity?.sequence)
            XCTAssertEqual(compact.integrity?.eventHash, full.integrity?.eventHash)
            XCTAssertEqual(compact.integrity?.previousEventHash, "")
            XCTAssertEqual(compact.integrity?.eventRoot, "")
            XCTAssertEqual(compact.integrity?.fieldCommitments, [])
        }

        let generatedAt = fixtureStart.addingTimeInterval(80_000)
        let expected = ComputerHistoryEngine.analyze(
            events: fullEvents,
            day: dayStart,
            calendar: calendar,
            generatedAt: generatedAt
        )
        let actual = ComputerHistoryEngine.analyze(
            events: loaded.events,
            day: dayStart,
            calendar: calendar,
            sourceJournalSummary: loaded.sourceJournalSummary,
            generatedAt: generatedAt
        )
        XCTAssertEqual(actual, expected)

        let fullEncodedBytes = try fullEvents.reduce(into: 0) { total, event in
            total += try encoder.encode(event).count
        }
        let compactEncodedBytes = try loaded.events.reduce(into: 0) { total, event in
            total += try encoder.encode(event).count
        }
        XCTAssertLessThan(compactEncodedBytes * 5, fullEncodedBytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytesBefore)
        print(
            "ComputerHistory transient_event_bytes full=\(fullEncodedBytes) "
                + "compact=\(compactEncodedBytes)"
        )
    }

    func testComputerHistoryEvidenceStreamMatchesFullJournalAnalysis() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-computer-history-stream-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: semanticDirectory, withIntermediateDirectories: true)

        let semantic = fixtureSemanticPayload(
            id: "streamed-context",
            text: "User: verify the streaming Computer History result"
        )
        let unreferencedSemantic = fixtureSemanticPayload(
            id: "unreferenced-context",
            text: "This payload is not referenced by any retained event"
        )
        let evidence = [
            fixtureEvent(
                id: "semantic-before",
                sequence: 10,
                offset: 15,
                kind: .semanticSnapshot,
                metadata: [
                    ComputerHistoryMetadata.interactionID: "stream-interaction",
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ],
                semanticContext: semantic.reference
            ),
            fixtureEvent(
                id: "stream-click",
                sequence: 11,
                offset: 16,
                kind: .mouseClick,
                metadata: [ComputerHistoryMetadata.interactionID: "stream-interaction"],
                semanticContext: semantic.reference,
                pointer: PointerSnapshot(button: "left", x: 20, y: 30, clickCount: 1)
            ),
            fixtureEvent(
                id: "stream-gap",
                sequence: 12,
                offset: 17,
                kind: .captureSuppressed,
                suppression: .manualPause
            ),
        ]
        let maintenance = (0..<500).map { index in
            fixtureEvent(
                id: "agent-index-\(index)",
                sequence: UInt64(100 + index),
                offset: TimeInterval(30 + index),
                kind: .agentArtifactCaptured,
                message: "Indexed an original transcript source without copying its contents"
            )
        }
        let allEvents = evidence + maintenance
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try writeJSONLines(
            allEvents,
            encoder: encoder,
            to: eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        )
        try writeJSONLines(
            [semantic, unreferencedSemantic],
            encoder: encoder,
            to: semanticDirectory.appendingPathComponent("2027-01-15.semantic.jsonl")
        )

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let streamed = HistoryLocalStoreReader(rootDirectory: root).loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd
        )
        let generatedAt = fixtureStart.addingTimeInterval(80_000)
        let baseline = ComputerHistoryEngine.analyze(
            events: allEvents,
            semanticSnapshots: [
                semantic.id: semantic,
                unreferencedSemantic.id: unreferencedSemantic,
            ],
            day: dayStart,
            calendar: calendar,
            generatedAt: generatedAt
        )
        let filtered = ComputerHistoryEngine.analyze(
            events: streamed.events,
            semanticSnapshots: streamed.semanticSnapshots,
            day: dayStart,
            calendar: calendar,
            sourceJournalSummary: streamed.sourceJournalSummary,
            generatedAt: generatedAt
        )

        XCTAssertEqual(filtered, baseline)
        XCTAssertEqual(streamed.metrics.rawEventCount, allEvents.count)
        XCTAssertEqual(streamed.metrics.retainedEventCount, evidence.count)
        XCTAssertEqual(streamed.events.map(\.id), evidence.map(\.id))
        XCTAssertEqual(streamed.semanticSnapshots, [semantic.id: semantic])
        XCTAssertEqual(streamed.metrics.semanticRowsVisited, 2)
        XCTAssertEqual(streamed.metrics.retainedSemanticSnapshotCount, 1)
        XCTAssertGreaterThan(
            streamed.metrics.semanticBytesRead,
            streamed.metrics.retainedSemanticSnapshotBytes
        )
        XCTAssertEqual(streamed.sourceJournalSummary.eventCount, allEvents.count)
        XCTAssertEqual(streamed.sourceJournalSummary.continuityBoundaryCount, 1)
        XCTAssertEqual(streamed.sourceJournalSummary.firstSourceSequence, 10)
        XCTAssertEqual(streamed.sourceJournalSummary.lastSourceSequence, UInt64(599))
        XCTAssertEqual(streamed.sourceJournalSummary.lastSourceEventHash, "hash-599")
        XCTAssertEqual(streamed.issues, [])
    }

    func testComputerHistoryEvidenceStreamKeepsLargeMaintenanceJournalWorkingSetSmall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-computer-history-stream-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let file = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let maintenanceCount = 20_000
        let maintenanceMessage = String(repeating: "source-index-metadata ", count: 64)
        let evidence = [
            fixtureEvent(
                id: "large-stream-app",
                sequence: 1,
                offset: 1,
                kind: .applicationActivated
            ),
            fixtureEvent(
                id: "large-stream-click",
                sequence: 2,
                offset: 2,
                kind: .mouseClick,
                pointer: PointerSnapshot(button: "left", x: 42, y: 24, clickCount: 1)
            ),
        ]
        let handle = try FileHandle(forWritingTo: file)
        var buffer = Data()
        buffer.reserveCapacity(256 * 1_024)

        func append(_ event: HistoryEvent) throws {
            buffer.append(try encoder.encode(event))
            buffer.append(0x0A)
            if buffer.count >= 256 * 1_024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        for event in evidence { try append(event) }
        for index in 0..<maintenanceCount {
            try append(
                fixtureEvent(
                    id: "large-stream-maintenance-\(index)",
                    sequence: UInt64(index + 3),
                    offset: TimeInterval(index + 3),
                    kind: .agentArtifactCaptured,
                    message: maintenanceMessage
                )
            )
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let streamed = HistoryLocalStoreReader(rootDirectory: root).loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd
        )
        let expected = ComputerHistoryEngine.analyze(
            events: evidence,
            day: dayStart,
            calendar: calendar,
            sourceJournalSummary: ComputerHistorySourceJournalSummary(
                eventCount: maintenanceCount + evidence.count,
                continuityBoundaryCount: 0,
                firstSourceSequence: 1,
                lastSourceSequence: UInt64(maintenanceCount + 2),
                lastSourceEventHash: "hash-\(maintenanceCount + 2)"
            ),
            generatedAt: fixtureStart.addingTimeInterval(80_000)
        )
        let actual = ComputerHistoryEngine.analyze(
            events: streamed.events,
            semanticSnapshots: streamed.semanticSnapshots,
            day: dayStart,
            calendar: calendar,
            sourceJournalSummary: streamed.sourceJournalSummary,
            generatedAt: fixtureStart.addingTimeInterval(80_000)
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(streamed.metrics.rawEventCount, maintenanceCount + evidence.count)
        XCTAssertEqual(streamed.metrics.retainedEventCount, evidence.count)
        XCTAssertEqual(streamed.events.map(\.id), evidence.map(\.id))
        XCTAssertFalse(streamed.events.contains { $0.kind == .agentArtifactCaptured })
        XCTAssertGreaterThan(streamed.metrics.eventBytesRead, 20 * 1_024 * 1_024)
        XCTAssertLessThan(streamed.metrics.retainedEventBytes, 16 * 1_024)
        XCTAssertLessThan(streamed.metrics.peakStreamBufferBytes, 256 * 1_024)
        XCTAssertEqual(streamed.metrics.semanticBytesRead, 0)
        XCTAssertEqual(streamed.metrics.retainedSemanticSnapshotBytes, 0)
        XCTAssertEqual(streamed.issues, [])
    }

    func testComputerHistoryEvidenceLoaderHonorsCallerCancellationWithoutScanningTheDay()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-computer-history-cancelled-load-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        let events = (0..<1_000).map { index in
            fixtureEvent(
                id: "cancelled-load-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index),
                kind: .windowChanged,
                message: String(repeating: "bounded cancellation row ", count: 10)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines(events, encoder: encoder, to: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        var continuationChecks = 0
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )

        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                shouldContinue: {
                    continuationChecks += 1
                    return continuationChecks < 3
                }
            )

        XCTAssertTrue(loaded.metrics.wasCancelled)
        XCTAssertLessThan(loaded.metrics.eventBytesRead, Int64(sourceBytes.count))
        XCTAssertTrue(
            loaded.issues.contains {
                $0.message.contains("caller's time budget")
            }
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testLargeJSONLUsesBoundedBufferAndPreservesUnicodeFinalRowAndOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-streaming-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let file = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let rowCount = 6_000
        let unicodeMessage = "Café déjà vu — 東京 — 🧠 " + String(repeating: "mémoire-légère ", count: 40)
        let handle = try FileHandle(forWritingTo: file)
        var writeBuffer = Data()
        writeBuffer.reserveCapacity(256 * 1_024)
        var largestEncodedRow = 0

        for index in 0..<rowCount {
            let event = fixtureEvent(
                id: "stream-event-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index),
                kind: .diagnostic,
                message: index == rowCount - 1 ? unicodeMessage : String(repeating: "x", count: 640)
            )
            let encoded = try encoder.encode(event)
            largestEncodedRow = max(largestEncodedRow, encoded.count)
            writeBuffer.append(encoded)
            if index != rowCount - 1 {
                writeBuffer.append(0x0A)
            }
            if writeBuffer.count >= 256 * 1_024 {
                try handle.write(contentsOf: writeBuffer)
                writeBuffer.removeAll(keepingCapacity: true)
            }
        }
        if !writeBuffer.isEmpty {
            try handle.write(contentsOf: writeBuffer)
        }
        try handle.close()

        let streamReader = HistoryJSONLinesStreamReader()
        var streamedRows = 0
        var oversizedRows: [Int] = []
        let metrics = try streamReader.read(
            file: file,
            onLine: { _, _ in streamedRows += 1 },
            onOversizedLine: { line, _ in oversizedRows.append(line) }
        )
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        ).int64Value

        XCTAssertEqual(streamedRows, rowCount)
        XCTAssertEqual(oversizedRows, [])
        XCTAssertEqual(metrics.bytesRead, fileSize)
        XCTAssertEqual(metrics.rowsVisited, rowCount)
        XCTAssertEqual(metrics.oversizedRows, 0)
        XCTAssertGreaterThan(fileSize, 5 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(
            metrics.peakBufferedBytes,
            largestEncodedRow + HistoryJSONLinesStreamReader.defaultChunkSize
        )
        XCTAssertLessThan(Int64(metrics.peakBufferedBytes) * 50, fileSize)

        let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
        XCTAssertEqual(loaded.issues, [])
        XCTAssertEqual(loaded.events.count, rowCount)
        XCTAssertEqual(
            loaded.events.map(\.id),
            (0..<rowCount).map { "stream-event-\($0)" }
        )
        XCTAssertEqual(loaded.events.last?.message, unicodeMessage)
    }

    func testOversizedRowIsReportedWithoutRetainingItAndScanningContinues() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-streaming-oversized-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data(("first\n" + String(repeating: "x", count: 4_096) + "\nlast").utf8)
        try payload.write(to: file)

        let reader = HistoryJSONLinesStreamReader(chunkSize: 31, maximumLineBytes: 128)
        var lines: [String] = []
        var oversized: [(line: Int, limit: Int)] = []
        let metrics = try reader.read(
            file: file,
            onLine: { data, _ in lines.append(String(decoding: data, as: UTF8.self)) },
            onOversizedLine: { line, limit in oversized.append((line, limit)) }
        )

        XCTAssertEqual(lines, ["first", "last"])
        XCTAssertEqual(oversized.map { $0.line }, [2])
        XCTAssertEqual(oversized.map { $0.limit }, [128])
        XCTAssertEqual(metrics.rowsVisited, 3)
        XCTAssertEqual(metrics.oversizedRows, 1)
        XCTAssertLessThanOrEqual(metrics.peakBufferedBytes, 128 + 31)
    }

    func testStreamingReaderReportsAnAppendDuringThePinnedRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-reader-live-append-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let file = root.appendingPathComponent("live.jsonl")
        try Data("first\n".utf8).write(to: file)

        var appended = false
        var lines: [String] = []
        let metrics = try HistoryJSONLinesStreamReader(chunkSize: 4).read(
            file: file,
            onLine: { line, _ in
                lines.append(String(decoding: line, as: UTF8.self))
                guard !appended else { return }
                appended = true
                let writer = try! FileHandle(forWritingTo: file)
                try! writer.seekToEnd()
                try! writer.write(contentsOf: Data("second\n".utf8))
                try! writer.close()
            },
            onOversizedLine: { _, _ in }
        )

        XCTAssertTrue(appended)
        XCTAssertTrue(metrics.sourceChangedDuringRead)
        XCTAssertEqual(lines, ["first"])
    }

    func testComputerHistoryEvidenceRejectsAnAtomicallyReplacedSourceDay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-evidence-live-append-\(UUID().uuidString)",
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
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        var initialEvents: [HistoryEvent] = []
        initialEvents.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let pointer = PointerSnapshot(
                button: "left",
                x: Double(index % 500),
                y: Double(index % 300),
                clickCount: 1
            )
            initialEvents.append(
                fixtureEvent(
                    id: "stable-view-event-\(index)",
                    sequence: UInt64(index + 1),
                    offset: TimeInterval(index + 1),
                    kind: .mouseClick,
                    pointer: pointer
                )
            )
        }
        try writeJSONLines(initialEvents, encoder: encoder, to: sourceURL)

        let replacementEvent = fixtureEvent(
            id: "event-in-atomic-replacement",
            sequence: 1_001,
            offset: 1_001,
            kind: .mouseClick,
            pointer: PointerSnapshot(button: "left", x: 42, y: 24, clickCount: 1)
        )
        var replacementData = try encoder.encode(replacementEvent)
        replacementData.append(0x0A)
        let replacementURL = eventsDirectory.appendingPathComponent("replacement.tmp")
        try replacementData.write(to: replacementURL)
        var continuationChecks = 0
        var replaced = false
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )

        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                shouldContinue: {
                    continuationChecks += 1
                    guard continuationChecks == 2 else { return true }
                    let result = replacementURL.path.withCString { replacementPath in
                        sourceURL.path.withCString { sourcePath in
                            Darwin.rename(replacementPath, sourcePath)
                        }
                    }
                    XCTAssertEqual(result, 0, "Could not atomically replace pinned fixture")
                    replaced = result == 0
                    return result == 0
                }
            )

        XCTAssertTrue(replaced)
        XCTAssertTrue(loaded.metrics.sourceChangedDuringRead)
        XCTAssertFalse(loaded.metrics.wasCancelled)
        XCTAssertGreaterThan(loaded.metrics.eventBytesRead, 0)
        XCTAssertEqual(loaded.metrics.retainedEventCount, 0)
        XCTAssertEqual(loaded.metrics.retainedEventBytes, 0)
        XCTAssertEqual(loaded.events, [])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            loaded.issues.contains {
                $0.message.contains("source changed during read")
                    && $0.message.contains("day projection was rejected")
            }
        )
    }

    func testComputerHistoryEvidenceRejectsEventsAndSemanticParentSymlinks() throws {
        let fileManager = FileManager.default
        let eventsRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "goalong-events-parent-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let semanticRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "goalong-semantic-parent-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? fileManager.removeItem(at: eventsRoot)
            try? fileManager.removeItem(at: semanticRoot)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )

        try fileManager.createDirectory(
            at: eventsRoot,
            withIntermediateDirectories: true
        )
        let realEventsDirectory = eventsRoot.appendingPathComponent(
            "real-events",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: realEventsDirectory,
            withIntermediateDirectories: true
        )
        let event = fixtureEvent(
            id: "event-behind-parent-symlink",
            sequence: 1,
            offset: 1,
            kind: .applicationActivated
        )
        let realEventSource = realEventsDirectory.appendingPathComponent(
            "2027-01-15.jsonl"
        )
        try writeJSONLines([event], encoder: encoder, to: realEventSource)
        let realEventBytesBefore = try Data(contentsOf: realEventSource)
        try fileManager.createSymbolicLink(
            at: eventsRoot.appendingPathComponent("events", isDirectory: true),
            withDestinationURL: realEventsDirectory
        )

        let eventsSymlinkLoad = HistoryLocalStoreReader(rootDirectory: eventsRoot)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)
        XCTAssertTrue(eventsSymlinkLoad.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(eventsSymlinkLoad.metrics.sourceChangedDuringRead)
        XCTAssertTrue(eventsSymlinkLoad.events.isEmpty)
        XCTAssertEqual(eventsSymlinkLoad.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            eventsSymlinkLoad.issues.contains {
                $0.message.contains("refused symbolic-link source directory")
            }
        )
        XCTAssertEqual(try Data(contentsOf: realEventSource), realEventBytesBefore)

        let eventsDirectory = semanticRoot.appendingPathComponent(
            "events",
            isDirectory: true
        )
        let realSemanticDirectory = semanticRoot.appendingPathComponent(
            "real-semantic",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: realSemanticDirectory,
            withIntermediateDirectories: true
        )
        let semantic = fixtureSemanticPayload(
            id: "semantic-behind-parent-symlink",
            text: "This original semantic source must not be followed through a symlink."
        )
        let semanticEvent = fixtureEvent(
            id: "event-referencing-parent-symlink",
            sequence: 1,
            offset: 16,
            kind: .mouseClick,
            semanticContext: semantic.reference,
            pointer: PointerSnapshot(button: "left", x: 20, y: 30, clickCount: 1)
        )
        try writeJSONLines(
            [semanticEvent],
            encoder: encoder,
            to: eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        )
        let realSemanticSource = realSemanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.jsonl"
        )
        try writeJSONLines([semantic], encoder: encoder, to: realSemanticSource)
        let realSemanticBytesBefore = try Data(contentsOf: realSemanticSource)
        try fileManager.createSymbolicLink(
            at: semanticRoot.appendingPathComponent("semantic", isDirectory: true),
            withDestinationURL: realSemanticDirectory
        )

        let semanticSymlinkLoad = HistoryLocalStoreReader(rootDirectory: semanticRoot)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)
        XCTAssertTrue(semanticSymlinkLoad.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(semanticSymlinkLoad.metrics.sourceChangedDuringRead)
        XCTAssertTrue(semanticSymlinkLoad.events.isEmpty)
        XCTAssertTrue(semanticSymlinkLoad.semanticSnapshots.isEmpty)
        XCTAssertEqual(semanticSymlinkLoad.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            semanticSymlinkLoad.issues.contains {
                $0.message.contains("refused symbolic-link source directory")
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: realSemanticSource),
            realSemanticBytesBefore
        )
    }

    func testComputerHistoryEvidenceRejectsAnEventsParentDirectorySwap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-events-parent-swap-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let replacementDirectory = root.appendingPathComponent(
            "replacement-events",
            isDirectory: true
        )
        let displacedDirectory = root.appendingPathComponent(
            "displaced-events",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var originalEvents: [HistoryEvent] = []
        originalEvents.reserveCapacity(1_000)
        for index in 0..<1_000 {
            originalEvents.append(
                fixtureEvent(
                    id: "parent-swap-original-\(index)",
                    sequence: UInt64(index + 1),
                    offset: TimeInterval(index + 1),
                    kind: .applicationActivated
                )
            )
        }
        let originalSource = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines(originalEvents, encoder: encoder, to: originalSource)
        let originalBytesBefore = try Data(contentsOf: originalSource)
        let replacementSource = replacementDirectory.appendingPathComponent(
            "2027-01-15.jsonl"
        )
        try writeJSONLines(
            [
                fixtureEvent(
                    id: "parent-swap-replacement",
                    sequence: 2_000,
                    offset: 2_000,
                    kind: .applicationActivated
                )
            ],
            encoder: encoder,
            to: replacementSource
        )
        let replacementBytesBefore = try Data(contentsOf: replacementSource)

        var continuationChecks = 0
        var swapped = false
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                shouldContinue: {
                    continuationChecks += 1
                    guard continuationChecks == 2 else { return true }
                    let displacedResult = eventsDirectory.path.withCString { oldPath in
                        displacedDirectory.path.withCString { newPath in
                            Darwin.rename(oldPath, newPath)
                        }
                    }
                    guard displacedResult == 0 else {
                        XCTFail("Could not displace pinned events directory")
                        return false
                    }
                    let replacementResult = replacementDirectory.path.withCString { oldPath in
                        eventsDirectory.path.withCString { newPath in
                            Darwin.rename(oldPath, newPath)
                        }
                    }
                    XCTAssertEqual(replacementResult, 0, "Could not install replacement directory")
                    swapped = replacementResult == 0
                    return replacementResult == 0
                }
            )

        XCTAssertTrue(swapped)
        XCTAssertTrue(loaded.metrics.sourceChangedDuringRead)
        XCTAssertTrue(loaded.events.isEmpty)
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            loaded.issues.contains {
                $0.message.contains("source changed during read")
                    || $0.message.contains("source directory changed during read")
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: displacedDirectory.appendingPathComponent("2027-01-15.jsonl")),
            originalBytesBefore
        )
        XCTAssertEqual(
            try Data(contentsOf: eventsDirectory.appendingPathComponent("2027-01-15.jsonl")),
            replacementBytesBefore
        )
    }

    func testComputerHistoryEvidenceRejectsSemanticJSONThatGrowsPastTheLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-semantic-growth-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let semantic = fixtureSemanticPayload(
            id: "growing-semantic-json",
            text: String(repeating: "bounded semantic evidence ", count: 6_000)
        )
        let event = fixtureEvent(
            id: "event-referencing-growing-semantic-json",
            sequence: 1,
            offset: 16,
            kind: .mouseClick,
            semanticContext: semantic.reference,
            pointer: PointerSnapshot(button: "left", x: 42, y: 24, clickCount: 1)
        )
        let eventSourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([event], encoder: encoder, to: eventSourceURL)
        let eventSourceBytesBefore = try Data(contentsOf: eventSourceURL)
        let semanticSourceURL = semanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.json"
        )
        let initialSemanticData = try encoder.encode(semantic)
        XCTAssertGreaterThan(
            initialSemanticData.count,
            HistoryJSONLinesStreamReader.defaultChunkSize
        )
        XCTAssertLessThan(
            initialSemanticData.count,
            HistoryJSONLinesStreamReader.defaultMaximumLineBytes
        )
        try initialSemanticData.write(to: semanticSourceURL)

        var continuationChecks = 0
        var grewPastLimit = false
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                shouldContinue: {
                    continuationChecks += 1
                    guard continuationChecks == 5 else { return true }
                    do {
                        let growthBytes =
                            HistoryJSONLinesStreamReader.defaultMaximumLineBytes
                            - initialSemanticData.count + 1
                        let writer = try FileHandle(forWritingTo: semanticSourceURL)
                        try writer.seekToEnd()
                        try writer.write(contentsOf: Data(repeating: 0x20, count: growthBytes))
                        try writer.close()
                        grewPastLimit = true
                        return true
                    } catch {
                        XCTFail("Could not grow semantic fixture: \(error)")
                        return false
                    }
                }
            )

        XCTAssertTrue(grewPastLimit)
        XCTAssertTrue(loaded.metrics.sourceChangedDuringRead)
        XCTAssertFalse(loaded.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(loaded.events, [])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            loaded.issues.contains {
                $0.message.contains("semantic source changed during read")
                    && $0.message.contains("day projection was rejected")
            }
        )
        XCTAssertEqual(try Data(contentsOf: eventSourceURL), eventSourceBytesBefore)
    }

    func testComputerHistoryEvidenceRejectsAnEventSourceChangedDuringLaterSemanticRead()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-cross-source-revalidation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let semantic = fixtureSemanticPayload(
            id: "cross-source-semantic",
            text: String(repeating: "semantic pass keeps the operation open ", count: 6_000)
        )
        let event = fixtureEvent(
            id: "cross-source-original-event",
            sequence: 1,
            offset: 16,
            kind: .mouseClick,
            semanticContext: semantic.reference,
            pointer: PointerSnapshot(button: "left", x: 42, y: 24, clickCount: 1)
        )
        let appendedEvent = fixtureEvent(
            id: "cross-source-appended-event",
            sequence: 2,
            offset: 17,
            kind: .applicationActivated
        )
        let eventSourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([event], encoder: encoder, to: eventSourceURL)
        let originalEventBytes = try Data(contentsOf: eventSourceURL)
        var appendedEventBytes = try encoder.encode(appendedEvent)
        appendedEventBytes.append(0x0A)
        let semanticSourceURL = semanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.json"
        )
        let semanticBytes = try encoder.encode(semantic)
        XCTAssertGreaterThan(
            semanticBytes.count,
            HistoryJSONLinesStreamReader.defaultChunkSize
        )
        try semanticBytes.write(to: semanticSourceURL)

        var continuationChecks = 0
        var appendedDuringSemanticRead = false
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                shouldContinue: {
                    continuationChecks += 1
                    guard continuationChecks == 5 else { return true }
                    do {
                        let writer = try FileHandle(forWritingTo: eventSourceURL)
                        try writer.seekToEnd()
                        try writer.write(contentsOf: appendedEventBytes)
                        try writer.close()
                        appendedDuringSemanticRead = true
                        return true
                    } catch {
                        XCTFail("Could not append cross-source fixture: \(error)")
                        return false
                    }
                }
            )

        XCTAssertTrue(appendedDuringSemanticRead)
        XCTAssertTrue(loaded.metrics.sourceChangedDuringRead)
        XCTAssertFalse(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(loaded.metrics.wasCancelled)
        XCTAssertEqual(loaded.events, [])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.metrics.retainedEventCount, 0)
        XCTAssertEqual(loaded.metrics.retainedSemanticSnapshotCount, 0)
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            loaded.issues.contains {
                $0.path == eventSourceURL.path
                    && $0.message.contains("changed after its initial read")
                    && $0.message.contains("whole-day projection was rejected")
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: eventSourceURL),
            originalEventBytes + appendedEventBytes
        )
        XCTAssertEqual(try Data(contentsOf: semanticSourceURL), semanticBytes)
    }

    func testComputerHistoryEvidenceRejectsTheWholeDayForMalformedEventJSONL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-malformed-evidence-day-\(UUID().uuidString)",
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
            id: "malformed-day-before",
            sequence: 1,
            offset: 1,
            kind: .applicationActivated
        )
        let last = fixtureEvent(
            id: "malformed-day-after",
            sequence: 2,
            offset: 2,
            kind: .mouseClick,
            pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
        )
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        var sourceBytes = try encoder.encode(first)
        sourceBytes.append(0x0A)
        sourceBytes.append(Data("{malformed-json}\n".utf8))
        sourceBytes.append(try encoder.encode(last))
        sourceBytes.append(0x0A)
        try sourceBytes.write(to: sourceURL)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)

        XCTAssertTrue(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(loaded.metrics.sourceChangedDuringRead)
        XCTAssertEqual(loaded.events, [])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.metrics.rawEventCount, 1)
        XCTAssertEqual(loaded.metrics.retainedEventCount, 0)
        XCTAssertEqual(loaded.metrics.retainedEventBytes, 0)
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(
            loaded.issues.contains {
                $0.path == sourceURL.path && $0.line == 2
                    && $0.message.contains("source content was incomplete")
                    && $0.message.contains("day projection was rejected")
            }
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testComputerHistoryEvidenceWorkingSetBudgetRejectsInsteadOfTruncating() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-evidence-working-set-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let semantic = fixtureSemanticPayload(
            id: "working-set-semantic",
            text: "Global event and semantic working-set evidence"
        )
        var events: [HistoryEvent] = []
        events.reserveCapacity(3)
        for index in 0..<3 {
            let semanticContext: SemanticContextReference? =
                index == 0 ? semantic.reference : nil
            let pointer = PointerSnapshot(
                button: "left",
                x: 10,
                y: 20,
                clickCount: 1
            )
            events.append(
                fixtureEvent(
                    id: "working-set-event-\(index)",
                    sequence: UInt64(index + 1),
                    offset: TimeInterval(index + 1),
                    kind: .mouseClick,
                    semanticContext: semanticContext,
                    pointer: pointer
                )
            )
        }
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines(events, encoder: encoder, to: sourceURL)
        let sourceBytesBefore = try Data(contentsOf: sourceURL)
        let semanticSourceURL = semanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.jsonl"
        )
        try writeJSONLines([semantic], encoder: encoder, to: semanticSourceURL)
        let semanticSourceBytesBefore = try Data(contentsOf: semanticSourceURL)
        let firstEstimatedBytes = Int64(
            try encoder.encode(events[0].compactedForComputerHistoryAnalysis).count
                + MemoryLayout<HistoryEvent>.stride + 256
        )
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let reader = HistoryLocalStoreReader(rootDirectory: root)

        let exactRowBoundary = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd,
            limits: ComputerHistoryEvidenceLoadLimits(
                maximumRetainedRows: events.count + 1,
                maximumRetainedBytes: 1_024 * 1_024
            )
        )
        XCTAssertFalse(exactRowBoundary.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(exactRowBoundary.events.count, events.count)
        XCTAssertEqual(exactRowBoundary.semanticSnapshots.count, 1)
        XCTAssertEqual(
            exactRowBoundary.metrics.peakRetainedEvidenceRows,
            events.count + 1
        )

        let rowLimited = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd,
            limits: ComputerHistoryEvidenceLoadLimits(
                maximumRetainedRows: events.count,
                maximumRetainedBytes: 1_024 * 1_024
            )
        )
        XCTAssertTrue(rowLimited.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(rowLimited.metrics.peakRetainedEvidenceRows, events.count)
        XCTAssertTrue(rowLimited.events.isEmpty)
        XCTAssertTrue(rowLimited.semanticSnapshots.isEmpty)
        XCTAssertEqual(rowLimited.sourceJournalSummary.eventCount, 0)
        XCTAssertTrue(rowLimited.issues.contains { $0.message.contains("budget exceeded") })

        let byteLimited = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd,
            limits: ComputerHistoryEvidenceLoadLimits(
                maximumRetainedRows: 100,
                maximumRetainedBytes: firstEstimatedBytes
            )
        )
        XCTAssertTrue(byteLimited.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(byteLimited.metrics.peakRetainedEvidenceRows, 1)
        XCTAssertEqual(
            byteLimited.metrics.peakEstimatedRetainedEvidenceBytes,
            firstEstimatedBytes
        )
        XCTAssertTrue(byteLimited.events.isEmpty)
        XCTAssertEqual(byteLimited.metrics.retainedEventCount, 0)
        XCTAssertEqual(byteLimited.metrics.retainedEventBytes, 0)
        XCTAssertGreaterThan(
            ComputerHistoryEvidenceLoadLimits.production.maximumRetainedRows,
            16_286
        )
        XCTAssertGreaterThan(
            ComputerHistoryEvidenceLoadLimits.production.maximumRetainedBytes,
            15 * 1_024 * 1_024
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytesBefore)
        XCTAssertEqual(
            try Data(contentsOf: semanticSourceURL),
            semanticSourceBytesBefore
        )
    }

    func testNonEvidenceIntegrityBoundariesDoNotConsumeRetainedEvidenceBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-integrity-boundary-budget-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let commitments = (0..<128).map { index in
            LocalFieldCommitment(
                name: "large-boundary-field-\(index)",
                commitmentHex: String(repeating: "a", count: 64),
                opening: CommitmentOpening(
                    domain: "event-field:large-boundary-field-\(index)",
                    fields: ["value": String(repeating: "x", count: 512)],
                    saltBase64: Data(repeating: UInt8(index), count: 32).base64EncodedString()
                )
            )
        }
        func withLargeIntegrity(_ event: HistoryEvent) -> HistoryEvent {
            let integrity = try! XCTUnwrap(event.integrity)
            return event.replacingIntegrity(
                EventIntegrity(
                    sequence: integrity.sequence,
                    previousEventHash: integrity.previousEventHash,
                    eventRoot: integrity.eventRoot,
                    eventHash: integrity.eventHash,
                    fieldCommitments: commitments
                )
            )
        }
        let firstMaintenance = withLargeIntegrity(
            fixtureEvent(
                id: "large-first-maintenance",
                sequence: 1,
                offset: 1,
                kind: .agentArtifactCaptured,
                message: String(repeating: "not retained ", count: 1_000)
            )
        )
        let retained = fixtureEvent(
            id: "small-retained-click",
            sequence: 2,
            offset: 2,
            kind: .mouseClick,
            pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
        )
        let lastMaintenance = withLargeIntegrity(
            fixtureEvent(
                id: "large-last-maintenance",
                sequence: 3,
                offset: 3,
                kind: .diagnostic,
                message: String(repeating: "not retained ", count: 1_000)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines(
            [firstMaintenance, retained, lastMaintenance],
            encoder: encoder,
            to: sourceURL
        )
        let sourceBytes = try Data(contentsOf: sourceURL)
        let retainedEstimate = Int64(
            try encoder.encode(retained.compactedForComputerHistoryAnalysis).count
                + MemoryLayout<HistoryEvent>.stride + 256
        )

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(
                start: dayStart,
                endExclusive: dayEnd,
                limits: ComputerHistoryEvidenceLoadLimits(
                    maximumRetainedRows: 1,
                    maximumRetainedBytes: retainedEstimate
                )
            )

        XCTAssertFalse(loaded.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(loaded.events.map(\.id), [retained.id])
        XCTAssertEqual(loaded.metrics.peakRetainedEvidenceRows, 1)
        XCTAssertEqual(loaded.metrics.peakEstimatedRetainedEvidenceBytes, retainedEstimate)
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 3)
        XCTAssertEqual(loaded.sourceJournalSummary.firstSourceSequence, 1)
        XCTAssertEqual(loaded.sourceJournalSummary.lastSourceSequence, 3)
        XCTAssertEqual(loaded.sourceJournalSummary.lastSourceEventHash, "hash-3")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testDuplicateSemanticIdentifiersAreDeduplicatedOrRejectedClearly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-duplicate-semantic-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let original = fixtureSemanticPayload(
            id: "duplicate-semantic-id",
            text: "Original semantic evidence"
        )
        let conflicting = fixtureSemanticPayload(
            id: original.id,
            text: "Conflicting semantic evidence"
        )
        let event = fixtureEvent(
            id: "duplicate-semantic-event",
            sequence: 1,
            offset: 1,
            kind: .mouseClick,
            semanticContext: original.reference,
            pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
        )
        let eventSource = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        let semanticSource = semanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.jsonl"
        )
        try writeJSONLines([event], encoder: encoder, to: eventSource)
        try writeJSONLines([original, original], encoder: encoder, to: semanticSource)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let limits = ComputerHistoryEvidenceLoadLimits(
            maximumRetainedRows: 2,
            maximumRetainedBytes: 1_024 * 1_024
        )
        let reader = HistoryLocalStoreReader(rootDirectory: root)
        let identical = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd,
            limits: limits
        )
        XCTAssertFalse(identical.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(identical.metrics.evidenceBudgetExceeded)
        XCTAssertEqual(identical.semanticSnapshots, [original.id: original])
        XCTAssertEqual(identical.metrics.peakRetainedEvidenceRows, 2)

        try writeJSONLines([original, conflicting], encoder: encoder, to: semanticSource)
        let rejected = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd,
            limits: limits
        )
        XCTAssertTrue(rejected.metrics.sourceAccessWasIncomplete)
        XCTAssertTrue(rejected.events.isEmpty)
        XCTAssertTrue(rejected.semanticSnapshots.isEmpty)
        XCTAssertTrue(
            rejected.issues.contains {
                $0.message.contains("duplicate semantic payload identifier")
                    && $0.message.contains("conflicting contents")
            }
        )
    }

    func testReferencedSemanticPayloadMayExpireWithoutRejectingEventEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-expired-semantic-evidence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let semantic = fixtureSemanticPayload(
            id: "expired-semantic-id",
            text: "This independently retained plaintext has expired"
        )
        let event = fixtureEvent(
            id: "event-survives-semantic-retention",
            sequence: 1,
            offset: 1,
            kind: .mouseClick,
            semanticContext: semantic.reference,
            pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([event], encoder: encoder, to: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)

        XCTAssertEqual(loaded.events.map(\.id), [event.id])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertFalse(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(loaded.metrics.sourceChangedDuringRead)
        XCTAssertEqual(loaded.issues, [])
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testContinuityBoundaryDoesNotOpenItsSuppressedSemanticReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-suppressed-semantic-reference-\(UUID().uuidString)",
                isDirectory: true
            )
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-external-semantic-reference-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("semantic", isDirectory: true),
            withDestinationURL: external
        )

        let semantic = fixtureSemanticPayload(
            id: "suppressed-semantic-id",
            text: "PRIVATE-SUPPRESSED-SEMANTIC-TEXT"
        )
        let boundary = fixtureEvent(
            id: "suppressed-semantic-boundary",
            sequence: 1,
            offset: 1,
            kind: .captureSuppressed,
            suppression: .manualPause,
            semanticContext: semantic.reference
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourceURL = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([boundary], encoder: encoder, to: sourceURL)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)

        XCTAssertEqual(loaded.events.map(\.id), [boundary.id])
        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.metrics.semanticBytesRead, 0)
        XCTAssertFalse(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertEqual(loaded.issues, [])
    }

    func testRawComputerHistorySearchFindsOmittedSemanticEvidenceWithoutWritingAnIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-streaming-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let targetText = "quasar invoice 92731 is ready for review"
        let publicPayload = fixtureSemanticPayload(
            id: "raw-search-public",
            text: targetText
        )
        let privatePayload = fixtureSemanticPayload(
            id: "raw-search-private",
            text: "ZXQ_SUPPRESSED_7319"
        )
        var events = (0..<5_000).map { index in
            fixtureEvent(
                id: "raw-search-noise-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(100 + index),
                kind: .windowChanged,
                windowTitle: "Routine window \(index)",
                message: String(repeating: "bounded-noise ", count: 20)
            )
        }
        events.append(
            fixtureEvent(
                id: "raw-search-public-event",
                sequence: 6_000,
                offset: 15,
                kind: .semanticSnapshot,
                windowTitle: "Review workspace",
                semanticContext: publicPayload.reference
            )
        )
        events.append(
            fixtureEvent(
                id: "raw-search-private-event",
                sequence: 6_001,
                offset: 16,
                kind: .semanticSnapshot,
                windowTitle: "Private window",
                suppression: .privateBrowserWindow,
                semanticContext: privatePayload.reference
            )
        )
        events.append(
            fixtureEvent(
                id: "raw-search-secure-event",
                sequence: 6_002,
                offset: 17,
                kind: .windowChanged,
                windowTitle: "ZXQ8421SECRET",
                message: "ZXQ8421SECRET",
                secureElement: true
            )
        )
        events.append(
            fixtureEvent(
                id: "raw-search-maintenance-event",
                sequence: 6_003,
                offset: 18,
                kind: .agentArtifactCaptured,
                message: targetText
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let eventFile = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        let semanticFile = semanticDirectory.appendingPathComponent(
            "2027-01-15.semantic.jsonl"
        )
        try writeJSONLines(events, encoder: encoder, to: eventFile)
        try writeJSONLines(
            [publicPayload, privatePayload],
            encoder: encoder,
            to: semanticFile
        )
        let eventBytesBefore = try Data(contentsOf: eventFile)
        let semanticBytesBefore = try Data(contentsOf: semanticFile)
        let childrenBefore = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let sourceSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "quasar invoice 92731",
                start: dayStart,
                endExclusive: dayEnd,
                maximumHits: 7
            )
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: sourceSearch
        ).ask(
            "quasar invoice 92731",
            now: dayEnd,
            maximumHits: 7
        )

        XCTAssertTrue(sourceSearch.isComplete)
        XCTAssertEqual(sourceSearch.sourceEventCount, events.count - 1)
        XCTAssertEqual(sourceSearch.semanticSnapshotCount, 2)
        XCTAssertEqual(sourceSearch.hits.count, 1)
        XCTAssertEqual(
            sourceSearch.hits.first?.provenance.sourceEventIDs,
            ["raw-search-public-event"]
        )
        XCTAssertTrue(sourceSearch.hits.first?.snippet.contains(targetText) == true)
        XCTAssertEqual(answer.hits.map(\.id), sourceSearch.hits.map(\.id))
        XCTAssertTrue(answer.answer.contains(targetText))
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("created no search index or persisted copy")
            }
        )
        XCTAssertGreaterThan(sourceSearch.eventBytesRead, 1_024 * 1_024)
        XCTAssertLessThan(
            Int64(sourceSearch.peakStreamBufferBytes) * 10,
            sourceSearch.eventBytesRead
        )

        let privateSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "ZXQ_SUPPRESSED_7319",
                start: dayStart,
                endExclusive: dayEnd
            )
        XCTAssertTrue(privateSearch.hits.isEmpty)
        let secureSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "ZXQ8421SECRET",
                start: dayStart,
                endExclusive: dayEnd
            )
        XCTAssertTrue(secureSearch.hits.isEmpty)
        XCTAssertEqual(try Data(contentsOf: eventFile), eventBytesBefore)
        XCTAssertEqual(try Data(contentsOf: semanticFile), semanticBytesBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            childrenBefore
        )
    }

    func testRawComputerHistorySearchReportsDecodeGapsWithoutHidingReadableHits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-gap-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let event = fixtureEvent(
            id: "readable-after-gap",
            sequence: 1,
            offset: 20,
            kind: .windowChanged,
            windowTitle: "zephyr search result"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("{malformed-json}\n".utf8)
        bytes.append(try encoder.encode(event))
        bytes.append(0x0A)
        try bytes.write(
            to: eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        )

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let sourceSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "zephyr search result",
                start: dayStart,
                endExclusive: dayEnd
            )
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: sourceSearch
        ).ask("zephyr search result", now: dayEnd)

        XCTAssertFalse(sourceSearch.isComplete)
        XCTAssertEqual(sourceSearch.issues.count, 1)
        XCTAssertEqual(sourceSearch.hits.map(\.provenance.sourceEventIDs), [[event.id]])
        XCTAssertEqual(answer.hits.count, 1)
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("explicit coverage gaps")
            }
        )
    }

    func testRawComputerHistorySearchCapsTransientSemanticCandidatesWithoutClaimingCompleteness()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-candidate-cap-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let payloads = (0..<101).map { index in
            fixtureSemanticPayload(
                id: "candidate-\(index)",
                text: "candidate overflow anchor \(index)"
            )
        }
        let events = payloads.enumerated().map { index, payload in
            fixtureEvent(
                id: "candidate-event-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index + 20),
                kind: .semanticSnapshot,
                windowTitle: "Routine window",
                host: nil,
                semanticContext: payload.reference
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try writeJSONLines(
            payloads,
            encoder: encoder,
            to: semanticDirectory.appendingPathComponent("2027-01-15.semantic.jsonl")
        )
        try writeJSONLines(
            events,
            encoder: encoder,
            to: eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        )

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let sourceSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "candidate overflow anchor",
                start: dayStart,
                endExclusive: dayEnd
            )
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: sourceSearch
        ).ask("candidate overflow anchor", now: dayEnd, maximumHits: 100)

        XCTAssertFalse(sourceSearch.isComplete)
        XCTAssertEqual(sourceSearch.hits.count, 100)
        XCTAssertTrue(
            sourceSearch.issues.contains {
                $0.message.contains("semantic candidate limit")
            }
        )
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("could not be searched completely")
            }
        )
    }

    func testRawComputerHistorySearchRefusesSymbolicLinkRootAndSourceFile() throws {
        let realRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-real-\(UUID().uuidString)",
                isDirectory: true
            )
        let linkedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-linked-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileLinkRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-file-link-\(UUID().uuidString)",
                isDirectory: true
            )
        let directoryLinkRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-directory-link-\(UUID().uuidString)",
                isDirectory: true
            )
        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-external-directory-\(UUID().uuidString)",
                isDirectory: true
            )
        let externalFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-raw-search-external-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: linkedRoot)
            try? FileManager.default.removeItem(at: realRoot)
            try? FileManager.default.removeItem(at: fileLinkRoot)
            try? FileManager.default.removeItem(at: directoryLinkRoot)
            try? FileManager.default.removeItem(at: externalDirectory)
            try? FileManager.default.removeItem(at: externalFile)
        }

        let event = fixtureEvent(
            id: "symlink-secret-event",
            sequence: 1,
            offset: 20,
            kind: .windowChanged,
            windowTitle: "symlink-secret-anchor"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try writeJSONLines([event], encoder: encoder, to: externalFile)

        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let linkedRootResult = HistoryLocalStoreReader(rootDirectory: linkedRoot)
            .searchComputerHistorySource(
                query: "symlink-secret-anchor",
                start: dayStart,
                endExclusive: dayEnd
            )

        XCTAssertFalse(linkedRootResult.isComplete)
        XCTAssertEqual(linkedRootResult.eventBytesRead, 0)
        XCTAssertTrue(linkedRootResult.hits.isEmpty)
        XCTAssertTrue(
            linkedRootResult.issues.contains {
                $0.message.contains("refused symbolic-link source directory")
            }
        )

        try FileManager.default.createDirectory(
            at: directoryLinkRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: directoryLinkRoot.appendingPathComponent("events", isDirectory: true),
            withDestinationURL: externalDirectory
        )
        let linkedDirectoryResult = HistoryLocalStoreReader(
            rootDirectory: directoryLinkRoot
        ).searchComputerHistorySource(
            query: "symlink-secret-anchor",
            start: dayStart,
            endExclusive: dayEnd
        )

        XCTAssertFalse(linkedDirectoryResult.isComplete)
        XCTAssertEqual(linkedDirectoryResult.eventBytesRead, 0)
        XCTAssertTrue(linkedDirectoryResult.hits.isEmpty)
        XCTAssertTrue(
            linkedDirectoryResult.issues.contains {
                $0.message.contains("refused symbolic-link source directory")
            }
        )

        let eventsDirectory = fileLinkRoot.appendingPathComponent(
            "events",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: eventsDirectory.appendingPathComponent("2027-01-15.jsonl"),
            withDestinationURL: externalFile
        )
        let linkedFileResult = HistoryLocalStoreReader(rootDirectory: fileLinkRoot)
            .searchComputerHistorySource(
                query: "symlink-secret-anchor",
                start: dayStart,
                endExclusive: dayEnd
            )

        XCTAssertFalse(linkedFileResult.isComplete)
        XCTAssertEqual(linkedFileResult.eventBytesRead, 0)
        XCTAssertTrue(linkedFileResult.hits.isEmpty)
        XCTAssertTrue(
            linkedFileResult.issues.contains {
                $0.message.contains("refused symbolic-link source file")
            }
        )
        let linkedFileAnswer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: linkedFileResult
        ).ask("symlink-secret-anchor", now: dayEnd)
        XCTAssertTrue(
            linkedFileAnswer.answer.contains(
                "prevent an exhaustive absence conclusion"
            )
        )
        XCTAssertTrue(
            linkedFileAnswer.limitations.contains {
                $0.contains("symbolic-link source paths were refused")
            }
        )
    }

    func testRawComputerHistorySearchStopsAtByteAndTimeBudgetsWithExplicitGaps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-budget-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )

        let target = fixtureEvent(
            id: "budget-target",
            sequence: 1,
            offset: 20,
            kind: .windowChanged,
            windowTitle: "budget-anchor"
        )
        let noise = (0..<500).map { index in
            fixtureEvent(
                id: "budget-noise-\(index)",
                sequence: UInt64(index + 2),
                offset: TimeInterval(index + 21),
                kind: .windowChanged,
                windowTitle: "noise \(index)",
                message: String(repeating: "bounded row ", count: 20)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let eventFile = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([target] + noise, encoder: encoder, to: eventFile)
        let firstRowBudget = Int64(try encoder.encode(target).count + 8)
        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )

        let byteLimited = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "budget-anchor",
                start: dayStart,
                endExclusive: dayEnd,
                limits: ComputerHistorySourceSearchLimits(
                    maximumEventBytes: firstRowBudget,
                    maximumSemanticBytes: 0,
                    maximumElapsedSeconds: 45
                )
            )
        let limitedAnswer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: byteLimited
        ).ask("budget-anchor", now: dayEnd)

        XCTAssertFalse(byteLimited.isComplete)
        XCTAssertEqual(byteLimited.eventBytesRead, firstRowBudget)
        XCTAssertLessThanOrEqual(
            byteLimited.eventBytesRead,
            ComputerHistorySourceSearchLimits.production.maximumEventBytes
        )
        XCTAssertEqual(byteLimited.hits.first?.provenance.sourceEventIDs, [target.id])
        XCTAssertTrue(
            byteLimited.issues.contains {
                $0.message.contains("cumulative budget")
            }
        )
        XCTAssertTrue(
            limitedAnswer.limitations.contains {
                $0.contains("explicit coverage gaps")
            }
        )

        let timeLimited = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "budget-anchor",
                start: dayStart,
                endExclusive: dayEnd,
                limits: ComputerHistorySourceSearchLimits(
                    maximumEventBytes: 1_024 * 1_024,
                    maximumSemanticBytes: 1_024 * 1_024,
                    maximumElapsedSeconds: 0
                )
            )
        XCTAssertFalse(timeLimited.isComplete)
        XCTAssertEqual(timeLimited.eventBytesRead, 0)
        XCTAssertTrue(
            timeLimited.issues.contains {
                $0.message.contains("time budget")
            }
        )

        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )
        let semanticPayload = fixtureSemanticPayload(
            id: "budget-semantic",
            text: String(repeating: "semantic budget anchor ", count: 50)
        )
        try encoder.encode(semanticPayload).write(
            to: semanticDirectory.appendingPathComponent("2027-01-15.semantic.json")
        )
        let semanticLimited = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "semantic budget anchor",
                start: dayStart,
                endExclusive: dayEnd,
                limits: ComputerHistorySourceSearchLimits(
                    maximumEventBytes: 1_024 * 1_024,
                    maximumSemanticBytes: 32,
                    maximumElapsedSeconds: 45
                )
            )

        XCTAssertFalse(semanticLimited.isComplete)
        XCTAssertEqual(semanticLimited.semanticBytesRead, 0)
        XCTAssertTrue(
            semanticLimited.issues.contains {
                $0.message.contains("semantic search stopped")
                    && $0.message.contains("cumulative budget")
            }
        )
    }

    func testRawComputerHistorySearchReportsAnInaccessibleOriginalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-raw-search-inaccessible-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: eventsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: eventsDirectory.path
            )
        }

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let sourceSearch = HistoryLocalStoreReader(rootDirectory: root)
            .searchComputerHistorySource(
                query: "inaccessible source anchor",
                start: dayStart,
                endExclusive: dayEnd
            )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: eventsDirectory.path
        )
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: sourceSearch
        ).ask("inaccessible source anchor", now: dayEnd)

        XCTAssertFalse(sourceSearch.isComplete)
        XCTAssertTrue(sourceSearch.hits.isEmpty)
        XCTAssertTrue(
            sourceSearch.issues.contains {
                $0.message.contains("could not access source directory")
            }
        )
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("absent, inaccessible or unreadable")
            }
        )
    }

    func testBoundedIntervalSkipsDisjointDailyFilesAndFiltersMemories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-reader-day-pruning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let memoriesDirectory = root.appendingPathComponent("memories", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let selectedEvent = fixtureEvent(
            id: "selected-day-event",
            sequence: 1,
            offset: 0,
            kind: .diagnostic,
            message: "selected"
        )
        var selectedEventData = try encoder.encode(selectedEvent)
        selectedEventData.append(0x0A)
        try selectedEventData.write(to: eventsDirectory.appendingPathComponent("2027-01-15.jsonl"))

        // If this disjoint daily file were opened, it would surface a decode issue.
        // Filename pruning must exclude it before any row allocation or decoding.
        try Data("not-json\n".utf8).write(
            to: eventsDirectory.appendingPathComponent("2026-12-01.jsonl")
        )

        let selectedMemory = try DeterministicActivitySummarizer().summarize(
            ActivitySummaryInput(events: [selectedEvent])
        )
        let oldEvent = fixtureEvent(
            id: "old-day-event",
            sequence: 2,
            offset: -(3 * 86_400),
            kind: .diagnostic,
            message: "old"
        )
        let oldMemory = try DeterministicActivitySummarizer().summarize(
            ActivitySummaryInput(events: [oldEvent])
        )
        try encoder.encode(selectedMemory).write(
            to: memoriesDirectory.appendingPathComponent("2027-01-15.memory.json")
        )
        try encoder.encode(oldMemory).write(
            to: memoriesDirectory.appendingPathComponent("2027-01-12.memory.json")
        )

        let loaded = HistoryLocalStoreReader(rootDirectory: root).load(
            start: fixtureStart.addingTimeInterval(-1),
            end: fixtureStart.addingTimeInterval(1)
        )

        XCTAssertEqual(loaded.events.map(\.id), [selectedEvent.id])
        XCTAssertEqual(loaded.memories.map(\.id), [selectedMemory.id])
        XCTAssertEqual(loaded.issues, [])
    }

    func testGenericReaderOmitsConflictingSemanticDuplicatesDeterministically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-generic-semantic-conflict-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: semanticDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let original = fixtureSemanticPayload(
            id: "PRIVATE-CONFLICTING-SEMANTIC-ID",
            text: "first conflicting semantic value"
        )
        let conflicting = fixtureSemanticPayload(
            id: original.id,
            text: "second conflicting semantic value"
        )
        try writeJSONLines(
            [original, original],
            encoder: encoder,
            to: semanticDirectory.appendingPathComponent("2027-01-15.semantic.jsonl")
        )
        try encoder.encode(conflicting).write(
            to: semanticDirectory.appendingPathComponent("2027-01-15.semantic.json")
        )

        let loaded = HistoryLocalStoreReader(rootDirectory: root).load(
            start: fixtureStart.addingTimeInterval(-1),
            end: fixtureStart.addingTimeInterval(30)
        )

        XCTAssertEqual(loaded.semanticSnapshots, [:])
        XCTAssertEqual(loaded.issues.count, 1)
        let issue = try XCTUnwrap(loaded.issues.first)
        XCTAssertTrue(issue.message.contains("1 semantic snapshot identifier"))
        XCTAssertTrue(issue.message.contains("conflicting duplicate contents"))
        XCTAssertFalse(issue.message.contains(original.id))
        XCTAssertFalse(issue.message.contains(original.text))
        XCTAssertFalse(issue.message.contains(conflicting.text))
    }

    func testComputerHistoryEvidenceSkipsAFileWhoseDayEndsAtTheRequestedStart()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "goalong-evidence-day-pruning-\(UUID().uuidString)",
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
        let selectedEvent = fixtureEvent(
            id: "evidence-selected-day-event",
            sequence: 1,
            offset: 1,
            kind: .applicationActivated
        )
        let selectedSource = eventsDirectory.appendingPathComponent("2027-01-15.jsonl")
        try writeJSONLines([selectedEvent], encoder: encoder, to: selectedSource)
        let disjointSource = eventsDirectory.appendingPathComponent("2027-01-14.jsonl")
        let disjointBytes = Data("{malformed-disjoint-day}\n".utf8)
        try disjointBytes.write(to: disjointSource)

        let dayStart = Calendar.current.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        )
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)

        XCTAssertEqual(loaded.events.map(\.id), [selectedEvent.id])
        XCTAssertEqual(loaded.sourceJournalSummary.eventCount, 1)
        XCTAssertFalse(loaded.metrics.sourceAccessWasIncomplete)
        XCTAssertFalse(loaded.metrics.sourceChangedDuringRead)
        XCTAssertEqual(loaded.issues, [])
        XCTAssertEqual(try Data(contentsOf: disjointSource), disjointBytes)
    }

    private func writeJSONLines<T: Encodable>(
        _ values: [T],
        encoder: JSONEncoder,
        to fileURL: URL
    ) throws {
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        try data.write(to: fileURL)
    }

}
