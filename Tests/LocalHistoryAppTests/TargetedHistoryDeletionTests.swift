#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    final class TargetedHistoryDeletionTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDownWithError() throws {
            for root in roots { try? FileManager.default.removeItem(at: root) }
            roots.removeAll()
            try super.tearDownWithError()
        }

        func testEpisodeResolverRebuildsExactIDsAndSemanticReferencesFromOriginalJournal() throws {
            let root = try makeRoot()
            let start = makeDate(hour: 12)
            let payload = semanticPayload(id: "episode-semantic", timestamp: start)
            let app = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let events = [
                HistoryEvent(
                    id: "episode-event-1",
                    sessionID: "episode-session",
                    timestamp: start,
                    kind: .mouseClick,
                    app: app,
                    window: WindowSnapshot(title: "Deletion fixture", role: nil, subrole: nil),
                    pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                    semanticContext: payload.reference
                ),
                HistoryEvent(
                    id: "episode-event-2",
                    sessionID: "episode-session",
                    timestamp: start.addingTimeInterval(2),
                    kind: .mouseClick,
                    app: app,
                    window: WindowSnapshot(title: "Deletion fixture", role: nil, subrole: nil),
                    pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
                ),
            ]
            try write(events: events, payloads: [payload], root: root)
            let memory = ComputerHistoryEngine.analyze(
                events: events,
                semanticSnapshots: [payload.id: payload],
                day: start
            )
            let episode = try XCTUnwrap(memory.episodes.first)

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: episode.id, day: start)
            )

            XCTAssertEqual(selection.eventIDs, Set(events.map(\.id)))
            XCTAssertEqual(selection.semanticSnapshotIDs, [payload.id])
            XCTAssertEqual(selection.start, events.first?.timestamp)
            XCTAssertEqual(selection.end, events.last?.timestamp)
            XCTAssertEqual(selection.affectedDays, [Calendar.current.startOfDay(for: start)])
            XCTAssertEqual(selection.semanticDays, [Calendar.current.startOfDay(for: start)])
        }

        func testEpisodeResolverUsesSnapshotDayAcrossMidnightWithoutBroadeningDerivedDeletion()
            throws
        {
            let root = try makeRoot()
            let eventTime = makeDate(hour: 23).addingTimeInterval(59 * 60 + 59)
            let snapshotTime = eventTime.addingTimeInterval(2)
            let payload = semanticPayload(id: "midnight-semantic", timestamp: snapshotTime)
            let event = HistoryEvent(
                id: "midnight-event",
                sessionID: "midnight-session",
                timestamp: eventTime,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Across midnight", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: payload.reference
            )
            try write(events: [event], payloads: [payload], root: root)
            let episode = try XCTUnwrap(
                ComputerHistoryEngine.analyze(events: [event], day: eventTime).episodes.first
            )

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: episode.id, day: eventTime)
            )

            XCTAssertEqual(
                selection.affectedDays,
                [Calendar.current.startOfDay(for: eventTime)]
            )
            XCTAssertEqual(
                selection.semanticDays,
                [Calendar.current.startOfDay(for: snapshotTime)]
            )

            let semanticStore = SemanticContextStore(
                semanticDirectory: root.appendingPathComponent("semantic", isDirectory: true)
            )
            try semanticStore.preflightSnapshotDeletion(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            )
            let completion = expectation(description: "cross-midnight semantic deletion")
            var deletedCount: Int?
            semanticStore.deleteSnapshots(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            ) { result in
                deletedCount = try? result.get()
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            XCTAssertEqual(deletedCount, 1)
            XCTAssertTrue(
                HistoryLocalStoreReader(rootDirectory: root).load().semanticSnapshots.isEmpty
            )
        }

        func testSessionResolverDoesNotSelectOverlappingOtherApplication() throws {
            let root = try makeRoot()
            let start = makeDate(hour: 13)
            let textEdit = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let safari = AppSnapshot(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 43
            )
            let selectedEvent = HistoryEvent(
                id: "session-selected",
                sessionID: "session-fixture",
                timestamp: start,
                kind: .mouseClick,
                app: textEdit,
                window: WindowSnapshot(title: "Selected window", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1)
            )
            let unrelated = HistoryEvent(
                id: "session-unrelated",
                sessionID: "session-fixture",
                timestamp: start,
                kind: .mouseClick,
                app: safari,
                window: WindowSnapshot(title: "Other window", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
            )
            try write(events: [selectedEvent, unrelated], payloads: [], root: root)
            let session = ActivitySession(
                id: "selected-session",
                start: start,
                end: start,
                appName: textEdit.name,
                bundleIdentifier: textEdit.bundleIdentifier,
                windowTitle: selectedEvent.window?.title,
                host: nil,
                category: nil,
                isWork: nil,
                confidence: nil,
                suppressionReason: nil,
                eventCount: 1,
                inputEventCount: 1,
                softwareAttributedEventCount: 0,
                kindCounts: [EventKind.mouseClick.rawValue: 1],
                latestMessage: nil
            )

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .activitySession(session)
            )

            XCTAssertEqual(selection.eventIDs, [selectedEvent.id])
            XCTAssertFalse(selection.eventIDs.contains(unrelated.id))
        }

        func testTargetedDeletionPipelinePreservesUnrelatedSourceAndOtherDays() throws {
            let root = try makeRoot()
            let codex = root.appendingPathComponent("codex-memory", isDirectory: true)
            let computerHistory = root.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: computerHistory,
                withIntermediateDirectories: true
            )
            let start = makeDate(hour: 12)
            let app = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let targetedPayload = semanticPayload(id: "pipeline-targeted", timestamp: start)
            let retainedPayload = semanticPayload(
                id: "pipeline-retained",
                timestamp: start.addingTimeInterval(3_600)
            )
            let targeted = HistoryEvent(
                id: "pipeline-targeted-event",
                sessionID: "pipeline",
                timestamp: start,
                kind: .mouseClick,
                app: app,
                window: WindowSnapshot(title: "Targeted work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: targetedPayload.reference
            )
            let unrelated = HistoryEvent(
                id: "pipeline-unrelated-event",
                sessionID: "pipeline",
                timestamp: start.addingTimeInterval(3_600),
                kind: .mouseClick,
                app: app,
                window: WindowSnapshot(title: "Unrelated work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1),
                semanticContext: retainedPayload.reference
            )
            try write(
                events: [targeted, unrelated],
                payloads: [targetedPayload, retainedPayload],
                root: root
            )
            for key in ["2026-08-23", "2026-08-24"] {
                try Data("derived-\(key)".utf8).write(
                    to: root.appendingPathComponent("analysis/\(key).analysis.json")
                )
                try Data("derived-\(key)".utf8).write(
                    to: root.appendingPathComponent("memories/\(key).memory.json")
                )
                try Data("derived-\(key)".utf8).write(
                    to: computerHistory.appendingPathComponent(
                        "\(key).computer-history.json"
                    )
                )
                try Data("derived-\(key)".utf8).write(
                    to: codex.appendingPathComponent(
                        "\(key)-goalong-computer-history.md"
                    )
                )
            }
            let memory = ComputerHistoryEngine.analyze(
                events: [targeted, unrelated],
                semanticSnapshots: [
                    targetedPayload.id: targetedPayload,
                    retainedPayload.id: retainedPayload,
                ],
                day: start
            )
            let targetedEpisode = try XCTUnwrap(
                memory.episodes.first(where: { $0.provenance.sourceEventIDs.contains(targeted.id) })
            )
            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: targetedEpisode.id, day: start)
            )
            let semanticStore = SemanticContextStore(
                semanticDirectory: root.appendingPathComponent("semantic", isDirectory: true)
            )
            try semanticStore.preflightSnapshotDeletion(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            )
            let derivedPlan = try DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            ).prepareDeletion(days: selection.affectedDays)
            let rawStore = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: root.appendingPathComponent("events", isDirectory: true),
                prepareApplicationStorage: false
            )
            let rawCompletion = expectation(description: "pipeline raw deletion")
            var rawOutcome: JSONLTargetedDeletionOutcome?
            rawStore.deleteEvents(
                withIDs: selection.eventIDs,
                from: selection.start,
                through: selection.end
            ) { result in
                rawOutcome = try? result.get()
                rawCompletion.fulfill()
            }
            wait(for: [rawCompletion], timeout: 2)
            let raw = try XCTUnwrap(rawOutcome)

            let semanticCompletion = expectation(description: "pipeline semantic deletion")
            var semanticDeleted: Int?
            semanticStore.deleteSnapshots(
                withIDs: selection.semanticSnapshotIDs.union(raw.semanticSnapshotIDs),
                on: selection.semanticDays
            ) { result in
                semanticDeleted = try? result.get()
                semanticCompletion.fulfill()
            }
            wait(for: [semanticCompletion], timeout: 2)
            let derived = try derivedPlan.execute()

            XCTAssertEqual(raw.eventCount, 1)
            XCTAssertEqual(semanticDeleted, 1)
            XCTAssertEqual(derived.total, 4)
            let remainingEvents = HistoryLocalStoreReader(rootDirectory: root).load().events
            XCTAssertEqual(remainingEvents.map(\.id), [unrelated.id])
            let remainingSemantic = HistoryLocalStoreReader(rootDirectory: root)
                .load().semanticSnapshots
            XCTAssertEqual(Set(remainingSemantic.keys), [retainedPayload.id])
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "computer-history/2026-08-23.computer-history.json"
                    ).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "computer-history/2026-08-24.computer-history.json"
                    ).path
                )
            )
        }

        private func makeRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-targeted-deletion-\(UUID().uuidString)",
                isDirectory: true
            )
            for name in ["events", "semantic", "memories", "analysis"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            roots.append(root)
            return root
        }

        private func write(
            events: [HistoryEvent],
            payloads: [SemanticContextPayload],
            root: URL
        ) throws {
            for (day, dayEvents) in Dictionary(
                grouping: events,
                by: { AppPaths.localDayString(for: $0.timestamp) }
            ) {
                var eventData = Data()
                for event in dayEvents {
                    eventData.append(try encoder.encode(event))
                    eventData.append(0x0A)
                }
                try eventData.write(
                    to: root.appendingPathComponent("events/\(day).jsonl")
                )
            }

            for (day, dayPayloads) in Dictionary(
                grouping: payloads,
                by: { AppPaths.localDayString(for: $0.capturedAt) }
            ) {
                var semanticData = Data()
                for payload in dayPayloads {
                    semanticData.append(try encoder.encode(payload))
                    semanticData.append(0x0A)
                }
                try semanticData.write(
                    to: root.appendingPathComponent("semantic/\(day).semantic.jsonl")
                )
            }
        }

        private func semanticPayload(id: String, timestamp: Date) -> SemanticContextPayload {
            let text = "targeted semantic fixture"
            return SemanticContextPayload(
                id: id,
                capturedAt: timestamp,
                application: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
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

        private var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        private func makeDate(hour: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 23, hour: hour)
            )!
        }
    }
#endif
