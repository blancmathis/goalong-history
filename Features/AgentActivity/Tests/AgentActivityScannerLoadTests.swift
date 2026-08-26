import Foundation
import XCTest

@testable import AgentActivity

final class AgentActivityScannerLoadTests: XCTestCase {
    func testMultiFolderCycleSharesOneBodyBudgetAndOneAtomicIndexWrite() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-multifolder-\(UUID().uuidString)",
            isDirectory: true
        )
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        var folders: [AgentWatchedFolder] = []
        for folderIndex in 0..<2 {
            let sourceRoot = fixtureRoot.appendingPathComponent("source-\(folderIndex)", isDirectory: true)
            try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            for index in 0..<200 {
                let file = sourceRoot.appendingPathComponent(String(format: "session-%03d.jsonl", index))
                try Data("{\"content\":\"folder-\(folderIndex)-\(index)\"}".utf8).write(to: file)
            }
            folders.append(
                AgentWatchedFolder(
                    id: "multi-\(folderIndex)",
                    displayName: "Custom",
                    path: sourceRoot.path,
                    provider: .custom
                )
            )
        }

        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let result = scanner.scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: folders,
                maximumIndexEntries: 1_000
            ),
            forceFullDiscovery: true
        )
        let metrics = scanner.cycleMetricsForTesting()
        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(metrics.sourceBodyReadCount, 256)
        XCTAssertEqual(metrics.indexWriteCount, 1)
        XCTAssertEqual(store.indexEntryCount(), 256)
        XCTAssertTrue(metrics.stoppedByBudget)
    }

    func testDeferredInventoriesStayGloballyBoundedAndDrainOneFolderAtATime() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-pending-global-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        var folders: [AgentWatchedFolder] = []
        let sourcesPerFolder = 300
        for folderIndex in 0..<3 {
            let sourceRoot = fixtureRoot.appendingPathComponent(
                "source-\(folderIndex)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            for sourceIndex in 0..<sourcesPerFolder {
                let source = sourceRoot.appendingPathComponent(
                    String(format: "session-%03d.txt", sourceIndex)
                )
                try Data("\(folderIndex)-\(sourceIndex)".utf8).write(to: source)
            }
            folders.append(
                AgentWatchedFolder(
                    id: "pending-global-\(folderIndex)",
                    displayName: "Pending \(folderIndex)",
                    path: sourceRoot.path,
                    provider: .custom
                )
            )
        }

        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(store: store)
        let configuration = AgentActivityConfiguration(
            watchedFolders: folders,
            maximumIndexEntries: folders.count * sourcesPerFolder
        )
        let startedAt = Date(timeIntervalSince1970: 1_787_472_000)
        var cycle = 0
        repeat {
            let result = scanner.scan(
                configuration: configuration,
                forceFullDiscovery: cycle == 0,
                at: startedAt.addingTimeInterval(TimeInterval(cycle * 10))
            )
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertLessThanOrEqual(scanner.cycleMetricsForTesting().indexWriteCount, 1)
            let pending = scanner.pendingDiscoveryUsageForTesting()
            XCTAssertLessThanOrEqual(pending.activeInventoryCount, 1)
            XCTAssertLessThanOrEqual(pending.entryCount, 512)
            XCTAssertLessThanOrEqual(pending.estimatedBytes, 4 * 1_024 * 1_024)
            cycle += 1
        } while store.indexEntryCount() < folders.count * sourcesPerFolder && cycle < 10

        XCTAssertEqual(store.indexEntryCount(), folders.count * sourcesPerFolder)
        XCTAssertLessThan(cycle, 10)
        for folder in folders {
            XCTAssertEqual(store.entries(folderID: folder.id).count, sourcesPerFolder)
        }
    }

    func testSourceAboveGlobalBodyLimitFailsIndividuallyWithoutStarvingLaterSource() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-oversized-fairness-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let firstSourceRoot = fixtureRoot.appendingPathComponent("source-a", isDirectory: true)
        let secondSourceRoot = fixtureRoot.appendingPathComponent("source-b", isDirectory: true)
        try fileManager.createDirectory(at: firstSourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondSourceRoot, withIntermediateDirectories: true)
        let oversized = firstSourceRoot.appendingPathComponent("oversized.txt")
        try Data(repeating: 65, count: 128 * 1_024).write(to: oversized)
        let firstSmall = firstSourceRoot.appendingPathComponent("small-a.txt")
        let secondSmall = secondSourceRoot.appendingPathComponent("small-b.txt")
        let firstSmallBytes = Data("later source in the same folder remains eligible".utf8)
        let secondSmallBytes = Data("a later folder also remains eligible".utf8)
        try firstSmallBytes.write(to: firstSmall)
        try secondSmallBytes.write(to: secondSmall)
        let observedAt = Date(timeIntervalSince1970: 1_787_472_000)
        try fileManager.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(2)],
            ofItemAtPath: oversized.path
        )
        try fileManager.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(1)],
            ofItemAtPath: firstSmall.path
        )

        let firstFolder = AgentWatchedFolder(
            id: "oversized-fairness-a",
            displayName: "Oversized fairness A",
            path: firstSourceRoot.path,
            provider: .custom
        )
        let secondFolder = AgentWatchedFolder(
            id: "oversized-fairness-b",
            displayName: "Oversized fairness B",
            path: secondSourceRoot.path,
            provider: .custom
        )
        let requestedConfiguration = AgentActivityConfiguration(
            watchedFolders: [firstFolder, secondFolder],
            maximumFileBytes: 1 * 1_024 * 1_024 * 1_024
        )
        XCTAssertEqual(
            requestedConfiguration.validated().maximumFileBytes,
            512 * 1_024 * 1_024
        )
        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: AgentSourceBodyReadLimits(
                maximumBytes: 64 * 1_024,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadCancellationCheck: { false }
        )
        let result = scanner.scan(
            configuration: requestedConfiguration,
            forceFullDiscovery: true,
            at: observedAt.addingTimeInterval(10)
        )

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(
            scanner.cycleMetricsForTesting().sourceBodyReadBytes,
            Int64(firstSmallBytes.count + secondSmallBytes.count)
        )
        XCTAssertNil(scanner.cycleMetricsForTesting().sourceBodyReadStopReason)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)
        XCTAssertEqual(store.indexEntryCount(), 3)
        XCTAssertEqual(
            store.entries().first { $0.reference.path == oversized.path }?.availability,
            .inaccessible
        )
        XCTAssertEqual(
            store.entries().first { $0.reference.path == firstSmall.path }?.availability,
            .available
        )
        XCTAssertEqual(
            store.entries().first { $0.reference.path == secondSmall.path }?.availability,
            .available
        )
    }

    func testPermanentBodyDeadlineRotatesThenReleasesDiscoveryForAnotherFolder() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-deadline-fairness-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let firstSourceRoot = fixtureRoot.appendingPathComponent("source-a", isDirectory: true)
        let secondSourceRoot = fixtureRoot.appendingPathComponent("source-b", isDirectory: true)
        try fileManager.createDirectory(at: firstSourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondSourceRoot, withIntermediateDirectories: true)
        let permanentlySlow = firstSourceRoot.appendingPathComponent("slow.txt")
        let laterInSameFolder = firstSourceRoot.appendingPathComponent("small-a.txt")
        let laterFolderSource = secondSourceRoot.appendingPathComponent("small-b.txt")
        try Data(repeating: 65, count: 384 * 1_024).write(to: permanentlySlow)
        try Data("same-folder progress".utf8).write(to: laterInSameFolder)
        try Data("later-folder progress".utf8).write(to: laterFolderSource)
        let startedAt = Date(timeIntervalSince1970: 1_787_472_000)
        try fileManager.setAttributes(
            [.modificationDate: startedAt.addingTimeInterval(2)],
            ofItemAtPath: permanentlySlow.path
        )
        try fileManager.setAttributes(
            [.modificationDate: startedAt.addingTimeInterval(1)],
            ofItemAtPath: laterInSameFolder.path
        )
        let firstFolder = AgentWatchedFolder(
            displayName: "Deadline fairness A",
            path: firstSourceRoot.path,
            provider: .custom
        )
        let secondFolder = AgentWatchedFolder(
            displayName: "Deadline fairness B",
            path: secondSourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [firstFolder, secondFolder]
        )
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        var tick: UInt64 = 0
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: AgentSourceBodyReadLimits(
                maximumBytes: 1 * 1_024 * 1_024,
                maximumDurationNanoseconds: 100
            ),
            sourceBodyReadUptimeNanoseconds: {
                defer { tick += 20 }
                return tick
            },
            sourceBodyReadCancellationCheck: { false }
        )

        let first = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: startedAt
        )
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadStopReason, .deadlineExceeded)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 1)
        XCTAssertEqual(store.fullDiscoveryFailureCount(folderID: firstFolder.id), 1)
        XCTAssertEqual(store.lastFullDiscoveryAttempt(folderID: firstFolder.id), startedAt)
        XCTAssertEqual(store.indexEntryCount(), 0)

        let boundedRetry = scanner.scan(
            configuration: configuration,
            at: startedAt.addingTimeInterval(10)
        )
        XCTAssertTrue(
            boundedRetry.failures.isEmpty,
            boundedRetry.failures.joined(separator: "\n")
        )
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadStopReason, .deadlineExceeded)
        XCTAssertEqual(
            scanner.pendingDiscoveryUsageForTesting(),
            AgentPendingDiscoveryUsage(activeInventoryCount: 0, entryCount: 0, estimatedBytes: 0)
        )
        XCTAssertEqual(store.fullDiscoveryFailureCount(folderID: firstFolder.id), 2)
        XCTAssertEqual(
            store.lastFullDiscoveryAttempt(folderID: firstFolder.id),
            startedAt.addingTimeInterval(10)
        )
        XCTAssertNotNil(store.entries().first { $0.reference.path == laterInSameFolder.path })
        XCTAssertNil(store.entries().first { $0.reference.path == permanentlySlow.path })
        XCTAssertNil(store.entries().first { $0.reference.path == laterFolderSource.path })

        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(
            store: restartedStore,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: AgentSourceBodyReadLimits(
                maximumBytes: 1 * 1_024 * 1_024,
                maximumDurationNanoseconds: 100
            ),
            sourceBodyReadUptimeNanoseconds: {
                defer { tick += 20 }
                return tick
            },
            sourceBodyReadCancellationCheck: { false }
        )
        let afterRestart = restartedScanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: startedAt.addingTimeInterval(20)
        )
        XCTAssertTrue(
            afterRestart.failures.isEmpty,
            afterRestart.failures.joined(separator: "\n")
        )
        XCTAssertEqual(
            restartedScanner.cycleMetricsForTesting().sourceBodyReadStopReason,
            .deadlineExceeded
        )
        XCTAssertEqual(
            restartedScanner.pendingDiscoveryUsageForTesting(),
            AgentPendingDiscoveryUsage(activeInventoryCount: 0, entryCount: 0, estimatedBytes: 0)
        )
        XCTAssertNotNil(
            restartedStore.entries().first { $0.reference.path == laterFolderSource.path }
        )
        XCTAssertNil(
            restartedStore.entries().first { $0.reference.path == permanentlySlow.path }
        )
        XCTAssertEqual(restartedStore.fullDiscoveryFailureCount(folderID: firstFolder.id), 3)
        XCTAssertEqual(
            restartedStore.lastFullDiscoveryAttempt(folderID: firstFolder.id),
            startedAt.addingTimeInterval(20)
        )
        XCTAssertNotNil(restartedStore.lastFullDiscovery(folderID: secondFolder.id))
        XCTAssertEqual(
            restartedStore.entries().filter { $0.reference.path == laterInSameFolder.path }.count,
            1
        )
        XCTAssertEqual(
            restartedStore.entries().filter { $0.reference.path == laterFolderSource.path }.count,
            1
        )
    }

    func testUnavailableLargeRootBacksOffBeforeLoadingChildrenOrRewritingState() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-root-backoff-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let movedRoot = fixtureRoot.appendingPathComponent("source-moved", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceCount = 300
        for index in 0..<sourceCount {
            try Data("\(index)".utf8).write(
                to: sourceRoot.appendingPathComponent(String(format: "session-%03d.txt", index))
            )
        }
        let folder = AgentWatchedFolder(
            id: "missing-root-backoff",
            displayName: "Unavailable root",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            maximumIndexEntries: sourceCount
        )
        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_787_472_000)

        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: startedAt
        )
        _ = scanner.scan(
            configuration: configuration,
            at: startedAt.addingTimeInterval(10)
        )
        XCTAssertEqual(store.entries(folderID: folder.id).count, sourceCount)

        try fileManager.moveItem(at: sourceRoot, to: movedRoot)
        let firstFailure = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: startedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(firstFailure.failures.isEmpty)
        XCTAssertEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(
            scanner.cycleMetricsForTesting().materializedIndexEntryCount,
            sourceCount
        )
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 1)
        let persistedFailure = try Data(contentsOf: store.indexFile)

        let skippedBeforeFirstRetry = scanner.scan(
            configuration: configuration,
            at: startedAt.addingTimeInterval(90)
        )
        XCTAssertTrue(skippedBeforeFirstRetry.failures.isEmpty)
        XCTAssertEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().materializedIndexEntryCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try Data(contentsOf: store.indexFile), persistedFailure)

        let firstRetry = scanner.scan(
            configuration: configuration,
            at: startedAt.addingTimeInterval(120)
        )
        XCTAssertFalse(firstRetry.failures.isEmpty)
        XCTAssertEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(
            scanner.cycleMetricsForTesting().materializedIndexEntryCount,
            256
        )
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try Data(contentsOf: store.indexFile), persistedFailure)

        for offset in [150, 239] {
            let skipped = scanner.scan(
                configuration: configuration,
                at: startedAt.addingTimeInterval(TimeInterval(offset))
            )
            XCTAssertTrue(skipped.failures.isEmpty)
            XCTAssertEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 0)
            XCTAssertEqual(scanner.cycleMetricsForTesting().materializedIndexEntryCount, 0)
            XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
            XCTAssertEqual(try Data(contentsOf: store.indexFile), persistedFailure)
        }

        try fileManager.moveItem(at: movedRoot, to: sourceRoot)
        let recovered = scanner.scan(
            configuration: configuration,
            at: startedAt.addingTimeInterval(240)
        )
        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(scanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(store.entries(folderID: folder.id).count, sourceCount)
        XCTAssertEqual(store.rootStatus(folderID: folder.id)?.availability, .available)
    }

    func testPersistedIdentityDetectsMetadataIdenticalReplacementAfterRestart() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-force-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let source = sourceRoot.appendingPathComponent("session.jsonl")
        let sourceDate = Date(timeIntervalSince1970: 1_787_472_100)
        let original = Data(#"{"content":"AAAA"}"#.utf8)
        let replacement = Data(#"{"content":"BBBB"}"#.utf8)
        XCTAssertEqual(original.count, replacement.count)
        try original.write(to: source)
        try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

        let folder = AgentWatchedFolder(
            id: "forced-validation",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: sourceDate)
        let originalHash = try XCTUnwrap(store.entries(folderID: folder.id).first?.sha256)

        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.truncate(atOffset: UInt64(replacement.count))
        try handle.synchronize()
        try handle.close()
        try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(store: restartedStore)
        let detected = restartedScanner.scan(
            configuration: configuration,
            at: sourceDate.addingTimeInterval(10)
        )
        XCTAssertEqual(detected.scannedSourceCount, 1)
        XCTAssertEqual(detected.changedSourceCount, 1)
        XCTAssertNotEqual(restartedStore.entries(folderID: folder.id).first?.sha256, originalHash)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 1)
    }

    func testGrowingIndexedSourceWaitsForQuiescenceThenRehashesOnceWithoutDuplication() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-growing-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let source = sourceRoot.appendingPathComponent("session.jsonl")
        let startedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let original = Data("{\"role\":\"user\",\"content\":\"first\"}\n".utf8)
        let appended = Data("{\"role\":\"assistant\",\"content\":\"second\"}\n".utf8)
        try original.write(to: source)
        try fileManager.setAttributes([.modificationDate: startedAt], ofItemAtPath: source.path)

        let folder = AgentWatchedFolder(
            id: "growing-source",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analyzeContent: false,
            at: startedAt
        )
        let originalEntry = try XCTUnwrap(store.entries(folderID: folder.id).first)

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.synchronize()
        try handle.close()
        let appendedAt = startedAt.addingTimeInterval(10)
        try fileManager.setAttributes([.modificationDate: appendedAt], ofItemAtPath: source.path)

        let active = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: appendedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(active.scannedSourceCount, 0)
        XCTAssertEqual(active.changedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().deferredGrowingSourceCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(store.entries(folderID: folder.id), [originalEntry])

        let settled = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: appendedAt.addingTimeInterval(
                AgentActivityScanner.growingSourceQuiescenceSeconds + 1
            )
        )
        XCTAssertEqual(settled.scannedSourceCount, 1)
        XCTAssertEqual(settled.changedSourceCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 1)
        XCTAssertEqual(
            scanner.cycleMetricsForTesting().sourceBodyReadBytes,
            Int64(original.count + appended.count)
        )
        XCTAssertEqual(scanner.cycleMetricsForTesting().deferredGrowingSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 1)
        let updatedEntries = store.entries(folderID: folder.id)
        XCTAssertEqual(updatedEntries.count, 1)
        XCTAssertEqual(updatedEntries[0].id, originalEntry.id)
        XCTAssertEqual(updatedEntries[0].byteCount, Int64(original.count + appended.count))
        XCTAssertNotEqual(updatedEntries[0].sha256, originalEntry.sha256)

        let warm = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: appendedAt.addingTimeInterval(
                AgentActivityScanner.growingSourceQuiescenceSeconds + 30
            )
        )
        XCTAssertEqual(warm.scannedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(store.entries(folderID: folder.id).count, 1)
    }

    func testExplicitAnalysisDoesNotWaitForGrowingSourceQuiescence() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-growing-explicit-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let source = sourceRoot.appendingPathComponent("session.jsonl")
        let startedAt = Date(timeIntervalSince1970: 1_787_472_100)
        try Data("{\"role\":\"user\",\"content\":\"first\"}\n".utf8).write(to: source)
        try fileManager.setAttributes([.modificationDate: startedAt], ofItemAtPath: source.path)
        let folder = AgentWatchedFolder(
            id: "growing-explicit",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: startedAt,
            analyzeContent: false,
            at: startedAt
        )

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"role\":\"assistant\",\"content\":\"second\"}\n".utf8))
        try handle.synchronize()
        try handle.close()
        let appendedAt = startedAt.addingTimeInterval(10)
        try fileManager.setAttributes([.modificationDate: appendedAt], ofItemAtPath: source.path)

        let explicit = scanner.scan(
            configuration: configuration,
            analysisDay: startedAt,
            analyzeContent: true,
            at: appendedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(explicit.scannedSourceCount, 1)
        XCTAssertEqual(explicit.changedSourceCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().deferredGrowingSourceCount, 0)
        XCTAssertEqual(store.entries(folderID: folder.id).count, 1)
        XCTAssertEqual(store.transientAnalysisCount(), 1)
    }

    func testExplicitDayRepopulatesTransientAnalysisButWarmMetadataPollReadsNothing() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-explicit-day-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let source = sourceRoot.appendingPathComponent("session.jsonl")
        let sourceDate = Date(timeIntervalSince1970: 1_787_472_100)
        try Data(#"{"role":"user","content":"explicit analysis"}"#.utf8).write(to: source)
        try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

        let folder = AgentWatchedFolder(
            id: "explicit-day",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let initialStore = try AgentActivityStore(rootDirectory: storeRoot)
        let initialScanner = AgentActivityScanner(store: initialStore)
        _ = initialScanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: sourceDate,
            at: sourceDate
        )

        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(store: restartedStore)
        let hiddenStartup = restartedScanner.scan(
            configuration: configuration,
            analysisDay: sourceDate,
            analyzeContent: false,
            at: sourceDate.addingTimeInterval(5)
        )
        XCTAssertEqual(hiddenStartup.scannedSourceCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(restartedStore.transientAnalysisCount(), 0)

        let explicit = restartedScanner.scan(
            configuration: configuration,
            analysisDay: sourceDate,
            at: sourceDate.addingTimeInterval(10)
        )
        XCTAssertEqual(explicit.scannedSourceCount, 1)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 1)
        XCTAssertEqual(restartedStore.transientAnalysisCount(), 1)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 0)

        restartedStore.discardTransientSummaries()
        XCTAssertEqual(restartedStore.transientSummaryCount(), 0)
        XCTAssertEqual(restartedStore.transientSummaryByteCount(), 0)
        XCTAssertEqual(restartedStore.transientAnalysisCount(), 1)

        let warm = restartedScanner.scan(
            configuration: configuration,
            analysisDay: sourceDate,
            analyzeContent: false,
            at: sourceDate.addingTimeInterval(20)
        )
        XCTAssertEqual(warm.scannedSourceCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 0)

        let visibleAgain = restartedScanner.scan(
            configuration: configuration,
            analysisDay: sourceDate,
            analyzeContent: true,
            at: sourceDate.addingTimeInterval(30)
        )
        XCTAssertEqual(visibleAgain.scannedSourceCount, 1)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 1)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(restartedStore.transientSummaryCount(), 1)

        let visibleWarm = restartedScanner.scan(
            configuration: configuration,
            analysisDay: sourceDate,
            analyzeContent: true,
            at: sourceDate.addingTimeInterval(40)
        )
        XCTAssertEqual(visibleWarm.scannedSourceCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
    }

    func testVisibleSummaryRehydrationIsBoundedAfterDashboardPurge() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-rehydrate-bound-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let selectedDay = Date(timeIntervalSince1970: 1_787_472_100)
        for index in 0..<70 {
            let source = sourceRoot.appendingPathComponent(String(format: "session-%03d.jsonl", index))
            try Data("{\"role\":\"user\",\"content\":\"summary-\(index)\"}".utf8).write(to: source)
            try fileManager.setAttributes([.modificationDate: selectedDay], ofItemAtPath: source.path)
        }
        let folder = AgentWatchedFolder(
            id: "rehydrate-bound",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let scanner = AgentActivityScanner(store: store)
        _ = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: selectedDay,
            at: selectedDay
        )
        XCTAssertEqual(store.transientAnalysisCount(), 70)
        store.discardTransientSummaries()

        let hidden = scanner.scan(
            configuration: configuration,
            analysisDay: selectedDay,
            analyzeContent: false,
            at: selectedDay.addingTimeInterval(10)
        )
        XCTAssertEqual(hidden.scannedSourceCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 0)

        let visible = scanner.scan(
            configuration: configuration,
            analysisDay: selectedDay,
            analyzeContent: true,
            at: selectedDay.addingTimeInterval(20)
        )
        XCTAssertEqual(visible.scannedSourceCount, 64)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 64)
        XCTAssertEqual(store.transientSummaryCount(), 64)
        XCTAssertEqual(scanner.cycleMetricsForTesting().indexWriteCount, 0)
    }

    func testExplicitAnalysisPromotesPendingMetadataInventoryAndFinishesWithoutDuplication() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-analysis-catch-up-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let sourceCount = 300
        let selectedDay = Date(timeIntervalSince1970: 1_787_472_000)
        for index in 0..<sourceCount {
            let source = sourceRoot.appendingPathComponent(String(format: "session-%03d.jsonl", index))
            try Data("{\"role\":\"user\",\"content\":\"analysis-\(index)\"}\n".utf8)
                .write(to: source)
            try fileManager.setAttributes(
                [.modificationDate: selectedDay.addingTimeInterval(60)],
                ofItemAtPath: source.path
            )
        }

        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let folder = AgentWatchedFolder(
            id: "analysis-catch-up",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            maximumIndexEntries: sourceCount
        )
        let scanner = AgentActivityScanner(store: store)

        let hidden = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: selectedDay,
            analyzeContent: false,
            at: selectedDay.addingTimeInterval(120)
        )
        XCTAssertFalse(hidden.analysisIncomplete)
        XCTAssertEqual(store.indexEntryCount(), 256)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().entryCount, sourceCount)

        var result = scanner.scan(
            configuration: configuration,
            analysisDay: selectedDay,
            analyzeContent: true,
            at: selectedDay.addingTimeInterval(130)
        )
        var analyzedBodyReadCount = result.scannedSourceCount
        var catchUpCount = 0
        while result.analysisIncomplete, catchUpCount < 8 {
            catchUpCount += 1
            result = scanner.scan(
                configuration: configuration,
                analysisDay: selectedDay,
                analyzeContent: true,
                at: selectedDay.addingTimeInterval(130 + Double(catchUpCount))
            )
            analyzedBodyReadCount += result.scannedSourceCount
        }

        XCTAssertFalse(result.analysisIncomplete)
        XCTAssertLessThanOrEqual(catchUpCount, 3)
        XCTAssertEqual(analyzedBodyReadCount, sourceCount)
        XCTAssertEqual(store.indexEntryCount(), sourceCount)
        XCTAssertEqual(store.transientAnalysisCount(), sourceCount)
        XCTAssertEqual(Set(store.entries().map(\.id)).count, sourceCount)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)
    }

    func testSatisfiedProviderSignalDoesNotRepeatHealthyRootDiscovery() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-signal-progress-\(UUID().uuidString)",
            isDirectory: true
        )
        let healthyRoot = fixtureRoot.appendingPathComponent("healthy", isDirectory: true)
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: healthyRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        try Data("healthy\n".utf8).write(to: healthyRoot.appendingPathComponent("session.txt"))

        let healthyFolder = AgentWatchedFolder(
            id: "signal-healthy",
            displayName: "Custom",
            path: healthyRoot.path,
            provider: .custom
        )
        let missingFolder = AgentWatchedFolder(
            id: "signal-missing",
            displayName: "Custom",
            path: missingRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [healthyFolder, missingFolder],
            maximumIndexEntries: 100
        )
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let scanner = AgentActivityScanner(store: store)
        let signalDate = Date(timeIntervalSince1970: 1_787_472_500)
        _ = try AgentHookSignalWriter.write(
            rootDirectory: storeRoot,
            provider: .custom,
            eventName: "changed",
            discardedPayloadBytes: 0,
            processIdentifier: 1,
            signaledAt: signalDate
        )

        let first = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: signalDate.addingTimeInterval(1)
        )
        XCTAssertFalse(first.failures.isEmpty)
        XCTAssertEqual(first.fullDiscoveryCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().discoveredCandidateCount, 1)
        XCTAssertNil(store.lastHandledSignal(provider: .custom))

        let backedOff = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: signalDate.addingTimeInterval(30)
        )
        XCTAssertTrue(backedOff.failures.isEmpty)
        XCTAssertEqual(backedOff.fullDiscoveryCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().discoveredCandidateCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertNil(store.lastHandledSignal(provider: .custom))

        try fileManager.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        try Data("recovered\n".utf8).write(to: missingRoot.appendingPathComponent("session.txt"))
        let recovered = scanner.scan(
            configuration: configuration,
            analyzeContent: false,
            at: signalDate.addingTimeInterval(62)
        )
        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(recovered.fullDiscoveryCount, 1)
        XCTAssertEqual(scanner.cycleMetricsForTesting().discoveredCandidateCount, 1)
        XCTAssertEqual(store.lastHandledSignal(provider: .custom), signalDate)
        XCTAssertEqual(store.indexEntryCount(), 2)
    }

    func testTenThousandSourcesUseOneCommitAndBoundedWarmPollingWithoutLostChanges() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-load-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let storeRoot = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let sourceCount = 10_000
        for index in 0..<sourceCount {
            let file = sourceRoot.appendingPathComponent(String(format: "session-%05d.jsonl", index))
            try Data("{\"role\":\"user\",\"content\":\"load-\(index)\"}".utf8).write(to: file)
        }

        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let folder = AgentWatchedFolder(
            id: "scanner-load",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            fullDiscoveryIntervalSeconds: 900,
            maximumIndexEntries: sourceCount
        )
        let scanner = AgentActivityScanner(store: store)
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let unrelatedAnalysisDay = Date(timeIntervalSince1970: 946_684_800)

        let first = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            analysisDay: unrelatedAnalysisDay,
            at: observedAt
        )
        let firstMetrics = scanner.cycleMetricsForTesting()
        XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "\n"))
        XCTAssertTrue(firstMetrics.stoppedByBudget)
        XCTAssertLessThanOrEqual(firstMetrics.sourceBodyReadCount, 256)
        XCTAssertLessThanOrEqual(firstMetrics.discoveredCandidateCount, 512)
        XCTAssertLessThanOrEqual(firstMetrics.sourceTraversalVisitCount, 50_000)
        XCTAssertLessThanOrEqual(firstMetrics.indexWriteCount, 1)
        XCTAssertLessThanOrEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 1)
        XCTAssertLessThanOrEqual(scanner.pendingDiscoveryUsageForTesting().entryCount, sourceCount * 2)
        XCTAssertLessThanOrEqual(
            scanner.pendingDiscoveryUsageForTesting().estimatedBytes,
            24 * 1_024 * 1_024
        )

        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(store: restartedStore)
        let entryCountAfterFirstProcess = restartedStore.indexEntryCount()
        var cycleOffset: TimeInterval = 10
        var cycleCount = 0
        var cumulativeTraversalVisits = 0
        var cumulativeDiscoveredCandidates = 0
        var cumulativeChangedSources = 0
        while restartedStore.indexEntryCount() < sourceCount
            || restartedScanner.pendingDiscoveryUsageForTesting().activeInventoryCount > 0,
            cycleCount < 100
        {
            cycleCount += 1
            let cycle = restartedScanner.scan(
                configuration: configuration,
                analysisDay: unrelatedAnalysisDay,
                at: observedAt.addingTimeInterval(cycleOffset)
            )
            let cycleMetrics = restartedScanner.cycleMetricsForTesting()
            XCTAssertTrue(cycle.failures.isEmpty, cycle.failures.joined(separator: "\n"))
            XCTAssertLessThanOrEqual(cycleMetrics.sourceBodyReadCount, 256)
            XCTAssertLessThanOrEqual(cycleMetrics.discoveredCandidateCount, 512)
            XCTAssertLessThanOrEqual(cycleMetrics.sourceTraversalVisitCount, 50_000)
            XCTAssertLessThanOrEqual(cycleMetrics.indexWriteCount, 1)
            let pendingUsage = restartedScanner.pendingDiscoveryUsageForTesting()
            XCTAssertLessThanOrEqual(pendingUsage.activeInventoryCount, 1)
            XCTAssertLessThanOrEqual(pendingUsage.entryCount, sourceCount * 2)
            XCTAssertLessThanOrEqual(pendingUsage.estimatedBytes, 24 * 1_024 * 1_024)
            cumulativeTraversalVisits += cycleMetrics.sourceTraversalVisitCount
            cumulativeDiscoveredCandidates += cycleMetrics.discoveredCandidateCount
            cumulativeChangedSources += cycle.changedSourceCount
            cycleOffset += 10
        }
        XCTAssertLessThanOrEqual(cycleCount, 100)
        XCTAssertEqual(restartedStore.indexEntryCount(), sourceCount)
        XCTAssertEqual(Set(restartedStore.entries().map(\.stableConversationID)).count, sourceCount)
        XCTAssertLessThan(restartedStore.indexBytes(), 12 * 1_024 * 1_024)
        XCTAssertEqual(cumulativeDiscoveredCandidates, sourceCount)
        XCTAssertEqual(cumulativeChangedSources, sourceCount - entryCountAfterFirstProcess)
        XCTAssertGreaterThanOrEqual(cumulativeTraversalVisits, sourceCount)
        XCTAssertLessThanOrEqual(
            cumulativeTraversalVisits,
            sourceCount + firstMetrics.sourceTraversalVisitCount + 16,
            "A relaunch may revisit the lost process-local prefix once; the replacement cursor must not rescan it again."
        )
        XCTAssertEqual(restartedScanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)

        let warm = restartedScanner.scan(
            configuration: configuration,
            at: observedAt.addingTimeInterval(cycleOffset)
        )
        let warmMetrics = restartedScanner.cycleMetricsForTesting()
        XCTAssertEqual(warm.scannedSourceCount, 0)
        XCTAssertEqual(warm.changedSourceCount, 0)
        XCTAssertEqual(warmMetrics.sourceBodyReadCount, 0)
        XCTAssertLessThanOrEqual(warmMetrics.metadataResolutionCount, 256)
        XCTAssertLessThanOrEqual(warmMetrics.visitedIndexEntryCount, 256)
        XCTAssertEqual(warmMetrics.indexWriteCount, 0)

        let entriesBeforeChange = Dictionary(
            uniqueKeysWithValues: restartedStore.entries(folderID: folder.id).map {
                ($0.reference.path, $0.sha256)
            }
        )
        let changedSourceCount = 100
        for index in 0..<changedSourceCount {
            let file = sourceRoot.appendingPathComponent(String(format: "session-%05d.jsonl", index))
            let previousModifiedAt = try XCTUnwrap(
                fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            )
            try Data("{\"role\":\"user\",\"content\":\"modified-load-\(index)\"}".utf8)
                .write(to: file, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: previousModifiedAt.addingTimeInterval(5)],
                ofItemAtPath: file.path
            )
        }

        let changedPaths = Set(
            (0..<changedSourceCount).map {
                sourceRoot.appendingPathComponent(String(format: "session-%05d.jsonl", $0)).path
            }
        )
        var detectedChangedPaths: Set<String> = []
        var cumulativeChangedSourceCount = 0
        var refreshAttempt = 0
        let maximumRefreshAttempts = (sourceCount + 255) / 256 + 1
        var refreshDate = observedAt.addingTimeInterval(cycleOffset + 920)
        while detectedChangedPaths.count < changedSourceCount,
            refreshAttempt < maximumRefreshAttempts
        {
            let changed = restartedScanner.scan(
                configuration: configuration,
                analysisDay: unrelatedAnalysisDay,
                at: refreshDate
            )
            let changedMetrics = restartedScanner.cycleMetricsForTesting()
            XCTAssertTrue(changed.failures.isEmpty, changed.failures.joined(separator: "\n"))
            XCTAssertEqual(changed.fullDiscoveryCount, 0)
            XCTAssertLessThanOrEqual(changed.scannedSourceCount, 256)
            XCTAssertLessThanOrEqual(changedMetrics.sourceBodyReadCount, 256)
            XCTAssertLessThanOrEqual(changedMetrics.visitedIndexEntryCount, 256)
            XCTAssertLessThanOrEqual(changedMetrics.indexWriteCount, 1)
            XCTAssertEqual(restartedStore.indexEntryCount(), sourceCount)
            cumulativeChangedSourceCount += changed.changedSourceCount
            let currentHashes = Dictionary(
                uniqueKeysWithValues: restartedStore.entries(folderID: folder.id).map {
                    ($0.reference.path, $0.sha256)
                }
            )
            detectedChangedPaths = Set(
                changedPaths.filter {
                    currentHashes[$0] != entriesBeforeChange[$0]
                })
            refreshAttempt += 1
            refreshDate = refreshDate.addingTimeInterval(10)
        }
        XCTAssertEqual(detectedChangedPaths, changedPaths)
        XCTAssertEqual(cumulativeChangedSourceCount, changedSourceCount)

        let movedSourceRoot = fixtureRoot.appendingPathComponent(
            "source-unavailable",
            isDirectory: true
        )
        try fileManager.moveItem(at: sourceRoot, to: movedSourceRoot)
        let failureDate = refreshDate.addingTimeInterval(60)
        let firstFailure = restartedScanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: failureDate
        )
        XCTAssertFalse(firstFailure.failures.isEmpty)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(
            restartedScanner.cycleMetricsForTesting().materializedIndexEntryCount,
            sourceCount
        )
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 1)
        let persistedFailure = try Data(contentsOf: restartedStore.indexFile)

        let skippedDuringBackoff = restartedScanner.scan(
            configuration: configuration,
            at: failureDate.addingTimeInterval(30)
        )
        XCTAssertTrue(skippedDuringBackoff.failures.isEmpty)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().materializedIndexEntryCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try Data(contentsOf: restartedStore.indexFile), persistedFailure)

        // Process-local retry state intentionally resets with a new scanner. It permits one
        // bounded probe after restart, then rearms before any 10k-child materialization.
        let relaunchedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let relaunchedScanner = AgentActivityScanner(store: relaunchedStore)
        let restartProbe = relaunchedScanner.scan(
            configuration: configuration,
            at: failureDate.addingTimeInterval(60)
        )
        XCTAssertFalse(restartProbe.failures.isEmpty)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(
            relaunchedScanner.cycleMetricsForTesting().materializedIndexEntryCount,
            256
        )
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try Data(contentsOf: relaunchedStore.indexFile), persistedFailure)

        let restartedBackoff = relaunchedScanner.scan(
            configuration: configuration,
            at: failureDate.addingTimeInterval(90)
        )
        XCTAssertTrue(restartedBackoff.failures.isEmpty)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 0)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().materializedIndexEntryCount, 0)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(try Data(contentsOf: relaunchedStore.indexFile), persistedFailure)

        try fileManager.moveItem(at: movedSourceRoot, to: sourceRoot)
        let stillBackedOff = relaunchedScanner.scan(
            configuration: configuration,
            at: failureDate.addingTimeInterval(119)
        )
        XCTAssertTrue(stillBackedOff.failures.isEmpty)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 0)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().materializedIndexEntryCount, 0)
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().indexWriteCount, 0)

        let recovered = relaunchedScanner.scan(
            configuration: configuration,
            at: failureDate.addingTimeInterval(120)
        )
        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(relaunchedScanner.cycleMetricsForTesting().rootOpenAttemptCount, 1)
        XCTAssertEqual(relaunchedStore.indexEntryCount(), sourceCount)
        XCTAssertEqual(relaunchedStore.rootStatus(folderID: folder.id)?.availability, .available)
    }

    func testSelectedDaySourceIsAnalyzedBeforeNewerIrrelevantFilesUnderBodyReadCap() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-scanner-day-priority-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let selectedDay = Date(timeIntervalSince1970: 1_787_443_200)
        let irrelevantNewerDate = selectedDay.addingTimeInterval(2 * 24 * 60 * 60)
        for index in 0..<300 {
            let file = sourceRoot.appendingPathComponent(String(format: "session-%03d.jsonl", index))
            try Data("{\"role\":\"user\",\"content\":\"fixture-\(index)\"}".utf8).write(to: file)
            try fileManager.setAttributes(
                [.modificationDate: irrelevantNewerDate],
                ofItemAtPath: file.path
            )
        }
        let selected = sourceRoot.appendingPathComponent("selected-day.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"selected-day\"}".utf8).write(to: selected)
        try fileManager.setAttributes([.modificationDate: selectedDay], ofItemAtPath: selected.path)

        let store = try AgentActivityStore(
            rootDirectory: fixtureRoot.appendingPathComponent("store", isDirectory: true)
        )
        let folder = AgentWatchedFolder(
            id: "selected-day-priority",
            displayName: "Custom",
            path: sourceRoot.path,
            provider: .custom
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder],
                maximumIndexEntries: 1_000
            ),
            forceFullDiscovery: true,
            analysisDay: selectedDay,
            at: irrelevantNewerDate
        )

        XCTAssertEqual(result.scannedSourceCount, 256)
        let selectedEntry = try XCTUnwrap(
            store.entries().first { $0.reference.path == selected.path }
        )
        XCTAssertTrue(
            store.hasTransientAnalysis(
                id: selectedEntry.id,
                reference: selectedEntry.reference
            )
        )
    }

    func testOptInRealCodexRootUsesBoundedStreamingAndMetadataOnlyIndex() throws {
        guard
            let sourcePath = ProcessInfo.processInfo.environment[
                "GOALONG_TEST_REAL_CODEX_SOURCE_ROOT"
            ]
        else {
            throw XCTSkip("Set GOALONG_TEST_REAL_CODEX_SOURCE_ROOT for the local read-only benchmark.")
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            XCTFail("The opt-in Codex source root is not a readable directory.")
            return
        }
        let storeRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "goalong-real-codex-streaming-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: storeRoot) }
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let folder = AgentWatchedFolder(
            id: "opt-in-real-codex",
            displayName: "Codex",
            path: sourcePath,
            provider: .codex
        )
        let configuration = AgentActivityConfiguration(
            watchedFolders: [folder],
            maximumIndexEntries: 10_000
        )
        let scanner = AgentActivityScanner(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_787_520_000)
        var completed = false
        for cycle in 0..<128 {
            _ = autoreleasepool {
                scanner.scan(
                    configuration: configuration,
                    forceFullDiscovery: cycle == 0,
                    analyzeContent: false,
                    at: startedAt.addingTimeInterval(Double(cycle * 61))
                )
            }
            if scanner.pendingDiscoveryUsageForTesting().activeInventoryCount == 0,
                store.lastFullDiscovery(folderID: folder.id) != nil
            {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed, "The bounded continuation did not finish within 128 cycles.")
        XCTAssertGreaterThan(store.indexEntryCount(), 0)
        XCTAssertTrue(store.entries().allSatisfy { $0.provider == .codex })
        XCTAssertTrue(store.entries().allSatisfy { store.cachedRecord(id: $0.id) == nil })
        XCTAssertFalse(fileManager.fileExists(atPath: storeRoot.appendingPathComponent("blobs").path))
        XCTAssertLessThanOrEqual(store.storageBytes(), 12 * 1_024 * 1_024 + 1 * 1_024 * 1_024)
    }
}
