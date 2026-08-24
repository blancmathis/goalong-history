import Foundation
import SQLite3
import XCTest

@testable import AgentActivity

final class AgentSourceTraversalBudgetTests: XCTestCase {
    private struct PersistedFileSnapshot: Equatable {
        var inode: UInt64
        var byteCount: Int64
        var modifiedAt: Date?
        var data: Data
    }

    func testBodyBytesAreSharedAcrossProvidersAndFoldersAndDeferredSourceResumesWithoutDuplication() throws {
        let fixture = try makeTemporaryDirectory("body-global")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        var folders: [AgentWatchedFolder] = []
        for index in 0..<2 {
            let sourceRoot = fixture.appendingPathComponent("source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try Data(repeating: UInt8(65 + index), count: 80).write(
                to: sourceRoot.appendingPathComponent("session-\(index).txt")
            )
            folders.append(
                AgentWatchedFolder(
                    id: "body-folder-\(index)",
                    displayName: "Body \(index)",
                    path: sourceRoot.path,
                    provider: index == 0 ? .custom : .cursor,
                    captureMode: .everyFile
                )
            )
        }
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: .init(
                maximumBytes: 100,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadCancellationCheck: { false }
        )
        let configuration = AgentActivityConfiguration(watchedFolders: folders)

        let first = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_471_000)
        )
        let firstMetrics = scanner.cycleMetricsForTesting()
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(firstMetrics.sourceBodyReadBytes, 80)
        XCTAssertEqual(firstMetrics.sourceBodyReadStopReason, .byteLimit)
        XCTAssertEqual(firstMetrics.indexWriteCount, 1)

        let second = scanner.scan(
            configuration: configuration,
            at: Date(timeIntervalSince1970: 1_787_471_010)
        )
        let secondMetrics = scanner.cycleMetricsForTesting()
        XCTAssertTrue(second.failures.isEmpty, second.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 2)
        XCTAssertEqual(Set(store.entries().map(\.id)).count, 2)
        XCTAssertEqual(secondMetrics.sourceBodyReadBytes, 80)
        XCTAssertNil(secondMetrics.sourceBodyReadStopReason)
        XCTAssertEqual(secondMetrics.indexWriteCount, 1)
    }

    func testCandidateThatDoesNotFitRemainingBodyBudgetDoesNotStarveSmallerLaterCandidate() throws {
        let fixture = try makeTemporaryDirectory("body-nonblocking")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let baseDate = Date(timeIntervalSince1970: 1_787_471_000)
        let sources = [
            ("large.txt", 80, baseDate.addingTimeInterval(3)),
            ("deferred.txt", 30, baseDate.addingTimeInterval(2)),
            ("small.txt", 20, baseDate.addingTimeInterval(1)),
        ]
        for (name, size, modifiedAt) in sources {
            let url = sourceRoot.appendingPathComponent(name)
            try Data(repeating: 65, count: size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        let store = try AgentActivityStore(
            rootDirectory: fixture.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: .init(
                maximumBytes: 100,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadCancellationCheck: { false }
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder(root: sourceRoot, provider: .custom)]
        )

        let first = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: baseDate.addingTimeInterval(10)
        )
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 100)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadStopReason, .byteLimit)
        XCTAssertEqual(
            Set(store.entries().map { URL(fileURLWithPath: $0.reference.path).lastPathComponent }),
            Set(["large.txt", "small.txt"])
        )

        let second = scanner.scan(
            configuration: configuration,
            at: baseDate.addingTimeInterval(20)
        )
        XCTAssertTrue(second.failures.isEmpty, second.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 3)
        XCTAssertEqual(Set(store.entries().map(\.id)).count, 3)
    }

    func testTraversalVisitsAreGlobalAcrossProvidersAndFolders() throws {
        let fixture = try makeTemporaryDirectory("traversal-global")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        let providers: [AgentProvider] = [.custom, .cursor]
        var folders: [AgentWatchedFolder] = []
        for (providerOffset, provider) in providers.enumerated() {
            let sourceRoot = fixture.appendingPathComponent("source-\(providerOffset)", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            for index in 0..<40 {
                try Data("fixture\n".utf8).write(
                    to: sourceRoot.appendingPathComponent(String(format: "session-%04d.txt", index))
                )
            }
            folders.append(
                AgentWatchedFolder(
                    id: "global-\(provider.rawValue)",
                    displayName: provider.displayName,
                    path: sourceRoot.path,
                    provider: provider,
                    captureMode: .everyFile
                )
            )
        }
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .init(
                maximumNodeOrRowVisits: 50,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceTraversalCancellationCheck: { false }
        )

        let result = scanner.scan(
            configuration: AgentActivityConfiguration(watchedFolders: folders),
            forceFullDiscovery: true
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 50)
        XCTAssertEqual(Set(store.entries().map(\.provider)), Set(providers))
        XCTAssertTrue(scanner.cycleMetricsForTesting().stoppedByBudget)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 1)
    }

    func testBodyDeadlineDefersLargeFileThenCompletesOnNextCycle() throws {
        let fixture = try makeTemporaryDirectory("body-deadline")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 384 * 1_024).write(
            to: sourceRoot.appendingPathComponent("large.txt")
        )
        var tick: UInt64 = 0
        var advanceClock = true
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: .init(
                maximumBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 50
            ),
            sourceBodyReadUptimeNanoseconds: {
                defer {
                    if advanceClock { tick += 20 }
                }
                return tick
            },
            sourceBodyReadCancellationCheck: { false }
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder(root: sourceRoot, provider: .custom)]
        )
        let first = scanner.scan(configuration: configuration, forceFullDiscovery: true)
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadStopReason, .deadlineExceeded)
        XCTAssertLessThanOrEqual(
            scanner.cycleMetricsForTesting().sourceBodyReadBytes,
            Int64(1 * 1_024 * 1_024)
        )

        advanceClock = false
        let second = scanner.scan(configuration: configuration)
        XCTAssertTrue(second.failures.isEmpty, second.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertNil(scanner.cycleMetricsForTesting().sourceBodyReadStopReason)
    }

    func testCancelCurrentScanInterruptsBodyReadAndNextCycleResumes() throws {
        let fixture = try makeTemporaryDirectory("body-cancel")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 256 * 1_024).write(
            to: sourceRoot.appendingPathComponent("cancel.txt")
        )
        let enteredClock = expectation(description: "body budget entered")
        let scanFinished = expectation(description: "scan finished")
        let releaseClock = DispatchSemaphore(value: 0)
        let clockLock = NSLock()
        var shouldBlock = true
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: .init(
                maximumBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadUptimeNanoseconds: {
                clockLock.lock()
                let blocks = shouldBlock
                shouldBlock = false
                clockLock.unlock()
                if blocks {
                    enteredClock.fulfill()
                    _ = releaseClock.wait(timeout: .now() + 5)
                }
                return DispatchTime.now().uptimeNanoseconds
            }
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder(root: sourceRoot, provider: .custom)]
        )
        let resultLock = NSLock()
        var firstResult: AgentScanResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = scanner.scan(configuration: configuration, forceFullDiscovery: true)
            resultLock.lock()
            firstResult = result
            resultLock.unlock()
            scanFinished.fulfill()
        }
        wait(for: [enteredClock], timeout: 5)
        scanner.cancelCurrentScan()
        releaseClock.signal()
        wait(for: [scanFinished], timeout: 5)
        resultLock.lock()
        let cancelledResult = firstResult
        resultLock.unlock()
        XCTAssertTrue(cancelledResult?.failures.isEmpty == true)
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadStopReason, .cancelled)

        let resumed = scanner.scan(configuration: configuration)
        XCTAssertTrue(resumed.failures.isEmpty, resumed.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 1)
    }

    func testCancellationRequestedBeforeDispatchIsNotClearedAtScanEntry() throws {
        let fixture = try makeTemporaryDirectory("pre-dispatch-cancel")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: sourceRoot.appendingPathComponent("session.txt"))
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder(root: sourceRoot, provider: .custom)]
        )

        scanner.cancelCurrentScan()
        let cancelled = scanner.scan(configuration: configuration, forceFullDiscovery: true)
        XCTAssertTrue(cancelled.failures.isEmpty, cancelled.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertTrue(scanner.cycleMetricsForTesting().stoppedByBudget)

        let resumed = scanner.scan(configuration: configuration, forceFullDiscovery: true)
        XCTAssertTrue(resumed.failures.isEmpty, resumed.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 1)
    }

    func testFileDiscoveryStopsAtGlobalVisitBudgetWithExplicitIncompleteInventory() throws {
        let root = try makeTemporaryDirectory("nodes")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<512 {
            try Data("{}\n".utf8).write(
                to: root.appendingPathComponent(String(format: "session-%04d.jsonl", index))
            )
        }

        let budget = AgentSourceTraversalBudget(
            limits: .init(
                maximumNodeOrRowVisits: 64,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            isCancelled: { false }
        )
        let result = try AgentDirectSourceReader.makeScanSession(
            folder: folder(root: root, provider: .custom),
            traversalBudget: budget
        ).discover(maximumCandidates: 1_000)

        XCTAssertEqual(result.incompleteReason, .visitLimit)
        XCTAssertFalse(result.isCompleteInventory)
        XCTAssertEqual(result.traversalUsage.visitedNodeOrRowCount, 64)
        XCTAssertLessThanOrEqual(result.candidates.count, 64)
        XCTAssertLessThanOrEqual(result.traversalUsage.metadataByteCount, 1 * 1_024 * 1_024)
    }

    func testFileDiscoveryStopsBeforeMetadataBudgetCanBeExceeded() throws {
        let root = try makeTemporaryDirectory("metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<32 {
            let longName = String(repeating: "x", count: 120) + "-\(index).jsonl"
            try Data("{}\n".utf8).write(to: root.appendingPathComponent(longName))
        }
        let maximumMetadataBytes: Int64 = 512
        let result = try AgentDirectSourceReader.makeScanSession(
            folder: folder(root: root, provider: .custom),
            traversalBudget: AgentSourceTraversalBudget(
                limits: .init(
                    maximumNodeOrRowVisits: 1_000,
                    maximumMetadataBytes: maximumMetadataBytes,
                    maximumDurationNanoseconds: 5_000_000_000
                ),
                isCancelled: { false }
            )
        ).discover(maximumCandidates: 1_000)

        XCTAssertEqual(result.incompleteReason, .metadataByteLimit)
        XCTAssertLessThanOrEqual(result.traversalUsage.metadataByteCount, maximumMetadataBytes)
        XCTAssertLessThan(result.candidates.count, 32)
    }

    func testMonotonicDeadlineExpiresWithoutSleeping() throws {
        let root = try makeTemporaryDirectory("deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<64 {
            try Data("{}\n".utf8).write(
                to: root.appendingPathComponent(String(format: "session-%04d.jsonl", index))
            )
        }
        var tick: UInt64 = 0
        let result = try AgentDirectSourceReader.makeScanSession(
            folder: folder(root: root, provider: .custom),
            traversalBudget: AgentSourceTraversalBudget(
                limits: .init(
                    maximumNodeOrRowVisits: 1_000,
                    maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                    maximumDurationNanoseconds: 25
                ),
                uptimeNanoseconds: {
                    defer { tick += 10 }
                    return tick
                },
                isCancelled: { false }
            )
        ).discover(maximumCandidates: 1_000)

        XCTAssertEqual(result.incompleteReason, .deadlineExceeded)
        XCTAssertGreaterThanOrEqual(result.traversalUsage.elapsedNanoseconds, 25)
        XCTAssertLessThan(result.candidates.count, 64)
    }

    func testOpenCodeCatalogRowsShareTheSameBound() throws {
        let root = try makeTemporaryDirectory("sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("opencode.db")
        try createOpenCodeCatalog(at: database, sessionCount: 500)
        let budget = AgentSourceTraversalBudget(
            limits: .init(
                maximumNodeOrRowVisits: 37,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            isCancelled: { false }
        )
        let result = try AgentDirectSourceReader.makeScanSession(
            folder: folder(root: root, provider: .openCode),
            traversalBudget: budget
        ).discover(maximumCandidates: 1_000)

        XCTAssertEqual(result.incompleteReason, .visitLimit)
        XCTAssertEqual(result.traversalUsage.visitedNodeOrRowCount, 37)
        XCTAssertEqual(result.candidates.count, 37)
        XCTAssertTrue(result.candidates.allSatisfy { $0.reference.kind == .sqliteConversation })
    }

    func testRetainedCursorRejectsReplacedRootAndRestartsFromCurrentSource() throws {
        let fixture = try makeTemporaryDirectory("cursor-root-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let oldSourceRoot = fixture.appendingPathComponent("source-old", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data("old-\(index)\n".utf8).write(
                to: sourceRoot.appendingPathComponent(String(format: "session-%04d.txt", index))
            )
        }
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [watchedFolder],
            maximumIndexEntries: 64
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .init(
                maximumNodeOrRowVisits: 8,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceTraversalCancellationCheck: { false }
        )
        let observedAt = Date(timeIntervalSince1970: 1_787_475_000)

        let partial = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: observedAt
        )
        XCTAssertTrue(partial.failures.isEmpty, partial.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 8)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 1)

        try FileManager.default.moveItem(at: sourceRoot, to: oldSourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let currentSource = sourceRoot.appendingPathComponent("replacement.txt")
        try Data("current\n".utf8).write(to: currentSource)

        let invalidated = scanner.scan(
            configuration: configuration,
            at: observedAt.addingTimeInterval(1)
        )
        XCTAssertTrue(
            invalidated.failures.contains { $0.contains("changed while it was being read") },
            invalidated.failures.joined(separator: "\n")
        )
        XCTAssertEqual(store.indexEntryCount(), 8)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)

        let restarted = scanner.scan(
            configuration: configuration,
            at: observedAt.addingTimeInterval(2)
        )
        XCTAssertTrue(restarted.failures.isEmpty, restarted.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 9)
        XCTAssertEqual(
            store.entries().filter { $0.reference.path == currentSource.path }.map(\.availability),
            [.available]
        )
        XCTAssertEqual(store.entries().filter { $0.availability == .missing }.count, 8)
        XCTAssertEqual(Set(store.entries().map(\.id)).count, 9)
    }

    func testRetainedOpenCodeCursorRejectsChangedDatabaseBeforeCombiningPages() throws {
        let fixture = try makeTemporaryDirectory("cursor-opencode-change")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let database = sourceRoot.appendingPathComponent("opencode.db")
        try createOpenCodeCatalog(at: database, sessionCount: 40)
        let watchedFolder = folder(root: sourceRoot, provider: .openCode)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [watchedFolder],
            maximumIndexEntries: 64
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .init(
                maximumNodeOrRowVisits: 8,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceTraversalCancellationCheck: { false }
        )
        let observedAt = Date(timeIntervalSince1970: 1_787_475_100)

        let partial = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: observedAt
        )
        XCTAssertTrue(partial.failures.isEmpty, partial.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 8)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 1)

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        try execute(
            writer,
            "UPDATE session SET time_updated = time_updated + 1000000 WHERE id = 'session-39'"
        )
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)

        let invalidated = scanner.scan(
            configuration: configuration,
            at: observedAt.addingTimeInterval(1)
        )
        XCTAssertTrue(
            invalidated.failures.contains { $0.contains("changed while it was being read") },
            invalidated.failures.joined(separator: "\n")
        )
        XCTAssertEqual(store.indexEntryCount(), 8)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)

        var recoveryObservations: [String] = []
        for cycle in 0..<10 where store.indexEntryCount() < 40 {
            let result = scanner.scan(
                configuration: configuration,
                at: observedAt.addingTimeInterval(Double(cycle + 2))
            )
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            let metrics = scanner.cycleMetricsForTesting()
            let pending = scanner.pendingDiscoveryUsageForTesting()
            recoveryObservations.append(
                "cycle=\(cycle) index=\(store.indexEntryCount()) "
                    + "visits=\(metrics.sourceTraversalVisitCount) "
                    + "discovered=\(metrics.discoveredCandidateCount) "
                    + "pending=\(pending.activeInventoryCount)/\(pending.entryCount)"
            )
        }
        XCTAssertEqual(store.indexEntryCount(), 40, recoveryObservations.joined(separator: "\n"))
        XCTAssertEqual(
            Set(store.entries().map(\.id)).count,
            40,
            recoveryObservations.joined(separator: "\n")
        )
    }

    func testOpenCodeMultiSessionScanNeverHashesWholeDatabase() throws {
        let fixture = try makeTemporaryDirectory("sqlite-batch-hash")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let database = sourceRoot.appendingPathComponent("opencode.db")
        try createOpenCodeCatalog(at: database, sessionCount: 3)
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let watchedFolder = folder(root: sourceRoot, provider: .openCode)
        let configuration = AgentActivityConfiguration(watchedFolders: [watchedFolder])
        AgentSQLiteReadMetrics.reset(path: database.path)

        let scanner = AgentActivityScanner(store: store)
        let first = scanner.scan(
            configuration: configuration,
            at: Date(timeIntervalSince1970: 1_787_471_500)
        )
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 3)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.openCount(path: database.path), 1)
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: database.path), 0)
        #endif

        let warm = scanner.scan(
            configuration: configuration,
            at: Date(timeIntervalSince1970: 1_787_471_510)
        )
        XCTAssertTrue(warm.failures.isEmpty, warm.failures.joined(separator: "\n"))
        XCTAssertEqual(warm.scannedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.openCount(path: database.path), 2)
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: database.path), 0)
        #endif

        let signalDate = Date(timeIntervalSince1970: 1_787_471_511)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .openCode,
            eventName: "boundary",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: signalDate
        )
        let signaled = scanner.scan(
            configuration: configuration,
            at: Date(timeIntervalSince1970: 1_787_471_571)
        )
        XCTAssertTrue(signaled.failures.isEmpty, signaled.failures.joined(separator: "\n"))
        XCTAssertEqual(signaled.scannedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        XCTAssertEqual(store.lastHandledSignal(provider: .openCode), signalDate)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.openCount(path: database.path), 3)
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: database.path), 0)
        #endif

        let forced = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_471_580)
        )
        XCTAssertTrue(forced.failures.isEmpty, forced.failures.joined(separator: "\n"))
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.openCount(path: database.path), 4)
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: database.path), 0)
        #endif
    }

    func testOpenCodeCatalogResolutionIsColdOnceWarmZeroAndInvalidatesOnDatabaseChange() throws {
        let fixture = try makeTemporaryDirectory("sqlite-session-cache")
        defer {
            AgentSQLiteReadMetrics.reset()
            try? FileManager.default.removeItem(at: fixture)
        }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let database = sourceRoot.appendingPathComponent("opencode.db")
        try createOpenCodeCatalog(at: database, sessionCount: 500)
        let watchedFolder = folder(root: sourceRoot, provider: .openCode)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [watchedFolder],
            maximumIndexEntries: 128
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let initialDate = Date(timeIntervalSince1970: 1_787_471_500)
        let initial = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 128)

        AgentSQLiteReadMetrics.reset(path: database.path)
        let cold = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(10)
        )
        XCTAssertTrue(cold.failures.isEmpty, cold.failures.joined(separator: "\n"))
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.catalogScanCount(path: database.path), 1)
        #endif

        let warm = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(20)
        )
        XCTAssertTrue(warm.failures.isEmpty, warm.failures.joined(separator: "\n"))
        XCTAssertEqual(warm.scannedSourceCount, 0)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.catalogScanCount(path: database.path), 1)
        #endif

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        try execute(
            writer,
            "UPDATE session SET time_updated = time_updated + 1000000 WHERE id = 'session-499'"
        )
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)

        let changed = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(30)
        )
        XCTAssertTrue(changed.failures.isEmpty, changed.failures.joined(separator: "\n"))
        XCTAssertEqual(changed.changedSourceCount, 1)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.catalogScanCount(path: database.path), 2)
        #endif
        XCTAssertLessThanOrEqual(AgentSQLiteReadMetrics.sessionCacheEntryCount, 512)
    }

    func testOpenCodeSnapshotCacheCoversAllActiveFoldersWithoutWarmThrash() throws {
        let fixture = try makeTemporaryDirectory("sqlite-cache-bound")
        defer {
            AgentSQLiteReadMetrics.reset()
            try? FileManager.default.removeItem(at: fixture)
        }
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        var folders: [AgentWatchedFolder] = []
        var databasePaths: [String] = []
        AgentSQLiteReadMetrics.reset()
        for index in 0...AgentActivityConfiguration.maximumWatchedFolders {
            let sourceRoot = fixture.appendingPathComponent("source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try createOpenCodeCatalog(
                at: sourceRoot.appendingPathComponent("opencode.db"),
                sessionCount: 1
            )
            databasePaths.append(sourceRoot.appendingPathComponent("opencode.db").path)
            folders.append(
                AgentWatchedFolder(
                    id: "cache-folder-\(index)",
                    displayName: "OpenCode \(index)",
                    path: sourceRoot.path,
                    provider: .openCode
                )
            )
        }
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let configuration = AgentActivityConfiguration(watchedFolders: folders)

        var discoveryFailures: [String] = []
        for _ in 0..<8 where store.indexEntryCount() < AgentActivityConfiguration.maximumWatchedFolders {
            let result = scanner.scan(configuration: configuration)
            discoveryFailures.append(contentsOf: result.failures)
            XCTAssertLessThanOrEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 32)
        }
        XCTAssertTrue(discoveryFailures.isEmpty, discoveryFailures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 256)
        XCTAssertEqual(AgentSQLiteReadMetrics.snapshotCacheEntryCount, 0)
        XCTAssertLessThanOrEqual(AgentSQLiteReadMetrics.sessionCacheEntryCount, 512)
        #if DEBUG
            XCTAssertEqual(
                databasePaths.reduce(0) { $0 + AgentSQLiteReadMetrics.sourceHashCount(path: $1) },
                0
            )
        #endif

        let warm = scanner.scan(configuration: configuration)
        XCTAssertTrue(warm.failures.isEmpty, warm.failures.joined(separator: "\n"))
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        #if DEBUG
            XCTAssertEqual(
                databasePaths.reduce(0) { $0 + AgentSQLiteReadMetrics.sourceHashCount(path: $1) },
                0
            )
        #endif
    }

    func testOpenCodeActiveJournalIsRejectedBeforeAnyDatabaseHash() throws {
        let fixture = try makeTemporaryDirectory("sqlite-journal-no-hash")
        defer {
            AgentSQLiteReadMetrics.reset()
            try? FileManager.default.removeItem(at: fixture)
        }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let database = sourceRoot.appendingPathComponent("opencode.db")
        try createOpenCodeCatalog(at: database, sessionCount: 1)
        try Data("active".utf8).write(to: URL(fileURLWithPath: database.path + "-journal"))
        AgentSQLiteReadMetrics.reset(path: database.path)
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)

        let result = scanner.scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder(root: sourceRoot, provider: .openCode)]
            ),
            forceFullDiscovery: true
        )

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: database.path), 0)
        #endif
    }

    func testOversizedBufferedJSONIsNotMarkedAvailableWithoutAnalysis() throws {
        let fixture = try makeTemporaryDirectory("oversized-json")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("large.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 9 * 1_024 * 1_024)
        try handle.close()
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)

        let result = scanner.scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder(root: sourceRoot, provider: .custom)]
            ),
            forceFullDiscovery: true
        )

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(store.entries().first?.availability, .inaccessible)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
    }

    func testTemporarilyInaccessibleRootDoesNotMisclassifyEveryConversation() throws {
        let fixture = try makeTemporaryDirectory("root-inaccessible")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let movedRoot = fixture.appendingPathComponent("source-moved", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: sourceRoot.appendingPathComponent("session.txt"))
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(watchedFolders: [watchedFolder])
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let initialDate = Date(timeIntervalSince1970: 1_787_472_000)
        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(store.rootStatus(folderID: watchedFolder.id)?.availability, .available)

        try FileManager.default.moveItem(at: sourceRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: sourceRoot, withDestinationURL: movedRoot)
        let transitionDate = initialDate.addingTimeInterval(60)
        let inaccessible = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: transitionDate
        )

        XCTAssertFalse(inaccessible.failures.isEmpty)
        XCTAssertEqual(inaccessible.statusChangeCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(
            store.rootStatus(folderID: watchedFolder.id),
            AgentFolderRootStatus(availability: .inaccessible, changedAt: transitionDate)
        )
        XCTAssertEqual(store.latestRecords().first?.availability, .inaccessible)
        let inaccessibleOverview = store.overview(for: Date())
        XCTAssertEqual(inaccessibleOverview.captures.first?.availability, .inaccessible)
        XCTAssertEqual(inaccessibleOverview.sessionCount, 0)

        let reloadedStore = try AgentActivityStore(rootDirectory: storeRoot)
        XCTAssertEqual(
            reloadedStore.rootStatus(folderID: watchedFolder.id),
            AgentFolderRootStatus(availability: .inaccessible, changedAt: transitionDate)
        )
        let persistedBeforeRetry = try persistedFileSnapshot(store.indexFile)
        let repeated = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: transitionDate.addingTimeInterval(120)
        )
        XCTAssertFalse(repeated.failures.isEmpty)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try persistedFileSnapshot(store.indexFile), persistedBeforeRetry)

        try FileManager.default.removeItem(at: sourceRoot)
        try FileManager.default.moveItem(at: movedRoot, to: sourceRoot)
        let recovered = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: transitionDate.addingTimeInterval(180)
        )
        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(store.rootStatus(folderID: watchedFolder.id)?.availability, .available)

        try FileManager.default.removeItem(at: sourceRoot)
        let missingDate = transitionDate.addingTimeInterval(240)
        let missing = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: missingDate
        )
        XCTAssertFalse(missing.failures.isEmpty)
        XCTAssertEqual(missing.statusChangeCount, 1)
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(
            store.rootStatus(folderID: watchedFolder.id),
            AgentFolderRootStatus(availability: .missing, changedAt: missingDate)
        )
        XCTAssertEqual(store.latestRecords().first?.availability, .missing)
        XCTAssertEqual(store.overview(for: Date()).captures.first?.availability, .missing)
    }

    func testSavingConfigurationPrunesOnlyDisabledAndRemovedFolderMetadata() throws {
        let fixture = try makeTemporaryDirectory("configuration-pruning")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = try AgentActivityStore(
            rootDirectory: fixture.appendingPathComponent("store", isDirectory: true)
        )
        let observedAt = Date(timeIntervalSince1970: 1_787_472_000)
        let folders = [
            folder(root: fixture.appendingPathComponent("codex", isDirectory: true), provider: .codex),
            folder(root: fixture.appendingPathComponent("claude", isDirectory: true), provider: .claudeCode),
            folder(root: fixture.appendingPathComponent("opencode", isDirectory: true), provider: .openCode),
        ]
        _ = try store.saveConfiguration(AgentActivityConfiguration(watchedFolders: folders))

        let records = folders.enumerated().map { index, folder in
            let reference = AgentSourceReference(
                kind: .file,
                path: folder.url.appendingPathComponent("session-\(index).jsonl").path
            )
            let entry = AgentSourceIndexEntry(
                id: "ignored-\(index)",
                stableConversationID: "session-\(index)",
                watchedFolderID: folder.id,
                watchedFolderName: folder.displayName,
                provider: folder.provider,
                reference: reference,
                relativePath: "session-\(index).jsonl",
                sourceCreatedAt: observedAt,
                sourceModifiedAt: observedAt,
                firstIndexedAt: observedAt,
                lastObservedAt: observedAt,
                byteCount: Int64(index + 1),
                sha256: String(repeating: String(index + 1), count: 64)
            )
            return AgentCaptureRecord(
                index: entry,
                summary: AgentDocumentSummary(
                    format: .jsonLines,
                    sessionID: "session-\(index)",
                    messageCount: 1
                ),
                isAnalyzed: true
            )
        }
        _ = try store.upsertBatch(records, maximumEntries: 100)
        for folder in folders {
            _ = try store.commitScanCycle(
                folderMutations: [
                    AgentFolderScanMutation(
                        folderID: folder.id,
                        preparedCaptures: [],
                        availabilityObservations: [],
                        maximumEntries: 100,
                        discoveryAttempt: AgentFolderDiscoveryAttempt(
                            folderID: folder.id,
                            observedAt: observedAt,
                            succeeded: true
                        ),
                        rootObservation: AgentFolderRootObservation(
                            folderID: folder.id,
                            availability: .available,
                            observedAt: observedAt
                        )
                    )
                ],
                handledSignals: [folder.provider: observedAt]
            )
        }

        var disabled = folders[1]
        disabled.isEnabled = false
        _ = try store.saveConfiguration(
            AgentActivityConfiguration(watchedFolders: [folders[0], disabled])
        )

        XCTAssertEqual(store.entries().map(\.watchedFolderID), [folders[0].id])
        XCTAssertNotNil(store.lastFullDiscovery(folderID: folders[0].id))
        XCTAssertNotNil(store.rootStatus(folderID: folders[0].id))
        XCTAssertEqual(store.lastHandledSignal(provider: .codex), observedAt)
        for removedFolder in folders.dropFirst() {
            XCTAssertTrue(store.entries(folderID: removedFolder.id).isEmpty)
            XCTAssertNil(store.lastFullDiscovery(folderID: removedFolder.id))
            XCTAssertNil(store.rootStatus(folderID: removedFolder.id))
            let removedRecord = try XCTUnwrap(
                records.first { $0.index.watchedFolderID == removedFolder.id }
            )
            XCTAssertNil(store.cachedRecord(id: removedRecord.id))
        }
        XCTAssertNil(store.lastHandledSignal(provider: .claudeCode))
        XCTAssertNil(store.lastHandledSignal(provider: .openCode))

        let reloaded = try AgentActivityStore(rootDirectory: store.rootDirectory)
        XCTAssertEqual(reloaded.entries().map(\.watchedFolderID), [folders[0].id])
        XCTAssertTrue(reloaded.indexIsValid(maximumEntries: 100))
    }

    func testCancelledDiscoveryDoesNotMarkMissingOrAcknowledgeSignalAndRetries() throws {
        let fixture = try makeTemporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("session.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"fixture\"}\n".utf8).write(to: source)
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(watchedFolders: [watchedFolder])
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let initial = AgentActivityScanner(store: store).scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_000)
        )
        XCTAssertEqual(initial.changedSourceCount, 1)
        let entryID = try XCTUnwrap(store.entries().first?.id)
        try FileManager.default.removeItem(at: source)
        let signalDate = Date(timeIntervalSince1970: 1_787_472_100)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "event",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: signalDate
        )

        var cancellationRequested = true
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .init(
                maximumNodeOrRowVisits: 100,
                maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceTraversalCancellationCheck: { cancellationRequested }
        )
        let cancelled = scanner.scan(
            configuration: configuration,
            at: signalDate.addingTimeInterval(1)
        )
        XCTAssertTrue(cancelled.failures.isEmpty, cancelled.failures.joined(separator: "\n"))
        XCTAssertTrue(scanner.cycleMetricsForTesting().stoppedByBudget)
        XCTAssertEqual(store.entry(id: entryID)?.availability, .available)
        XCTAssertNil(store.lastHandledSignal(provider: .custom))

        cancellationRequested = false
        let resumed = scanner.scan(
            configuration: configuration,
            at: signalDate.addingTimeInterval(62)
        )
        XCTAssertTrue(resumed.failures.isEmpty, resumed.failures.joined(separator: "\n"))
        XCTAssertEqual(store.entry(id: entryID)?.availability, .missing)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), signalDate)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 1)
    }

    func testProviderSignalDiscoversWithoutRehashingUnchangedAndTargetsIdentityChange() throws {
        let fixture = try makeTemporaryDirectory("signal-rehash")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("session.txt")
        try Data("fixture\n".utf8).write(to: source)
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(watchedFolders: [watchedFolder])
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let initialDate = Date(timeIntervalSince1970: 1_787_472_500)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: source.path)
        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        let signalDate = initialDate.addingTimeInterval(1)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "boundary",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: signalDate
        )

        let unchangedSignal = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(61)
        )

        XCTAssertTrue(
            unchangedSignal.failures.isEmpty,
            unchangedSignal.failures.joined(separator: "\n")
        )
        XCTAssertEqual(unchangedSignal.scannedSourceCount, 0)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), signalDate)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)

        try Data("changed\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: source.path)
        let changedSignalDate = initialDate.addingTimeInterval(70)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "boundary",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: changedSignalDate
        )
        let changedSignal = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(122)
        )
        XCTAssertTrue(changedSignal.failures.isEmpty, changedSignal.failures.joined(separator: "\n"))
        XCTAssertEqual(changedSignal.scannedSourceCount, 1)
        XCTAssertEqual(changedSignal.changedSourceCount, 1)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), changedSignalDate)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 8)
    }

    func testIncompletePrefixExpandsFromPersistedFailureStateAfterScannerRestart() throws {
        let fixture = try makeTemporaryDirectory("restart-progression")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceCount = 100
        for index in 0..<sourceCount {
            try Data("{\"content\":\"\(index)\"}\n".utf8).write(
                to: sourceRoot.appendingPathComponent(String(format: "session-%04d.jsonl", index))
            )
        }
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [watchedFolder],
            maximumIndexEntries: sourceCount
        )
        let baseLimits = AgentSourceTraversalLimits(
            maximumNodeOrRowVisits: 16,
            maximumMetadataBytes: Int64(1 * 1_024 * 1_024),
            maximumDurationNanoseconds: 5_000_000_000
        )
        var entryCounts: [Int] = []
        for cycle in 0..<4 {
            let relaunchedStore = try AgentActivityStore(rootDirectory: storeRoot)
            let relaunchedScanner = AgentActivityScanner(
                store: relaunchedStore,
                sourceTraversalLimits: baseLimits,
                sourceTraversalCancellationCheck: { false }
            )
            let result = relaunchedScanner.scan(
                configuration: configuration,
                forceFullDiscovery: true,
                at: Date(timeIntervalSince1970: 1_787_473_000 + Double(cycle))
            )
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertLessThanOrEqual(relaunchedScanner.cycleMetricsForTesting().sourceBodyReadCount, 256)
            XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().indexWriteCount, 1)
            entryCounts.append(relaunchedStore.indexEntryCount())
        }

        let finalStore = try AgentActivityStore(rootDirectory: storeRoot)
        XCTAssertEqual(entryCounts, [16, 32, 64, 100])
        XCTAssertEqual(finalStore.indexEntryCount(), sourceCount)
        XCTAssertTrue(
            finalStore.entries().contains {
                $0.reference.path.hasSuffix("session-0099.jsonl")
            },
            "A source beyond the first bounded prefix must become reachable after relaunches."
        )
        XCTAssertEqual(finalStore.fullDiscoveryFailureCount(folderID: watchedFolder.id), 0)
        XCTAssertLessThan(finalStore.indexBytes(), 256 * 1_024)
    }

    func testCandidateProjectionCapAcknowledgesCompletedTraversalWithoutRetryLoop() throws {
        let fixture = try makeTemporaryDirectory("candidate-cap")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        for index in 0..<120 {
            try Data("{\"content\":\"\(index)\"}\n".utf8).write(
                to: sourceRoot.appendingPathComponent(String(format: "session-%04d.jsonl", index))
            )
        }
        let watchedFolder = folder(root: sourceRoot, provider: .custom)
        let configuration = AgentActivityConfiguration(
            watchedFolders: [watchedFolder],
            maximumIndexEntries: 100
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let signalDate = Date(timeIntervalSince1970: 1_787_474_000)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "event",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: signalDate
        )
        let scanner = AgentActivityScanner(store: store)
        let first = scanner.scan(
            configuration: configuration,
            at: signalDate.addingTimeInterval(1)
        )
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(first.fullDiscoveryCount, 1)
        XCTAssertEqual(first.capacityLimitedFolderCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 100)
        XCTAssertEqual(store.fullDiscoveryFailureCount(folderID: watchedFolder.id), 0)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), signalDate)

        let warm = scanner.scan(
            configuration: configuration,
            at: signalDate.addingTimeInterval(10)
        )
        XCTAssertEqual(warm.fullDiscoveryCount, 0)
        XCTAssertEqual(warm.capacityLimitedFolderCount, 0)
        XCTAssertEqual(warm.scannedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)

        let indexedPaths = Set(store.entries().map(\.reference.path))
        let previouslyProjectedOut = try XCTUnwrap(
            (0..<120).lazy.map {
                sourceRoot.appendingPathComponent(String(format: "session-%04d.jsonl", $0))
            }.first { !indexedPaths.contains($0.path) }
        )
        let priorEntryIDs = Set(store.entries().map(\.id))
        let newestIndexedDate = try XCTUnwrap(
            store.entries().compactMap(\.sourceModifiedAt).max()
        )
        let promotedDate = newestIndexedDate.addingTimeInterval(120)
        try Data("{\"content\":\"now-recent\"}\n".utf8).write(
            to: previouslyProjectedOut,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.modificationDate: promotedDate],
            ofItemAtPath: previouslyProjectedOut.path
        )
        let secondSignalDate = Date(
            timeIntervalSince1970: floor(promotedDate.timeIntervalSince1970) + 1
        )
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "event",
            discardedPayloadBytes: 0,
            processIdentifier: 2,
            signaledAt: secondSignalDate
        )
        let refreshedProjection = scanner.scan(
            configuration: configuration,
            at: secondSignalDate.addingTimeInterval(61)
        )
        XCTAssertTrue(
            refreshedProjection.failures.isEmpty,
            refreshedProjection.failures.joined(separator: "\n")
        )
        XCTAssertEqual(store.indexEntryCount(), 100)
        XCTAssertTrue(store.entries().contains { $0.reference.path == previouslyProjectedOut.path })
        XCTAssertNotEqual(Set(store.entries().map(\.id)), priorEntryIDs)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), secondSignalDate)
    }

    func testFiveHundredTwelveRootsAdvanceInBoundedThirtyTwoRootCycles() throws {
        let fixture = try makeTemporaryDirectory("root-open-fairness")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
        var watchedFolders: [AgentWatchedFolder] = []
        watchedFolders.reserveCapacity(AgentActivityConfiguration.maximumWatchedFolders)
        for index in 0..<AgentActivityConfiguration.maximumWatchedFolders {
            let sourceRoot = fixture.appendingPathComponent("source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            watchedFolders.append(
                AgentWatchedFolder(
                    id: "fair-root-\(index)",
                    displayName: "Custom",
                    path: sourceRoot.path,
                    provider: .custom,
                    captureMode: .everyFile
                )
            )
        }
        let configuration = AgentActivityConfiguration(
            watchedFolders: watchedFolders,
            maximumIndexEntries: 100
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_787_474_500)

        var completedFolderIDs: Set<String> = []
        for cycle in 0..<16 {
            let result = scanner.scan(
                configuration: configuration,
                forceFullDiscovery: true,
                analyzeContent: false,
                at: startedAt.addingTimeInterval(Double(cycle))
            )
            let metrics = scanner.cycleMetricsForTesting()
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertEqual(metrics.rootOpenAttemptCount, 32)
            XCTAssertEqual(result.fullDiscoveryCount, 32)
            XCTAssertTrue(metrics.stoppedByBudget)
            for folder in watchedFolders where store.lastFullDiscovery(folderID: folder.id) != nil {
                completedFolderIDs.insert(folder.id)
            }
        }

        XCTAssertEqual(completedFolderIDs.count, watchedFolders.count)
        XCTAssertEqual(store.indexEntryCount(), 0)
    }

    private func folder(root: URL, provider: AgentProvider) -> AgentWatchedFolder {
        AgentWatchedFolder(
            id: "budget-\(provider.rawValue)",
            displayName: "Budget fixture",
            path: root.path,
            provider: provider,
            captureMode: .everyFile
        )
    }

    private func createOpenCodeCatalog(at url: URL, sessionCount: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "AgentSourceTraversalBudgetTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(
            database,
            "CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER)"
        )
        try execute(
            database,
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)"
        )
        try execute(
            database,
            "CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)"
        )
        try execute(database, "BEGIN IMMEDIATE")
        do {
            for index in 0..<sessionCount {
                try execute(
                    database,
                    "INSERT INTO session VALUES ('session-\(index)', 'title-\(index)', '/tmp/project-\(index)', \(index), \(index))"
                )
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func execute(_ database: OpaquePointer?, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "AgentSourceTraversalBudgetTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func persistedFileSnapshot(_ url: URL) throws -> PersistedFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return PersistedFileSnapshot(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modifiedAt: attributes[.modificationDate] as? Date,
            data: try Data(contentsOf: url)
        )
    }

    private func makeTemporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-source-budget-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
