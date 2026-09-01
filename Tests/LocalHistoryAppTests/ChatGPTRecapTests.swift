#if os(macOS)
    import AgentActivity
    import CryptoKit
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

        func testTransientRecapContextReadsAgentSummaryButPersistedReportDoesNotCopyIt() throws {
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let secret = "AGENT-TRANSCRIPT-SENTINEL-DO-NOT-COPY"
            let userPrompt = "USER-PROMPT-SENTINEL-VISIBLE-ONLY-IN-RUN"
            let finalReply = "FINAL-REPLY-SENTINEL-VISIBLE-ONLY-IN-RUN"
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
                models: ["gpt-5.6-luna"],
                tools: [secret],
                touchedFiles: [secret],
                commands: [secret],
                visibleMessages: [
                    AgentVisibleMessage(role: .user, text: userPrompt),
                    AgentVisibleMessage(role: .assistantFinal, text: finalReply),
                ]
            )
            let overview = AgentActivityOverview(
                day: timestamp,
                captures: [AgentCaptureRecord(index: entry, summary: summary)],
                sessionCount: 1,
                analyzedSessionCount: 1,
                messageCount: 9,
                visibleMessageCount: 2,
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
            XCTAssertTrue(rendered.contains(userPrompt))
            XCTAssertTrue(rendered.contains(finalReply))
            XCTAssertFalse(rendered.contains(secret))

            let directory = try makeTemporaryDirectory(prefix: "goalong-agent-summary-not-persisted")
            defer { try? FileManager.default.removeItem(at: directory) }
            let lines = [
                "A concrete result was advanced.",
                "Observed work time remained bounded by captured evidence.",
                "The strongest focus period advanced the selected task.",
                "A context-switching period reduced momentum.",
                "Agent collaboration was useful and can be made more concise tomorrow.",
            ]
            let recap = ChatGPTDailyRecap(
                day: timestamp,
                planType: "plus",
                contextDigest: String(repeating: "a", count: 64),
                sourceCounts: ChatGPTRecapSourceCounts(
                    localEvents: 1,
                    activeMinutes: 1,
                    semanticSnapshots: 1,
                    screenTimeDevices: 0,
                    screenTimeApplications: 0,
                    agentCaptures: 1,
                    agentMessages: 9,
                    visibleAgentMessages: 2,
                    agentToolCalls: 4,
                    agentErrors: 1,
                    analyzedAgentCaptures: 1,
                    importedChatMessages: 0,
                    computerHistoryEpisodes: 1,
                    computerHistoryResources: 0,
                    workflowSuggestions: 0
                ),
                markdown: lines.joined(separator: "\n"),
                model: CodexDailyAssessmentContract.model,
                reasoningEffort: CodexDailyAssessmentContract.reasoningEffort,
                productivityScore: 72,
                confidenceScore: 64,
                summaryLines: lines
            )
            try ChatGPTRecapPersistence.write(recap, to: directory)
            let persisted = try String(
                contentsOf: ChatGPTRecapPersistence.jsonURL(for: timestamp, in: directory),
                encoding: .utf8
            )
            XCTAssertFalse(persisted.contains(secret))
            XCTAssertFalse(persisted.contains(userPrompt))
            XCTAssertFalse(persisted.contains(finalReply))
            let reloaded = try XCTUnwrap(ChatGPTRecapPersistence.load(for: timestamp, from: directory))
            XCTAssertEqual(reloaded.sourceCounts.agentMessages, 9)
            XCTAssertEqual(reloaded.sourceCounts.visibleAgentMessages, 2)
            XCTAssertEqual(reloaded.sourceCounts.agentToolCalls, 4)
            XCTAssertEqual(reloaded.sourceCounts.agentErrors, 1)
            XCTAssertEqual(reloaded.sourceCounts.analyzedAgentCaptures, 1)
        }

        func testDailyAgentAnalysisDrainsPastEightCyclesAndCountsEverySession() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-agent-drain")
            defer { try? FileManager.default.removeItem(at: container) }
            let sourceRoot = container.appendingPathComponent("original-sources", isDirectory: true)
            let storeRoot = container.appendingPathComponent("index", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

            let sourceCount = 2_049
            let day = Calendar.current.startOfDay(for: Date())
            let line = Data("{\"role\":\"user\",\"content\":\"bounded fixture\"}\n".utf8)
            for index in 0..<sourceCount {
                try line.write(
                    to: sourceRoot.appendingPathComponent(
                        String(format: "session-%04d.jsonl", index)
                    )
                )
            }

            let store = try AgentActivityStore(rootDirectory: storeRoot)
            let folder = AgentWatchedFolder(
                id: "recap-drain",
                displayName: "Original fixture sources",
                path: sourceRoot.path,
                provider: .custom
            )
            let configuration = AgentActivityConfiguration(
                watchedFolders: [folder],
                maximumIndexEntries: sourceCount
            )
            let overview = ChatGPTRecapContextBuilder.scanAgentActivity(
                for: day,
                analyzeContent: true,
                store: store,
                configuration: configuration,
                scanner: AgentActivityScanner(store: store)
            )

            XCTAssertEqual(overview.sessionCount, sourceCount)
            XCTAssertEqual(overview.analyzedSessionCount, sourceCount)
            XCTAssertEqual(overview.messageCount, sourceCount)
            XCTAssertEqual(overview.captures.count, 256, "Detailed summaries remain RAM-bounded.")
            XCTAssertEqual(store.indexEntryCount(), sourceCount)
            let canonicalSourcePrefix = sourceRoot.resolvingSymlinksInPath().path + "/"
            XCTAssertTrue(
                store.entries().allSatisfy {
                    URL(fileURLWithPath: $0.reference.path)
                        .resolvingSymlinksInPath().path
                        .hasPrefix(canonicalSourcePrefix)
                }
            )
            XCTAssertEqual(try Data(contentsOf: sourceRoot.appendingPathComponent("session-2048.jsonl")), line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("blobs").path))
            XCTAssertLessThan(store.storageBytes(), 4 * 1_024 * 1_024)
        }

        func testAgentDialoguePromptProjectionStaysBoundedAndExcludesProcessFields() {
            let timestamp = Date(timeIntervalSince1970: 1_787_472_000)
            let processSentinel = "PROCESS-CONTENT-MUST-NOT-REACH-LUNA"
            let captures = (0..<16).map { sessionIndex -> AgentCaptureRecord in
                let reference = AgentSourceReference(
                    kind: .file,
                    path: "/tmp/session-\(sessionIndex).jsonl"
                )
                let entry = AgentSourceIndexEntry(
                    id: "entry-\(sessionIndex)",
                    stableConversationID: "session-\(sessionIndex)",
                    watchedFolderID: "codex",
                    watchedFolderName: "Codex",
                    provider: .codex,
                    reference: reference,
                    relativePath: "session-\(sessionIndex).jsonl",
                    sourceCreatedAt: timestamp,
                    sourceModifiedAt: timestamp,
                    firstIndexedAt: timestamp,
                    lastObservedAt: timestamp,
                    byteCount: 10_000,
                    sha256: String(repeating: "a", count: 64)
                )
                let messages = (0..<80).map { messageIndex in
                    AgentVisibleMessage(
                        role: messageIndex.isMultiple(of: 2) ? .user : .assistantFinal,
                        text: "session \(sessionIndex) visible \(messageIndex) "
                            + String(repeating: "useful ", count: 100)
                    )
                }
                return AgentCaptureRecord(
                    index: entry,
                    summary: AgentDocumentSummary(
                        excerpt: processSentinel,
                        messageCount: 240,
                        toolCallCount: 80,
                        tools: [processSentinel],
                        commands: [processSentinel],
                        visibleMessages: messages
                    )
                )
            }
            let overview = AgentActivityOverview(
                day: timestamp,
                captures: captures,
                sessionCount: captures.count,
                analyzedSessionCount: captures.count,
                messageCount: 3_840,
                visibleMessageCount: captures.reduce(0) {
                    $0 + $1.summary.visibleMessages.count
                },
                toolCallCount: 1_280
            )

            let rendered = ChatGPTRecapContextBuilder.renderAgentActivityForTesting(overview)

            XCTAssertLessThanOrEqual(
                rendered.count,
                ChatGPTRecapContextBuilder.maximumAgentActivityCharacters
            )
            XCTAssertTrue(rendered.contains("user request:"))
            XCTAssertTrue(rendered.contains("final assistant reply:"))
            XCTAssertTrue(rendered.contains("omitted by the daily prompt budget"))
            XCTAssertFalse(rendered.contains(processSentinel))
        }

        func testOptInRealDailyAgentAnalysisCompletesFromOriginalCodexSources() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let sourcePath = environment["GOALONG_TEST_REAL_CODEX_SOURCE_ROOT"],
                let dayText = environment["GOALONG_TEST_REAL_AGENT_DAY"]
            else {
                throw XCTSkip(
                    "Set GOALONG_TEST_REAL_CODEX_SOURCE_ROOT and GOALONG_TEST_REAL_AGENT_DAY for the read-only daily coverage audit."
                )
            }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let day = try XCTUnwrap(formatter.date(from: dayText))
            let sourceRoot = URL(fileURLWithPath: sourcePath, isDirectory: true)
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                XCTFail("The opt-in Codex source root is not a readable directory.")
                return
            }

            let storeRoot = try makeTemporaryDirectory(prefix: "goalong-real-daily-agent-index")
            defer { try? FileManager.default.removeItem(at: storeRoot) }
            let store = try AgentActivityStore(rootDirectory: storeRoot)
            let folder = AgentWatchedFolder(
                id: "real-daily-codex",
                displayName: "Codex",
                path: sourceRoot.path,
                provider: .codex
            )
            let overview = ChatGPTRecapContextBuilder.scanAgentActivity(
                for: day,
                analyzeContent: true,
                store: store,
                configuration: AgentActivityConfiguration(
                    watchedFolders: [folder],
                    maximumIndexEntries: 50_000
                ),
                scanner: AgentActivityScanner(store: store)
            )

            XCTAssertGreaterThan(overview.sessionCount, 0)
            XCTAssertEqual(overview.analyzedSessionCount, overview.sessionCount)
            XCTAssertGreaterThan(overview.messageCount, 0)
            XCTAssertGreaterThan(overview.visibleMessageCount, 0)
            let rendered = ChatGPTRecapContextBuilder.renderAgentActivityForTesting(overview)
            XCTAssertLessThanOrEqual(
                rendered.count,
                ChatGPTRecapContextBuilder.maximumAgentActivityCharacters
            )
            XCTAssertTrue(rendered.contains("user request:") || rendered.contains("final assistant reply:"))
            XCTAssertFalse(rendered.contains("<in-app-browser-context"))
            XCTAssertFalse(rendered.contains("<environment_context"))
            XCTAssertFalse(rendered.contains("<oai-mem-citation>"))
            XCTAssertTrue(
                store.entries().allSatisfy {
                    !$0.reference.path.hasPrefix(storeRoot.path + "/")
                }
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("blobs").path))
            XCTAssertLessThanOrEqual(store.storageBytes(), 13 * 1_024 * 1_024)
            print(
                "REAL_AGENT_DAILY_COVERAGE sessions=\(overview.sessionCount) "
                    + "analyzed=\(overview.analyzedSessionCount) messages=\(overview.messageCount) "
                    + "visibleMessages=\(overview.visibleMessageCount) promptChars=\(rendered.count) "
                    + "tools=\(overview.toolCallCount) errors=\(overview.errorCount) "
                    + "sourceBytes=\(overview.sourceBytes) indexBytes=\(overview.indexBytes) "
                    + "storeBytes=\(store.storageBytes())"
            )
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

        func testDailyAssessmentContractPinsLunaHighAndRequiresExactlyFiveLines() throws {
            XCTAssertEqual(CodexDailyAssessmentContract.definitionID, "daily-activity-five-line")
            XCTAssertEqual(CodexDailyAssessmentContract.definitionRevision, "2026.08.v1")
            XCTAssertEqual(CodexDailyAssessmentContract.model, "gpt-5.6-luna")
            XCTAssertEqual(CodexDailyAssessmentContract.reasoningEffort, "high")
            XCTAssertEqual(CodexDailyAssessmentContract.threadStartTimeout, 120)
            XCTAssertEqual(CodexDailyAssessmentContract.turnStartTimeout, 120)
            XCTAssertEqual(CodexDailyAssessmentContract.generationTimeout, 900)
            let schema = CodexDailyAssessmentContract.outputSchema
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let lineSchema = try XCTUnwrap(properties["summaryLines"] as? [String: Any])
            XCTAssertEqual(lineSchema["minItems"] as? Int, 5)
            XCTAssertEqual(lineSchema["maxItems"] as? Int, 5)

            var collector = CodexRecapOutputCollector()
            try collector.setFinalText(
                """
                {"productivityScore":78,"confidenceScore":67,"summaryLines":["one","two","three","four","five"]}
                """
            )
            let result = try collector.completedAssessment()
            XCTAssertEqual(result.productivityScore, 78)
            XCTAssertEqual(result.confidenceScore, 67)
            XCTAssertEqual(result.summaryLines.count, 5)
            XCTAssertEqual(result.markdown.components(separatedBy: "\n").count, 5)
            XCTAssertEqual(
                result.rawResponse,
                """
                {"productivityScore":78,"confidenceScore":67,"summaryLines":["one","two","three","four","five"]}
                """
            )

            var invalid = CodexRecapOutputCollector()
            try invalid.setFinalText(
                """
                {"productivityScore":78,"confidenceScore":67,"summaryLines":["one","two","three","four"]}
                """
            )
            XCTAssertThrowsError(try invalid.completedAssessment())
        }

        func testGeneratedResponseCapsuleIsEncryptedBoundedAuthenticatedAndCryptographicallyDeleted() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-evidence-capsule")
            defer { try? FileManager.default.removeItem(at: container) }
            let executionID = UUID().uuidString.lowercased()
            let plaintext = Data(
                #"{"productivityScore":81,"summaryLines":["one","two","three","four","five"]}"#.utf8
            )
            let store = AnalysisEvidenceCapsuleStore(directory: container)
            defer { try? store.destroy(executionID: executionID) }

            let url = try store.storeGeneratedResponse(
                plaintext,
                executionID: executionID,
                createdAt: Date()
            )
            let capsule = try Data(contentsOf: url)
            XCTAssertNil(capsule.range(of: plaintext))
            XCTAssertLessThanOrEqual(
                capsule.count - plaintext.count,
                AnalysisEvidenceCapsuleStore.maximumCapsuleOverheadBytes
            )
            XCTAssertEqual(
                try store.decryptGeneratedResponse(executionID: executionID),
                plaintext
            )

            var tampered = capsule
            tampered[tampered.count - 1] ^= 0x01
            try tampered.write(to: url, options: [.atomic])
            XCTAssertThrowsError(try store.decryptGeneratedResponse(executionID: executionID))

            try store.destroy(executionID: executionID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertThrowsError(try store.decryptGeneratedResponse(executionID: executionID))
        }

        func testAnalysisProofStoreCreatesBoundedVerifiableArtifactsWithoutCopyingPromptOrTranscript() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-analysis-proof-store")
            defer { try? FileManager.default.removeItem(at: container) }
            let proofRoot = container.appendingPathComponent("proofs", isDirectory: true)
            let missingEvents = container.appendingPathComponent("events", isDirectory: true)
            let missingSeals = container.appendingPathComponent("seals", isDirectory: true)
            let missingReceipts = container.appendingPathComponent("receipts", isDirectory: true)
            let shareBuilder = SharePackageBuilder(
                eventFileURL: { day in
                    missingEvents.appendingPathComponent("\(AppPaths.localDayString(for: day)).jsonl")
                },
                sealFileURL: { day in
                    missingSeals.appendingPathComponent("\(AppPaths.localDayString(for: day)).seals.jsonl")
                },
                sealsDirectory: missingSeals,
                receiptsDirectory: missingReceipts
            )
            let store = AnalysisProofStore(
                rootDirectory: proofRoot,
                shareBuilder: shareBuilder
            )
            let runID = UUID()
            defer {
                try? AnalysisEvidenceCapsuleStore(
                    directory: proofRoot.appendingPathComponent("private-evidence", isDirectory: true)
                ).destroy(executionID: runID.uuidString.lowercased())
            }
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: 1_788_148_800)
            )
            let transcriptSecret = "UNIQUE_TRANSCRIPT_BODY_MUST_NEVER_BE_STORED"
            let promptSecret = "UNIQUE_COMPLETE_PROMPT_MUST_NEVER_BE_STORED"
            let sourcePath = container.appendingPathComponent("original-session.jsonl").path
            let sourceIndex = AgentSourceIndexEntry(
                id: "ignored",
                stableConversationID: "conversation-proof-fixture",
                watchedFolderID: "fixture-folder",
                watchedFolderName: "Fixture",
                provider: .codex,
                reference: AgentSourceReference(kind: .file, path: sourcePath),
                relativePath: "original-session.jsonl",
                sourceCreatedAt: day,
                sourceModifiedAt: day.addingTimeInterval(60),
                conversationStartedAt: day,
                conversationEndedAt: day.addingTimeInterval(120),
                firstIndexedAt: day,
                lastObservedAt: day.addingTimeInterval(120),
                byteCount: 1_024,
                sha256: SHA256Digest.hashHex(Data("original source".utf8)),
                startOffset: 10,
                endOffset: 900,
                availability: .available
            )
            let capture = AgentCaptureRecord(
                index: sourceIndex,
                summary: AgentDocumentSummary(
                    format: .jsonLines,
                    sessionID: "conversation-proof-fixture",
                    title: "Proof fixture",
                    startedAt: day,
                    endedAt: day.addingTimeInterval(120),
                    messageCount: 2,
                    userMessageCount: 1,
                    assistantMessageCount: 1,
                    visibleMessages: [
                        AgentVisibleMessage(role: .user, text: transcriptSecret),
                        AgentVisibleMessage(role: .assistantFinal, text: "Bounded final answer"),
                    ]
                ),
                isAnalyzed: true,
                digestScope: .selectedIntervalProjection,
                analysisInterval: DateInterval(start: day, duration: 86_400),
                projectionIsComplete: true
            )
            let sourceCounts = ChatGPTRecapSourceCounts(
                localEvents: 0,
                activeMinutes: 0,
                semanticSnapshots: 0,
                screenTimeDevices: 0,
                screenTimeApplications: 0,
                agentCaptures: 1,
                agentMessages: 2,
                visibleAgentMessages: 2,
                analyzedAgentCaptures: 1,
                importedChatMessages: 0,
                computerHistoryEpisodes: 0,
                computerHistoryResources: 0,
                workflowSuggestions: 0
            )
            let rendered = "Context includes \(transcriptSecret)"
            let context = ChatGPTRecapContext(
                day: day,
                activity: ActivityAnalysisEngine.analyze(events: [], day: day),
                computerHistory: nil,
                screenTime: nil,
                agentActivity: AgentActivityOverview(
                    day: day,
                    captures: [capture],
                    sessionCount: 1,
                    analyzedSessionCount: 1,
                    messageCount: 2,
                    visibleMessageCount: 2,
                    sourceBytes: 1_024,
                    indexBytes: 512,
                    lastCaptureAt: day.addingTimeInterval(120)
                ),
                importedChats: [],
                localJournalSourceAbsent: true,
                renderedData: rendered,
                sourceCounts: sourceCounts,
                digest: SHA256Digest.hashHex(Data(rendered.utf8))
            )
            let lines = ["one", "two", "three", "four", "five"]
            let recap = ChatGPTDailyRecap(
                schemaVersion: 3,
                day: day,
                generatedAt: day.addingTimeInterval(3_600),
                planType: "plus",
                contextDigest: context.digest,
                sourceCounts: sourceCounts,
                markdown: lines.joined(separator: "\n"),
                model: CodexDailyAssessmentContract.model,
                reasoningEffort: CodexDailyAssessmentContract.reasoningEffort,
                productivityScore: 80,
                confidenceScore: 70,
                summaryLines: lines
            )
            let rawResponse =
                #"{"productivityScore":80,"confidenceScore":70,"summaryLines":["one","two","three","four","five"]}"#
            let assessment = try ChatGPTDailyAssessment(
                productivityScore: 80,
                confidenceScore: 70,
                summaryLines: lines,
                rawResponse: rawResponse,
                threadID: "thread-proof-fixture",
                turnID: "turn-proof-fixture"
            )
            let prompt = "\(promptSecret)\n<goalong_context>\n\(rendered)\n</goalong_context>"
            let result = try store.create(
                runID: runID,
                day: day,
                generatedAt: recap.generatedAt,
                trigger: "manual",
                prompt: prompt,
                context: context,
                assessment: assessment,
                recap: recap,
                identity: FixtureAnalysisIdentity()
            )
            XCTAssertTrue(result.report.isLocallyValid, result.report.issues.joined(separator: ", "))
            XCTAssertEqual(result.reference.retentionMode, "hash_only_no_transcript_copy")

            let proofDirectory = proofRoot.appendingPathComponent(
                result.reference.proofDirectoryName, isDirectory: true
            )
            let files = try FileManager.default.contentsOfDirectory(
                at: proofDirectory,
                includingPropertiesForKeys: nil
            )
            let proofBytes = try files.reduce(0) { total, file in
                total + (try Data(contentsOf: file).count)
            }
            XCTAssertLessThan(proofBytes, 128 * 1_024)
            for file in files {
                let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                XCTAssertFalse(text.contains(transcriptSecret), file.lastPathComponent)
                XCTAssertFalse(text.contains(promptSecret), file.lastPathComponent)
            }

            let allProofFiles = FileManager.default.enumerator(
                at: proofRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.allObjects as? [URL] ?? []
            for file in allProofFiles {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let bytes = try Data(contentsOf: file)
                XCTAssertNil(bytes.range(of: Data(transcriptSecret.utf8)), file.path)
                XCTAssertNil(bytes.range(of: Data(promptSecret.utf8)), file.path)
            }

            let exported = container.appendingPathComponent("fixture.goalong-proof")
            let exportReport = try store.export(reference: result.reference, to: exported)
            XCTAssertTrue(exportReport.isLocallyValid)
            let archive = try Data(contentsOf: exported)
            XCTAssertLessThan(archive.count, 128 * 1_024)
            XCTAssertTrue(try GoalongProofPackageVerifier.verify(archive: archive).isLocallyValid)
            XCTAssertNil(archive.range(of: Data(transcriptSecret.utf8)))
            XCTAssertNil(archive.range(of: Data(promptSecret.utf8)))
            XCTAssertNil(archive.range(of: Data(sourcePath.utf8)))
            print("Analysis proof bytes=\(proofBytes) archive_bytes=\(archive.count)")
        }

        func testAutomaticRecapScheduleTargetsOnlyThePreviousCompletedDay() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let now = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 18, minute: 30))
            )
            let completed = try XCTUnwrap(ChatGPTDailyRecapSchedule.completedDay(at: now, calendar: calendar))
            let boundary = try XCTUnwrap(ChatGPTDailyRecapSchedule.nextBoundary(after: now, calendar: calendar))
            XCTAssertEqual(
                calendar.dateComponents([.year, .month, .day], from: completed),
                DateComponents(year: 2026, month: 8, day: 26)
            )
            XCTAssertEqual(
                calendar.dateComponents([.year, .month, .day, .hour, .minute], from: boundary),
                DateComponents(year: 2026, month: 8, day: 28, hour: 0, minute: 5)
            )
        }

        func testCodexSessionReadsResponsesWithoutWaitingForStdoutClosure() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-codex-streaming-response")
            defer { try? FileManager.default.removeItem(at: container) }
            let codexHome = container.appendingPathComponent("codex-home", isDirectory: true)
            let executable = container.appendingPathComponent("codex-fixture")
            let script = """
                #!/bin/sh
                IFS= read -r initialize_request
                printf '%s\\n' '{"id":1,"result":{"codexHome":"\(codexHome.path)"}}'
                IFS= read -r initialized_notification
                IFS= read -r account_request
                printf '%s\\n' '{"id":2,"result":{"account":null}}'
                sleep 3
                """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )

            let startedAt = Date()
            let session = try CodexAppServerSession(
                executableURL: executable,
                codexHomeURL: codexHome
            )
            defer { session.close() }

            XCTAssertNil(try session.readAccount())
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                2,
                "A newline-delimited app-server response must be consumed before stdout closes."
            )
        }

        func testCodexDailyAssessmentSessionPinsModelAndEffortBeforeStartingStructuredTurn() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-codex-assessment-contract")
            defer { try? FileManager.default.removeItem(at: container) }
            let codexHome = container.appendingPathComponent("codex-home", isDirectory: true)
            let workspace = container.appendingPathComponent("workspace", isDirectory: true)
            let executable = container.appendingPathComponent("codex-fixture")
            let threadRequest = container.appendingPathComponent("thread-request.json")
            let turnRequest = container.appendingPathComponent("turn-request.json")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            let script = """
                #!/bin/sh
                IFS= read -r initialize_request
                printf '%s\\n' '{"id":1,"result":{"codexHome":"\(codexHome.path)"}}'
                IFS= read -r initialized_notification
                IFS= read -r account_request
                printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
                IFS= read -r model_request
                printf '%s\\n' '{"id":3,"result":{"data":[{"id":"luna","model":"gpt-5.6-luna","displayName":"GPT-5.6 Luna","description":"fixture","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}]}],"nextCursor":null}}'
                IFS= read -r thread_request
                printf '%s' "$thread_request" > '\(threadRequest.path)'
                printf '%s\\n' '{"id":4,"result":{"thread":{"id":"thread-1","ephemeral":true},"model":"gpt-5.6-luna","reasoningEffort":"high","activePermissionProfile":{"id":"goalong-recap"},"cwd":"\(workspace.path)","runtimeWorkspaceRoots":[]}}'
                IFS= read -r turn_request
                printf '%s' "$turn_request" > '\(turnRequest.path)'
                printf '%s\\n' '{"id":5,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress"}}}'
                printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"{\\"productivityScore\\":81,\\"confidenceScore\\":73,\\"summaryLines\\":[\\"one\\",\\"two\\",\\"three\\",\\"four\\",\\"five\\"]}"}}}'
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-1","items":[],"status":"completed"}}}'
                """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )

            let session = try CodexAppServerSession(
                executableURL: executable,
                codexHomeURL: codexHome
            )
            defer { session.close() }
            let assessment = try session.generateRecap(prompt: "fixture", workingDirectory: workspace)
            XCTAssertEqual(assessment.productivityScore, 81)
            XCTAssertEqual(assessment.summaryLines.count, 5)

            let thread = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: threadRequest)) as? [String: Any]
            )
            let threadParams = try XCTUnwrap(thread["params"] as? [String: Any])
            XCTAssertEqual(threadParams["model"] as? String, "gpt-5.6-luna")
            let config = try XCTUnwrap(threadParams["config"] as? [String: Any])
            XCTAssertEqual(config["model_reasoning_effort"] as? String, "high")

            let turn = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: turnRequest)) as? [String: Any]
            )
            let turnParams = try XCTUnwrap(turn["params"] as? [String: Any])
            XCTAssertNil(turnParams["model"])
            XCTAssertNil(turnParams["effort"])
            let outputSchema = try XCTUnwrap(turnParams["outputSchema"] as? [String: Any])
            XCTAssertEqual(outputSchema["additionalProperties"] as? Bool, false)
        }

        func testCodexDailyAssessmentWorkspaceRootsAcceptOnlyNoAccessOrExactTemporaryWorkspace() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-codex-root-confinement")
            defer { try? FileManager.default.removeItem(at: container) }
            let workspace = container.appendingPathComponent("workspace", isDirectory: true)
            let outside = container.appendingPathComponent("outside", isDirectory: true)

            XCTAssertTrue(CodexAppServerSession.workspaceRootsAreConfined([], to: workspace))
            XCTAssertTrue(
                CodexAppServerSession.workspaceRootsAreConfined([workspace.path], to: workspace)
            )
            XCTAssertFalse(
                CodexAppServerSession.workspaceRootsAreConfined([outside.path], to: workspace)
            )
            XCTAssertFalse(
                CodexAppServerSession.workspaceRootsAreConfined(
                    [workspace.path, outside.path],
                    to: workspace
                )
            )
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

        func testSignedRecapBindsSavedResultWithoutPersistingPromptBody() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-signed-recap")
            defer { try? FileManager.default.removeItem(at: container) }
            let directory = container.appendingPathComponent("recaps", isDirectory: true)
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
            let unsigned = try ChatGPTRecapPersistence.preparedForPersistence(
                recapFixture(day: day, markdown: "A signed useful result.")
            )
            let prompt = Data("private prompt body that must not be copied".utf8)
            let identity = FixtureAnalysisIdentity()
            let attestation = try AnalysisRunAttestationSigner.sign(
                runID: UUID(),
                day: day,
                generatedAt: unsigned.generatedAt,
                trigger: "manual",
                prompt: prompt,
                recap: unsigned,
                identity: identity
            )
            let signed = ChatGPTDailyRecap(
                schemaVersion: 3,
                day: unsigned.day,
                generatedAt: unsigned.generatedAt,
                provider: unsigned.provider,
                planType: unsigned.planType,
                contextDigest: unsigned.contextDigest,
                sourceCounts: unsigned.sourceCounts,
                markdown: unsigned.markdown,
                model: unsigned.model,
                reasoningEffort: unsigned.reasoningEffort,
                productivityScore: unsigned.productivityScore,
                confidenceScore: unsigned.confidenceScore,
                summaryLines: unsigned.summaryLines,
                attestation: attestation
            )

            XCTAssertTrue(signed.verifiesLocalAttestation)
            XCTAssertTrue(signed.isValidCurrentAssessment)
            try ChatGPTRecapPersistence.write(signed, to: directory)
            XCTAssertEqual(ChatGPTRecapPersistence.load(for: day, from: directory), signed)

            let persisted = try Data(
                contentsOf: ChatGPTRecapPersistence.jsonURL(for: day, in: directory)
            )
            let comparisonEncoder = JSONEncoder()
            comparisonEncoder.dateEncodingStrategy = .iso8601
            comparisonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let unsignedBytes = try comparisonEncoder.encode(unsigned).count
            XCTAssertLessThan(persisted.count, ChatGPTRecapPersistence.maximumJSONBytes)
            XCTAssertLessThan(persisted.count - unsignedBytes, 4 * 1_024)
            XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(String(decoding: prompt, as: UTF8.self)))
            XCTAssertTrue(String(decoding: persisted, as: UTF8.self).contains(attestation.promptSHA256))
            print(
                "ChatGPT signed recap bytes=\(persisted.count) "
                    + "unsigned_bytes=\(unsignedBytes) overhead=\(persisted.count - unsignedBytes)"
            )

            let tampered = ChatGPTDailyRecap(
                schemaVersion: 3,
                day: signed.day,
                generatedAt: signed.generatedAt,
                provider: signed.provider,
                planType: signed.planType,
                contextDigest: signed.contextDigest,
                sourceCounts: signed.sourceCounts,
                markdown: signed.markdown.replacingOccurrences(of: "useful", with: "altered"),
                model: signed.model,
                reasoningEffort: signed.reasoningEffort,
                productivityScore: signed.productivityScore,
                confidenceScore: signed.confidenceScore,
                summaryLines: signed.summaryLines?.map {
                    $0.replacingOccurrences(of: "useful", with: "altered")
                },
                attestation: signed.attestation
            )
            XCTAssertFalse(tampered.verifiesLocalAttestation)
            XCTAssertThrowsError(try ChatGPTRecapPersistence.write(tampered, to: directory))
            XCTAssertEqual(ChatGPTRecapPersistence.load(for: day, from: directory), signed)

            let tamperedScore = ChatGPTDailyRecap(
                schemaVersion: 3,
                day: signed.day,
                generatedAt: signed.generatedAt,
                provider: signed.provider,
                planType: signed.planType,
                contextDigest: signed.contextDigest,
                sourceCounts: signed.sourceCounts,
                markdown: signed.markdown,
                model: signed.model,
                reasoningEffort: signed.reasoningEffort,
                productivityScore: 99,
                confidenceScore: signed.confidenceScore,
                summaryLines: signed.summaryLines,
                attestation: signed.attestation
            )
            XCTAssertFalse(tamperedScore.verifiesLocalAttestation)
            XCTAssertThrowsError(try ChatGPTRecapPersistence.write(tamperedScore, to: directory))
            XCTAssertEqual(ChatGPTRecapPersistence.load(for: day, from: directory), signed)
        }

        func testSignedRecapTimestampSurvivesISO8601PersistenceRoundTrip() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-signed-recap-time")
            defer { try? FileManager.default.removeItem(at: container) }
            let directory = container.appendingPathComponent("recaps", isDirectory: true)
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
            let base = recapFixture(day: day, markdown: "A time-stable signed result.")
            let fractionalGeneratedAt = Date(timeIntervalSince1970: 1_700_000_000.789)
            let draft = ChatGPTDailyRecap(
                day: base.day,
                generatedAt: fractionalGeneratedAt,
                provider: base.provider,
                planType: base.planType,
                contextDigest: base.contextDigest,
                sourceCounts: base.sourceCounts,
                markdown: base.markdown,
                model: base.model,
                reasoningEffort: base.reasoningEffort,
                productivityScore: base.productivityScore,
                confidenceScore: base.confidenceScore,
                summaryLines: base.summaryLines
            )
            let normalized = try ChatGPTRecapPersistence.preparedForPersistence(draft)
            let attestation = try AnalysisRunAttestationSigner.sign(
                runID: UUID(),
                day: day,
                generatedAt: fractionalGeneratedAt,
                trigger: "automatic",
                prompt: Data("transient prompt".utf8),
                recap: normalized,
                identity: FixtureAnalysisIdentity()
            )
            let signed = ChatGPTDailyRecap(
                schemaVersion: 3,
                day: normalized.day,
                generatedAt: normalized.generatedAt,
                provider: normalized.provider,
                planType: normalized.planType,
                contextDigest: normalized.contextDigest,
                sourceCounts: normalized.sourceCounts,
                markdown: normalized.markdown,
                model: normalized.model,
                reasoningEffort: normalized.reasoningEffort,
                productivityScore: normalized.productivityScore,
                confidenceScore: normalized.confidenceScore,
                summaryLines: normalized.summaryLines,
                attestation: attestation
            )

            try ChatGPTRecapPersistence.write(signed, to: directory)
            let reloaded = try XCTUnwrap(
                ChatGPTRecapPersistence.load(for: day, from: directory)
            )
            XCTAssertTrue(reloaded.verifiesLocalAttestation)
            XCTAssertEqual(reloaded.attestation?.generatedAtMilliseconds, 1_700_000_000_000)
            XCTAssertEqual(reloaded.generatedAt.timeIntervalSince1970, 1_700_000_000)
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

        func testAutomaticRecapRetryPolicyIsBoundedAndSkipsPermanentFailures() {
            XCTAssertEqual(
                ChatGPTRecapRuntime.automaticRetryDelaysForTesting,
                [900, 3_600, 10_800] as [TimeInterval]
            )
            XCTAssertTrue(
                ChatGPTRecapRuntime.isRetryableAutomaticError(
                    CodexAppServerError.timeout("starting the recap agent")
                )
            )
            XCTAssertTrue(
                ChatGPTRecapRuntime.isRetryableAutomaticError(
                    CodexAppServerError.malformedResponse("temporary invalid response")
                )
            )
            XCTAssertFalse(
                ChatGPTRecapRuntime.isRetryableAutomaticError(
                    CodexAppServerError.accountNotChatGPT("api")
                )
            )
            XCTAssertFalse(
                ChatGPTRecapRuntime.isRetryableAutomaticError(
                    CodexAppServerError.protocolLimitExceeded("bounded prompt")
                )
            )
            XCTAssertFalse(
                ChatGPTRecapRuntime.isRetryableAutomaticError(
                    NSError(domain: "ChatGPTRecapTests", code: 1)
                )
            )
        }

        func testAutomaticRecapRetrySchedulingIsBoundedAndCancelledOnStop() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-retry-runtime")
            defer { try? FileManager.default.removeItem(at: container) }
            var scheduledDelays: [TimeInterval] = []
            var scheduledWork: [DispatchWorkItem] = []
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: container.appendingPathComponent("recaps", isDirectory: true),
                executableLocator: { nil },
                sessionFactory: { _ in
                    throw NSError(domain: "ChatGPTRecapTests", code: 101)
                },
                directoryOpener: { _ in },
                fileRevealer: { _ in },
                delayedAutomaticScheduler: { _ in },
                automaticRetryScheduler: { delay, workItem in
                    scheduledDelays.append(delay)
                    scheduledWork.append(workItem)
                },
                analysisConsentProvider: { true }
            )
            runtime.automaticRecapsEnabled = true
            runtime.start()
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
            for _ in 0..<4 {
                runtime.scheduleAutomaticRetryForTesting(
                    for: day,
                    after: CodexAppServerError.timeout("starting the recap agent")
                )
            }

            XCTAssertEqual(scheduledDelays, [900, 3_600, 10_800] as [TimeInterval])
            XCTAssertEqual(runtime.automaticRetryAttemptForTesting, 3)
            XCTAssertEqual(scheduledWork.count, 3)
            XCTAssertTrue(scheduledWork[0].isCancelled)
            XCTAssertTrue(scheduledWork[1].isCancelled)
            XCTAssertFalse(scheduledWork[2].isCancelled)

            runtime.stop()
            XCTAssertTrue(scheduledWork[2].isCancelled)
            XCTAssertEqual(runtime.automaticRetryAttemptForTesting, 0)
        }

        func testAutomaticRecapHasOneIndependentDailyBoundaryFallback() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-boundary-fallback")
            defer { try? FileManager.default.removeItem(at: container) }
            var scheduledDates: [Date] = []
            var scheduledItems: [DispatchWorkItem] = []
            let beforeStart = Date()
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: container.appendingPathComponent("recaps", isDirectory: true),
                executableLocator: { nil },
                sessionFactory: { _ in
                    throw NSError(domain: "ChatGPTRecapTests", code: 102)
                },
                directoryOpener: { _ in },
                fileRevealer: { _ in },
                delayedAutomaticScheduler: { _ in },
                automaticRetryScheduler: { _, _ in },
                automaticBoundaryFallbackScheduler: { fireDate, workItem in
                    scheduledDates.append(fireDate)
                    scheduledItems.append(workItem)
                },
                analysisConsentProvider: { true }
            )

            runtime.automaticRecapsEnabled = true
            runtime.start()

            XCTAssertEqual(scheduledDates.count, 1)
            XCTAssertEqual(scheduledItems.count, 1)
            XCTAssertTrue(runtime.hasAutomaticBoundaryFallbackForTesting)
            let boundary = try XCTUnwrap(
                ChatGPTDailyRecapSchedule.nextBoundary(after: beforeStart)
            )
            XCTAssertEqual(
                scheduledDates[0].timeIntervalSince(boundary),
                5 * 60,
                accuracy: 1
            )
            XCTAssertFalse(scheduledItems[0].isCancelled)

            runtime.stop()
            XCTAssertTrue(scheduledItems[0].isCancelled)
            XCTAssertFalse(runtime.hasAutomaticBoundaryFallbackForTesting)
        }

        func testAutomaticRecapCannotStartWithoutGoalongConsent() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-recap-no-consent")
            defer { try? FileManager.default.removeItem(at: container) }
            var scheduledDates: [Date] = []
            var delayedAutomaticItems: [DispatchWorkItem] = []
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: container.appendingPathComponent("recaps", isDirectory: true),
                executableLocator: { nil },
                sessionFactory: { _ in
                    throw NSError(domain: "ChatGPTRecapTests", code: 103)
                },
                directoryOpener: { _ in },
                fileRevealer: { _ in },
                delayedAutomaticScheduler: { delayedAutomaticItems.append($0) },
                automaticRetryScheduler: { _, _ in },
                automaticBoundaryFallbackScheduler: { fireDate, _ in
                    scheduledDates.append(fireDate)
                },
                analysisConsentProvider: { false }
            )

            runtime.automaticRecapsEnabled = true
            runtime.start()

            XCTAssertTrue(scheduledDates.isEmpty)
            XCTAssertTrue(delayedAutomaticItems.isEmpty)
            XCTAssertFalse(runtime.hasAutomaticBoundaryFallbackForTesting)
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

        func testChatGPTTranscriptImportIsDisabledAndCreatesNoArchive() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-chatgpt-import")
            defer { try? FileManager.default.removeItem(at: container) }
            let source = container.appendingPathComponent("conversations.json")
            let sourceData = try exportFixtureData(text: "A stable imported message")
            try sourceData.write(to: source)
            let store = ChatGPTHistoryStore(
                rootDirectory: container.appendingPathComponent("history", isDirectory: true)
            )
            XCTAssertThrowsError(try store.importConversations(from: source)) { error in
                guard case ChatGPTHistoryStoreError.importsDisabled = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.archiveFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootDirectory.path))
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

        func testDisabledChatGPTImportDoesNotOpenSymlinkOrCreateStorage() throws {
            let container = try makeTemporaryDirectory(prefix: "goalong-chatgpt-import-races")
            defer { try? FileManager.default.removeItem(at: container) }
            let outside = container.appendingPathComponent("outside.json")
            let outsideData = try exportFixtureData(text: "Do not read or copy")
            try outsideData.write(to: outside)
            let source = container.appendingPathComponent("conversations-link.json")
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            let store = ChatGPTHistoryStore(
                rootDirectory: container.appendingPathComponent("history", isDirectory: true)
            )
            XCTAssertThrowsError(try store.importConversations(from: source)) { error in
                guard case ChatGPTHistoryStoreError.importsDisabled = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: outside), outsideData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.archiveFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootDirectory.path))
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
                "## Computer activity aggregates",
                "## Apple Screen Time",
                "## Local agent and coding-chat history",
                "## Imported ChatGPT conversation history",
                "## Source manifest — exact counts",
            ]
            let positions = try orderedHeaders.map { try XCTUnwrap(rendered.range(of: $0)?.lowerBound) }
            XCTAssertEqual(positions, positions.sorted())
            XCTAssertFalse(rendered.contains("CH_TAIL_MUST_BE_OMITTED"))
            XCTAssertFalse(rendered.contains("computer-history-detail"))
            XCTAssertTrue(rendered.contains("IMPORTED_CHAT_LATE"))
            XCTAssertTrue(rendered.contains("events=101"))
            XCTAssertTrue(rendered.contains("actions=103"))
            XCTAssertTrue(rendered.contains("episodes=131"))
            XCTAssertTrue(rendered.contains("resources=127"))
            XCTAssertTrue(rendered.contains("paired_before_after=113"))
            XCTAssertTrue(rendered.contains("Screen Time applications: 11"))
            XCTAssertTrue(rendered.contains("Direct-read agent messages: 17"))
            XCTAssertFalse(rendered.contains(secret))
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
            XCTAssertTrue(config.contains("[features]"))
            XCTAssertTrue(config.contains("plugins = false"))
            XCTAssertTrue(config.contains("remote_plugin = false"))
            XCTAssertTrue(config.contains("goals = false"))
            XCTAssertTrue(config.contains("memories = false"))
            XCTAssertTrue(config.contains("shell_tool = false"))
            XCTAssertFalse(config.contains("workspaceWrite"))
            XCTAssertFalse(config.contains("readOnlyAccess"))
        }

        func testCodexHomePrunesOnlyEphemeralRuntimeArtifacts() throws {
            let directory = try canonicalTemporaryDirectory()
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try CodexAppServerSession.prepareCodexHome(at: directory)

            let removableNames = [
                ".tmp", "cache", "plugins", "skills", "sessions", "tmp", "history.jsonl",
                "logs_2.sqlite", "logs_2.sqlite-wal", "state_5.sqlite",
            ]
            for name in removableNames {
                let url = directory.appendingPathComponent(name)
                if name.contains(".") && !name.hasPrefix(".") {
                    try Data("ephemeral".utf8).write(to: url)
                } else if name == "history.jsonl" {
                    try Data("ephemeral".utf8).write(to: url)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                }
            }
            let retainedNames = ["auth.json", "models_cache.json", "installation_id", "custom.json"]
            for name in retainedNames {
                try Data("retained".utf8).write(to: directory.appendingPathComponent(name))
            }

            try CodexAppServerSession.pruneEphemeralCodexArtifacts(at: directory)

            for name in removableNames {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                    "Expected \(name) to be removed"
                )
            }
            for name in retainedNames {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                    "Expected \(name) to be retained"
                )
            }
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
            let lines = [
                markdown,
                "Observed start and end remain evidence-bounded.",
                "The strongest focus period advanced concrete work.",
                "The lowest-momentum period involved context switching.",
                "Agent collaboration produced a useful next step.",
            ]
            return ChatGPTDailyRecap(
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
                markdown: lines.joined(separator: "\n"),
                model: CodexDailyAssessmentContract.model,
                reasoningEffort: CodexDailyAssessmentContract.reasoningEffort,
                productivityScore: 74,
                confidenceScore: 68,
                summaryLines: lines
            )
        }

        private final class FixtureAnalysisIdentity: AnalysisRunSigningIdentity {
            private let key = P256.Signing.PrivateKey()
            lazy var info: DeviceIdentityInfo = {
                let publicKey = key.publicKey.x963Representation
                return DeviceIdentityInfo(
                    deviceID: SHA256Digest.hashHex(publicKey),
                    publicKeyBase64: publicKey.base64EncodedString(),
                    trustTier: "fixture",
                    algorithm: AnchorSignatureVerifier.supportedAlgorithm
                )
            }()

            func sign(_ message: Data) throws -> Data {
                try key.signature(for: message).derRepresentation
            }
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
