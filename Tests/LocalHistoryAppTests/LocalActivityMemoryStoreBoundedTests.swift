#if os(macOS)
    import Foundation
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore
    import XCTest

    final class LocalActivityMemoryStoreBoundedTests: XCTestCase {
        func testDefaultReaderPreservesActivityMemoryFieldsWithoutMutatingSource() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )

            let calendar = Calendar.current
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_184_000))
            let classification = LocalClassification(
                category: "focused-work",
                isWork: true,
                confidence: 0.875,
                classifierVersion: "fixture-v1"
            )
            let inputOrigin = InputOriginSnapshot(
                sourceProcessIdentifier: 314,
                sourceUserIdentifier: 501,
                sourceStateID: 1,
                sourceProcessName: "Fixture Input Source",
                sourceBundleIdentifier: "ai.goalong.fixture-input",
                assessment: .softwareAttributed
            )
            let metadata = [
                "duration_ms": "250",
                "idle_seconds": "12.5",
                "fixture_marker": "bounded-metadata",
            ]
            let commitment = CommitmentBuilder.make(
                name: "classification",
                fields: ["category": classification.category],
                salt: Data(repeating: 7, count: 32)
            )
            let sourceEvent = HistoryEvent(
                id: "activity-memory-heartbeat",
                sessionID: "activity-memory-production-reader",
                timestamp: day.addingTimeInterval(60),
                kind: .heartbeat,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "ai.goalong.fixture",
                    processIdentifier: 42
                ),
                inputOrigin: inputOrigin,
                classification: classification,
                metadata: metadata,
                integrity: EventIntegrity(
                    sequence: 7,
                    previousEventHash: String(repeating: "a", count: 64),
                    eventRoot: String(repeating: "b", count: 64),
                    eventHash: String(repeating: "c", count: 64),
                    fieldCommitments: [commitment]
                )
            )
            XCTAssertTrue(sourceEvent.isDerivedAnalysisEvidence)
            XCTAssertFalse(sourceEvent.isComputerHistoryEvidence)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var sourceBytes = try encoder.encode(sourceEvent)
            sourceBytes.append(0x0A)
            let sourceURL = eventsDirectory.appendingPathComponent(
                AppPaths.localDayString(for: day) + ".jsonl"
            )
            try sourceBytes.write(to: sourceURL, options: .atomic)
            let sourceBefore = try Data(contentsOf: sourceURL)

            let summarizer = CapturingSummarizer()
            let store = LocalActivityMemoryStore(
                summarizer: summarizer,
                rootDirectory: root
            )
            let memory = try XCTUnwrap(store.buildAndWrite(for: day))

            let captured = try XCTUnwrap(summarizer.input)
            let projected = try XCTUnwrap(captured.events.only)
            XCTAssertEqual(projected.id, sourceEvent.id)
            XCTAssertEqual(projected.kind, .heartbeat)
            XCTAssertEqual(projected.classification, classification)
            XCTAssertEqual(projected.inputOrigin, inputOrigin)
            XCTAssertEqual(projected.metadata, metadata)
            XCTAssertEqual(projected.integrity?.sequence, sourceEvent.integrity?.sequence)
            XCTAssertEqual(projected.integrity?.previousEventHash, sourceEvent.integrity?.previousEventHash)
            XCTAssertEqual(projected.integrity?.eventRoot, sourceEvent.integrity?.eventRoot)
            XCTAssertEqual(projected.integrity?.eventHash, sourceEvent.integrity?.eventHash)
            XCTAssertEqual(projected.integrity?.fieldCommitments, [])
            XCTAssertEqual(memory.coverage.sourceEventCount, 1)

            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persistedSource = try decoder.decode(
                HistoryEvent.self,
                from: Data(sourceBefore.dropLast())
            )
            XCTAssertEqual(persistedSource, sourceEvent)
            XCTAssertEqual(persistedSource.integrity?.fieldCommitments, [commitment])

            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                ["events", "memories"]
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("memories", isDirectory: true).path
                ).sorted(),
                [
                    AppPaths.localDayString(for: day) + ".memory.json",
                    AppPaths.localDayString(for: day) + ".memory.md",
                ]
            )
        }

        func testIncompleteBoundedSourceNeverWritesActivityMemory() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let day = Date(timeIntervalSince1970: 1_787_184_000)
            let event = sourceEvent(at: day.addingTimeInterval(60))
            let cases: [ComputerHistoryEvidenceLoad] = [
                load(events: [event], wasCancelled: true),
                load(events: [event], sourceChangedDuringRead: true),
                load(events: [event], sourceAccessWasIncomplete: true),
                load(events: [event], evidenceBudgetExceeded: true),
                load(
                    events: [event],
                    issues: [
                        HistoryLoadIssue(
                            path: "fixture.jsonl",
                            line: 1,
                            message: "malformed source row"
                        )
                    ]
                ),
            ]

            for incomplete in cases {
                let store = LocalActivityMemoryStore(
                    rootDirectory: root,
                    evidenceLoader: { _, _ in incomplete }
                )
                XCTAssertThrowsError(try store.buildAndWrite(for: day)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("incomplete source evidence"))
                }
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("memories").path
                    )
                )
            }
        }

        func testStableBoundedSourceWritesOnlyTheTwoCompactMemoryViews() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_184_000))
            let event = sourceEvent(at: day.addingTimeInterval(60))
            var observedInterval: DateInterval?
            let store = LocalActivityMemoryStore(
                rootDirectory: root,
                evidenceLoader: { start, endExclusive in
                    observedInterval = DateInterval(start: start, end: endExclusive)
                    return self.load(events: [event])
                }
            )

            let memory = try XCTUnwrap(store.buildAndWrite(for: day))
            let expectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            XCTAssertEqual(observedInterval?.start, day)
            XCTAssertEqual(observedInterval?.end, expectedEnd)
            XCTAssertEqual(memory.coverage.sourceEventCount, 1)

            let memoriesDirectory = root.appendingPathComponent("memories", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: memoriesDirectory.path)
                .sorted()
            XCTAssertEqual(
                names,
                [
                    AppPaths.localDayString(for: day) + ".memory.json",
                    AppPaths.localDayString(for: day) + ".memory.md",
                ]
            )
        }

        private func load(
            events: [HistoryEvent],
            issues: [HistoryLoadIssue] = [],
            wasCancelled: Bool = false,
            sourceChangedDuringRead: Bool = false,
            sourceAccessWasIncomplete: Bool = false,
            evidenceBudgetExceeded: Bool = false
        ) -> ComputerHistoryEvidenceLoad {
            ComputerHistoryEvidenceLoad(
                events: events,
                semanticSnapshots: [:],
                sourceJournalSummary: ComputerHistorySourceJournalSummary(
                    eventCount: events.count,
                    continuityBoundaryCount: 0,
                    firstSourceSequence: nil,
                    lastSourceSequence: nil,
                    lastSourceEventHash: nil
                ),
                issues: issues,
                metrics: ComputerHistoryEvidenceLoadMetrics(
                    eventBytesRead: Int64(events.count),
                    semanticBytesRead: 0,
                    peakStreamBufferBytes: events.count,
                    rawEventCount: events.count,
                    retainedEventCount: events.count,
                    retainedEventBytes: Int64(events.count),
                    semanticRowsVisited: 0,
                    retainedSemanticSnapshotCount: 0,
                    retainedSemanticSnapshotBytes: 0,
                    wasCancelled: wasCancelled,
                    sourceChangedDuringRead: sourceChangedDuringRead,
                    sourceAccessWasIncomplete: sourceAccessWasIncomplete,
                    evidenceBudgetExceeded: evidenceBudgetExceeded
                )
            )
        }

        private func sourceEvent(at timestamp: Date) -> HistoryEvent {
            HistoryEvent(
                sessionID: "bounded-memory-session",
                timestamp: timestamp,
                kind: .applicationActivated,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "ai.goalong.fixture",
                    processIdentifier: 42
                )
            )
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-bounded-memory-\(UUID().uuidString)", isDirectory: true)
        }

        private final class CapturingSummarizer: ActivitySummarizer {
            private(set) var input: ActivitySummaryInput?

            func summarize(_ input: ActivitySummaryInput) throws -> ActivityMemory {
                self.input = input
                return try DeterministicActivitySummarizer().summarize(input)
            }
        }
    }

    extension Array {
        fileprivate var only: Element? {
            count == 1 ? first : nil
        }
    }
#endif
