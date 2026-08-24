#if os(macOS)
    import AgentActivity
    import Darwin
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class ChatGPTRecapTests: XCTestCase {
        func testRecapOneDayReadFeedsBothDerivedViewsAndRetainsComputerHistoryWhenSourceDisappears() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-recap-shared-cycle-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
            let codexMirror = container.appendingPathComponent("codex-memory", isDirectory: true)
            try FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: container) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))
            )
            let event = HistoryEvent(
                id: "recap-click",
                sessionID: "recap-shared-cycle-test",
                timestamp: day,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Fixture Document", role: "AXWindow", subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 40, y: 80, clickCount: 1),
                classification: LocalClassification(
                    category: "document_productivity",
                    isWork: true,
                    confidence: 0.9,
                    classifierVersion: "fixture"
                )
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var sourceData = try encoder.encode(event)
            sourceData.append(0x0A)
            let eventURL = eventsDirectory.appendingPathComponent(
                ActivityAnalysisPaths.dayString(day) + ".jsonl"
            )
            try sourceData.write(to: eventURL, options: [.atomic])

            let computerHistoryStore = ComputerHistoryStore(
                rootDirectory: root,
                codexMemoryDirectory: codexMirror
            )
            let built = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                for: day,
                rootDirectory: root,
                computerHistoryStore: computerHistoryStore
            )

            XCTAssertFalse(built.cycleResult.sourceAbsent)
            XCTAssertEqual(built.cycleResult.sourceReadPasses, 1)
            XCTAssertEqual(built.cycleResult.sourceBytesRead, Int64(sourceData.count))
            XCTAssertEqual(built.cycleResult.derivedViewsWritten, 2)
            XCTAssertEqual(built.activity.coverage.sourceEventCount, 1)
            XCTAssertEqual(built.computerHistory?.coverage.sourceEventCount, 1)

            let sourceBeforeRepeat = try Data(contentsOf: eventURL)
            let eventNamesBeforeRepeat = try FileManager.default.contentsOfDirectory(
                atPath: eventsDirectory.path
            ).sorted()
            let repeated = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                for: day,
                rootDirectory: root,
                computerHistoryStore: computerHistoryStore
            )
            XCTAssertTrue(repeated.cycleResult.usedCachedRevision)
            XCTAssertEqual(repeated.cycleResult.sourceReadPasses, 0)
            XCTAssertEqual(repeated.cycleResult.sourceBytesRead, 0)
            XCTAssertEqual(repeated.cycleResult.derivedViewsWritten, 0)
            XCTAssertEqual(repeated.activity, built.activity)
            XCTAssertEqual(repeated.computerHistory, built.computerHistory)
            XCTAssertEqual(try Data(contentsOf: eventURL), sourceBeforeRepeat)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: eventsDirectory.path).sorted(),
                eventNamesBeforeRepeat
            )

            try FileManager.default.removeItem(at: eventURL)
            let absent = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                for: day,
                rootDirectory: root,
                computerHistoryStore: computerHistoryStore
            )

            XCTAssertTrue(absent.cycleResult.sourceAbsent)
            XCTAssertEqual(absent.cycleResult.sourceReadPasses, 0)
            XCTAssertEqual(absent.activity.coverage.sourceEventCount, 0)
            XCTAssertEqual(absent.computerHistory, built.computerHistory)
        }

        func testRuntimeAndRecapTriggersShareSourceResultFailureAndBoundedCache() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "goalong-recap-single-flight-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
            let codexMirror = container.appendingPathComponent("codex-memory", isDirectory: true)
            try FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: container) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))
            )
            let dayKey = ActivityAnalysisPaths.dayString(day)
            let event = HistoryEvent(
                id: "recap-single-flight-click",
                sessionID: "recap-single-flight-test",
                timestamp: day,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Fixture Document", role: "AXWindow", subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 40, y: 80, clickCount: 1)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var sourceData = try encoder.encode(event)
            sourceData.append(0x0A)
            let eventURL = eventsDirectory.appendingPathComponent(dayKey + ".jsonl")
            try sourceData.write(to: eventURL, options: [.atomic])

            let computerHistoryStore = ComputerHistoryStore(
                rootDirectory: root,
                codexMemoryDirectory: codexMirror
            )
            let coordinator = ActivityAnalysisCycleCoordinator(
                rootDirectory: root,
                computerHistoryStore: computerHistoryStore,
                engineRevision: "recap-single-flight-test-v1"
            )
            let operationStarted = [
                DispatchSemaphore(value: 0), DispatchSemaphore(value: 0),
            ]
            let releaseOperation = [
                DispatchSemaphore(value: 0), DispatchSemaphore(value: 0),
            ]
            let stateLock = NSLock()
            var operationCount = 0
            let service = ActivityAnalysisCycleService(
                revisionProvider: { coordinator.probe(day: $0, tokenBudget: $1) },
                operation: { day, tokenBudget, forceVerification, includeActivityMemory in
                    stateLock.lock()
                    operationCount += 1
                    let operationIndex = operationCount - 1
                    stateLock.unlock()
                    if operationIndex < operationStarted.count {
                        operationStarted[operationIndex].signal()
                        _ = releaseOperation[operationIndex].wait(timeout: .now() + 2)
                    }
                    return try coordinator.process(
                        day: day,
                        tokenBudget: tokenBudget,
                        forceVerification: forceVerification,
                        includeActivityMemory: includeActivityMemory
                    )
                },
                retainCacheEntries: { coordinator.retainCacheEntries(for: $0) },
                invalidateRevisionCache: { try coordinator.invalidateRevisionCache() }
            )
            let tokenBudget = ActivityAnalysisPreferences.agentTokenBudget
            let workQueue = DispatchQueue(
                label: "goalong-recap-single-flight-test-\(UUID().uuidString)",
                attributes: .concurrent
            )

            var runtimeResult: Result<ActivityAnalysisCycleResult, Error>?
            var recapResult: Result<ActivityAnalysisCycleResult, Error>?
            var recapActivity: ActivityDayAnalysis?
            var recapComputerHistory: ComputerHistoryDayMemory?
            let firstFlight = expectation(description: "runtime and recap finish shared source pass")
            firstFlight.expectedFulfillmentCount = 2
            workQueue.async {
                let result = Result {
                    try service.process(
                        day: day,
                        tokenBudget: tokenBudget,
                        forceVerification: true,
                        includeActivityMemory: false
                    )
                }
                stateLock.lock()
                runtimeResult = result
                stateLock.unlock()
                firstFlight.fulfill()
            }
            XCTAssertEqual(operationStarted[0].wait(timeout: .now() + 2), .success)
            workQueue.async {
                do {
                    let views = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                        for: day,
                        rootDirectory: root,
                        computerHistoryStore: computerHistoryStore,
                        cycleService: service
                    )
                    stateLock.lock()
                    recapResult = .success(views.cycleResult)
                    recapActivity = views.activity
                    recapComputerHistory = views.computerHistory
                    stateLock.unlock()
                } catch {
                    stateLock.lock()
                    recapResult = .failure(error)
                    stateLock.unlock()
                }
                firstFlight.fulfill()
            }
            XCTAssertTrue(service.waitUntilCurrentFlightIsShared(timeout: 2))
            releaseOperation[0].signal()
            wait(for: [firstFlight], timeout: 3)

            stateLock.lock()
            let firstRuntimeResult = runtimeResult
            let firstRecapResult = recapResult
            let firstRecapActivity = recapActivity
            let firstRecapComputerHistory = recapComputerHistory
            let firstOperationCount = operationCount
            stateLock.unlock()
            let runtimeCycle = try XCTUnwrap(firstRuntimeResult).get()
            let recapCycle = try XCTUnwrap(firstRecapResult).get()
            XCTAssertEqual(firstOperationCount, 1)
            XCTAssertEqual(runtimeCycle, recapCycle)
            XCTAssertEqual(runtimeCycle.sourceReadPasses, 1)
            XCTAssertEqual(runtimeCycle.sourceBytesRead, Int64(sourceData.count))
            XCTAssertEqual(firstRecapActivity?.coverage.sourceEventCount, 1)
            XCTAssertEqual(firstRecapComputerHistory?.coverage.sourceEventCount, 1)

            let cacheURL = root.appendingPathComponent("analysis/runtime-input-cache.json")
            let cacheData = try Data(contentsOf: cacheURL)
            let cacheObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: cacheData) as? [String: Any]
            )
            let entries = try XCTUnwrap(cacheObject["entries"] as? [String: Any])
            XCTAssertLessThanOrEqual(entries.count, 4)
            XCTAssertLessThanOrEqual(cacheData.count, 64 * 1_024)

            let outputURLs = [
                root.appendingPathComponent("analysis/\(dayKey).analysis.json"),
                root.appendingPathComponent("analysis/\(dayKey).agent.md"),
                root.appendingPathComponent(
                    "computer-history/\(dayKey).computer-history.json"
                ),
            ]
            let lastKnownGood = try outputURLs.map { try Data(contentsOf: $0) }
            let outsideSource = container.appendingPathComponent("outside-source.jsonl")
            try sourceData.write(to: outsideSource, options: [.atomic])
            try FileManager.default.removeItem(at: eventURL)
            try FileManager.default.createSymbolicLink(
                at: eventURL,
                withDestinationURL: outsideSource
            )

            runtimeResult = nil
            recapResult = nil
            let failedFlight = expectation(description: "runtime and recap share source failure")
            failedFlight.expectedFulfillmentCount = 2
            workQueue.async {
                let result = Result {
                    try service.process(
                        day: day,
                        tokenBudget: tokenBudget,
                        forceVerification: true,
                        includeActivityMemory: false
                    )
                }
                stateLock.lock()
                runtimeResult = result
                stateLock.unlock()
                failedFlight.fulfill()
            }
            XCTAssertEqual(operationStarted[1].wait(timeout: .now() + 2), .success)
            workQueue.async {
                do {
                    let views = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                        for: day,
                        rootDirectory: root,
                        computerHistoryStore: computerHistoryStore,
                        cycleService: service
                    )
                    stateLock.lock()
                    recapResult = .success(views.cycleResult)
                    stateLock.unlock()
                } catch {
                    stateLock.lock()
                    recapResult = .failure(error)
                    stateLock.unlock()
                }
                failedFlight.fulfill()
            }
            XCTAssertTrue(service.waitUntilCurrentFlightIsShared(timeout: 2))
            releaseOperation[1].signal()
            wait(for: [failedFlight], timeout: 3)

            stateLock.lock()
            let failedRuntimeResult = runtimeResult
            let failedRecapResult = recapResult
            let finalOperationCount = operationCount
            stateLock.unlock()
            let runtimeError = try Self.failure(from: XCTUnwrap(failedRuntimeResult))
            let recapError = try Self.failure(from: XCTUnwrap(failedRecapResult))
            XCTAssertEqual(finalOperationCount, 2)
            XCTAssertEqual(runtimeError.localizedDescription, recapError.localizedDescription)
            XCTAssertEqual(try outputURLs.map { try Data(contentsOf: $0) }, lastKnownGood)

            let finalCacheData = try Data(contentsOf: cacheURL)
            let finalCacheObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: finalCacheData) as? [String: Any]
            )
            let finalEntries = try XCTUnwrap(finalCacheObject["entries"] as? [String: Any])
            XCTAssertLessThanOrEqual(finalEntries.count, 4)
            XCTAssertLessThanOrEqual(finalCacheData.count, 64 * 1_024)
        }

        func testRecapMultiDayBuildKeepsSharedRevisionCacheBounded() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "goalong-recap-cache-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
            let codexMirror = container.appendingPathComponent("codex-memory", isDirectory: true)
            try FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: container) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let firstDay = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let computerHistoryStore = ComputerHistoryStore(
                rootDirectory: root,
                codexMemoryDirectory: codexMirror
            )
            var processedDayKeys: [String] = []

            for offset in 0..<8 {
                let day = try XCTUnwrap(
                    calendar.date(byAdding: .day, value: offset, to: firstDay)
                )
                let event = HistoryEvent(
                    id: "recap-cache-\(offset)",
                    sessionID: "recap-cache-test",
                    timestamp: day.addingTimeInterval(12 * 60 * 60),
                    kind: .mouseClick,
                    app: AppSnapshot(
                        name: "Fixture App",
                        bundleIdentifier: "test.fixture",
                        processIdentifier: 42
                    ),
                    pointer: PointerSnapshot(
                        button: "left",
                        x: Double(offset),
                        y: 80,
                        clickCount: 1
                    )
                )
                var sourceData = try encoder.encode(event)
                sourceData.append(0x0A)
                let dayKey = ActivityAnalysisPaths.dayString(day)
                processedDayKeys.append(dayKey)
                try sourceData.write(
                    to: eventsDirectory.appendingPathComponent(dayKey + ".jsonl"),
                    options: [.atomic]
                )

                _ = try ChatGPTRecapContextBuilder.buildLocalActivityViews(
                    for: day,
                    rootDirectory: root,
                    computerHistoryStore: computerHistoryStore
                )
            }

            let cacheURL = root.appendingPathComponent("analysis/runtime-input-cache.json")
            let cacheData = try Data(contentsOf: cacheURL)
            let cacheObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: cacheData) as? [String: Any]
            )
            let entries = try XCTUnwrap(cacheObject["entries"] as? [String: Any])

            XCTAssertEqual(entries.count, 4)
            XCTAssertTrue(entries.keys.contains(try XCTUnwrap(processedDayKeys.last)))
            XCTAssertLessThanOrEqual(cacheData.count, 64 * 1_024)
        }

        func testSavedRecapContextDoesNotIncludeAgentTranscriptFields() {
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let secret = "AGENT-TRANSCRIPT-SENTINEL-DO-NOT-COPY"
            let reference = AgentSourceReference(
                kind: .file,
                path: "/tmp/\(secret).jsonl"
            )
            let entry = AgentSourceIndexEntry(
                id: "ignored",
                stableConversationID: "session-\(secret)",
                watchedFolderID: "folder-\(secret)",
                watchedFolderName: secret,
                provider: .codex,
                reference: reference,
                relativePath: "\(secret).jsonl",
                sourceCreatedAt: timestamp,
                sourceModifiedAt: timestamp,
                firstIndexedAt: timestamp,
                lastObservedAt: timestamp,
                byteCount: 12_345,
                sha256: String(repeating: "a", count: 64)
            )
            let summary = AgentDocumentSummary(
                sessionID: secret,
                title: secret,
                excerpt: secret,
                projectPath: "/tmp/\(secret)",
                startedAt: timestamp,
                endedAt: timestamp,
                messageCount: 9,
                toolCallCount: 4,
                errorCount: 1,
                models: [secret],
                tools: [secret],
                touchedFiles: [secret],
                commands: [secret]
            )
            let overview = AgentActivityOverview(
                day: timestamp,
                captures: [AgentCaptureRecord(index: entry, summary: summary)],
                sessionCount: 1,
                messageCount: 9,
                toolCallCount: 4,
                errorCount: 1,
                sourceBytes: 12_345,
                indexBytes: 512,
                lastCaptureAt: timestamp
            )

            let rendered = ChatGPTRecapContextBuilder.renderAgentActivityForTesting(overview)

            XCTAssertTrue(rendered.contains("provider: Codex"))
            XCTAssertTrue(rendered.contains("source bytes: 12345"))
            XCTAssertTrue(rendered.contains("messages: 9"))
            XCTAssertFalse(rendered.contains(secret))
        }

        private static func failure(
            from result: Result<ActivityAnalysisCycleResult, Error>
        ) throws -> Error {
            switch result {
            case .success:
                throw NSError(
                    domain: "ChatGPTRecapTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected the shared cycle to fail"]
                )
            case .failure(let error):
                return error
            }
        }

        func testChatGPTExportParserKeepsDatedUserAndAssistantMessages() throws {
            let fixture: [String: Any] = [
                "conversations": [
                    [
                        "id": "conversation-1",
                        "title": "Launch plan",
                        "create_time": 1_700_000_000.0,
                        "mapping": [
                            "node-user": [
                                "message": [
                                    "id": "message-user",
                                    "author": ["role": "user"],
                                    "create_time": 1_700_000_001.0,
                                    "content": ["parts": ["Draft the launch plan"]],
                                ]
                            ],
                            "node-assistant": [
                                "message": [
                                    "id": "message-assistant",
                                    "author": ["role": "assistant"],
                                    "create_time": 1_700_000_002.0,
                                    "content": ["parts": ["Start with the target audience."]],
                                ]
                            ],
                            "node-system": [
                                "message": [
                                    "id": "message-system",
                                    "author": ["role": "system"],
                                    "create_time": 1_700_000_000.0,
                                    "content": ["parts": ["Hidden system text"]],
                                ]
                            ],
                        ],
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: fixture)
            let parsed = try ChatGPTHistoryStore.parseConversations(data: data)

            XCTAssertEqual(parsed.conversationIDs, ["conversation-1"])
            XCTAssertEqual(parsed.messages.map(\.role).sorted(), ["assistant", "user"])
            XCTAssertEqual(parsed.messages.count, 2)
        }

        func testChatGPTExportParserRedactsCommonSecrets() throws {
            let bearerSecret = "bearer-secret-value-123"
            let basicSecret = "dXNlcjpwYXNzd29yZA=="
            let fixture: [[String: Any]] = [
                [
                    "id": "conversation-1",
                    "title": "Credential check",
                    "mapping": [
                        "node-user": [
                            "message": [
                                "id": "message-user",
                                "author": ["role": "user"],
                                "create_time": 1_700_000_001.0,
                                "content": [
                                    "parts": [
                                        "api_key=sk-abcdefghijklmnopqrstuvwxyz123456\n"
                                            + "Authorization: Bearer \(bearerSecret)\n"
                                            + "authorization=Basic \(basicSecret)"
                                    ]
                                ],
                            ]
                        ]
                    ],
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: fixture)
            let parsed = try ChatGPTHistoryStore.parseConversations(data: data)

            XCTAssertEqual(parsed.messages.count, 1)
            XCTAssertFalse(parsed.messages[0].text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
            XCTAssertFalse(parsed.messages[0].text.contains(bearerSecret))
            XCTAssertFalse(parsed.messages[0].text.contains(basicSecret))
            XCTAssertTrue(parsed.messages[0].text.contains("REDACTED"))
        }

        func testCodexAppServerProductionLimitsAreExplicitAndBounded() {
            let limits = CodexAppServerLimits.production
            XCTAssertEqual(limits.maximumProtocolLineBytes, 8 * 1_024 * 1_024)
            XCTAssertEqual(limits.maximumBufferedStdoutBytes, 8 * 1_024 * 1_024 + 65_536)
            XCTAssertEqual(limits.maximumDeferredMessages, 512)
            XCTAssertEqual(limits.maximumDeferredBytes, 16 * 1_024 * 1_024)
            XCTAssertEqual(limits.maximumMessages, 20_000)
            XCTAssertEqual(limits.maximumBlankLines, 4_096)
            XCTAssertEqual(limits.maximumBlankLineBytes, 65_536)
            XCTAssertEqual(limits.maximumRecapCandidateBytes, 2 * 1_024 * 1_024)
            XCTAssertEqual(limits.maximumRecapMarkdownBytes, 1 * 1_024 * 1_024)
            XCTAssertEqual(limits.maximumStderrBytes, 65_536)

            let bounded = CodexAppServerLimits.boundedUTF8(
                String(repeating: "é", count: 100),
                maximumBytes: 31
            )
            XCTAssertLessThanOrEqual(bounded.utf8.count, 31)
        }

        func testCodexJSONLDecoderRejectsOversizedAndUnterminatedLines() throws {
            var limits = CodexAppServerLimits.production
            limits.maximumProtocolLineBytes = 32
            limits.maximumBufferedStdoutBytes = 64

            var oversized = CodexAppServerMessageDecoder(limits: limits)
            XCTAssertThrowsError(
                try oversized.append(Data((String(repeating: "x", count: 33) + "\n").utf8))
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("JSON line exceeded 32 bytes"))
            }

            var unterminated = CodexAppServerMessageDecoder(limits: limits)
            try unterminated.append(Data(String(repeating: "x", count: 32).utf8))
            XCTAssertEqual(unterminated.outputBuffer.count, 32)
            XCTAssertThrowsError(try unterminated.append(Data("x".utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("without a newline"))
            }

            var validAtEOF = CodexAppServerMessageDecoder(limits: limits)
            try validAtEOF.append(Data("{\"id\":1}".utf8))
            let message = try XCTUnwrap(validAtEOF.finish())
            XCTAssertEqual((message["id"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual(validAtEOF.outputBuffer.count, 0)

            var blankLimits = limits
            blankLimits.maximumBlankLines = 2
            blankLimits.maximumBlankLineBytes = 2
            var blankFlood = CodexAppServerMessageDecoder(limits: blankLimits)
            try blankFlood.append(Data("\n\n\n".utf8))
            XCTAssertThrowsError(try blankFlood.popMessage()) { error in
                XCTAssertTrue(error.localizedDescription.contains("blank JSONL records"))
            }
            XCTAssertEqual(blankFlood.blankLineCount, 2)
            XCTAssertEqual(blankFlood.blankLineBytes, 2)
        }

        func testCodexProtocolRejectsMessageAndDeferredFloods() throws {
            var limits = CodexAppServerLimits.production
            limits.maximumMessages = 2
            limits.maximumDeferredMessages = 2
            limits.maximumDeferredBytes = 1_024

            var decoder = CodexAppServerMessageDecoder(limits: limits)
            try decoder.append(Data("{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n".utf8))
            XCTAssertNotNil(try decoder.popMessage())
            XCTAssertNotNil(try decoder.popMessage())
            XCTAssertThrowsError(try decoder.popMessage()) { error in
                XCTAssertTrue(error.localizedDescription.contains("more than 2 JSON messages"))
            }

            var queue = CodexAppServerDeferredMessageQueue(limits: limits)
            try queue.append(["id": 1])
            try queue.append(["id": 2])
            let bytesBeforeFailure = queue.byteCount
            XCTAssertThrowsError(try queue.append(["id": 3]))
            XCTAssertEqual(queue.count, 2)
            XCTAssertEqual(queue.byteCount, bytesBeforeFailure)
        }

        func testCodexMessageRoutingRequiresStrictIntegerIDsAndRejectsUnmatchedResponses() throws {
            XCTAssertEqual(
                CodexAppServerMessageRouter.strictIntegerID(from: NSNumber(value: 7)),
                7
            )
            XCTAssertNil(CodexAppServerMessageRouter.strictIntegerID(from: NSNumber(value: true)))
            XCTAssertNil(CodexAppServerMessageRouter.strictIntegerID(from: NSNumber(value: 1.5)))
            XCTAssertNil(CodexAppServerMessageRouter.strictIntegerID(from: "1"))
            XCTAssertThrowsError(
                try CodexAppServerMessageRouter.responseID(in: ["id": NSNumber(value: 1.5)])
            )
            XCTAssertThrowsError(
                try CodexAppServerMessageRouter.notificationMethod(in: ["id": 2])
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("unmatched JSON-RPC response"))
            }
            XCTAssertEqual(
                try CodexAppServerMessageRouter.notificationMethod(in: ["method": "turn/completed"]),
                "turn/completed"
            )
        }

        func testCodexTimedWriterCannotBlockPastDeadline() throws {
            let pipe = Pipe()
            defer {
                try? pipe.fileHandleForWriting.close()
                try? pipe.fileHandleForReading.close()
            }
            try CodexAppServerTimedWriter.prepareNonBlocking(
                pipe.fileHandleForWriting.fileDescriptor
            )
            let startedAt = Date()
            XCTAssertThrowsError(
                try CodexAppServerTimedWriter.write(
                    Data(repeating: 0x61, count: 1 * 1_024 * 1_024),
                    to: pipe.fileHandleForWriting.fileDescriptor,
                    deadline: Date().addingTimeInterval(0.02),
                    operation: "writing a bounded test request"
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }

        func testCodexRecapCollectorBoundsAndRedactsSuccessfulOutput() throws {
            var limits = CodexAppServerLimits.production
            limits.maximumRecapCandidateBytes = 96
            limits.maximumRecapMarkdownBytes = 48

            var collector = CodexRecapOutputCollector(limits: limits)
            try collector.append(delta: "ignored streamed draft")
            try collector.setFinalText("{\"markdown\":\"Résumé ✅ api_key=sk-abcdefghijklmnop\"}")
            let markdown = try collector.completedMarkdown()
            XCTAssertTrue(markdown.contains("Résumé ✅"))
            XCTAssertTrue(markdown.contains("REDACTED"))
            XCTAssertFalse(markdown.contains("sk-abcdefghijklmnop"))

            var streamedOverflow = CodexRecapOutputCollector(limits: limits)
            try streamedOverflow.append(delta: String(repeating: "a", count: 80))
            XCTAssertThrowsError(
                try streamedOverflow.append(delta: String(repeating: "b", count: 17))
            )

            var markdownOverflow = CodexRecapOutputCollector(limits: limits)
            try markdownOverflow.setFinalText(String(repeating: "c", count: 49))
            XCTAssertThrowsError(try markdownOverflow.completedMarkdown())

            let splitSecret = "sk-abcdefghijklmnop"
            var streamingRedactor = CodexStreamingRedactor()
            XCTAssertEqual(streamingRedactor.append("Authorization: Bearer sk-abc"), "")
            let safeDelta = streamingRedactor.append("defghijklmnop\nVisible line")
            XCTAssertFalse(safeDelta.contains(splitSecret))
            XCTAssertTrue(safeDelta.contains("REDACTED"))
            XCTAssertEqual(streamingRedactor.finish(), "Visible line")

            let launchDescription = CodexAppServerError.launchFailed(
                "Authorization: Bearer \(splitSecret) " + String(repeating: "x", count: 8_000)
            ).localizedDescription
            XCTAssertFalse(launchDescription.contains(splitSecret))
            XCTAssertLessThan(launchDescription.utf8.count, 4_300)
        }

        func testCodexWireEncoderBoundsUTF8RequestBytes() throws {
            var limits = CodexAppServerLimits.production
            limits.maximumProtocolLineBytes = 48
            XCTAssertThrowsError(
                try CodexAppServerWireEncoder.encode(
                    ["text": String(repeating: "é", count: 30)],
                    limits: limits
                )
            )

            let encoded = try CodexAppServerWireEncoder.encode(["id": 1], limits: limits)
            XCTAssertEqual(encoded.last, 0x0A)
            XCTAssertLessThanOrEqual(encoded.count - 1, limits.maximumProtocolLineBytes)
        }

        func testRecapPersistenceIsBoundedRedactedAndIdempotent() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-persistence")
            defer { try? FileManager.default.removeItem(at: container) }
            let directory = container.appendingPathComponent("recaps", isDirectory: true)
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let recap = recapFixture(day: day, markdown: "# Stable recap\n\nUseful result.")

            try ChatGPTRecapPersistence.write(recap, to: directory)
            let jsonURL = ChatGPTRecapPersistence.jsonURL(for: day, in: directory)
            let markdownURL = ChatGPTRecapPersistence.markdownURL(for: day, in: directory)
            let firstJSON = try Data(contentsOf: jsonURL)
            let firstMarkdown = try Data(contentsOf: markdownURL)
            try ChatGPTRecapPersistence.write(recap, to: directory)

            XCTAssertEqual(try Data(contentsOf: jsonURL), firstJSON)
            XCTAssertEqual(try Data(contentsOf: markdownURL), firstMarkdown)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                [jsonURL.lastPathComponent, markdownURL.lastPathComponent].sorted()
            )
            let directoryPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                    as? NSNumber
            )
            let jsonPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: jsonURL.path)[.posixPermissions]
                    as? NSNumber
            )
            let markdownPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: markdownURL.path)[.posixPermissions]
                    as? NSNumber
            )
            XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
            XCTAssertEqual(jsonPermissions.intValue & 0o777, 0o600)
            XCTAssertEqual(markdownPermissions.intValue & 0o777, 0o600)
            XCTAssertEqual(ChatGPTRecapPersistence.load(for: day, from: directory), recap)

            let oversized = recapFixture(
                day: day,
                markdown: String(
                    repeating: "x",
                    count: ChatGPTRecapPersistence.maximumMarkdownBytes + 1
                )
            )
            XCTAssertThrowsError(try ChatGPTRecapPersistence.write(oversized, to: directory))
            XCTAssertEqual(try Data(contentsOf: jsonURL), firstJSON)
            XCTAssertEqual(try Data(contentsOf: markdownURL), firstMarkdown)

            let uncommitted = recapFixture(day: day, markdown: "# Must not commit")
            XCTAssertThrowsError(
                try ChatGPTRecapPersistence.write(
                    uncommitted,
                    to: directory,
                    writer: { data, destination in
                        if destination == jsonURL {
                            throw NSError(domain: "ChatGPTRecapTests.commit", code: 1)
                        }
                        try ChatGPTSecureStorage.writeFileAtomically(data, to: destination)
                    }
                )
            )
            XCTAssertEqual(try Data(contentsOf: jsonURL), firstJSON)
            XCTAssertEqual(try Data(contentsOf: markdownURL), firstMarkdown)
            XCTAssertEqual(ChatGPTRecapPersistence.load(for: day, from: directory), recap)

            let secret = "sk-abcdefghijklmnop"
            let secretDay = day.addingTimeInterval(86_400)
            try ChatGPTRecapPersistence.write(
                recapFixture(day: secretDay, markdown: "api_key=\(secret)"),
                to: directory
            )
            let persistedJSON = try String(
                contentsOf: ChatGPTRecapPersistence.jsonURL(for: secretDay, in: directory),
                encoding: .utf8
            )
            let persistedMarkdown = try String(
                contentsOf: ChatGPTRecapPersistence.markdownURL(for: secretDay, in: directory),
                encoding: .utf8
            )
            XCTAssertFalse(persistedJSON.contains(secret))
            XCTAssertFalse(persistedMarkdown.contains(secret))
            XCTAssertTrue(persistedMarkdown.contains("REDACTED"))
            XCTAssertFalse(
                CodexAppServerError.generationFailed("api_key=\(secret)")
                    .localizedDescription.contains(secret)
            )
        }

        func testChatGPTStorageRejectsSymlinkedDirectoriesAndFiles() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-symlink-storage")
            defer { try? FileManager.default.removeItem(at: container) }
            let outside = container.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let linkedRecaps = container.appendingPathComponent("recaps", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedRecaps,
                withDestinationURL: outside
            )

            XCTAssertThrowsError(
                try ChatGPTRecapPersistence.write(
                    recapFixture(day: Date(), markdown: "safe"),
                    to: linkedRecaps
                )
            )
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

            let linkedHome = container.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: outside)
            XCTAssertThrowsError(try CodexAppServerSession.prepareCodexHome(at: linkedHome))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

            let realRecaps = container.appendingPathComponent("real-recaps", isDirectory: true)
            try FileManager.default.createDirectory(at: realRecaps, withIntermediateDirectories: false)
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let outsideFile = outside.appendingPathComponent("must-not-change")
            let outsideBytes = Data("external".utf8)
            try outsideBytes.write(to: outsideFile)
            let linkedMarkdown = ChatGPTRecapPersistence.markdownURL(for: day, in: realRecaps)
            try FileManager.default.createSymbolicLink(
                at: linkedMarkdown,
                withDestinationURL: outsideFile
            )
            XCTAssertThrowsError(
                try ChatGPTRecapPersistence.write(
                    recapFixture(day: day, markdown: "must not escape"),
                    to: realRecaps
                )
            )
            XCTAssertEqual(try Data(contentsOf: outsideFile), outsideBytes)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: ChatGPTRecapPersistence.jsonURL(for: day, in: realRecaps).path
                )
            )
        }

        func testChatGPTStorageRejectsSymlinkedAncestorWithoutTouchingTarget() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-symlink-ancestor")
            defer { try? FileManager.default.removeItem(at: container) }
            let outside = container.appendingPathComponent("outside", isDirectory: true)
            let outsideHistory = outside.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideHistory,
                withIntermediateDirectories: true
            )
            let outsideArchive = outsideHistory.appendingPathComponent(
                "normalized-conversations.json",
                isDirectory: false
            )
            let outsideBytes = Data("must remain outside".utf8)
            try outsideBytes.write(to: outsideArchive)

            let linkedAncestor = container.appendingPathComponent("linked-parent", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedAncestor,
                withDestinationURL: outside
            )
            let linkedHistory = linkedAncestor.appendingPathComponent("history", isDirectory: true)
            let linkedArchive = linkedHistory.appendingPathComponent(
                "normalized-conversations.json",
                isDirectory: false
            )

            XCTAssertThrowsError(try ChatGPTSecureStorage.prepareDirectory(linkedHistory))
            XCTAssertThrowsError(
                try ChatGPTSecureStorage.writeFileAtomically(Data("must not escape".utf8), to: linkedArchive)
            )
            XCTAssertThrowsError(
                try ChatGPTSecureStorage.removeRegularFileIfPresent(at: linkedArchive)
            )
            XCTAssertEqual(try Data(contentsOf: outsideArchive), outsideBytes)
        }

        func testChatGPTStorageRejectsExtendedDirectoryAccessControls() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-storage-acl")
            defer { try? FileManager.default.removeItem(at: container) }
            let history = container.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(
                at: history,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let archive = history.appendingPathComponent(
                "normalized-conversations.json",
                isDirectory: false
            )
            let preservedBytes = Data("preserve ACL-protected storage".utf8)
            try preservedBytes.write(to: archive)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = [
                "+a",
                "everyone allow list,search,readattr,readextattr,readsecurity",
                history.path,
            ]
            try chmod.run()
            chmod.waitUntilExit()
            XCTAssertEqual(chmod.terminationStatus, 0)
            guard chmod.terminationStatus == 0 else { return }

            XCTAssertThrowsError(try ChatGPTSecureStorage.prepareDirectory(history))
            XCTAssertThrowsError(
                try ChatGPTSecureStorage.writeFileAtomically(Data("must not replace".utf8), to: archive)
            )
            XCTAssertThrowsError(
                try ChatGPTSecureStorage.removeRegularFileIfPresent(at: archive)
            )
            XCTAssertEqual(try Data(contentsOf: archive), preservedBytes)
        }

        func testChatGPTStorageKeepsPinnedDirectoryAcrossPathReplacement() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-pinned-storage")
            defer { try? FileManager.default.removeItem(at: container) }

            let writeDirectory = container.appendingPathComponent("write-history", isDirectory: true)
            let displacedWriteDirectory = container.appendingPathComponent(
                "write-history-displaced",
                isDirectory: true
            )
            let outsideWriteDirectory = container.appendingPathComponent(
                "write-history-outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: writeDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: outsideWriteDirectory,
                withIntermediateDirectories: false
            )
            let fileName = "normalized-conversations.json"
            let writeDestination = writeDirectory.appendingPathComponent(fileName)
            let outsideWriteDestination = outsideWriteDirectory.appendingPathComponent(fileName)
            let outsideWriteBytes = Data("outside write sentinel".utf8)
            try outsideWriteBytes.write(to: outsideWriteDestination)
            let replacementBytes = Data("pinned write".utf8)
            var writeMutationError: Error?
            var didMutateWritePath = false

            try ChatGPTSecureStorage.writeFileAtomically(
                replacementBytes,
                to: writeDestination
            ) { checkpoint in
                guard case .directoryPinned = checkpoint, !didMutateWritePath else { return }
                didMutateWritePath = true
                do {
                    try FileManager.default.moveItem(
                        at: writeDirectory,
                        to: displacedWriteDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: writeDirectory,
                        withDestinationURL: outsideWriteDirectory
                    )
                } catch {
                    writeMutationError = error
                }
            }
            XCTAssertTrue(didMutateWritePath)
            XCTAssertNil(writeMutationError)
            XCTAssertEqual(
                try Data(contentsOf: displacedWriteDirectory.appendingPathComponent(fileName)),
                replacementBytes
            )
            XCTAssertEqual(try Data(contentsOf: outsideWriteDestination), outsideWriteBytes)

            let removeDirectory = container.appendingPathComponent("remove-history", isDirectory: true)
            let displacedRemoveDirectory = container.appendingPathComponent(
                "remove-history-displaced",
                isDirectory: true
            )
            let outsideRemoveDirectory = container.appendingPathComponent(
                "remove-history-outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: removeDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: outsideRemoveDirectory,
                withIntermediateDirectories: false
            )
            let removeDestination = removeDirectory.appendingPathComponent(fileName)
            let outsideRemoveDestination = outsideRemoveDirectory.appendingPathComponent(fileName)
            try ChatGPTSecureStorage.writeFileAtomically(Data("remove me".utf8), to: removeDestination)
            let outsideRemoveBytes = Data("outside remove sentinel".utf8)
            try outsideRemoveBytes.write(to: outsideRemoveDestination)
            var removeMutationError: Error?
            var didMutateRemovePath = false

            try ChatGPTSecureStorage.removeRegularFileIfPresent(at: removeDestination) { checkpoint in
                guard case .directoryPinned = checkpoint, !didMutateRemovePath else { return }
                didMutateRemovePath = true
                do {
                    try FileManager.default.moveItem(
                        at: removeDirectory,
                        to: displacedRemoveDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: removeDirectory,
                        withDestinationURL: outsideRemoveDirectory
                    )
                } catch {
                    removeMutationError = error
                }
            }
            XCTAssertTrue(didMutateRemovePath)
            XCTAssertNil(removeMutationError)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: displacedRemoveDirectory.appendingPathComponent(fileName).path
                )
            )
            XCTAssertEqual(try Data(contentsOf: outsideRemoveDestination), outsideRemoveBytes)
        }

        func testRuntimeConfigureAndStartDoNotLaunchCodex() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-idle-runtime")
            defer { try? FileManager.default.removeItem(at: container) }
            var locatorCalls = 0
            var sessionCalls = 0
            var scheduledAutomaticWork: DispatchWorkItem?
            var openedDirectory: URL?
            var revealedFiles: [URL] = []
            let recapsDirectory = container.appendingPathComponent("recaps", isDirectory: true)
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: recapsDirectory,
                executableLocator: {
                    locatorCalls += 1
                    return container.appendingPathComponent("codex")
                },
                sessionFactory: { _ in
                    sessionCalls += 1
                    throw NSError(domain: "ChatGPTRecapTests", code: 99)
                },
                directoryOpener: { openedDirectory = $0 },
                fileRevealer: { revealedFiles = $0 },
                delayedAutomaticScheduler: { scheduledAutomaticWork = $0 }
            )

            runtime.configure(deviceID: "device-test")
            runtime.revealRecapFiles()
            XCTAssertEqual(openedDirectory, recapsDirectory)
            XCTAssertTrue(revealedFiles.isEmpty)

            runtime.beginRunForTesting(streamed: "old-day-preview")
            runtime.selectDay(runtime.selectedDay.addingTimeInterval(86_400))
            XCTAssertFalse(runtime.hasActiveRunForTesting)
            XCTAssertFalse(runtime.isGenerating)
            XCTAssertTrue(runtime.streamedMarkdown.isEmpty)

            runtime.start()
            runtime.beginRunForTesting(streamed: "automatic-preview")
            runtime.stop()
            scheduledAutomaticWork?.perform()

            XCTAssertFalse(runtime.hasActiveRunForTesting)
            XCTAssertFalse(runtime.isGenerating)
            XCTAssertTrue(runtime.streamedMarkdown.isEmpty)
            XCTAssertEqual(locatorCalls, 0)
            XCTAssertEqual(sessionCalls, 0)
        }

        func testRuntimeRevealRepairsMarkdownFromCanonicalJSON() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-reveal-runtime")
            defer { try? FileManager.default.removeItem(at: container) }
            let recapsDirectory = container.appendingPathComponent("recaps", isDirectory: true)
            let today = Calendar.current.startOfDay(for: Date())
            let recap = recapFixture(day: today, markdown: "# Canonical recap")
            try ChatGPTRecapPersistence.write(recap, to: recapsDirectory)
            let markdownURL = ChatGPTRecapPersistence.markdownURL(for: today, in: recapsDirectory)
            try ChatGPTSecureStorage.writeFileAtomically(Data("stale mirror".utf8), to: markdownURL)
            var revealedFiles: [URL] = []
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: recapsDirectory,
                executableLocator: { nil },
                sessionFactory: { _ in
                    throw NSError(domain: "ChatGPTRecapTests", code: 100)
                },
                directoryOpener: { _ in
                    XCTFail("Canonical JSON should produce reveal files")
                },
                fileRevealer: { revealedFiles = $0 },
                delayedAutomaticScheduler: { _ in }
            )

            runtime.revealRecapFiles()

            XCTAssertEqual(
                Set(revealedFiles),
                Set([
                    markdownURL,
                    ChatGPTRecapPersistence.jsonURL(for: today, in: recapsDirectory),
                ]))
            XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), recap.markdown)
        }

        func testChatGPTImportIsStableIdempotentAndLeavesSourceUnchanged() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-chatgpt-import")
            defer { try? FileManager.default.removeItem(at: container) }
            let source = container.appendingPathComponent("conversations.json")
            let sourceData = try exportFixtureData(text: "A stable imported message")
            try sourceData.write(to: source)
            let store = ChatGPTHistoryStore(
                rootDirectory: container.appendingPathComponent("history", isDirectory: true)
            )
            let importedAt = Date(timeIntervalSince1970: 1_700_000_100)

            let first = try store.importConversations(from: source, importedAt: importedAt)
            let firstArchive = try Data(contentsOf: store.archiveFile)
            let second = try store.importConversations(from: source)

            XCTAssertEqual(first, second)
            XCTAssertEqual(first.messageCount, 1)
            XCTAssertEqual(try Data(contentsOf: source), sourceData)
            XCTAssertEqual(try Data(contentsOf: store.archiveFile), firstArchive)
            XCTAssertEqual(store.summary(), first)
            let permissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: store.archiveFile.path)[.posixPermissions]
                    as? NSNumber
            )
            let directoryPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: store.rootDirectory.path)[.posixPermissions]
                    as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)

            let normalParsed = try ChatGPTHistoryStore.parseConversations(data: sourceData)
            XCTAssertEqual(normalParsed.messages.first?.conversationID, "conversation-1")
            XCTAssertEqual(normalParsed.messages.first?.id, "conversation-1:message-user")

            let sensitiveConversationID =
                "Authorization: Bearer identifier-secret-that-must-not-be-persisted"
            let oversizedMessageID = String(repeating: "oversized-id-", count: 10_000)
            let amplifiedSource = try exportFixtureData(
                text: "A bounded imported message",
                conversationID: sensitiveConversationID,
                messageID: oversizedMessageID
            )
            try amplifiedSource.write(to: source, options: [.atomic])
            _ = try store.importConversations(from: source)
            let boundedArchive = try Data(contentsOf: store.archiveFile)
            let boundedArchiveString = try XCTUnwrap(String(data: boundedArchive, encoding: .utf8))
            let boundedParsed = try ChatGPTHistoryStore.parseConversations(data: amplifiedSource)
            let boundedMessage = try XCTUnwrap(boundedParsed.messages.first)
            XCTAssertLessThan(boundedMessage.conversationID.utf8.count, 100)
            XCTAssertLessThan(boundedMessage.id.utf8.count, 200)
            XCTAssertFalse(boundedArchiveString.contains(sensitiveConversationID))
            XCTAssertFalse(boundedArchiveString.contains(oversizedMessageID))
            XCTAssertLessThan(boundedArchive.count, amplifiedSource.count)

            _ = try store.importConversations(from: source)
            XCTAssertEqual(try Data(contentsOf: store.archiveFile), boundedArchive)
        }

        func testRemoveImportRefusesUnexpectedDirectoryOrSymlink() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-chatgpt-remove-import")
            defer { try? FileManager.default.removeItem(at: container) }
            let history = container.appendingPathComponent("history", isDirectory: true)
            try ChatGPTSecureStorage.prepareDirectory(history)
            let store = ChatGPTHistoryStore(rootDirectory: history)
            let unexpectedDirectory = store.archiveFile
            try FileManager.default.createDirectory(
                at: unexpectedDirectory,
                withIntermediateDirectories: false
            )
            let sentinel = unexpectedDirectory.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)

            XCTAssertThrowsError(try store.removeImport())
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))

            try FileManager.default.removeItem(at: unexpectedDirectory)
            let outside = container.appendingPathComponent("outside")
            let outsideBytes = Data("outside".utf8)
            try outsideBytes.write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: store.archiveFile,
                withDestinationURL: outside
            )
            XCTAssertThrowsError(try store.removeImport())
            XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
        }

        func testChatGPTImportRejectsGrowingReplacedAndSymlinkSourcesWithoutArchiveChanges() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-chatgpt-import-races")
            defer { try? FileManager.default.removeItem(at: container) }
            let source = container.appendingPathComponent("conversations.json")
            let initialData = try exportFixtureData(text: "Initial archive")
            try initialData.write(to: source)
            let store = ChatGPTHistoryStore(
                rootDirectory: container.appendingPathComponent("history", isDirectory: true)
            )
            _ = try store.importConversations(
                from: source,
                importedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
            let lastKnownGood = try Data(contentsOf: store.archiveFile)

            var didGrow = false
            XCTAssertThrowsError(
                try store.importConversations(from: source) { checkpoint in
                    guard case .opened = checkpoint, !didGrow else { return }
                    didGrow = true
                    let handle = try? FileHandle(forWritingTo: source)
                    _ = try? handle?.seekToEnd()
                    try? handle?.write(contentsOf: Data(" ".utf8))
                    try? handle?.close()
                }
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed, grew, or was replaced"))
            }
            XCTAssertEqual(try Data(contentsOf: store.archiveFile), lastKnownGood)

            try initialData.write(to: source, options: [.atomic])
            let displaced = container.appendingPathComponent("original.json")
            let replacementData = try exportFixtureData(text: "Replacement archive")
            var replacementMutationError: Error?
            var didReplace = false
            XCTAssertThrowsError(
                try store.importConversations(from: source) { checkpoint in
                    guard case .reachedEnd = checkpoint, !didReplace else { return }
                    didReplace = true
                    do {
                        try FileManager.default.moveItem(at: source, to: displaced)
                        try replacementData.write(to: source)
                    } catch {
                        replacementMutationError = error
                    }
                }
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed, grew, or was replaced"))
            }
            XCTAssertNil(replacementMutationError)
            XCTAssertEqual(try Data(contentsOf: source), replacementData)
            XCTAssertEqual(try Data(contentsOf: store.archiveFile), lastKnownGood)

            try? FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: displaced)
            XCTAssertThrowsError(try store.importConversations(from: source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("symbolic link"))
            }
            XCTAssertEqual(try Data(contentsOf: store.archiveFile), lastKnownGood)
            XCTAssertEqual(try Data(contentsOf: displaced), initialData)
        }

        func testBoundedRecapContextKeepsLateSectionsExactCoverageAndRedactsSecrets() throws {
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let activity = ActivityAnalysisEngine.analyze(
                events: [],
                day: day,
                generatedAt: day
            )
            let secret = "sk-abcdefghijklmnop"
            let coverage = ComputerHistoryCoverage(
                sourceEventCount: 101,
                actionEventCount: 103,
                semanticSnapshotCount: 107,
                linkedInteractionCount: 109,
                interactionsWithBeforeAndAfterContext: 113,
                resourceCount: 127,
                episodeCount: 131,
                suppressedEventCount: 137,
                firstSourceSequence: 139,
                lastSourceSequence: 149,
                lastSourceEventHash: String(repeating: "a", count: 64),
                retainedEpisodeCount: 17,
                retainedInteractionCount: 19,
                retainedResourceCount: 23
            )
            let computerHistory = ComputerHistoryDayMemory(
                dayStart: day,
                dayEnd: day.addingTimeInterval(86_399),
                generatedAt: day,
                title: "Credential title",
                executiveSummary: "Observed work",
                episodes: [],
                resources: [],
                workflowPatterns: [],
                suggestions: [],
                coverage: coverage,
                markdown:
                    "# api_key=\(secret)\nURL: access_token=\(secret)\nAction: password=\(secret)\n"
                    + String(repeating: "computer-history-detail\n", count: 6_000)
                    + "CH_TAIL_MUST_BE_OMITTED"
            )
            let agent = AgentActivityOverview(day: day)
            let imported = ChatGPTImportedMessage(
                id: "conversation:message",
                conversationID: "conversation",
                conversationTitle: "Late imported section",
                role: "user",
                createdAt: day,
                text: "IMPORTED_CHAT_LATE"
            )
            let counts = ChatGPTRecapSourceCounts(
                localEvents: 2,
                activeMinutes: 3,
                semanticSnapshots: 5,
                screenTimeDevices: 7,
                screenTimeApplications: 11,
                agentCaptures: 13,
                agentMessages: 17,
                importedChatMessages: 19,
                computerHistoryEpisodes: 131,
                computerHistoryResources: 127,
                workflowSuggestions: 23
            )

            let rendered = try ChatGPTRecapContextBuilder.renderDataForTesting(
                day: day,
                activity: activity,
                computerHistory: computerHistory,
                screenTime: nil,
                agentActivity: agent,
                importedChats: [imported],
                sourceCounts: counts
            )

            let orderedHeaders = [
                "## Causal Computer History",
                "## Legacy minute-level computer activity digest",
                "## Apple Screen Time",
                "## Local agent and coding-chat history",
                "## Imported ChatGPT conversation history",
                "## Source manifest — exact counts",
            ]
            let positions = try orderedHeaders.map { try XCTUnwrap(rendered.range(of: $0)?.lowerBound) }
            XCTAssertEqual(positions, positions.sorted())
            XCTAssertFalse(rendered.contains("CH_TAIL_MUST_BE_OMITTED"))
            XCTAssertTrue(rendered.contains("IMPORTED_CHAT_LATE"))
            XCTAssertTrue(rendered.contains("- Source events: 101"))
            XCTAssertTrue(rendered.contains("- Action events: 103"))
            XCTAssertTrue(rendered.contains("- Reconstructed episodes: 131"))
            XCTAssertTrue(rendered.contains("- Identified resources: 127"))
            XCTAssertTrue(rendered.contains("- Before/after semantic pairs: 113"))
            XCTAssertTrue(rendered.contains("Screen Time applications: 11"))
            XCTAssertTrue(rendered.contains("Direct-read agent messages: 17"))
            XCTAssertFalse(rendered.contains(secret))
            XCTAssertTrue(rendered.contains("REDACTED"))
            XCTAssertLessThanOrEqual(
                rendered.count,
                ChatGPTRecapContextBuilder.maximumRenderedDataCharacters
            )

            let context = ChatGPTRecapContext(
                day: day,
                activity: activity,
                computerHistory: computerHistory,
                screenTime: nil,
                agentActivity: agent,
                importedChats: [imported],
                localJournalSourceAbsent: false,
                renderedData: rendered,
                sourceCounts: counts,
                digest: SHA256Digest.hashHex(rendered)
            )
            let prompt = try ChatGPTRecapContextBuilder.prompt(
                for: context,
                outputLanguage: "English"
            )
            XCTAssertFalse(prompt.contains(secret))
            XCTAssertLessThanOrEqual(prompt.count, ChatGPTRecapContextBuilder.maximumPromptCharacters)

            let unavailable = try ChatGPTRecapContextBuilder.renderDataForTesting(
                day: day,
                activity: activity,
                computerHistory: nil,
                screenTime: nil,
                agentActivity: agent,
                importedChats: [],
                localJournalSourceAbsent: true,
                sourceCounts: ChatGPTRecapSourceCounts(
                    localEvents: 0,
                    activeMinutes: 0,
                    semanticSnapshots: 0,
                    screenTimeDevices: 0,
                    screenTimeApplications: 0,
                    agentCaptures: 0,
                    agentMessages: 0,
                    importedChatMessages: 0,
                    computerHistoryEpisodes: nil,
                    computerHistoryResources: nil,
                    workflowSuggestions: nil
                )
            )
            XCTAssertTrue(unavailable.contains("Causal episodes: unavailable"))
            XCTAssertTrue(unavailable.contains("Identifiable resources: unavailable"))
            XCTAssertTrue(unavailable.contains("Local journal status: unavailable"))

            let retainedOnly = ChatGPTRecapContext(
                day: day,
                activity: activity,
                computerHistory: computerHistory,
                screenTime: nil,
                agentActivity: agent,
                importedChats: [],
                localJournalSourceAbsent: true,
                renderedData: unavailable,
                sourceCounts: ChatGPTRecapSourceCounts(
                    localEvents: 0,
                    activeMinutes: 0,
                    semanticSnapshots: 0,
                    screenTimeDevices: 0,
                    screenTimeApplications: 0,
                    agentCaptures: 0,
                    agentMessages: 0,
                    importedChatMessages: 0,
                    computerHistoryEpisodes: 131,
                    computerHistoryResources: 127,
                    workflowSuggestions: 0
                ),
                digest: SHA256Digest.hashHex(unavailable)
            )
            XCTAssertTrue(retainedOnly.hasMeaningfulData)
        }

        func testRecapStoredActivityReadRejectsSymlinkAndOversizedFile() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-activity-read")
            defer { try? FileManager.default.removeItem(at: container) }
            let analysisDirectory = container.appendingPathComponent("analysis", isDirectory: true)
            try FileManager.default.createDirectory(
                at: analysisDirectory,
                withIntermediateDirectories: false
            )

            let symlinkDay = Date(timeIntervalSince1970: 1_700_000_000)
            let outside = container.appendingPathComponent("outside-analysis.json")
            try Data("{}".utf8).write(to: outside)
            let symlinkURL = analysisDirectory.appendingPathComponent(
                ActivityAnalysisPaths.dayString(symlinkDay) + ".analysis.json"
            )
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outside)
            XCTAssertThrowsError(
                try ChatGPTRecapContextBuilder.loadStoredActivityForTesting(
                    for: symlinkDay,
                    rootDirectory: container
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("could not be read safely"))
            }

            let oversizedDay = symlinkDay.addingTimeInterval(86_400)
            let oversizedURL = analysisDirectory.appendingPathComponent(
                ActivityAnalysisPaths.dayString(oversizedDay) + ".analysis.json"
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: oversizedURL)
            try handle.truncate(
                atOffset: UInt64(ChatGPTRecapContextBuilder.maximumStoredActivityBytes + 1)
            )
            try handle.close()
            XCTAssertThrowsError(
                try ChatGPTRecapContextBuilder.loadStoredActivityForTesting(
                    for: oversizedDay,
                    rootDirectory: container
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("could not be read safely"))
            }
        }

        func testCodexHomeUsesRestrictedAppManagedPermissionProfile() throws {
            let directory = try canonicalTemporaryDirectory()
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }

            try CodexAppServerSession.prepareCodexHome(at: directory)
            let configURL = directory.appendingPathComponent("config.toml")
            let config = try String(contentsOf: configURL, encoding: .utf8)
            let directoryPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                    as? NSNumber
            )
            let configPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions]
                    as? NSNumber
            )

            XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
            XCTAssertEqual(configPermissions.intValue & 0o777, 0o600)
            XCTAssertTrue(config.contains("default_permissions = \"goalong-recap\""))
            XCTAssertTrue(config.contains("\":minimal\" = \"read\""))
            XCTAssertTrue(config.contains("\":workspace_roots\" = \"read\""))
            XCTAssertTrue(config.contains("[permissions.goalong-recap.network]"))
            XCTAssertTrue(config.contains("enabled = false"))
            XCTAssertFalse(config.contains("workspaceWrite"))
            XCTAssertFalse(config.contains("readOnlyAccess"))
        }

        func testCodexEnvironmentDropsSecretsAndCredentialSources() {
            let home = URL(fileURLWithPath: "/tmp/goalong-codex-home", isDirectory: true)
            let environment = CodexAppServerSession.codexEnvironment(
                inheriting: [
                    "HOME": "/Users/test",
                    "PATH": "/usr/bin:/bin",
                    "LANG": "en_US.UTF-8",
                    "OPENAI_API_KEY": "secret",
                    "AWS_SECRET_ACCESS_KEY": "secret",
                    "HTTPS_PROXY": "https://user:password@example.com",
                    "SSH_AUTH_SOCK": "/tmp/agent.sock",
                    "SHELL": "/tmp/malicious-shell",
                    "CODEX_HOME": "/tmp/other-home",
                ],
                codexHomeURL: home
            )

            XCTAssertEqual(environment["HOME"], "/Users/test")
            XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
            XCTAssertEqual(environment["CODEX_HOME"], home.path)
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            XCTAssertNil(environment["HTTPS_PROXY"])
            XCTAssertNil(environment["SSH_AUTH_SOCK"])
            XCTAssertEqual(environment["SHELL"], "/bin/zsh")
        }

        func testCodexLocatorHonorsExplicitExecutableOverride() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let executable = directory.appendingPathComponent("codex")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let located = CodexExecutableLocator.locate(
                environment: ["GOALONG_CODEX_PATH": executable.path],
                fileManager: .default,
                bundle: .main
            )
            XCTAssertEqual(located?.standardizedFileURL, executable.standardizedFileURL)
        }

        private func makeTemporaryDirectory(prefix: String) throws -> URL {
            let directory = try canonicalTemporaryDirectory()
                .appendingPathComponent(
                    "\(prefix)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            return directory
        }

        private func canonicalTemporaryDirectory() throws -> URL {
            let path = FileManager.default.temporaryDirectory.path
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = buffer.withUnsafeMutableBufferPointer { pointer in
                path.withCString { Darwin.realpath($0, pointer.baseAddress) }
            }
            guard resolved != nil else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        }

        private func recapFixture(day: Date, markdown: String) -> ChatGPTDailyRecap {
            ChatGPTDailyRecap(
                day: day,
                generatedAt: day.addingTimeInterval(123),
                planType: "plus",
                contextDigest: String(repeating: "d", count: 64),
                sourceCounts: ChatGPTRecapSourceCounts(
                    localEvents: 2,
                    activeMinutes: 3,
                    semanticSnapshots: 5,
                    screenTimeDevices: 7,
                    screenTimeApplications: 11,
                    agentCaptures: 13,
                    agentMessages: 17,
                    importedChatMessages: 19,
                    computerHistoryEpisodes: 23,
                    computerHistoryResources: 29,
                    workflowSuggestions: 31
                ),
                markdown: markdown
            )
        }

        private func exportFixtureData(
            text: String,
            conversationID: String = "conversation-1",
            messageID: String = "message-user"
        ) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    [
                        "id": conversationID,
                        "title": "Fixture conversation",
                        "mapping": [
                            "node-user": [
                                "message": [
                                    "id": messageID,
                                    "author": ["role": "user"],
                                    "create_time": 1_700_000_001.0,
                                    "content": ["parts": [text]],
                                ]
                            ]
                        ],
                    ]
                ],
                options: [.sortedKeys]
            )
        }
    }
#endif
