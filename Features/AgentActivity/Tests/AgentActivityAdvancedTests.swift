import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest

@testable import AgentActivity

final class AgentActivityAdvancedTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testNormalizedKeyCollisionsAndReversedJSONOrderProduceIdenticalTransientSummary() throws {
        let canonicalSessionID = "CANONICAL-SESSION-CONTENT-SENTINEL"
        let canonicalTitle = "Canonical title content sentinel"
        let canonicalExcerpt = "CANONICAL-EXCERPT-CONTENT-SENTINEL"
        let canonicalTool = "CANONICAL-TOOL-CONTENT-SENTINEL"
        let forward = Data(
            #"{"z_branch":{"session-id":"later-session","task-title":"Later title","con-tent":"LATER-EXCERPT-CONTENT-SENTINEL","role":"user","type":"tool_call","tool-name":"later-tool"},"a-branch":{"session_id":"shadow-session","session-id":"CANONICAL-SESSION-CONTENT-SENTINEL","task_title":"Shadow title","task-title":"Canonical title content sentinel","content":"SHADOW-EXCERPT-CONTENT-SENTINEL","con-tent":"CANONICAL-EXCERPT-CONTENT-SENTINEL","role":"user","type":"tool_call","tool_name":"shadow-tool","tool-name":"CANONICAL-TOOL-CONTENT-SENTINEL"}}"#
                .utf8
        )
        let reversed = Data(
            #"{"a-branch":{"tool-name":"CANONICAL-TOOL-CONTENT-SENTINEL","tool_name":"shadow-tool","type":"tool_call","role":"user","con-tent":"CANONICAL-EXCERPT-CONTENT-SENTINEL","content":"SHADOW-EXCERPT-CONTENT-SENTINEL","task-title":"Canonical title content sentinel","task_title":"Shadow title","session-id":"CANONICAL-SESSION-CONTENT-SENTINEL","session_id":"shadow-session"},"z_branch":{"tool-name":"later-tool","type":"tool_call","role":"user","con-tent":"LATER-EXCERPT-CONTENT-SENTINEL","task-title":"Later title","session-id":"later-session"}}"#
                .utf8
        )
        let fileURL = URL(fileURLWithPath: "/fixture/collision.json")

