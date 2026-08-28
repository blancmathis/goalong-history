import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest

@testable import AgentActivity

final class OpenCodeSQLiteReadOnlyTests: XCTestCase {
    private struct FileSnapshot: Equatable {
        var mode: mode_t
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var sha256: String
    }

    private struct DirectorySnapshot: Equatable {
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var entries: [String]
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        AgentSQLiteReadMetrics.reset()
    }

    func testOriginalOpenCodeDatabaseIsReadWithMemoryOnlyTemporaryStorageAndNeverMutated() throws {
        let rawSessionID = "OPENCODE-RAW-SESSION-SECRET-MUST-NOT-PERSIST"
        let fixtureHome = try makeTemporaryDirectory("fixture-home")
        let sourceDirectory =
            fixtureHome
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: rawSessionID)

        let fixedModificationDate = Date(timeIntervalSince1970: 1_787_472_600)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate, .posixPermissions: 0o444],
            ofItemAtPath: databaseURL.path
        )
        let sourceBefore = try fileSnapshot(databaseURL)
        let directoryBefore = try directorySnapshot(sourceDirectory)
        XCTAssertEqual(directoryBefore.entries, ["opencode.db"])

        AgentSQLiteReadMetrics.reset(path: databaseURL.path)
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("goalong-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-original-location",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true,
            at: fixedModificationDate.addingTimeInterval(60)
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(result.changedSourceCount, 1)
        let capture = try XCTUnwrap(result.captures.first)
        XCTAssertEqual(capture.provider, .openCode)
        XCTAssertEqual(capture.index.reference.path, databaseURL.path)
        let opaqueLocator = try XCTUnwrap(capture.index.reference.locator)
        XCTAssertTrue(AgentStableConversationIdentifier.isPersisted(opaqueLocator))
        XCTAssertEqual(capture.index.stableConversationID, opaqueLocator)
        XCTAssertEqual(capture.summary.sessionID, opaqueLocator)
        XCTAssertEqual(capture.index.relativePath, "opencode.db#session/\(opaqueLocator)")
        XCTAssertGreaterThan(capture.summary.messageCount, 0)

        let encodedRecordMetadata = try JSONEncoder().encode(capture.index)
        let persistedIndex = try Data(contentsOf: store.indexFile)
        let exposedRecordMetadata = [
            capture.id,
            capture.index.stableConversationID,
            capture.index.reference.locator,
            capture.relativePath,
            capture.summary.sessionID,
        ].compactMap { $0 }.joined(separator: "\n")
        XCTAssertFalse(String(decoding: encodedRecordMetadata, as: UTF8.self).contains(rawSessionID))
        XCTAssertFalse(String(decoding: persistedIndex, as: UTF8.self).contains(rawSessionID))
        XCTAssertFalse(exposedRecordMetadata.contains(rawSessionID))

        #if DEBUG
            let connectionConfiguration = try XCTUnwrap(
                AgentSQLiteReadMetrics.readOnlyConfiguration(path: databaseURL.path)
            )
            XCTAssertTrue(connectionConfiguration.databaseIsReadOnly)
            XCTAssertEqual(connectionConfiguration.tempStoreMode, 2, "SQLITE_TEMP_STORE_MEMORY")
            XCTAssertEqual(connectionConfiguration.memoryMapSizeBytes, 0)
            XCTAssertEqual(connectionConfiguration.queryOnlyMode, 1)
            XCTAssertTrue(connectionConfiguration.noFollowOpenAttempted)
            XCTAssertEqual(
                AgentSQLiteReadMetrics.statementSortCount(path: databaseURL.path),
                0,
                "Provider-controlled tables must never trigger an in-memory SQLite sort"
            )
            XCTAssertLessThanOrEqual(
                AgentSQLiteReadMetrics.maximumStatementMemoryBytes(path: databaseURL.path),
                512 * 1_024
            )
        #endif

        XCTAssertEqual(try fileSnapshot(databaseURL), sourceBefore)
        XCTAssertEqual(
            try directorySnapshot(sourceDirectory),
            directoryBefore,
            "Direct reads must not create WAL, SHM, journal, or temporary files beside opencode.db"
        )

        let incrementalResult = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: false,
            at: fixedModificationDate.addingTimeInterval(120)
        )
        XCTAssertTrue(
            incrementalResult.failures.isEmpty,
            incrementalResult.failures.joined(separator: "\n")
        )
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertFalse(try String(contentsOf: store.indexFile).contains(rawSessionID))
    }

    func testOpenCodeVisibleDialogueJoinsMessageRolesToTextPartsWithoutProcessContent() throws {
        let sourceDirectory = try makeTemporaryDirectory("visible-dialogue-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db")
        try createOpenCodeVisibleDialogueFixture(at: databaseURL, sessionID: "visible-dialogue")
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("visible-dialogue-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-visible-dialogue",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )

        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_700)
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        let summary = try XCTUnwrap(result.captures.first).summary
        XCTAssertEqual(
            summary.visibleMessages,
            [
                AgentVisibleMessage(role: .user, text: "OpenCode user request"),
                AgentVisibleMessage(role: .assistantFinal, text: "OpenCode final response"),
                AgentVisibleMessage(role: .user, text: "Second OpenCode request"),
                AgentVisibleMessage(role: .assistantFinal, text: "Second OpenCode final"),
            ]
        )
        let visibleText = summary.visibleMessages.map(\.text).joined(separator: "\n")
        for excluded in [
            "OPENCODE-SYSTEM-SENTINEL", "OPENCODE-PROGRESS-SENTINEL",
            "OPENCODE-TOOL-SENTINEL",
        ] {
            XCTAssertFalse(visibleText.contains(excluded), "Leaked \(excluded)")
        }
    }

    func testOversizedConversationDoesNotConsumeCycleBudgetOrStarveSmallerConversation() throws {
        let sourceDirectory = try makeTemporaryDirectory("oversized-conversation-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "large-session")
        try addSmallOpenCodeSession(at: databaseURL, sessionID: "small-session")
        let sourceBefore = try fileSnapshot(databaseURL)
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("oversized-conversation-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-oversized-conversation",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
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
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder],
                maximumFileBytes: 1 * 1_024 * 1_024
            ),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_600)
        )

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(store.indexEntryCount(), 2)
        XCTAssertEqual(store.entries().filter { $0.availability == .available }.count, 1)
        XCTAssertEqual(store.entries().filter { $0.availability == .inaccessible }.count, 1)
        XCTAssertGreaterThan(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        XCTAssertLessThan(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 1_024)
        XCTAssertNil(scanner.cycleMetricsForTesting().sourceBodyReadStopReason)
        XCTAssertEqual(scanner.pendingDiscoveryUsageForTesting().activeInventoryCount, 0)
        XCTAssertEqual(try fileSnapshot(databaseURL), sourceBefore)
    }

    func testSingleOversizedBlobIsRejectedBeforeBodyReadAndDoesNotStarveSmallerConversation() throws {
        let sourceDirectory = try makeTemporaryDirectory("oversized-blob-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "large-blob-session")
        try replaceOpenCodeMessageWithZeroBlob(
            at: databaseURL,
            sessionID: "large-blob-session",
            byteCount: 8 * 1_024 * 1_024
        )
        try addSmallOpenCodeSession(at: databaseURL, sessionID: "small-after-blob")

        let sourceBefore = try fileSnapshot(databaseURL)
        let directoryBefore = try directorySnapshot(sourceDirectory)
        XCTAssertEqual(directoryBefore.entries, ["opencode.db"])
        AgentSQLiteReadMetrics.reset(path: databaseURL.path)

        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("oversized-blob-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-oversized-blob",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let scanner = AgentActivityScanner(
            store: store,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: AgentSourceBodyReadLimits(
                maximumBytes: 16 * 1_024 * 1_024,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadCancellationCheck: { false }
        )

        let result = scanner.scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder],
                maximumFileBytes: 1 * 1_024 * 1_024
            ),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_600)
        )

        XCTAssertTrue(
            result.failures.contains { failure in
                failure.contains("configured maximum is 1048576")
            },
            result.failures.joined(separator: "\n")
        )
        XCTAssertEqual(store.indexEntryCount(), 2)
        XCTAssertEqual(store.entries().filter { $0.availability == .available }.count, 1)
        XCTAssertEqual(store.entries().filter { $0.availability == .inaccessible }.count, 1)
        XCTAssertGreaterThan(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        XCTAssertLessThan(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 1_024)
        XCTAssertNil(scanner.cycleMetricsForTesting().sourceBodyReadStopReason)
        #if DEBUG
            XCTAssertEqual(
                AgentSQLiteReadMetrics.maximumObservedBodyRowBytes(path: databaseURL.path),
                8 * 1_024 * 1_024
            )
            XCTAssertEqual(
                AgentSQLiteReadMetrics.bodyBlobReadBytes(path: databaseURL.path),
                scanner.cycleMetricsForTesting().sourceBodyReadBytes
            )
            XCTAssertLessThanOrEqual(
                AgentSQLiteReadMetrics.maximumBodyBlobReadChunkBytes(path: databaseURL.path),
                128 * 1_024
            )
        #endif

        AgentSQLiteReadMetrics.reset(path: databaseURL.path)
        let streamingStore = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("bounded-blob-stream-index")
        )
        let streamingScanner = AgentActivityScanner(
            store: streamingStore,
            sourceTraversalLimits: .production,
            sourceBodyReadLimits: AgentSourceBodyReadLimits(
                maximumBytes: 16 * 1_024 * 1_024,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            sourceBodyReadCancellationCheck: { false }
        )
        let streamed = streamingScanner.scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [folder],
                maximumFileBytes: 16 * 1_024 * 1_024
            ),
            forceFullDiscovery: true,
            at: Date(timeIntervalSince1970: 1_787_472_660)
        )
        XCTAssertTrue(streamed.failures.isEmpty, streamed.failures.joined(separator: "\n"))
        XCTAssertEqual(streamingStore.indexEntryCount(), 2)
        XCTAssertEqual(
            streamingStore.entries().filter { $0.availability == .available }.count,
            2
        )
        #if DEBUG
            XCTAssertEqual(
                AgentSQLiteReadMetrics.maximumObservedBodyRowBytes(path: databaseURL.path),
                8 * 1_024 * 1_024
            )
            XCTAssertGreaterThan(
                AgentSQLiteReadMetrics.bodyBlobReadBytes(path: databaseURL.path),
                8 * 1_024 * 1_024
            )
            XCTAssertLessThanOrEqual(
                AgentSQLiteReadMetrics.maximumBodyBlobReadChunkBytes(path: databaseURL.path),
                128 * 1_024
            )
        #endif
        XCTAssertEqual(try fileSnapshot(databaseURL), sourceBefore)
        XCTAssertEqual(
            try directorySnapshot(sourceDirectory),
            directoryBefore,
            "Incremental BLOB reads must not create WAL, SHM, journal, or temporary files."
        )
    }

    func testNonemptyRollbackJournalIsDeferredWithoutChangingDatabaseOrSidecar() throws {
        let fixtureHome = try makeTemporaryDirectory("rollback-home")
        let sourceDirectory =
            fixtureHome
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "rollback-session")
        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        try Data("ACTIVE-ROLLBACK-JOURNAL".utf8).write(to: journalURL)

        let databaseBefore = try fileSnapshot(databaseURL)
        let journalBefore = try fileSnapshot(journalURL)
        let directoryBefore = try directorySnapshot(sourceDirectory)
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("rollback-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-rollback",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )

        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: true
        )

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(result.failures.joined(separator: " ").lowercased().contains("journal"))
        XCTAssertEqual(result.changedSourceCount, 0)
        XCTAssertEqual(store.indexEntryCount(), 0)
        XCTAssertEqual(try fileSnapshot(databaseURL), databaseBefore)
        XCTAssertEqual(try fileSnapshot(journalURL), journalBefore)
        XCTAssertEqual(try directorySnapshot(sourceDirectory), directoryBefore)
    }

    func testConversationChangeWithoutSessionTimestampIsDetectedOnceAfterRestart() throws {
        let sentinel = "OPENCODE-CHANGED-BODY-MUST-NOT-PERSIST-91D4"
        let sourceDirectory = try makeTemporaryDirectory("revision-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "stable-session")
        let storeRoot = try makeTemporaryDirectory("revision-index")
        let folder = AgentWatchedFolder(
            id: "opencode-revision",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let initialDate = Date(timeIntervalSince1970: 1_787_472_600)
        let initialStore = try AgentActivityStore(rootDirectory: storeRoot)
        let initialScanner = AgentActivityScanner(store: initialStore)
        let initial = initialScanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        let initialCapture = try XCTUnwrap(initial.captures.first)
        let initialEntry = try XCTUnwrap(initialStore.entries().first)
        XCTAssertGreaterThan(initialCapture.summary.userMessageCount, 0)
        let unchangedSessionTimestamp = initialEntry.sourceModifiedAt

        try updateOpenCodeMessageBody(
            at: databaseURL,
            body: "{\"role\":\"assistant\",\"content\":\"\(sentinel)\",\"time\":{\"created\":1787472000000}}"
        )

        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(store: restartedStore)
        let changed = restartedScanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(60)
        )
        XCTAssertTrue(changed.failures.isEmpty, changed.failures.joined(separator: "\n"))
        XCTAssertEqual(changed.changedSourceCount, 1)
        XCTAssertEqual(restartedStore.indexEntryCount(), 1)
        let changedEntry = try XCTUnwrap(restartedStore.entries().first)
        XCTAssertNotEqual(changedEntry.sha256, initialEntry.sha256)
        XCTAssertEqual(changedEntry.sourceModifiedAt, unchangedSessionTimestamp)
        XCTAssertNotNil(changedEntry.sourceContainerByteCount)
        XCTAssertNotNil(changedEntry.sourceContainerModifiedSeconds)
        XCTAssertGreaterThan(try XCTUnwrap(changed.captures.first).summary.assistantMessageCount, 0)
        XCTAssertFalse(try String(contentsOf: restartedStore.indexFile).contains(sentinel))

        let warm = restartedScanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(120)
        )
        XCTAssertTrue(warm.failures.isEmpty, warm.failures.joined(separator: "\n"))
        XCTAssertEqual(warm.changedSourceCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(restartedScanner.cycleMetricsForTesting().indexWriteCount, 0)
        XCTAssertEqual(restartedStore.indexEntryCount(), 1)
    }

    func testLargeDatabaseRevisionReadsOnlyBoundedPagesAndLeavesSourceByteIdentical() throws {
        let sourceDirectory = try makeTemporaryDirectory("large-revision-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "bounded-large-session")
        try inflateOpenCodeFixture(at: databaseURL, fillerBytes: 32 * 1_024 * 1_024)

        let storeRoot = try makeTemporaryDirectory("large-revision-index")
        let folder = AgentWatchedFolder(
            id: "opencode-large-revision",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let initialDate = Date(timeIntervalSince1970: 1_787_473_200)
        let initialStore = try AgentActivityStore(rootDirectory: storeRoot)
        let initial = AgentActivityScanner(store: initialStore).scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        XCTAssertEqual(initial.changedSourceCount, 1)
        let initialEntry = try XCTUnwrap(initialStore.entries().first)
        let unchangedSessionTimestamp = initialEntry.sourceModifiedAt

        try updateOpenCodeMessageBody(
            at: databaseURL,
            body: "{\"role\":\"assistant\",\"content\":\"bounded revision\",\"time\":{\"created\":1787473200000}}"
        )
        let databaseBefore = try fileSnapshot(databaseURL)
        let directoryBefore = try directorySnapshot(sourceDirectory)
        XCTAssertGreaterThan(databaseBefore.byteCount, 32 * 1_024 * 1_024)
        XCTAssertEqual(directoryBefore.entries, ["opencode.db"])

        AgentSQLiteReadMetrics.reset(path: databaseURL.path)
        let restartedStore = try AgentActivityStore(rootDirectory: storeRoot)
        let restartedScanner = AgentActivityScanner(store: restartedStore)
        let changed = restartedScanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(60)
        )

        XCTAssertTrue(changed.failures.isEmpty, changed.failures.joined(separator: "\n"))
        XCTAssertEqual(changed.changedSourceCount, 1)
        XCTAssertEqual(restartedStore.indexEntryCount(), 1)
        let changedEntry = try XCTUnwrap(restartedStore.entries().first)
        XCTAssertNotEqual(changedEntry.sha256, initialEntry.sha256)
        XCTAssertEqual(changedEntry.sourceModifiedAt, unchangedSessionTimestamp)
        XCTAssertLessThanOrEqual(
            restartedScanner.cycleMetricsForTesting().sourceBodyReadBytes,
            1 * 1_024 * 1_024
        )
        #if DEBUG
            let databasePageReadBytes = AgentSQLiteReadMetrics.databasePageReadBytes(
                path: databaseURL.path
            )
            XCTAssertGreaterThan(databasePageReadBytes, 0)
            XCTAssertLessThanOrEqual(databasePageReadBytes, 4 * 1_024 * 1_024)
            XCTAssertLessThan(databasePageReadBytes, databaseBefore.byteCount / 4)
            XCTAssertEqual(AgentSQLiteReadMetrics.statementSortCount(path: databaseURL.path), 0)
            XCTAssertLessThanOrEqual(
                AgentSQLiteReadMetrics.maximumStatementMemoryBytes(path: databaseURL.path),
                512 * 1_024
            )
        #endif
        XCTAssertEqual(try fileSnapshot(databaseURL), databaseBefore)
        XCTAssertEqual(try directorySnapshot(sourceDirectory), directoryBefore)
    }

    func testOpenCodeDatabaseSymlinkReplacementFailsClosedWithoutReadingExternalTarget() throws {
        let attackerSentinel = "OPENCODE-SYMLINK-ATTACKER-BODY-NEVER-READ-6B2E"
        let sourceDirectory = try makeTemporaryDirectory("symlink-source")
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: "legitimate-session")
        let externalDirectory = try makeTemporaryDirectory("symlink-external")
        let externalDatabase = externalDirectory.appendingPathComponent("attacker.db", isDirectory: false)
        try createOpenCodeFixture(at: externalDatabase, sessionID: attackerSentinel)
        let storeRoot = try makeTemporaryDirectory("symlink-index")
        let store = try AgentActivityStore(rootDirectory: storeRoot)
        let folder = AgentWatchedFolder(
            id: "opencode-symlink",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let initialDate = Date(timeIntervalSince1970: 1_787_473_000)
        let scanner = AgentActivityScanner(store: store)
        let initial = scanner.scan(
            configuration: configuration,
            forceFullDiscovery: true,
            at: initialDate
        )
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        let trustedEntry = try XCTUnwrap(store.entries().first)

        let parkedDatabase = sourceDirectory.appendingPathComponent("legitimate-parked.db")
        try FileManager.default.moveItem(at: databaseURL, to: parkedDatabase)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: externalDatabase)
        let externalBefore = try fileSnapshot(externalDatabase)
        let externalDirectoryBefore = try directorySnapshot(externalDirectory)
        let sourceDirectoryBefore = try directorySnapshot(sourceDirectory)
        store.clearTransientAnalyses()
        AgentSQLiteReadMetrics.reset(path: databaseURL.path)

        let scan = scanner.scan(
            configuration: configuration,
            at: initialDate.addingTimeInterval(60)
        )
        XCTAssertFalse(scan.failures.isEmpty)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadCount, 0)
        XCTAssertEqual(scanner.cycleMetricsForTesting().sourceBodyReadBytes, 0)
        XCTAssertEqual(store.indexEntryCount(), 1)
        XCTAssertEqual(store.entries().first?.sha256, trustedEntry.sha256)
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(store.rootStatus(folderID: folder.id)?.availability, .inaccessible)
        XCTAssertThrowsError(
            try store.directRead(entryID: trustedEntry.id, maximumBytes: 512 * 1_024 * 1_024)
        )
        #if DEBUG
            XCTAssertEqual(AgentSQLiteReadMetrics.openCount(path: databaseURL.path), 0)
            XCTAssertEqual(AgentSQLiteReadMetrics.sourceHashCount(path: databaseURL.path), 0)
            XCTAssertEqual(AgentSQLiteReadMetrics.catalogScanCount(path: databaseURL.path), 0)
            XCTAssertNil(AgentSQLiteReadMetrics.readOnlyConfiguration(path: databaseURL.path))
        #endif
        XCTAssertEqual(try fileSnapshot(externalDatabase), externalBefore)
        XCTAssertEqual(try directorySnapshot(externalDirectory), externalDirectoryBefore)
        XCTAssertEqual(try directorySnapshot(sourceDirectory), sourceDirectoryBefore)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: databaseURL.path),
            externalDatabase.path
        )
        XCTAssertFalse(try regularFilesContain(Data(attackerSentinel.utf8), beneath: storeRoot))
    }

    func testLegacyRawLocatorMigratesInPlaceToOpaqueMetadataWithoutDuplication() throws {
        let rawSessionID = "LEGACY-OPENCODE-RAW-ID-MUST-DISAPPEAR"
        let fixtureHome = try makeTemporaryDirectory("legacy-home")
        let sourceDirectory =
            fixtureHome
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = sourceDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try createOpenCodeFixture(at: databaseURL, sessionID: rawSessionID)

        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("legacy-index")
        )
        let folder = AgentWatchedFolder(
            id: "opencode-legacy",
            displayName: "OpenCode",
            path: sourceDirectory.path,
            provider: .openCode
        )
        let legacyReference = AgentSourceReference(
            kind: .sqliteConversation,
            path: databaseURL.path,
            locator: rawSessionID
        )
        let legacyEntry = AgentSourceIndexEntry(
            id: "",
            stableConversationID: rawSessionID,
            watchedFolderID: folder.id,
            watchedFolderName: folder.displayName,
            provider: .openCode,
            reference: legacyReference,
            relativePath: "opencode.db#session/\(rawSessionID)",
            sourceCreatedAt: nil,
            sourceModifiedAt: nil,
            firstIndexedAt: Date(timeIntervalSince1970: 1_787_472_000),
            lastObservedAt: Date(timeIntervalSince1970: 1_787_472_000),
            byteCount: 0,
            sha256: String(repeating: "a", count: 64)
        )
        try store.upsert(AgentCaptureRecord(index: legacyEntry, isAnalyzed: false), maximumEntries: 100)
        XCTAssertFalse(
            try String(contentsOf: store.indexFile).contains(rawSessionID),
            "The public entry initializer must sanitize a legacy raw provider ID before persistence."
        )

        let result = AgentActivityScanner(store: store).scan(
            configuration: AgentActivityConfiguration(watchedFolders: [folder]),
            forceFullDiscovery: false,
            at: Date(timeIntervalSince1970: 1_787_472_600)
        )

        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(store.indexEntryCount(), 1)
        let migrated = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(migrated.id, legacyEntry.id)
        XCTAssertEqual(migrated.reference.locator, migrated.stableConversationID)
        XCTAssertTrue(AgentStableConversationIdentifier.isPersisted(migrated.stableConversationID))
        XCTAssertFalse(try String(contentsOf: store.indexFile).contains(rawSessionID))
    }

    private func createOpenCodeFixture(at url: URL, sessionID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open fixture")
        }
        defer { sqlite3_close(database) }

        try execute(database, "PRAGMA journal_mode=DELETE")
        try execute(
            database,
            "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)"
        )
        try execute(
            database,
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try execute(
            database,
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                "INSERT INTO session VALUES ('\(sessionID)', 'project', NULL, 'fixture', '/tmp/opencode-project', 'OpenCode read-only fixture', '1', 1787472000000, 1787472600000)"
            )
            try execute(
                database,
                "INSERT INTO message VALUES ('message-1', '\(sessionID)', 1787472000000, 1787472600000, '{\"role\":\"user\",\"time\":{\"created\":1787472000000}}')"
            )
            try execute(
                database,
                """
                WITH RECURSIVE sequence(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM sequence WHERE value < 2048
                )
                INSERT INTO part
                SELECT printf('part-%05d', value), 'message-1', '\(sessionID)',
                       1787472600000 - value, 1787472600000 - value,
                       '{"type":"text","text":"OpenCode immutable source row ' || value || '"}'
                FROM sequence
                """
            )
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func createOpenCodeVisibleDialogueFixture(at url: URL, sessionID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open visible dialogue fixture")
        }
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=DELETE")
        try execute(
            database,
            "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER)"
        )
        try execute(
            database,
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try execute(
            database,
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try execute(
            database,
            "INSERT INTO session VALUES ('\(sessionID)', 'project', NULL, 'visible', '/tmp/opencode-visible', 'Visible dialogue', '1', 1787472000000, 1787472600000)"
        )
        let messages: [(String, String)] = [
            ("system-1", "system"), ("user-1", "user"), ("assistant-progress", "assistant"),
            ("assistant-final", "assistant"), ("user-2", "user"), ("assistant-2", "assistant"),
        ]
        for (offset, message) in messages.enumerated() {
            try execute(
                database,
                "INSERT INTO message VALUES ('\(message.0)', '\(sessionID)', "
                    + "\(1787472000000 + offset), \(1787472000000 + offset), "
                    + "'{\"role\":\"\(message.1)\"}')"
            )
        }
        let parts: [(String, String, String, String)] = [
            ("part-system", "system-1", "text", "OPENCODE-SYSTEM-SENTINEL"),
            ("part-user-1", "user-1", "text", "OpenCode user request"),
            ("part-progress", "assistant-progress", "text", "OPENCODE-PROGRESS-SENTINEL"),
            ("part-tool", "assistant-final", "tool", "OPENCODE-TOOL-SENTINEL"),
            ("part-final", "assistant-final", "text", "OpenCode final response"),
            ("part-user-2", "user-2", "text", "Second OpenCode request"),
            ("part-assistant-2", "assistant-2", "text", "Second OpenCode final"),
        ]
        for (offset, part) in parts.enumerated() {
            try execute(
                database,
                "INSERT INTO part VALUES ('\(part.0)', '\(part.1)', '\(sessionID)', "
                    + "\(1787472100000 + offset), \(1787472100000 + offset), "
                    + "'{\"type\":\"\(part.2)\",\"text\":\"\(part.3)\"}')"
            )
        }
    }

    private func addSmallOpenCodeSession(at url: URL, sessionID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open small fixture")
        }
        defer { sqlite3_close(database) }
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                "INSERT INTO session VALUES ('\(sessionID)', 'project', NULL, 'small', "
                    + "'/tmp/opencode-small', 'Small session', '1', "
                    + "1787471000000, 1787471000000)"
            )
            try execute(
                database,
                "INSERT INTO message VALUES ('message-small', '\(sessionID)', "
                    + "1787471000000, 1787471000000, "
                    + "'{\"role\":\"user\",\"content\":\"small\"}')"
            )
            try execute(
                database,
                "INSERT INTO part VALUES ('part-small', 'message-small', '\(sessionID)', "
                    + "1787471000000, 1787471000000, "
                    + "'{\"type\":\"text\",\"text\":\"small\"}')"
            )
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func updateOpenCodeMessageBody(at url: URL, body: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open revision fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "UPDATE message SET data = ? WHERE id = 'message-1'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            throw sqliteError(database, context: "prepare revision")
        }
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)), SQLITE_OK)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(database, context: "update revision")
        }
    }

    private func replaceOpenCodeMessageWithZeroBlob(
        at url: URL,
        sessionID: String,
        byteCount: Int64
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open oversized BLOB fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "UPDATE message SET data = zeroblob(?) WHERE session_id = ?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            throw sqliteError(database, context: "prepare oversized BLOB fixture")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, byteCount) == SQLITE_OK,
            sqlite3_bind_text(
                statement,
                2,
                sessionID,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else {
            throw sqliteError(database, context: "write oversized BLOB fixture")
        }
    }

    private func inflateOpenCodeFixture(at url: URL, fillerBytes: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw sqliteError(database, context: "open large fixture")
        }
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE unrelated_large_payload (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
        let chunkBytes = 512 * 1_024
        let rowCount = max(1, (fillerBytes + chunkBytes - 1) / chunkBytes)
        try execute(
            database,
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < \(rowCount)
            )
            INSERT INTO unrelated_large_payload
            SELECT value, zeroblob(\(chunkBytes)) FROM sequence
            """
        )
    }

    private func regularFilesContain(_ needle: Data, beneath root: URL) throws -> Bool {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else { return false }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            if try Data(contentsOf: url).range(of: needle) != nil { return true }
        }
        return false
    }

    private func execute(_ database: OpaquePointer?, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        let message = errorPointer.map { String(cString: $0) }
        if let errorPointer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "OpenCodeSQLiteReadOnlyTests.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message ?? sql]
            )
        }
    }

    private func sqliteError(_ database: OpaquePointer?, context: String) -> Error {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return NSError(
            domain: "OpenCodeSQLiteReadOnlyTests.SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "\(context): \(detail)"]
        )
    }

    private func fileSnapshot(_ url: URL) throws -> FileSnapshot {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FileSnapshot(
            mode: status.st_mode & 0o777,
            byteCount: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            sha256: digest
        )
    }

    private func directorySnapshot(_ url: URL) throws -> DirectorySnapshot {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        return DirectorySnapshot(
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            entries: entries
        )
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeSQLiteReadOnlyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
