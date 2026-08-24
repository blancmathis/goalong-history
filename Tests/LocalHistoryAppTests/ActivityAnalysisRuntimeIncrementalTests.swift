#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class ActivityAnalysisRuntimeIncrementalTests: XCTestCase {
        func testSemanticBoundaryValidationRejectsPrivateOrChangedContext() {
            let safe = ContextSnapshot(
                app: AppSnapshot(
                    name: "Fixture",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Public document", role: "AXWindow", subrole: nil),
                focusedElement: ElementSnapshot(
                    role: "AXTextArea",
                    subrole: nil,
                    title: nil,
                    label: "Editor",
                    identifier: "editor",
                    isSecure: false
                ),
                url: URLSnapshot(
                    value: "https://example.com/public",
                    host: "example.com",
                    redactionApplied: false
                ),
                suppressionReason: nil
            )
            XCTAssertTrue(ActivityAnalysisRuntime.semanticBoundaryMatches(safe, expected: safe))

            let privateWindow = ContextSnapshot(
                app: safe.app,
                window: safe.window,
                focusedElement: safe.focusedElement,
                url: safe.url,
                suppressionReason: .privateBrowserWindow
            )
            XCTAssertFalse(
                ActivityAnalysisRuntime.semanticBoundaryMatches(privateWindow, expected: safe)
            )

            let changedWindow = ContextSnapshot(
                app: safe.app,
                window: WindowSnapshot(title: "Different document", role: "AXWindow", subrole: nil),
                focusedElement: safe.focusedElement,
                url: safe.url,
                suppressionReason: nil
            )
            XCTAssertFalse(
                ActivityAnalysisRuntime.semanticBoundaryMatches(changedWindow, expected: safe)
            )
        }

        func testCoalescerRunsOneActivePassAndAtMostOneCatchUp() {
            let coalescer = ActivityAnalysisPassCoalescer(
                label: "goalong-runtime-coalescer-test-\(UUID().uuidString)"
            )
            let firstPassStarted = DispatchSemaphore(value: 0)
            let releaseFirstPass = DispatchSemaphore(value: 0)
            let stateLock = NSLock()
            var runCount = 0
            var activeCount = 0
            var maximumConcurrent = 0
            var forceValues: [Bool] = []

            let operation: (Bool) -> Void = { force in
                stateLock.lock()
                runCount += 1
                let currentRun = runCount
                activeCount += 1
                maximumConcurrent = max(maximumConcurrent, activeCount)
                forceValues.append(force)
                stateLock.unlock()

                if currentRun == 1 {
                    firstPassStarted.signal()
                    _ = releaseFirstPass.wait(timeout: .now() + 2)
                }

                stateLock.lock()
                activeCount -= 1
                stateLock.unlock()
            }

            coalescer.request(force: false, operation: operation)
            XCTAssertEqual(firstPassStarted.wait(timeout: .now() + 2), .success)
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                coalescer.request(force: index == 50, operation: operation)
            }
            releaseFirstPass.signal()
            XCTAssertTrue(coalescer.waitUntilIdle(timeout: .now() + 2))

            stateLock.lock()
            let finalRunCount = runCount
            let finalMaximumConcurrent = maximumConcurrent
            let finalForceValues = forceValues
            stateLock.unlock()
            XCTAssertEqual(finalRunCount, 2)
            XCTAssertEqual(finalMaximumConcurrent, 1)
            XCTAssertEqual(finalForceValues, [false, true])
        }

        func testCoalescerDoesNotLoseRequestArrivingDuringCatchUp() {
            let coalescer = ActivityAnalysisPassCoalescer(
                label: "goalong-runtime-catchup-test-\(UUID().uuidString)"
            )
            let passStarted = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
            let releasePass = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
            let lock = NSLock()
            var forceValues: [Bool] = []
            let operation: (Bool) -> Void = { force in
                lock.lock()
                forceValues.append(force)
                let index = forceValues.count - 1
                lock.unlock()
                if index < 2 {
                    passStarted[index].signal()
                    _ = releasePass[index].wait(timeout: .now() + 2)
                }
            }

            coalescer.request(force: false, operation: operation)
            XCTAssertEqual(passStarted[0].wait(timeout: .now() + 2), .success)
            coalescer.request(force: false, operation: operation)
            releasePass[0].signal()
            XCTAssertEqual(passStarted[1].wait(timeout: .now() + 2), .success)
            coalescer.request(force: true, operation: operation)
            releasePass[1].signal()
            XCTAssertTrue(coalescer.waitUntilIdle(timeout: .now() + 2))

            lock.lock()
            let result = forceValues
            lock.unlock()
            XCTAssertEqual(result, [false, false, true])
        }

        func testRevisionCacheInvalidationForcesPostClearSourceRead() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            _ = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)

            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let cached = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            XCTAssertTrue(cached.usedCachedRevision)

            try coordinator.invalidateRevisionCache()
            let restartedCoordinator = makeCoordinator(fixture: fixture)
            let reloaded = try restartedCoordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertFalse(reloaded.usedCachedRevision)
            XCTAssertEqual(reloaded.sourceReadPasses, 1)
            XCTAssertGreaterThan(reloaded.sourceBytesRead, 0)
        }

        func testRevisionCacheFailedPersistRollsBackAndOversizedTailStaysBounded() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "goalong-runtime-cache-transaction-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: container) }
            var failWrites = false
            let cache = ActivityAnalysisRevisionCache(
                rootDirectory: container,
                dataWriter: { data, URL in
                    if failWrites {
                        throw NSError(
                            domain: "ActivityAnalysisRuntimeIncrementalTests",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Injected cache write failure"]
                        )
                    }
                    try data.write(to: URL, options: [.atomic])
                }
            )
            let stamp = ActivityAnalysisFileStamp(
                device: 1,
                inode: 2,
                size: 3,
                modificationSeconds: 4,
                modificationNanoseconds: 5
            )
            let revision = ActivityAnalysisSourceRevision(
                event: stamp,
                semantic: nil,
                processingKey: String(repeating: "a", count: 64)
            )
            let tail = ActivityAnalysisSourceTail(
                eventCount: 1,
                continuityBoundaryCount: 0,
                firstSourceSequence: 1,
                lastSourceSequence: 1,
                lastSourceEventHash: String(repeating: "b", count: 64),
                lastEventTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
                lastEventID: "event-1",
                endedWithNewline: true
            )
            let baseline = ActivityAnalysisRevisionCacheEntry(
                revision: revision,
                sourceContentDigest: String(repeating: "c", count: 64),
                sourceTail: tail,
                expectedOutputs: ["analysis-json"],
                outputRevision: String(repeating: "d", count: 64),
                successfulAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try cache.set(baseline, for: "2026-08-23")
            let cacheURL = container.appendingPathComponent("analysis/runtime-input-cache.json")
            let persistedBaseline = try Data(contentsOf: cacheURL)

            failWrites = true
            let replacement = ActivityAnalysisRevisionCacheEntry(
                revision: revision,
                sourceContentDigest: String(repeating: "e", count: 64),
                sourceTail: tail,
                expectedOutputs: ["analysis-json"],
                outputRevision: String(repeating: "f", count: 64),
                successfulAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
            XCTAssertThrowsError(try cache.set(replacement, for: "2026-08-23"))
            XCTAssertEqual(cache.entry(for: "2026-08-23"), baseline)
            XCTAssertEqual(try Data(contentsOf: cacheURL), persistedBaseline)

            failWrites = false
            let oversizedTail = ActivityAnalysisSourceTail(
                eventCount: tail.eventCount,
                continuityBoundaryCount: tail.continuityBoundaryCount,
                firstSourceSequence: tail.firstSourceSequence,
                lastSourceSequence: tail.lastSourceSequence,
                lastSourceEventHash: tail.lastSourceEventHash,
                lastEventTimestamp: tail.lastEventTimestamp,
                lastEventID: String(repeating: "x", count: 128 * 1_024),
                endedWithNewline: tail.endedWithNewline
            )
            let oversized = ActivityAnalysisRevisionCacheEntry(
                revision: revision,
                sourceContentDigest: String(repeating: "1", count: 64),
                sourceTail: oversizedTail,
                expectedOutputs: ["analysis-json"],
                outputRevision: String(repeating: "2", count: 64),
                successfulAt: Date(timeIntervalSince1970: 1_700_000_200)
            )
            try cache.set(oversized, for: "2026-08-24")
            XCTAssertNil(cache.entry(for: "2026-08-24")?.sourceTail)

            let boundedData = try Data(contentsOf: cacheURL)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: boundedData) as? [String: Any]
            )
            let entries = try XCTUnwrap(object["entries"] as? [String: Any])
            XCTAssertLessThanOrEqual(entries.count, 4)
            XCTAssertLessThanOrEqual(boundedData.count, 64 * 1_024)
        }

        func testPriorComputerHistoryRevisionScansThousandsWithExactBoundedTopThirty() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            _ = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let priorDirectory = fixture.root.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: priorDirectory,
                withIntermediateDirectories: true
            )
            let suffix = ".computer-history.json"
            let names = (0..<2_000).map { index in
                "0000-\(String(format: "%06d", index))\(suffix)"
            }
            for (index, name) in names.enumerated() {
                try Data([UInt8(index % 251)]).write(
                    to: priorDirectory.appendingPathComponent(name)
                )
            }
            let coordinator = makeCoordinator(fixture: fixture)

            guard
                case .available(let firstRevision) = coordinator.probe(
                    day: fixture.day,
                    tokenBudget: 1_600
                )
            else { return XCTFail("Expected the selected day source to be available") }
            let firstDiagnostics = coordinator.priorRevisionDiagnosticsForTesting
            XCTAssertEqual(firstDiagnostics.scannedEntryCount, names.count)
            XCTAssertLessThanOrEqual(firstDiagnostics.peakRetainedCandidateCount, 30)
            XCTAssertEqual(firstDiagnostics.selectedNames, Array(names.sorted().suffix(30)))
            XCTAssertFalse(firstDiagnostics.usedCachedDirectoryRevision)

            guard
                case .available(let cachedRevision) = coordinator.probe(
                    day: fixture.day,
                    tokenBudget: 1_600
                )
            else { return XCTFail("Expected the cached selected day source to be available") }
            let cachedDiagnostics = coordinator.priorRevisionDiagnosticsForTesting
            XCTAssertEqual(cachedRevision, firstRevision)
            XCTAssertEqual(cachedDiagnostics.scannedEntryCount, 0)
            XCTAssertLessThanOrEqual(cachedDiagnostics.peakRetainedCandidateCount, 30)
            XCTAssertEqual(cachedDiagnostics.selectedNames, firstDiagnostics.selectedNames)
            XCTAssertTrue(cachedDiagnostics.usedCachedDirectoryRevision)

            let selectedURL = priorDirectory.appendingPathComponent(
                try XCTUnwrap(firstDiagnostics.selectedNames.last)
            )
            let handle = try FileHandle(forWritingTo: selectedURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data([0xAA, 0xBB]))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: selectedURL.path
            )
            guard
                case .available(let changedRevision) = coordinator.probe(
                    day: fixture.day,
                    tokenBudget: 1_600
                )
            else { return XCTFail("Expected the changed prior memory to remain inspectable") }
            let changedDiagnostics = coordinator.priorRevisionDiagnosticsForTesting
            XCTAssertNotEqual(changedRevision.processingKey, cachedRevision.processingKey)
            XCTAssertEqual(changedDiagnostics.scannedEntryCount, names.count)
            XCTAssertLessThanOrEqual(changedDiagnostics.peakRetainedCandidateCount, 30)
            XCTAssertFalse(changedDiagnostics.usedCachedDirectoryRevision)

            let limitedCoordinator = ActivityAnalysisCycleCoordinator(
                rootDirectory: fixture.root,
                computerHistoryStore: ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ),
                engineRevision: "runtime-prior-budget-test-v1",
                priorRevisionLimits: ActivityAnalysisPriorRevisionLimits(
                    maximumDirectoryEntries: 64,
                    maximumScanDuration: 2
                )
            )
            guard
                case .inaccessible(let message) = limitedCoordinator.probe(
                    day: fixture.day,
                    tokenBudget: 1_600
                )
            else { return XCTFail("Expected an explicit prior-directory entry budget error") }
            XCTAssertTrue(message.contains("exceeded 64 entries"))
        }

        func testOneExactDayReadFeedsAllDerivedViewsAndPersistsBoundedCache() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }

            // This deliberately invalid file belongs to another day. The runtime's day
            // loader must not read, decode, or allocate it.
            let decoy = fixture.eventsDirectory.appendingPathComponent("2026-08-22.jsonl")
            try Data(repeating: 0x78, count: 2 * 1_024 * 1_024).write(to: decoy)

            let eventData = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            let result = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            XCTAssertFalse(result.sourceAbsent)
            XCTAssertEqual(result.sourceReadPasses, 1)
            XCTAssertEqual(result.sourceBytesRead, Int64(eventData.count))
            XCTAssertEqual(result.derivedViewsWritten, 3)
            XCTAssertTrue(result.issues.isEmpty)

            for URL in expectedOutputs(fixture: fixture) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: URL.path), URL.path)
            }
            let cacheURL = fixture.root.appendingPathComponent("analysis/runtime-input-cache.json")
            let cacheSize = try XCTUnwrap(
                cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            XCTAssertLessThan(cacheSize, 4 * 1_024)
            print(
                "ActivityAnalysisRuntime fixture source_bytes=\(result.sourceBytesRead) "
                    + "cache_bytes=\(cacheSize) views=\(result.derivedViewsWritten)"
            )
        }

        func testMatchingRevisionSkipsReadsAndTouchWithIdenticalBytesSkipsWrites() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            _ = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)

            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let initialDates = try modificationDates(outputs)

            // A fresh coordinator simulates a normal app restart and must honor the
            // tiny persisted revision cache instead of rescanning the day.
            let restartedCoordinator = makeCoordinator(fixture: fixture)
            let cached = try restartedCoordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            XCTAssertTrue(cached.usedCachedRevision)
            XCTAssertEqual(cached.sourceReadPasses, 0)
            XCTAssertEqual(cached.sourceBytesRead, 0)
            XCTAssertEqual(cached.derivedViewsWritten, 0)

            let source = fixture.eventsDirectory.appendingPathComponent(fixture.dayKey + ".jsonl")
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: source.path
            )
            let deferredTouch = try restartedCoordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            XCTAssertFalse(deferredTouch.usedCachedRevision)
            XCTAssertEqual(deferredTouch.sourceReadPasses, 0)
            XCTAssertEqual(deferredTouch.derivedViewsWritten, 0)

            let verifiedTouch = try restartedCoordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertEqual(verifiedTouch.sourceReadPasses, 1)
            XCTAssertEqual(verifiedTouch.derivedViewsWritten, 0)
            XCTAssertEqual(try modificationDates(outputs), initialDates)
        }

        func testSourceChangeIsVisibleWithoutDuplicateDerivedRows() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let first = fixtureEvent(at: fixture.day, id: "click-1")
            _ = try writeEvents([first], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            let second = fixtureEvent(
                at: fixture.day.addingTimeInterval(5),
                id: "click-2"
            )
            _ = try writeEvents([first, second], fixture: fixture)
            let updated = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            // Atomic replacement changes the inode, so this is not assumed to be an
            // append-only writer. Rebuild immediately and expose the change once.
            XCTAssertEqual(updated.sourceReadPasses, 1)
            XCTAssertGreaterThan(updated.sourceBytesRead, 0)
            XCTAssertGreaterThan(updated.derivedViewsWritten, 0)

            let explicitlyRefreshed = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertEqual(explicitlyRefreshed.sourceReadPasses, 0)
            XCTAssertEqual(explicitlyRefreshed.derivedViewsWritten, 0)

            let analysisURL = fixture.root
                .appendingPathComponent("analysis/\(fixture.dayKey).analysis.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let analysis = try decoder.decode(
                ActivityDayAnalysis.self,
                from: Data(contentsOf: analysisURL)
            )
            XCTAssertEqual(analysis.coverage.sourceEventCount, 2)

            let computerHistory = try XCTUnwrap(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)
            )
            XCTAssertEqual(computerHistory.coverage.sourceEventCount, 2)
            XCTAssertEqual(
                Set(computerHistory.episodes.flatMap(\.provenance.sourceEventIDs)).count,
                2
            )
        }

        func testAgentBookkeepingStaysRawButDoesNotInflateDerivedMemory() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let userEvent = fixtureEvent(at: fixture.day, id: "physical-click")
            var events = [userEvent]
            events.reserveCapacity(2_001)
            for index in 0..<2_000 {
                events.append(
                    HistoryEvent(
                        id: "agent-index-\(index)",
                        sessionID: "runtime-test",
                        timestamp: fixture.day.addingTimeInterval(Double(index % 60)),
                        kind: .agentArtifactCaptured,
                        app: AppSnapshot(
                            name: "Codex",
                            bundleIdentifier: "ai.goalong.agent.codex",
                            processIdentifier: 42
                        ),
                        message: "Agent source indexed from original storage",
                        metadata: ["agent_storage_mode": "direct_read_index_only"]
                    )
                )
            }
            let sourceData = try writeEvents(events, fixture: fixture)

            let result = try makeCoordinator(fixture: fixture).process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertEqual(result.sourceBytesRead, Int64(sourceData.count))

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let analysis = try decoder.decode(
                ActivityDayAnalysis.self,
                from: Data(
                    contentsOf: fixture.root
                        .appendingPathComponent("analysis/\(fixture.dayKey).analysis.json")
                )
            )
            let memory = try decoder.decode(
                ActivityMemory.self,
                from: Data(
                    contentsOf: fixture.root
                        .appendingPathComponent("memories/\(fixture.dayKey).memory.json")
                )
            )
            let computerHistory = try XCTUnwrap(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)
            )

            XCTAssertEqual(analysis.coverage.sourceEventCount, 1)
            XCTAssertEqual(memory.coverage.sourceEventCount, 1)
            XCTAssertEqual(computerHistory.coverage.sourceEventCount, 2_001)
            XCTAssertEqual(computerHistory.coverage.actionEventCount, 1)
            XCTAssertFalse(memory.applications.contains("Codex"))
        }

        func testIntegrityChainedMaintenanceAppendReadsOnlySuffixWithExactFullFallback() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let genesis = String(repeating: "0", count: 64)
            let first = eventWithIntegrity(
                fixtureEvent(at: fixture.day, id: "click-1"),
                sequence: 1,
                previousHash: genesis
            )
            _ = try writeEvents([first], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let unchangedDerivedURLs = Array(expectedOutputs(fixture: fixture).prefix(4))
            let unchangedDerived = try unchangedDerivedURLs.map { try Data(contentsOf: $0) }
            let before = try XCTUnwrap(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)
            )

            let maintenance = eventWithIntegrity(
                HistoryEvent(
                    id: "agent-index-1",
                    sessionID: "runtime-test",
                    timestamp: fixture.day.addingTimeInterval(60),
                    kind: .agentArtifactCaptured,
                    app: AppSnapshot(
                        name: "Codex",
                        bundleIdentifier: "ai.goalong.agent.codex",
                        processIdentifier: 42
                    ),
                    message: "Agent source indexed from original storage",
                    metadata: ["agent_storage_mode": "direct_read_index_only"]
                ),
                sequence: 2,
                previousHash: try XCTUnwrap(first.integrity?.eventHash)
            )
            let appendedData = try appendEvent(maintenance, fixture: fixture)
            let sourceURL = fixture.eventsDirectory
                .appendingPathComponent(fixture.dayKey + ".jsonl")
            let sourceAfterMaintenanceAppend = try Data(contentsOf: sourceURL)
            let incremental = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            XCTAssertEqual(incremental.sourceReadPasses, 1)
            XCTAssertEqual(incremental.sourceBytesRead, Int64(appendedData.count))
            XCTAssertEqual(incremental.derivedViewsWritten, 1)
            XCTAssertEqual(
                try unchangedDerivedURLs.map { try Data(contentsOf: $0) },
                unchangedDerived
            )
            let incrementallyUpdated = try XCTUnwrap(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)
            )
            XCTAssertEqual(incrementallyUpdated.coverage.sourceEventCount, 2)
            XCTAssertEqual(incrementallyUpdated.coverage.actionEventCount, 1)
            XCTAssertEqual(incrementallyUpdated.coverage.lastSourceSequence, 2)
            XCTAssertEqual(
                incrementallyUpdated.coverage.lastSourceEventHash,
                maintenance.integrity?.eventHash
            )
            XCTAssertEqual(incrementallyUpdated.episodes, before.episodes)
            XCTAssertEqual(incrementallyUpdated.resources, before.resources)
            XCTAssertEqual(incrementallyUpdated.workflowPatterns, before.workflowPatterns)
            XCTAssertEqual(incrementallyUpdated.suggestions, before.suggestions)
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceAfterMaintenanceAppend)

            let cached = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertTrue(cached.usedCachedRevision)
            XCTAssertEqual(cached.sourceBytesRead, 0)

            let incrementalOutputs = try expectedOutputs(fixture: fixture).map {
                try Data(contentsOf: $0)
            }
            try coordinator.invalidateRevisionCache()
            let fullyRebuilt = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertGreaterThan(fullyRebuilt.sourceBytesRead, incremental.sourceBytesRead)
            XCTAssertEqual(fullyRebuilt.derivedViewsWritten, 0)
            XCTAssertEqual(
                try expectedOutputs(fixture: fixture).map { try Data(contentsOf: $0) },
                incrementalOutputs
            )
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceAfterMaintenanceAppend)

            let secondClick = eventWithIntegrity(
                fixtureEvent(at: fixture.day.addingTimeInterval(61), id: "click-2"),
                sequence: 3,
                previousHash: try XCTUnwrap(maintenance.integrity?.eventHash)
            )
            _ = try appendEvent(secondClick, fixture: fixture)
            let sourceAfterActionAppend = try Data(contentsOf: sourceURL)
            let evidenceFallback = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let sourceSize = try XCTUnwrap(
                sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            XCTAssertEqual(evidenceFallback.sourceBytesRead, Int64(sourceSize))
            XCTAssertEqual(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)?.coverage.actionEventCount,
                2
            )
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceAfterActionAppend)
        }

        func testMaintenanceAppendFallsBackToFullReadWhenCachedTailHashWasInvalid() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let genesis = String(repeating: "0", count: 64)
            let validFirst = eventWithIntegrity(
                fixtureEvent(at: fixture.day, id: "click-1"),
                sequence: 1,
                previousHash: genesis
            )
            let validIntegrity = try XCTUnwrap(validFirst.integrity)
            let tamperedFirst = validFirst.replacingIntegrity(
                EventIntegrity(
                    sequence: validIntegrity.sequence,
                    previousEventHash: validIntegrity.previousEventHash,
                    eventRoot: validIntegrity.eventRoot,
                    eventHash: String(repeating: "f", count: 64),
                    fieldCommitments: []
                )
            )
            _ = try writeEvents([tamperedFirst], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            let maintenance = eventWithIntegrity(
                HistoryEvent(
                    id: "agent-index-1",
                    sessionID: "runtime-test",
                    timestamp: fixture.day.addingTimeInterval(60),
                    kind: .agentArtifactCaptured
                ),
                sequence: 2,
                previousHash: try XCTUnwrap(tamperedFirst.integrity?.eventHash)
            )
            _ = try appendEvent(maintenance, fixture: fixture)
            let sourceURL = fixture.eventsDirectory
                .appendingPathComponent(fixture.dayKey + ".jsonl")
            let sourceBytes = try Data(contentsOf: sourceURL)

            let refreshed = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            XCTAssertEqual(refreshed.sourceReadPasses, 1)
            XCTAssertEqual(refreshed.sourceBytesRead, Int64(sourceBytes.count))
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
            XCTAssertEqual(
                ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ).loadStored(for: fixture.day)?.coverage.actionEventCount,
                1
            )
        }

        func testBackgroundAppendsAreDebouncedButExplicitRefreshIsImmediate() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let first = fixtureEvent(at: fixture.day, id: "click-1")
            _ = try writeEvents([first], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            try appendEvent(
                HistoryEvent(
                    id: "heartbeat-1",
                    sessionID: "runtime-test",
                    timestamp: fixture.day.addingTimeInterval(60),
                    kind: .heartbeat,
                    app: first.app,
                    window: first.window,
                    metadata: ["idle_seconds": "20"]
                ),
                fixture: fixture
            )
            let deferred = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            XCTAssertEqual(deferred.sourceReadPasses, 0)
            XCTAssertEqual(deferred.derivedViewsWritten, 0)

            try appendEvent(
                fixtureEvent(at: fixture.day.addingTimeInterval(61), id: "click-2"),
                fixture: fixture
            )
            let refreshed = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: false,
                includeActivityMemory: true
            )
            XCTAssertEqual(refreshed.sourceReadPasses, 0)
            XCTAssertEqual(refreshed.sourceBytesRead, 0)
            XCTAssertEqual(refreshed.derivedViewsWritten, 0)

            let forced = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertEqual(forced.sourceReadPasses, 1)
            XCTAssertGreaterThan(forced.derivedViewsWritten, 0)

            let analysisURL = fixture.root
                .appendingPathComponent("analysis/\(fixture.dayKey).analysis.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let analysis = try decoder.decode(
                ActivityDayAnalysis.self,
                from: Data(contentsOf: analysisURL)
            )
            XCTAssertEqual(analysis.coverage.sourceEventCount, 3)
        }

        func testIncompletePriorComputerHistoryFailsBeforeChangingOutputsOrCache() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let first = fixtureEvent(at: fixture.day, id: "click-1")
            _ = try writeEvents([first], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )

            let outputs = expectedOutputs(fixture: fixture)
            let cacheURL = fixture.root.appendingPathComponent(
                "analysis/runtime-input-cache.json"
            )
            let lastKnownGoodOutputs = try outputs.map { try Data(contentsOf: $0) }
            let lastKnownGoodCache = try Data(contentsOf: cacheURL)

            let retainedDirectory = fixture.root.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try Data("{not-json".utf8).write(
                to: retainedDirectory.appendingPathComponent(
                    "2026-08-22.computer-history.json"
                ),
                options: [.atomic]
            )
            _ = try writeEvents(
                [
                    first,
                    fixtureEvent(
                        at: fixture.day.addingTimeInterval(60),
                        id: "click-2"
                    ),
                ],
                fixture: fixture
            )

            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: true
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError else {
                    return XCTFail("Expected an inaccessible retained-memory error, got \(error)")
                }
                guard case .sourceInaccessible = cycleError else {
                    return XCTFail("Expected an inaccessible retained-memory error, got \(error)")
                }
            }
            XCTAssertEqual(
                try outputs.map { try Data(contentsOf: $0) },
                lastKnownGoodOutputs
            )
            XCTAssertEqual(try Data(contentsOf: cacheURL), lastKnownGoodCache)
        }

        func testSymlinkedSourceIsInaccessibleAndKeepsLastKnownGoodViews() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let eventData = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let before = try outputs.map { try Data(contentsOf: $0) }

            let source = fixture.eventsDirectory.appendingPathComponent(fixture.dayKey + ".jsonl")
            let target = fixture.container.appendingPathComponent("outside-source.jsonl")
            try eventData.write(to: target)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: false,
                    includeActivityMemory: true
                )
            )
            XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, before)
        }

        func testOversizedSelectedDayRowsFailBeforeDecodeAndKeepLastKnownGoodViews() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let event = fixtureEvent(at: fixture.day)
            _ = try writeEvents([event], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let lastKnownGood = try outputs.map { try Data(contentsOf: $0) }
            let source = fixture.eventsDirectory.appendingPathComponent(
                fixture.dayKey + ".jsonl"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encodedEvent = try encoder.encode(event)
            let maximumBytes = 2 * 1_024 * 1_024

            for terminated in [true, false] {
                var oversized = Data(repeating: 0x20, count: maximumBytes)
                oversized.append(encodedEvent)
                if terminated { oversized.append(0x0A) }
                try oversized.write(to: source, options: [.atomic])

                XCTAssertThrowsError(
                    try coordinator.process(
                        day: fixture.day,
                        tokenBudget: 1_600,
                        forceVerification: true,
                        includeActivityMemory: true
                    )
                ) { error in
                    guard let cycleError = error as? ActivityAnalysisCycleError else {
                        return XCTFail("Expected ActivityAnalysisCycleError, got \(error)")
                    }
                    guard case .oversizedJSONLine(let path, let reportedMaximum) = cycleError else {
                        return XCTFail("Expected explicit oversized JSONL error, got \(error)")
                    }
                    XCTAssertEqual(path, source.path)
                    XCTAssertEqual(reportedMaximum, maximumBytes)
                    XCTAssertTrue(error.localizedDescription.contains(String(maximumBytes)))
                }
                XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, lastKnownGood)
            }
        }

        func testMalformedRowsKeepLastKnownGoodViewsAndRevisionCache() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let event = fixtureEvent(at: fixture.day)
            let validEventData = try writeEvents([event], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let cacheURL = fixture.root.appendingPathComponent(
                "analysis/runtime-input-cache.json"
            )
            let lastKnownGoodOutputs = try outputs.map { try Data(contentsOf: $0) }
            let lastKnownGoodCache = try Data(contentsOf: cacheURL)
            let privateSentinel = "PRIVATE-MALFORMED-ROW-MUST-NOT-SURFACE"
            let eventURL = fixture.eventsDirectory.appendingPathComponent(
                fixture.dayKey + ".jsonl"
            )
            var malformedEventData = validEventData
            malformedEventData.append(
                Data(("{\"value\":\"" + privateSentinel + "\"}\n").utf8)
            )
            try malformedEventData.write(to: eventURL, options: [.atomic])

            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: true
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError,
                    case .sourceInaccessible = cycleError
                else {
                    return XCTFail("Expected a fail-closed source error, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("1 unreadable row"))
                XCTAssertFalse(error.localizedDescription.contains(privateSentinel))
            }
            XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, lastKnownGoodOutputs)
            XCTAssertEqual(try Data(contentsOf: cacheURL), lastKnownGoodCache)

            _ = try writeEvents([event], fixture: fixture)
            let semanticURL = fixture.semanticDirectory.appendingPathComponent(
                fixture.dayKey + ".semantic.jsonl"
            )
            try Data(("{\"value\":\"" + privateSentinel + "\"}\n").utf8).write(
                to: semanticURL,
                options: [.atomic]
            )

            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: true
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError,
                    case .sourceInaccessible = cycleError
                else {
                    return XCTFail("Expected a fail-closed source error, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("1 unreadable row"))
                XCTAssertFalse(error.localizedDescription.contains(privateSentinel))
            }
            XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, lastKnownGoodOutputs)
            XCTAssertEqual(try Data(contentsOf: cacheURL), lastKnownGoodCache)
        }

        func testConflictingSemanticDuplicatesKeepLastKnownGoodViewsAndRevisionCache() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            _ = try writeEvents([fixtureEvent(at: fixture.day)], fixture: fixture)
            let coordinator = makeCoordinator(fixture: fixture)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let cacheURL = fixture.root.appendingPathComponent(
                "analysis/runtime-input-cache.json"
            )
            let lastKnownGoodOutputs = try outputs.map { try Data(contentsOf: $0) }
            let lastKnownGoodCache = try Data(contentsOf: cacheURL)

            let privateID = "PRIVATE-CONFLICTING-SEMANTIC-ID"
            let first = semanticPayload(
                id: privateID,
                text: "first public fixture",
                at: fixture.day
            )
            let conflicting = semanticPayload(
                id: privateID,
                text: "PRIVATE-CONFLICTING-TEXT-MUST-NOT-SURFACE",
                at: fixture.day
            )
            _ = try writeEvents(
                [
                    fixtureEvent(
                        at: fixture.day,
                        semanticContext: first.reference
                    )
                ],
                fixture: fixture
            )
            _ = try writeSemanticPayloads([first, conflicting], fixture: fixture)

            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: true
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError,
                    case .sourceInaccessible = cycleError
                else {
                    return XCTFail("Expected a conflicting semantic source error, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("conflicting duplicate"))
                XCTAssertFalse(error.localizedDescription.contains(privateID))
                XCTAssertFalse(error.localizedDescription.contains(conflicting.text))
            }
            XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, lastKnownGoodOutputs)
            XCTAssertEqual(try Data(contentsOf: cacheURL), lastKnownGoodCache)
        }

        func testSemanticLoaderKeepsOnlyUsableReferencesAndAllowsMissingPayloads() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let retained = semanticPayload(
                id: "semantic-retained",
                text: "retained fixture context",
                at: fixture.day
            )
            let suppressed = semanticPayload(
                id: "semantic-suppressed",
                text: "PRIVATE-SUPPRESSED-CONTEXT",
                at: fixture.day
            )
            let unreferenced = semanticPayload(
                id: "semantic-unreferenced",
                text: "PRIVATE-UNREFERENCED-CONTEXT",
                at: fixture.day
            )
            _ = try writeEvents(
                [
                    fixtureEvent(
                        at: fixture.day,
                        id: "usable",
                        semanticContext: retained.reference
                    ),
                    fixtureEvent(
                        at: fixture.day.addingTimeInterval(1),
                        id: "suppressed",
                        semanticContext: suppressed.reference,
                        suppressionReason: .secureInput
                    ),
                ],
                fixture: fixture
            )
            _ = try writeSemanticPayloads(
                [retained, retained, suppressed, unreferenced],
                fixture: fixture
            )

            // Two retained events plus one usable semantic payload exactly fill this
            // row budget. The identical duplicate, suppressed reference and
            // unreferenced payload must not consume retained working-set capacity.
            let loader = ActivityAnalysisDayLoader(
                rootDirectory: fixture.root,
                limits: ActivityAnalysisDayLoadLimits(
                    maximumRetainedRows: 3,
                    maximumEstimatedRetainedBytes: 48 * 1_024 * 1_024
                )
            )
            let loaded = try loader.load(day: fixture.day)
            XCTAssertTrue(loaded.issues.isEmpty)
            XCTAssertEqual(Set(loaded.semanticSnapshots.keys), Set([retained.id]))
            XCTAssertEqual(loaded.semanticSnapshots[retained.id], retained)

            let missing = semanticPayload(
                id: "semantic-deleted-independently",
                text: "deleted fixture context",
                at: fixture.day
            )
            _ = try writeEvents(
                [
                    fixtureEvent(
                        at: fixture.day,
                        semanticContext: missing.reference
                    )
                ],
                fixture: fixture
            )
            let semanticURL = fixture.semanticDirectory.appendingPathComponent(
                fixture.dayKey + ".semantic.jsonl"
            )
            try FileManager.default.removeItem(at: semanticURL)

            let withoutPayload = try loader.load(day: fixture.day)
            XCTAssertTrue(withoutPayload.issues.isEmpty)
            XCTAssertTrue(withoutPayload.semanticSnapshots.isEmpty)
            let result = try makeCoordinator(fixture: fixture).process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertGreaterThan(result.derivedViewsWritten, 0)
        }

        func testSharedRetainedEvidenceBudgetIsExactAndKeepsLastKnownGoodState() throws {
            XCTAssertEqual(ActivityAnalysisDayLoadLimits.production.maximumRetainedRows, 32_768)
            XCTAssertEqual(
                ActivityAnalysisDayLoadLimits.production.maximumEstimatedRetainedBytes,
                64 * 1_024 * 1_024
            )

            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let first = fixtureEvent(at: fixture.day, id: "click-1")
            _ = try writeEvents([first], fixture: fixture)
            let exactEventBytes = try ActivityAnalysisDayLoader.estimatedRetainedBytes(
                for: first.compactedForDerivedAnalysis
            )

            let exactByteLoader = ActivityAnalysisDayLoader(
                rootDirectory: fixture.root,
                limits: ActivityAnalysisDayLoadLimits(
                    maximumRetainedRows: 1,
                    maximumEstimatedRetainedBytes: exactEventBytes
                )
            )
            XCTAssertEqual(try exactByteLoader.load(day: fixture.day).events.count, 1)

            let oneByteShortLoader = ActivityAnalysisDayLoader(
                rootDirectory: fixture.root,
                limits: ActivityAnalysisDayLoadLimits(
                    maximumRetainedRows: 1,
                    maximumEstimatedRetainedBytes: exactEventBytes - 1
                )
            )
            XCTAssertThrowsError(try oneByteShortLoader.load(day: fixture.day)) { error in
                XCTAssertTrue(error.localizedDescription.contains("retained-evidence budget"))
            }

            let limits = ActivityAnalysisDayLoadLimits(
                maximumRetainedRows: 1,
                maximumEstimatedRetainedBytes: 48 * 1_024 * 1_024
            )
            let coordinator = makeCoordinator(fixture: fixture, dayLoadLimits: limits)
            _ = try coordinator.process(
                day: fixture.day,
                tokenBudget: 1_600,
                forceVerification: true,
                includeActivityMemory: true
            )
            let outputs = expectedOutputs(fixture: fixture)
            let cacheURL = fixture.root.appendingPathComponent(
                "analysis/runtime-input-cache.json"
            )
            let lastKnownGoodOutputs = try outputs.map { try Data(contentsOf: $0) }
            let lastKnownGoodCache = try Data(contentsOf: cacheURL)

            _ = try writeEvents(
                [
                    first,
                    fixtureEvent(
                        at: fixture.day.addingTimeInterval(1),
                        id: "click-2"
                    ),
                ],
                fixture: fixture
            )
            XCTAssertThrowsError(
                try coordinator.process(
                    day: fixture.day,
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: true
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError,
                    case .sourceInaccessible = cycleError
                else {
                    return XCTFail("Expected a fail-closed budget error, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("retained-evidence budget"))
            }
            XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, lastKnownGoodOutputs)
            XCTAssertEqual(try Data(contentsOf: cacheURL), lastKnownGoodCache)
        }

        private func makeCoordinator(
            fixture: Fixture,
            dayLoadLimits: ActivityAnalysisDayLoadLimits = .production
        ) -> ActivityAnalysisCycleCoordinator {
            ActivityAnalysisCycleCoordinator(
                rootDirectory: fixture.root,
                computerHistoryStore: ComputerHistoryStore(
                    rootDirectory: fixture.root,
                    codexMemoryDirectory: fixture.codexMirror
                ),
                engineRevision: "runtime-incremental-test-v1",
                dayLoadLimits: dayLoadLimits
            )
        }

        private func makeFixture() throws -> Fixture {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-runtime-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let events = root.appendingPathComponent("events", isDirectory: true)
            let semantic = root.appendingPathComponent("semantic", isDirectory: true)
            let codexMirror = container.appendingPathComponent("codex-memory", isDirectory: true)
            for directory in [events, semantic] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))
            )
            return Fixture(
                container: container,
                root: root,
                eventsDirectory: events,
                semanticDirectory: semantic,
                codexMirror: codexMirror,
                day: day,
                dayKey: dayKey(day)
            )
        }

        @discardableResult
        private func writeEvents(_ events: [HistoryEvent], fixture: Fixture) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for event in events {
                data.append(try encoder.encode(event))
                data.append(0x0A)
            }
            try data.write(
                to: fixture.eventsDirectory.appendingPathComponent(fixture.dayKey + ".jsonl"),
                options: [.atomic]
            )
            return data
        }

        @discardableResult
        private func appendEvent(_ event: HistoryEvent, fixture: Fixture) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(0x0A)
            let URL = fixture.eventsDirectory.appendingPathComponent(fixture.dayKey + ".jsonl")
            let handle = try FileHandle(forWritingTo: URL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return data
        }

        @discardableResult
        private func writeSemanticPayloads(
            _ payloads: [SemanticContextPayload],
            fixture: Fixture
        ) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for payload in payloads {
                data.append(try encoder.encode(payload))
                data.append(0x0A)
            }
            try data.write(
                to: fixture.semanticDirectory.appendingPathComponent(
                    fixture.dayKey + ".semantic.jsonl"
                ),
                options: [.atomic]
            )
            return data
        }

        private func semanticPayload(
            id: String,
            text: String,
            at date: Date
        ) -> SemanticContextPayload {
            SemanticContextPayload(
                id: id,
                capturedAt: date,
                application: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(
                    title: "Fixture Document",
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

        private func eventWithIntegrity(
            _ event: HistoryEvent,
            sequence: UInt64,
            previousHash: String
        ) -> HistoryEvent {
            let root = SHA256Digest.hashHex("runtime-test-root-\(sequence)")
            return event.replacingIntegrity(
                EventIntegrity(
                    sequence: sequence,
                    previousEventHash: previousHash,
                    eventRoot: root,
                    eventHash: ChainHash.event(
                        sequence: sequence,
                        previous: previousHash,
                        eventRoot: root
                    ),
                    fieldCommitments: []
                )
            )
        }

        private func fixtureEvent(
            at date: Date,
            id: String = "click-1",
            semanticContext: SemanticContextReference? = nil,
            suppressionReason: SuppressionReason? = nil
        ) -> HistoryEvent {
            HistoryEvent(
                id: id,
                sessionID: "runtime-test",
                timestamp: date,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Fixture Document", role: "AXWindow", subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 40, y: 80, clickCount: 1),
                semanticContext: semanticContext,
                classification: LocalClassification(
                    category: "document_productivity",
                    isWork: true,
                    confidence: 0.9,
                    classifierVersion: "fixture"
                ),
                suppressionReason: suppressionReason
            )
        }

        private func expectedOutputs(fixture: Fixture) -> [URL] {
            [
                fixture.root.appendingPathComponent("analysis/\(fixture.dayKey).analysis.json"),
                fixture.root.appendingPathComponent("analysis/\(fixture.dayKey).agent.md"),
                fixture.root.appendingPathComponent("memories/\(fixture.dayKey).memory.json"),
                fixture.root.appendingPathComponent("memories/\(fixture.dayKey).memory.md"),
                fixture.root.appendingPathComponent(
                    "computer-history/\(fixture.dayKey).computer-history.json"
                ),
                fixture.codexMirror.appendingPathComponent(
                    "\(fixture.dayKey)-goalong-computer-history.md"
                ),
            ]
        }

        private func modificationDates(_ URLs: [URL]) throws -> [Date] {
            try URLs.map { URL in
                try XCTUnwrap(
                    URL.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                    URL.path
                )
            }
        }

        private func dayKey(_ day: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: day)
        }

        private struct Fixture {
            let container: URL
            let root: URL
            let eventsDirectory: URL
            let semanticDirectory: URL
            let codexMirror: URL
            let day: Date
            let dayKey: String
        }
    }
#endif
