#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class HistoryDeletionCoordinatorTests: XCTestCase {
        private var root: URL!
        private var codexRoot: URL!
        private var calendar: Calendar!

        override func setUpWithError() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "HistoryDeletionCoordinatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
            codexRoot = root.appendingPathComponent("codex-mirror", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        }

        override func tearDownWithError() throws {
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
        }

        func testIntervalDeletionRebuildsSurvivingDayAndEveryLaterCausalMemory() throws {
            let firstDay = date("2026-08-20T12:00:00Z")
            let secondDay = date("2026-08-21T12:00:00Z")
            let interactionID = "delete-this-interaction"
            let before = payload(
                id: "delete-before-payload",
                at: firstDay,
                text: "Secret draft before deletion"
            )
            let settled = payload(
                id: "delete-settled-payload",
                at: firstDay.addingTimeInterval(2),
                text: "Secret draft after deletion"
            )
            try writeEvents([
                event(
                    id: "delete-before-event",
                    at: firstDay,
                    kind: .semanticSnapshot,
                    interactionID: interactionID,
                    semantic: before.reference,
                    title: "Secret Draft"
                ),
                event(
                    id: "delete-action-event",
                    at: firstDay.addingTimeInterval(1),
                    kind: .mouseClick,
                    interactionID: interactionID,
                    title: "Secret Draft"
                ),
                event(
                    id: "delete-settled-event",
                    at: firstDay.addingTimeInterval(2),
                    kind: .semanticSnapshot,
                    interactionID: interactionID,
                    semantic: settled.reference,
                    title: "Secret Draft"
                ),
                event(
                    id: "keep-first-day",
                    at: firstDay.addingTimeInterval(120),
                    kind: .mouseClick,
                    interactionID: "keep-first",
                    title: "Roadmap"
                ),
                event(
                    id: "keep-second-day",
                    at: secondDay,
                    kind: .mouseClick,
                    interactionID: "keep-second",
                    title: "Launch Plan"
                ),
            ])
            try writePayloads([before, settled])
            try createStaleDerivedFiles(days: [firstDay, secondDay])
            try createProofFixture()

            let outcome = try execute(
                HistoryDeletionRequest(
                    scope: .interval,
                    start: firstDay.addingTimeInterval(1),
                    end: firstDay.addingTimeInterval(1)
                )
            )

            XCTAssertEqual(outcome.deletedEventCount, 3)
            XCTAssertEqual(outcome.deletedSemanticSnapshotCount, 2)
            XCTAssertEqual(outcome.affectedDays, [calendar.startOfDay(for: firstDay)])
            XCTAssertEqual(
                Set(outcome.rebuiltDays),
                Set([
                    calendar.startOfDay(for: firstDay),
                    calendar.startOfDay(for: secondDay),
                ])
            )
            XCTAssertTrue(outcome.proofsPreserved)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("minute-seals/proof.json").path
                )
            )

            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            XCTAssertEqual(
                Set(loaded.events.map(\.id)),
                Set(["keep-first-day", "keep-second-day"])
            )
            XCTAssertTrue(loaded.semanticSnapshots.isEmpty)

            let allDerivedText = try derivedText()
            XCTAssertFalse(allDerivedText.contains("Secret draft"))
            XCTAssertFalse(allDerivedText.contains("STALE SECRET"))
            XCTAssertTrue(allDerivedText.contains("Roadmap") || allDerivedText.contains("Launch Plan"))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: codexRoot
                        .appendingPathComponent("2026-08-21-goalong-computer-history.md")
                        .path
                )
            )
        }

        func testAllDetailedDataRemovesRawSemanticAndDerivedButPreservesProofs() throws {
            let timestamp = date("2026-08-20T12:00:00Z")
            let semantic = payload(id: "payload", at: timestamp, text: "Private context")
            try writeEvents([
                event(
                    id: "event",
                    at: timestamp,
                    kind: .semanticSnapshot,
                    interactionID: "all",
                    semantic: semantic.reference,
                    title: "Private context"
                )
            ])
            try writePayloads([semantic])
            try createStaleDerivedFiles(days: [timestamp])
            try createProofFixture()

            let outcome = try execute(
                HistoryDeletionRequest(scope: .allDetailedData)
            )

            XCTAssertEqual(outcome.deletedEventCount, 1)
            XCTAssertEqual(outcome.deletedSemanticSnapshotCount, 1)
            XCTAssertGreaterThan(outcome.removedDerivedFileCount, 0)
            XCTAssertEqual(outcome.removedProofFileCount, 0)
            XCTAssertTrue(outcome.proofsPreserved)
            XCTAssertTrue(HistoryLocalStoreReader(rootDirectory: root).load().events.isEmpty)
            XCTAssertEqual(try derivedFileCount(), 0)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("minute-seals/proof.json").path
                )
            )
        }

        func testAllLocalHistoryIncludingProofsRemovesEveryLocalHistoryClass() throws {
            let timestamp = date("2026-08-20T12:00:00Z")
            try writeEvents([
                event(
                    id: "event",
                    at: timestamp,
                    kind: .mouseClick,
                    interactionID: "all",
                    title: "Delete all"
                )
            ])
            try createStaleDerivedFiles(days: [timestamp])
            try createProofFixture()

            let outcome = try execute(
                HistoryDeletionRequest(scope: .allLocalHistoryIncludingProofs)
            )

            XCTAssertFalse(outcome.proofsPreserved)
            XCTAssertGreaterThan(outcome.removedProofFileCount, 0)
            XCTAssertEqual(try derivedFileCount(), 0)
            XCTAssertTrue(HistoryLocalStoreReader(rootDirectory: root).load().events.isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("minute-seals/proof.json").path
                )
            )
            XCTAssertTrue(
                outcome.warnings.contains(where: { $0.contains("cannot be recalled") })
            )
        }

        func testSemanticFailureRestoresAlreadyMutatedDetailedEvents() throws {
            let timestamp = date("2026-08-20T12:00:00Z")
            try writeEvents([
                event(
                    id: "event",
                    at: timestamp,
                    kind: .mouseClick,
                    interactionID: "rollback",
                    title: "Rollback"
                )
            ])
            let semanticDirectory = root.appendingPathComponent("semantic", isDirectory: true)
            try FileManager.default.createDirectory(
                at: semanticDirectory,
                withIntermediateDirectories: true
            )
            try Data("{not-json}\n".utf8).write(
                to: semanticDirectory.appendingPathComponent("2026-08-20.semantic.jsonl")
            )
            let originalEvents = try Data(
                contentsOf: root.appendingPathComponent("events/2026-08-20.jsonl")
            )

            XCTAssertThrowsError(
                try execute(
                    HistoryDeletionRequest(
                        scope: .interval,
                        start: timestamp.addingTimeInterval(-1),
                        end: timestamp.addingTimeInterval(1)
                    )
                )
            )

            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("events/2026-08-20.jsonl")),
                originalEvents
            )
            XCTAssertEqual(
                HistoryLocalStoreReader(rootDirectory: root).load().events.map(\.id),
                ["event"]
            )
        }

        private func execute(
            _ request: HistoryDeletionRequest,
            timeout: TimeInterval = 10
        ) throws -> HistoryDeletionOutcome {
            let expectation = expectation(description: "deletion")
            var captured: Result<HistoryDeletionOutcome, Error>?
            HistoryDeletionCoordinator(
                rootDirectory: root,
                codexMemoryDirectory: codexRoot,
                calendar: calendar
            ).execute(request) { result in
                captured = result
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: timeout)
            return try XCTUnwrap(captured).get()
        }

        private func event(
            id: String,
            at timestamp: Date,
            kind: EventKind,
            interactionID: String,
            semantic: SemanticContextReference? = nil,
            title: String
        ) -> HistoryEvent {
            HistoryEvent(
                schemaVersion: 4,
                id: id,
                sessionID: "history-deletion-coordinator-tests",
                timestamp: timestamp,
                kind: kind,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: title, role: "AXWindow", subrole: nil),
                element: ElementSnapshot(
                    role: "AXButton",
                    subrole: nil,
                    title: "Save",
                    label: "Save",
                    identifier: "save",
                    isSecure: false
                ),
                pointer: kind == .mouseClick
                    ? PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
                    : nil,
                semanticContext: semantic,
                classification: LocalClassification(
                    category: "work",
                    isWork: true,
                    confidence: 0.9,
                    classifierVersion: "test"
                ),
                metadata: [ComputerHistoryMetadata.interactionID: interactionID],
                integrity: nil
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
                window: WindowSnapshot(title: "Semantic context", role: "AXWindow", subrole: nil),
                focusedRole: "AXTextArea",
                source: .visibleText,
                text: text,
                contentSHA256: SHA256Digest.hashHex(text),
                redacted: false,
                truncated: false
            )
        }

        private func writeEvents(_ events: [HistoryEvent]) throws {
            let grouped = Dictionary(grouping: events) { dayString($0.timestamp) }
            let directory = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (day, values) in grouped {
                try write(values, to: directory.appendingPathComponent(day + ".jsonl"))
            }
        }

        private func writePayloads(_ payloads: [SemanticContextPayload]) throws {
            let grouped = Dictionary(grouping: payloads) { dayString($0.capturedAt) }
            let directory = root.appendingPathComponent("semantic", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (day, values) in grouped {
                try write(values, to: directory.appendingPathComponent(day + ".semantic.jsonl"))
            }
        }

        private func write<T: Encodable>(_ values: [T], to URL: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for value in values {
                data.append(try encoder.encode(value))
                data.append(0x0A)
            }
            try data.write(to: URL)
        }

        private func createStaleDerivedFiles(days: [Date]) throws {
            let directories = ["analysis", "memories", "computer-history"]
            for name in directories {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
            for day in days {
                let base = dayString(day)
                let files = [
                    root.appendingPathComponent("analysis/\(base).analysis.json"),
                    root.appendingPathComponent("analysis/\(base).agent.md"),
                    root.appendingPathComponent("memories/\(base).memory.json"),
                    root.appendingPathComponent("memories/\(base).memory.md"),
                    root.appendingPathComponent("computer-history/\(base).computer-history.json"),
                    root.appendingPathComponent("computer-history/\(base).computer-history.md"),
                    codexRoot.appendingPathComponent("\(base)-goalong-computer-history.md"),
                ]
                for file in files {
                    try Data("STALE SECRET".utf8).write(to: file)
                }
            }
        }

        private func createProofFixture() throws {
            for name in ["minute-seals", "receipts", "shares"] {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("proof".utf8).write(to: directory.appendingPathComponent("proof.json"))
            }
            try Data("anchor-state".utf8).write(
                to: root.appendingPathComponent("anchor-upload-state.json")
            )
        }

        private func derivedText() throws -> String {
            var text = ""
            for directory in [
                root.appendingPathComponent("analysis", isDirectory: true),
                root.appendingPathComponent("memories", isDirectory: true),
                root.appendingPathComponent("computer-history", isDirectory: true),
                codexRoot,
            ] {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                for file in try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ) {
                    if let value = String(data: try Data(contentsOf: file), encoding: .utf8) {
                        text += value
                    }
                }
            }
            return text
        }

        private func derivedFileCount() throws -> Int {
            try [
                root.appendingPathComponent("analysis", isDirectory: true),
                root.appendingPathComponent("memories", isDirectory: true),
                root.appendingPathComponent("computer-history", isDirectory: true),
                codexRoot,
            ].reduce(0) { partial, directory in
                guard FileManager.default.fileExists(atPath: directory.path) else { return partial }
                return partial + (try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).count)
            }
        }

        private func dayString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        private func date(_ raw: String) -> Date {
            ISO8601DateFormatter().date(from: raw)!
        }
    }
#endif