        let first = AgentTranscriptParser.parse(data: forward, fileURL: fileURL, provider: .custom)
        let second = AgentTranscriptParser.parse(data: reversed, fileURL: fileURL, provider: .custom)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sessionID, canonicalSessionID)
        XCTAssertEqual(first.title, canonicalTitle)
        XCTAssertEqual(first.excerpt, canonicalExcerpt)
        XCTAssertEqual(first.tools, [canonicalTool, "later-tool"])
        XCTAssertEqual(first.toolCallCount, 2)
        XCTAssertEqual(try summaryProjectionData(first), try summaryProjectionData(second))

        let sourceRoot = try makeTemporaryDirectory("deterministic-parser-source")
        let source = sourceRoot.appendingPathComponent("collision.json")
        try forward.write(to: source)
        let storeRoot = try makeTemporaryDirectory("deterministic-parser-store")
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let observedAt = Date(timeIntervalSince1970: 1_787_472_000)
        let reference = AgentSourceReference(kind: .file, path: source.path)
        let index = AgentSourceIndexEntry(
            id: canonicalSessionID,
            stableConversationID: canonicalSessionID,
            watchedFolderID: "deterministic-parser-folder",
            watchedFolderName: "Fixture",
            provider: .custom,
            reference: reference,
            relativePath: source.lastPathComponent,
            sourceCreatedAt: observedAt,
            sourceModifiedAt: observedAt,
            firstIndexedAt: observedAt,
            lastObservedAt: observedAt,
            byteCount: Int64(forward.count),
            sha256: sha256Hex(forward)
        )
        try store.upsert(
            AgentCaptureRecord(index: index, summary: first),
            maximumEntries: 10
        )

        let forbiddenContents = [canonicalSessionID, canonicalTitle, canonicalExcerpt, canonicalTool]
            .map { Data($0.utf8) }
        for persistedFile in try regularFiles(beneath: storeRoot) {
            let persistedData = try Data(contentsOf: persistedFile)
            for forbiddenContent in forbiddenContents {
                XCTAssertNil(persistedData.range(of: forbiddenContent))
            }
        }
    }

    func testIncrementalJSONLinesHandlesUnicodeChunkBoundariesOversizedLineAndFinalLine() throws {
        let sessionID = "10000000-0000-4000-8000-000000000001"
        let first = try jsonLine([
            "session_id": sessionID,
            "timestamp": "2026-08-23T08:00:00Z",
            "role": "user",
            "content": "Bonjour 👩🏽‍💻 — café au lait",
        ])
        let oversized = Data(
            (#"{"role":"assistant","content":""#
                + String(repeating: "x", count: AgentTranscriptParser.maximumBufferedLineBytes + 100)
                + #""}"#).utf8
        )
        let final = try jsonLine([
            "timestamp": "2026-08-23T08:00:02Z",
            "role": "assistant",
            "content": "Dernière ligne sans saut final",
        ])
        var payload = Data()
        payload.append(first)
        payload.append(0x0A)
        payload.append(oversized)
        payload.append(0x0A)
        payload.append(final)

        var parser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: URL(fileURLWithPath: "/fixture/session.jsonl"),
            provider: .codex
        )
        let emojiBytes = Data("👩🏽‍💻".utf8)
        let emojiRange = try XCTUnwrap(payload.range(of: emojiBytes))
        let forcedSplit = emojiRange.lowerBound + 1
        parser.consume(payload.subdata(in: 0..<forcedSplit))
        parser.consume(payload.subdata(in: forcedSplit..<(forcedSplit + 1)))
        let chunkPattern = [1, 2, 7, 31, 4_093, 65_537]
        var offset = forcedSplit + 1
        var chunkIndex = 0
        while offset < payload.count {
            let length = min(chunkPattern[chunkIndex % chunkPattern.count], payload.count - offset)
            parser.consume(payload.subdata(in: offset..<(offset + length)))
            offset += length
            chunkIndex += 1
        }

        let summary = parser.finish()
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.messageCount, 2, "The oversized line must be skipped without losing the next line")
        XCTAssertEqual(summary.userMessageCount, 1)
        XCTAssertEqual(summary.assistantMessageCount, 1)
        XCTAssertTrue(summary.excerpt?.contains("👩🏽‍💻") == true)
        XCTAssertEqual(summary.startedAt, isoDate("2026-08-23T08:00:00Z"))
        XCTAssertEqual(summary.endedAt, isoDate("2026-08-23T08:00:02Z"))
        XCTAssertLessThanOrEqual(parser.peakBufferedBytes, AgentTranscriptParser.maximumBufferedLineBytes)

        let sourceRoot = try makeTemporaryDirectory("streaming-source")
        let sessionDirectory = sourceRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let source = sessionDirectory.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-\(sessionID).jsonl"
        )
        try payload.write(to: source)
        let original = try snapshot(of: source)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("streaming-store"))
        let folder = AgentWatchedFolder(
            id: "codex-streaming",
            displayName: "Codex",
            path: sourceRoot.path,
            provider: .codex
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_100)
        )
        let capture = try XCTUnwrap(result.captures.first)
        XCTAssertEqual(capture.sha256, sha256Hex(payload))
        XCTAssertEqual(capture.byteCount, Int64(payload.count))
        XCTAssertEqual(try snapshot(of: source), original, "Direct analysis must not mutate its source")
    }

    func testBorrowedReadBuffersMatchDataParserAcrossChunkBoundaries() throws {
        let payload = Data(
            """
            {"session_id":"borrowed-buffer","timestamp":"2026-08-23T08:00:00Z","role":"user","content":"Vérifier 👩🏽‍💻 sans copie de chunk"}
            {"session_id":"borrowed-buffer","timestamp":"2026-08-23T08:00:01Z","role":"assistant","content":"Terminé"}
            """.utf8
        )
        let fileURL = URL(fileURLWithPath: "/fixture/borrowed-buffer.jsonl")
        var dataParser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: fileURL,
            provider: .codex
        )
        var borrowedParser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: fileURL,
            provider: .codex
        )
        let chunkPattern = [1, 3, 17, 64, 127]
        var offset = 0
        var chunkIndex = 0
        while offset < payload.count {
            let count = min(chunkPattern[chunkIndex % chunkPattern.count], payload.count - offset)
            let chunk = payload.subdata(in: offset..<(offset + count))
            dataParser.consume(chunk)
            chunk.withUnsafeBytes { borrowedParser.consume(bytes: $0) }
            offset += count
            chunkIndex += 1
        }

        XCTAssertEqual(borrowedParser.finish(), dataParser.finish())
        XCTAssertLessThanOrEqual(
            borrowedParser.peakBufferedBytes,
            AgentTranscriptParser.maximumBufferedLineBytes
        )
    }

    func testSelectedDayJSONLAnalysisSkipsOutOfRangeCodexBodies() throws {
        let sessionID = "20000000-0000-4000-8000-000000000002"
        let lines = [
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"session_meta","payload":{"id":"20000000-0000-4000-8000-000000000002"}}"#,
            #"{"timestamp":"2026-08-26T21:59:59.999Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"BEFORE-DAY-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T08:00:00.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"text":"SYSTEM-PROMPT-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T08:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<in-app-browser-context source=\"ambient-ui-state\">AMBIENT-SENTINEL</in-app-browser-context>\n\n## My request:\nSelected-day request"}]}}"#,
            #"{"timestamp":"2026-08-27T08:00:00.200Z","type":"response_item","payload":{"type":"reasoning","summary":[{"text":"REASONING-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T08:00:00.300Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"text":"PROGRESS-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T08:00:00.400Z","type":"response_item","payload":{"type":"function_call","name":"PROCESS-TOOL-SENTINEL"}}"#,
            #"{"timestamp":"2026-08-27T08:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Selected-day final response"}]}}"#,
            #"{"timestamp":"2026-08-27T22:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"AFTER-DAY-SENTINEL"}]}}"#,
        ]
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        let interval = DateInterval(
            start: try XCTUnwrap(isoDate("2026-08-26T22:00:00Z")),
            end: try XCTUnwrap(isoDate("2026-08-27T22:00:00Z"))
        )
        var parser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: URL(fileURLWithPath: "/fixture/selected-day.jsonl"),
            provider: .codex,
            analysisInterval: interval
        )

        payload.withUnsafeBytes { parser.consume(bytes: $0) }
        let summary = parser.finish()

        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.messageCount, 4)
        XCTAssertEqual(summary.userMessageCount, 1)
        XCTAssertEqual(summary.assistantMessageCount, 2)
        XCTAssertEqual(summary.systemMessageCount, 1)
        XCTAssertTrue(summary.excerpt?.contains("Selected-day request") == true)
        XCTAssertFalse(summary.excerpt?.contains("BEFORE-DAY-SENTINEL") == true)
        XCTAssertFalse(summary.excerpt?.contains("AFTER-DAY-SENTINEL") == true)
        XCTAssertEqual(
            summary.visibleMessages,
            [
                AgentVisibleMessage(role: .user, text: "Selected-day request"),
                AgentVisibleMessage(role: .assistantFinal, text: "Selected-day final response"),
            ]
        )
        let visibleText = summary.visibleMessages.map(\.text).joined(separator: "\n")
        for excluded in [
            "AMBIENT-SENTINEL", "SYSTEM-PROMPT-SENTINEL", "REASONING-SENTINEL",
            "PROGRESS-SENTINEL", "PROCESS-TOOL-SENTINEL",
        ] {
            XCTAssertFalse(visibleText.contains(excluded), "Leaked \(excluded)")
        }
    }

    func testOversizedOldCodexConversationReadsOnlyCompleteSelectedDayProjection() throws {
        let sourceRoot = try makeTemporaryDirectory("oversized-selected-day-source")
        let sessionDirectory = sourceRoot.appendingPathComponent(
            "sessions/2026/08/23",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let sessionID = "20000000-0000-4000-8000-000000000099"
        let source = sessionDirectory.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-\(sessionID).jsonl"
        )
        let sessionMetadata =
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"session_meta","payload":{"id":"20000000-0000-4000-8000-000000000099"}}"#
        var payload = Data((sessionMetadata + "\n").utf8)
        let filler = String(repeating: "x", count: 1_600)
        for index in 0..<210 {
            payload.append(
                Data(
                    (#"{"timestamp":"2026-08-28T20:00:00.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"text":"OLD-FILLER-"#
                        + String(index)
                        + "-"
                        + filler
                        + #""}]}}"#
                        + "\n").utf8
                )
            )
        }
        payload.append(
            Data(
                """
                {"timestamp":"2026-08-28T21:59:59.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"BEFORE-SELECTED-DAY"}]}}
                {"timestamp":"2026-08-29T08:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"Old conversation reused today"}]}}
                {"timestamp":"2026-08-29T08:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Selected-day answer"}]}}
                {"timestamp":"2026-08-30T00:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"AFTER-SELECTED-DAY"}]}}
                """.utf8
            )
        )
        try payload.write(to: source)
        let original = try snapshot(of: source)
        let folder = AgentWatchedFolder(
            id: "oversized-selected-day",
            displayName: "Codex",
            path: sourceRoot.path,
            provider: .codex
        )
        let candidate = try XCTUnwrap(
            AgentDirectSourceReader.discover(folder: folder).first
        )
        let interval = DateInterval(
            start: try XCTUnwrap(isoDate("2026-08-28T22:00:00Z")),
            end: try XCTUnwrap(isoDate("2026-08-29T22:00:00Z"))
        )

        let record = try AgentDirectSourceReader.read(
            candidate: candidate,
            folder: folder,
            previous: nil,
            maximumBytes: 256 * 1_024,
            analysisInterval: interval
        )

        XCTAssertGreaterThan(Int64(payload.count), 256 * 1_024)
        XCTAssertEqual(record.digestScope, .selectedIntervalProjection)
        XCTAssertEqual(record.analysisInterval, interval)
        XCTAssertTrue(record.projectionIsComplete)
        let startOffset = try XCTUnwrap(record.index.startOffset)
        let endOffset = try XCTUnwrap(record.index.endOffset)
        XCTAssertGreaterThan(startOffset, 0)
        XCTAssertLessThan(endOffset - startOffset, Int64(payload.count))
        XCTAssertEqual(record.byteCount, Int64(payload.count))
        XCTAssertNotEqual(record.sha256, sha256Hex(payload))
        XCTAssertEqual(
            record.summary.visibleMessages,
            [
                AgentVisibleMessage(role: .user, text: "Old conversation reused today"),
                AgentVisibleMessage(role: .assistantFinal, text: "Selected-day answer"),
            ]
        )
        XCTAssertEqual(try snapshot(of: source), original)
    }

    func testCodexVisibleDialogueRemovesInjectedContextCompactionsAndReceipts() throws {
        let lines = [
            ##"{"timestamp":"2026-08-27T10:00:00.000Z","type":"session_meta","payload":{"id":"visible-sanitization"}}"##,
            ##"{"timestamp":"2026-08-27T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<summary>COMPACTION-SENTINEL</summary>"}]}}"##,
            ##"{"timestamp":"2026-08-27T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"# AGENTS.md instructions\nAGENT-INSTRUCTION-SENTINEL"}]}}"##,
            ##"{"timestamp":"2026-08-27T10:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<environment_context>ENVIRONMENT-SENTINEL</environment_context>"}]}}"##,
            ##"{"timestamp":"2026-08-27T10:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<codex_delegation><source_thread_id>opaque</source_thread_id><input>Delegated user request</input></codex_delegation>"}]}}"##,
            ##"{"timestamp":"2026-08-27T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Visible final reply\n<oai-mem-citation>MEMORY-RECEIPT-SENTINEL</oai-mem-citation>"}]}}"##,
        ]
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        let interval = DateInterval(
            start: try XCTUnwrap(isoDate("2026-08-26T22:00:00Z")),
            end: try XCTUnwrap(isoDate("2026-08-27T22:00:00Z"))
        )
        var parser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: URL(fileURLWithPath: "/fixture/codex-visible-sanitization.jsonl"),
            provider: .codex,
            analysisInterval: interval
        )

        parser.consume(payload)
        let summary = parser.finish()

        XCTAssertEqual(
            summary.visibleMessages,
            [
                AgentVisibleMessage(role: .user, text: "Delegated user request"),
                AgentVisibleMessage(role: .assistantFinal, text: "Visible final reply"),
            ]
        )
        let visibleText = summary.visibleMessages.map(\.text).joined(separator: "\n")
        for excluded in [
            "COMPACTION-SENTINEL", "AGENT-INSTRUCTION-SENTINEL",
            "ENVIRONMENT-SENTINEL", "MEMORY-RECEIPT-SENTINEL",
        ] {
            XCTAssertFalse(visibleText.contains(excluded), "Leaked \(excluded)")
        }
    }

    func testSelectedDaySnapshotAcceptsOnlySameInodeAppendOnlyGrowth() throws {
        let directory = try makeTemporaryDirectory("append-only-snapshot")
        let source = directory.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: source)
        var initial = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &initial), 0)

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        var appended = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &appended), 0)
        XCTAssertTrue(
            AgentDirectSourceReader.isSameAppendOnlyFile(
                appended,
                initialStatus: initial
            )
        )

        try Data("x".utf8).write(to: source, options: [.atomic])
        var replaced = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &replaced), 0)
        XCTAssertFalse(
            AgentDirectSourceReader.isSameAppendOnlyFile(
                replaced,
                initialStatus: initial
            )
        )
    }

    func testClaudeVisibleDialogueKeepsUserTextAndLastAssistantTextOnly() {
        let lines = [
            #"{"timestamp":"2026-08-27T09:00:00.000Z","type":"system","message":{"role":"system","content":"CLAUDE-SYSTEM-SENTINEL"}}"#,
            #"{"timestamp":"2026-08-27T09:01:00.000Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"Claude user request"},{"type":"tool_result","content":"CLAUDE-TOOL-RESULT-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T09:02:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"CLAUDE-PROGRESS-SENTINEL"},{"type":"tool_use","name":"CLAUDE-TOOL-SENTINEL"}]}}"#,
            #"{"timestamp":"2026-08-27T09:03:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Claude final response"}]}}"#,
            #"{"timestamp":"2026-08-27T09:04:00.000Z","type":"user","message":{"role":"user","content":"Second Claude request"}}"#,
            #"{"timestamp":"2026-08-27T09:05:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"CLAUDE-THINKING-SENTINEL"},{"type":"text","text":"Second Claude final"}]}}"#,
        ]
        var parser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: URL(fileURLWithPath: "/fixture/claude-visible.jsonl"),
            provider: .claudeCode
        )

        parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = parser.finish()

        XCTAssertEqual(
            summary.visibleMessages,
            [
                AgentVisibleMessage(role: .user, text: "Claude user request"),
                AgentVisibleMessage(role: .assistantFinal, text: "Claude final response"),
                AgentVisibleMessage(role: .user, text: "Second Claude request"),
                AgentVisibleMessage(role: .assistantFinal, text: "Second Claude final"),
            ]
        )
        let visibleText = summary.visibleMessages.map(\.text).joined(separator: "\n")
        for excluded in [
            "CLAUDE-SYSTEM-SENTINEL", "CLAUDE-TOOL-RESULT-SENTINEL",
            "CLAUDE-PROGRESS-SENTINEL", "CLAUDE-TOOL-SENTINEL",
            "CLAUDE-THINKING-SENTINEL",
        ] {
            XCTAssertFalse(visibleText.contains(excluded), "Leaked \(excluded)")
        }
    }

    func testFirstCodexDiscoveryIndexes150MetadataOnlyThenUsesCursorWithoutReads() throws {
        let sourceRoot = try makeTemporaryDirectory("bulk-codex-source")
        let sessionDirectory = sourceRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        for index in 0..<150 {
            let sessionID = deterministicUUID(index)
            let line = try jsonLine([
                "session_id": sessionID,
                "timestamp": "2026-08-23T08:00:00Z",
                "role": "user",
                "content": "fixture message \(index)",
            ])
            try line.write(
                to: sessionDirectory.appendingPathComponent(
                    "rollout-2026-08-23T08-00-00-\(sessionID).jsonl"
                )
            )
        }

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("bulk-codex-store"))
        let folder = AgentWatchedFolder(
            id: "bulk-codex",
            displayName: "Codex",
            path: sourceRoot.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            fullDiscoveryIntervalSeconds: 900,
            maximumIndexEntries: 1_000
        )
        let firstAt = Date(timeIntervalSince1970: 1_787_472_100)
        let analysisDay = Date(timeIntervalSince1970: 946_684_800)
        let scanner = AgentActivityScanner(store: store)
        let first = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: analysisDay,
            at: firstAt
        )

        XCTAssertEqual(first.scannedSourceCount, 150)
        XCTAssertEqual(first.changedSourceCount, 150)
        XCTAssertEqual(first.fullDiscoveryCount, 1)
        XCTAssertEqual(first.captures.count, 150)
        XCTAssertTrue(
            first.captures.allSatisfy { !$0.isAnalyzed },
            "An unrelated day must return metadata records without retaining transcript analysis"
        )
        XCTAssertEqual(store.indexEntryCount(), 150)
        XCTAssertEqual(store.lastFullDiscovery(folderID: folder.id), firstAt)
        XCTAssertTrue(store.entries(folderID: folder.id).allSatisfy { store.cachedRecord(id: $0.id) == nil })

        let second = scanner.scan(
            configuration: configuration,
            analysisDay: analysisDay,
            at: firstAt.addingTimeInterval(10)
        )
        XCTAssertEqual(second.scannedSourceCount, 0)
        XCTAssertEqual(second.changedSourceCount, 0)
        XCTAssertEqual(second.fullDiscoveryCount, 0)
        XCTAssertEqual(second.skippedSourceCount, 150)
    }

    func testPerSourceFailureIsIndexedWithoutPoisoningDiscoveryCursor() throws {
        let sourceRoot = try makeTemporaryDirectory("cursor-failure-source")
        let sessionDirectory = sourceRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionID = "20000000-0000-4000-8000-000000000001"
        let source = sessionDirectory.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-\(sessionID).jsonl"
        )
        try Data(repeating: 0x61, count: 70 * 1_024).write(to: source)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("cursor-failure-store"))
        let folder = AgentWatchedFolder(
            id: "cursor-failure",
            displayName: "Codex",
            path: sourceRoot.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            maximumFileBytes: 64 * 1_024,
            maximumIndexEntries: 1_000
        )
        let firstAt = Date(timeIntervalSince1970: 1_787_472_100)
        let scanner = AgentActivityScanner(store: store)
        let failed = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: firstAt)

        XCTAssertEqual(failed.fullDiscoveryCount, 1)
        XCTAssertEqual(store.lastFullDiscovery(folderID: folder.id), firstAt)
        XCTAssertFalse(failed.failures.isEmpty)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(store.entries(folderID: folder.id).first?.availability, .inaccessible)

        try jsonLine([
            "session_id": sessionID,
            "role": "user",
            "content": "small enough after recovery",
        ]).write(to: source, options: .atomic)
        let recoveredAt = firstAt.addingTimeInterval(1)
        let recovered = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: recoveredAt)
        XCTAssertEqual(recovered.fullDiscoveryCount, 1)
        XCTAssertEqual(store.lastFullDiscovery(folderID: folder.id), recoveredAt)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(store.entries(folderID: folder.id).first?.availability, .available)
    }

    func testCodexMoveToArchivedKeepsStableIDWithoutDuplicationAndRestartRehashIsUnchanged() throws {
        let sourceRoot = try makeTemporaryDirectory("codex-move-source")
        let sessions = sourceRoot.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = "30000000-0000-4000-8000-000000000001"
        let original = sessions.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-\(sessionID).jsonl"
        )
        try codexTranscript(sessionID: sessionID, message: "move me").write(to: original)

        let storeRoot = try makeTemporaryDirectory("codex-move-store")
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let folder = AgentWatchedFolder(
            id: "codex-move",
            displayName: "Codex",
            path: sourceRoot.path,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            fullDiscoveryIntervalSeconds: 900,
            maximumIndexEntries: 1_000
        )
        let firstAt = Date(timeIntervalSince1970: 1_787_472_100)
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: firstAt)
        let firstEntry = try XCTUnwrap(store.entries(folderID: folder.id).first)

        let archived = sourceRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let moved = archived.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.moveItem(at: original, to: moved)
        let movedResult = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: firstAt.addingTimeInterval(10)
        )

        XCTAssertEqual(movedResult.changedSourceCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 1)
        let movedEntry = try XCTUnwrap(store.entries(folderID: folder.id).first)
        XCTAssertEqual(movedEntry.id, firstEntry.id)
        XCTAssertEqual(movedEntry.stableConversationID, firstEntry.stableConversationID)
        XCTAssertTrue(AgentStableConversationIdentifier.isPersisted(movedEntry.stableConversationID))
        XCTAssertEqual(movedEntry.reference.path, moved.path)
        XCTAssertEqual(movedEntry.availability, .available)

        let reloaded = try AgentActivityStore(rootDirectory: storeRoot)
        let periodic = AgentActivityScanner(store: reloaded).scan(
            configuration: configuration,
            at: firstAt.addingTimeInterval(920)
        )
        XCTAssertEqual(periodic.scannedSourceCount, 0)
        XCTAssertEqual(periodic.changedSourceCount, 0)
        XCTAssertEqual(reloaded.indexEntryCount(), 1)
        XCTAssertEqual(reloaded.entries(folderID: folder.id).first?.id, firstEntry.id)
    }

    func testAlternatingStoreInstancesMergeWithoutLostEntries() throws {
        let root = try makeTemporaryDirectory("alternating-store")
        let first = try AgentActivityStore(rootDirectory: root)
        let second = try AgentActivityStore(rootDirectory: root)
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)

        for batch in 0..<6 {
            let lowerBound = batch * 20
            let records = (lowerBound..<(lowerBound + 20)).map {
                record(id: "alternating-\($0)", observedAt: observedAt.addingTimeInterval(Double($0)))
            }
            let writer = batch.isMultiple(of: 2) ? first : second
            _ = try writer.upsertBatch(records, maximumEntries: 500)
        }

        XCTAssertEqual(first.indexEntryCount(), 120)
        XCTAssertEqual(second.indexEntryCount(), 120)
        XCTAssertEqual(Set(first.entries().map(\.id)).count, 120)
        XCTAssertEqual(Set(second.entries().map(\.id)), Set(first.entries().map(\.id)))
        XCTAssertTrue(first.indexIsValid(maximumEntries: 500))
        XCTAssertTrue(second.indexIsValid(maximumEntries: 500))
    }

    func testEveryFilePolicyStillRejectsCredentialsTokensOAuthAndBackups() throws {
        let root = try makeTemporaryDirectory("sensitive-policy")
        let safe = root.appendingPathComponent("conversation.json")
        let sensitive = [
            ".credentials.json",
            ".tokens.backup.json",
            "oauth-profile.json",
            "session-token-copy.json",
            "credentials.old.json",
            "apiKey-session.txt",
        ].map { root.appendingPathComponent($0) }
        try Data(#"{"messages":[]}"#.utf8).write(to: safe)
        for file in sensitive { try Data("sensitive".utf8).write(to: file) }
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let nestedBackup = backupDirectory.appendingPathComponent("conversation.jsonl")
        try Data(#"{"role":"user"}"#.utf8).write(to: nestedBackup)

        XCTAssertTrue(AgentScannerPolicy.shouldIndex(safe, mode: .everyFile, sourceRoot: root))
        for file in sensitive {
            XCTAssertFalse(
                AgentScannerPolicy.shouldIndex(file, mode: .everyFile, sourceRoot: root),
                "Sensitive file unexpectedly accepted: \(file.lastPathComponent)"
            )
        }
        XCTAssertFalse(AgentScannerPolicy.shouldIndex(nestedBackup, mode: .everyFile, sourceRoot: root))
        XCTAssertTrue(AgentScannerPolicy.shouldSkipDirectory(backupDirectory))
    }

    func testGeminiAndCopilotDiscoverOnlyCanonicalConversationFiles() throws {
        let home = try makeTemporaryDirectory("gemini-copilot-home")
        let geminiRoot = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let projectHash = String(repeating: "a", count: 64)
        let geminiChats = geminiRoot.appendingPathComponent("\(projectHash)/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiChats, withIntermediateDirectories: true)
        let geminiSession = geminiChats.appendingPathComponent("session-2026-08-23T08-00-fixture.json")
        try jsonObject([
            "sessionId": "gemini-exact",
            "startTime": "2026-08-23T08:00:00Z",
            "lastUpdated": "2026-08-23T08:01:00Z",
            "messages": [["type": "user", "content": "GEMINI-EXACT-SENTINEL"]],
        ]).write(to: geminiSession)
        let geminiNeighbors = [
            geminiRoot.appendingPathComponent("\(projectHash)/oauth_creds.json"),
            geminiRoot.appendingPathComponent("\(projectHash)/profile.json"),
            geminiRoot.appendingPathComponent("\(projectHash)/chats/tokens.json"),
        ]
        for file in geminiNeighbors {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"secret":"must-not-index"}"#.utf8).write(to: file)
        }

        let copilotRoot = home.appendingPathComponent(
            "Library/Application Support/Code/User/workspaceStorage",
            isDirectory: true
        )
        let workspaceHash = String(repeating: "b", count: 32)
        let copilotWorkspace = copilotRoot.appendingPathComponent(workspaceHash, isDirectory: true)
        let copilotSessions = copilotWorkspace.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: copilotSessions, withIntermediateDirectories: true)
        let copilotSession = copilotSessions.appendingPathComponent("00000000-0000-4000-8000-000000000001.json")
        try jsonObject([
            "sessionId": "copilot-exact",
            "creationDate": "2026-08-23T08:00:00Z",
            "requests": [["message": ["text": "COPILOT-EXACT-SENTINEL"]]],
        ]).write(to: copilotSession)
        let editingState = copilotWorkspace.appendingPathComponent(
            "chatEditingSessions/00000000-0000-4000-8000-000000000001/state.json"
        )
        try FileManager.default.createDirectory(
            at: editingState.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copilotNeighbors = [
            copilotWorkspace.appendingPathComponent("workspace.json"),
            copilotWorkspace.appendingPathComponent("state.vscdb"),
            copilotWorkspace.appendingPathComponent("state.vscdb.backup"),
            editingState,
        ]
        for file in copilotNeighbors { try Data("must-not-index".utf8).write(to: file) }

        let defaultFolders = AgentDefaultSourceDiscovery.discover(homeDirectory: home)
        XCTAssertEqual(defaultFolders.first(where: { $0.provider == .gemini })?.path, geminiRoot.path)
        XCTAssertEqual(defaultFolders.first(where: { $0.provider == .copilot })?.path, copilotRoot.path)

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("gemini-copilot-store"))
        let folders = [
            AgentWatchedFolder(id: "gemini", displayName: "Gemini", path: geminiRoot.path, provider: .gemini),
            AgentWatchedFolder(id: "copilot", displayName: "Copilot", path: copilotRoot.path, provider: .copilot),
        ]
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: folders, maximumIndexEntries: 1_000),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_100)
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 2)
        XCTAssertEqual(Set(store.entries().map(\.reference.path)), Set([geminiSession.path, copilotSession.path]))
        XCTAssertEqual(Set(store.entries().map(\.provider)), Set([.gemini, .copilot]))
        XCTAssertTrue(
            geminiNeighbors.allSatisfy { neighbor in
                !store.entries().contains(where: { $0.reference.path == neighbor.path })
            })
        XCTAssertTrue(
            copilotNeighbors.allSatisfy { neighbor in
                !store.entries().contains(where: { $0.reference.path == neighbor.path })
            })
    }

    func testOpenCodeNonemptyWALIsDeferredWithoutMutatingDatabaseSidecars() throws {
        let root = try makeTemporaryDirectory("opencode-live-wal")
        let databaseURL = root.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { if database != nil { sqlite3_close(database) } }
        try executeSQLite(database, "PRAGMA journal_mode=WAL")
        try executeSQLite(database, "PRAGMA wal_autocheckpoint=0")
        try createOpenCodeSchemaAndFixture(database, sessionID: "live-wal-session")

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        XCTAssertGreaterThan((try? Data(contentsOf: walURL).count) ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
        let namesBefore = try childNames(of: root)
        let before = try [databaseURL, walURL, shmURL].map { try snapshot(of: $0) }

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("opencode-live-wal-store"))
        let folder = AgentWatchedFolder(
            id: "opencode-live-wal",
            displayName: "OpenCode",
            path: root.path,
            provider: .openCode
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_100)
        )

        XCTAssertFalse(result.failures.isEmpty, "A live non-empty WAL must be deferred instead of checkpointed")
        let failureDetail = result.failures.joined(separator: " ").lowercased()
        XCTAssertTrue(
            failureDetail.contains("wal") || failureDetail.contains("defer")
                || failureDetail.contains("busy") || failureDetail.contains("inaccessible"),
            result.failures.joined(separator: "\n")
        )
        XCTAssertEqual(result.fullDiscoveryCount, 0)
        XCTAssertNil(store.lastFullDiscovery(folderID: folder.id))
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertEqual(try childNames(of: root), namesBefore)
        XCTAssertEqual(try [databaseURL, walURL, shmURL].map { try snapshot(of: $0) }, before)
    }

    func testOpenCodeEmptyWALReadsImmutableDatabaseWithoutMutatingSourceTree() throws {
        let root = try makeTemporaryDirectory("opencode-empty-wal")
        let databaseURL = root.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { if database != nil { sqlite3_close(database) } }
        try executeSQLite(database, "PRAGMA journal_mode=WAL")
        try executeSQLite(database, "PRAGMA wal_autocheckpoint=0")
        try createOpenCodeSchemaAndFixture(database, sessionID: "empty-wal-session")
        try executeSQLite(database, "PRAGMA wal_checkpoint(TRUNCATE)")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        XCTAssertEqual((try? Data(contentsOf: walURL).count), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
        let namesBefore = try childNames(of: root)
        let before = try [databaseURL, walURL, shmURL].map { try snapshot(of: $0) }

        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("opencode-empty-wal-store"))
        let folder = AgentWatchedFolder(
            id: "opencode-empty-wal",
            displayName: "OpenCode",
            path: root.path,
            provider: .openCode
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_100)
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(result.fullDiscoveryCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertTrue(
            store.entries().first.map {
                AgentStableConversationIdentifier.isPersisted($0.stableConversationID)
            } == true
        )
        XCTAssertEqual(try childNames(of: root), namesBefore)
        XCTAssertEqual(try [databaseURL, walURL, shmURL].map { try snapshot(of: $0) }, before)
    }

    func testStorageWhitelistAndIndependentByteCountExcludeTranscriptSentinels() throws {
        let sourceRoot = try makeTemporaryDirectory("storage-source")
        let source = sourceRoot.appendingPathComponent("conversation.trace")
        let textSentinel = Data("ADVANCED-TRANSCRIPT-SENTINEL-DO-NOT-COPY".utf8)
        let binarySentinel = Data([0x00, 0x91, 0xE3, 0x7F, 0xFF, 0x12, 0xA5, 0xC8, 0x03, 0xD4])
        var sourceData = textSentinel
        sourceData.append(binarySentinel)
        try sourceData.write(to: source)

        let root = try makeTemporaryDirectory("storage-store")
        let store = try AgentActivityStore(rootDirectory: root)
        let folder = AgentWatchedFolder(
            id: "storage-folder",
            displayName: "Storage fixture",
            path: sourceRoot.path,
            provider: .custom,
            captureMode: .everyFile
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder], maximumIndexEntries: 1_000)
        _ = try store.saveConfiguration(configuration)
        let result = AgentActivityScanner(store: store).scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_100)
        )
        XCTAssertEqual(result.changedSourceCount, 1)

        let relativeFiles = try regularFiles(beneath: root).map { relativePath($0, beneath: root) }
        XCTAssertTrue(
            relativeFiles.allSatisfy {
                $0 == "configuration.json" || $0 == "index.json" || $0.hasPrefix("signals/")
            }, "Unexpected Agent Activity storage files: \(relativeFiles)")
        let topLevelNames = try childNames(of: root)
        XCTAssertTrue(topLevelNames.isSubset(of: Set(["configuration.json", "index.json", "signals"])))

        var independentBytes: Int64 = 0
        for file in try regularFiles(beneath: root) {
            let data = try Data(contentsOf: file)
            independentBytes += Int64(data.count)
            XCTAssertNil(data.range(of: textSentinel), "Transcript text leaked into \(file.lastPathComponent)")
            XCTAssertNil(data.range(of: binarySentinel), "Transcript bytes leaked into \(file.lastPathComponent)")
        }
        XCTAssertEqual(store.storageBytes(), independentBytes)
        XCTAssertLessThan(independentBytes, 64 * 1_024)
    }

    func testTransientAnalysisCacheIsBoundedAndClearable() throws {
        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("transient-cache"))
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let records = (0..<300).map {
            record(id: "transient-\($0)", observedAt: observedAt.addingTimeInterval(Double($0)))
        }
        _ = try store.upsertBatch(records, maximumEntries: 500)

        XCTAssertEqual(store.indexEntryCount(), 300)
        XCTAssertEqual(store.latestRecords().filter(\.isAnalyzed).count, 256)
        XCTAssertEqual(records.filter { store.cachedRecord(id: $0.id) != nil }.count, 256)
        store.clearTransientAnalyses()
        XCTAssertEqual(store.latestRecords().filter(\.isAnalyzed).count, 0)
        XCTAssertTrue(records.allSatisfy { store.cachedRecord(id: $0.id) == nil })
    }

    func testContentFreeTransientMetricsHaveStrictLRUCardinalityBound() throws {
        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("metric-cache"))
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let records = (0..<5_000).map {
            record(id: "metric-\($0)", observedAt: observedAt.addingTimeInterval(Double($0)))
        }
        _ = try store.upsertBatch(records, maximumEntries: 6_000)

        XCTAssertEqual(store.indexEntryCount(), records.count)
        XCTAssertLessThanOrEqual(
            store.transientAnalysisCount(),
            AgentActivityStore.maximumTransientAnalysisMetrics
        )
        XCTAssertLessThanOrEqual(store.transientSummaryCount(), AgentActivityStore.maximumTransientRecords)
        XCTAssertLessThanOrEqual(
            store.transientSummaryByteCount(),
            AgentActivityStore.maximumTransientSummaryBytes
        )

        let metricCount = store.transientAnalysisCount()
        store.discardTransientSummaries()
        XCTAssertEqual(store.transientSummaryCount(), 0)
        XCTAssertEqual(store.transientSummaryByteCount(), 0)
        XCTAssertEqual(store.transientAnalysisCount(), metricCount)
    }

    private struct FileSnapshot: Equatable {
        var path: String
        var byteCount: Int64
        var sha256: String
        var modifiedAt: Date?
        var permissions: Int
    }

    private func record(id: String, observedAt: Date) -> AgentCaptureRecord {
        let path = "/fixture/\(id).jsonl"
        let index = AgentSourceIndexEntry(
            id: id,
            stableConversationID: id,
            watchedFolderID: "alternating-folder",
            watchedFolderName: "Fixture",
            provider: .custom,
            reference: AgentSourceReference(kind: .file, path: path),
            relativePath: "\(id).jsonl",
            sourceCreatedAt: observedAt,
            sourceModifiedAt: observedAt,
            firstIndexedAt: observedAt,
            lastObservedAt: observedAt,
            byteCount: Int64(id.utf8.count),
            sha256: sha256Hex(Data(id.utf8))
        )
        return AgentCaptureRecord(
            index: index,
            summary: AgentDocumentSummary(
                format: .jsonLines,
                sessionID: id,
                title: id,
                excerpt: "Transient summary \(id)",
                messageCount: 1,
                userMessageCount: 1
            ),
            isAnalyzed: true
        )
    }

    private func codexTranscript(sessionID: String, message: String) throws -> Data {
        var data = try jsonLine([
            "type": "session_meta",
            "timestamp": "2026-08-23T08:00:00Z",
            "payload": ["id": sessionID, "session_id": sessionID],
        ])
        data.append(0x0A)
        data.append(
            try jsonLine([
                "type": "response_item",
                "timestamp": "2026-08-23T08:00:01Z",
                "payload": ["role": "user", "content": message],
            ]))
        data.append(0x0A)
        return data
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func deterministicUUID(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012x", index)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func summaryProjectionData(_ summary: AgentDocumentSummary) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "excerpt": summary.excerpt ?? "",
                "sessionID": summary.sessionID ?? "",
                "title": summary.title ?? "",
                "toolCallCount": summary.toolCallCount,
                "tools": summary.tools,
            ],
            options: [.sortedKeys]
        )
    }

    private func snapshot(of url: URL) throws -> FileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url)
        return FileSnapshot(
            path: url.lastPathComponent,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            sha256: sha256Hex(data),
            modifiedAt: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        )
    }

    private func childNames(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func regularFiles(beneath root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else { return [] }
        return try enumerator.compactMap { element -> URL? in
            guard let url = element as? URL,
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { return nil }
            return url
        }
    }

    private func relativePath(_ file: URL, beneath root: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func createOpenCodeSchemaAndFixture(_ database: OpaquePointer?, sessionID: String) throws {
        try executeSQLite(
            database,
            "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)"
        )
        try executeSQLite(
            database,
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try executeSQLite(
            database,
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try executeSQLite(
            database,
            "INSERT INTO session VALUES ('\(sqlQuote(sessionID))', 'project', NULL, 'fixture', '/tmp/opencode-project', 'OpenCode fixture', '1', 1787472000000, 1787472060000)"
        )
        try executeSQLite(
            database,
            "INSERT INTO message VALUES ('message-1', '\(sqlQuote(sessionID))', 1787472000000, 1787472060000, '{\"role\":\"user\",\"time\":{\"created\":1787472000000}}')"
        )
        try executeSQLite(
            database,
            "INSERT INTO part VALUES ('part-1', 'message-1', '\(sqlQuote(sessionID))', 1787472000000, 1787472060000, '{\"type\":\"text\",\"text\":\"OpenCode fixture\"}')"
        )
    }

    private func executeSQLite(_ database: OpaquePointer?, _ statement: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, statement, nil, nil, &errorPointer)
        let message = errorPointer.map { String(cString: $0) }
        if let errorPointer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "AgentActivityAdvancedTests.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message ?? statement]
            )
        }
    }

    private func sqlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentActivityAdvancedTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
