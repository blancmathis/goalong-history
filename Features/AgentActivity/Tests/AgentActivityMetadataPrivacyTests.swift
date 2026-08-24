import Foundation
import XCTest

@testable import AgentActivity

final class AgentActivityMetadataPrivacyTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testUnknownSignalProviderKeyIsDroppedWhenIndexIsDecodedAndReencoded() throws {
        let sentinel = "PRIVATE-TRANSCRIPT-SIGNAL-KEY-MUST-NOT-PERSIST"
        let handledAt = Date(timeIntervalSince1970: 1_787_472_100)
        let index = AgentActivityIndex(
            lastHandledSignalByProvider: [AgentProvider.codex.rawValue: handledAt],
            updatedAt: handledAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(index)) as? [String: Any]
        )
        var signalDates = try XCTUnwrap(
            object["lastHandledSignalByProvider"] as? [String: Any]
        )
        signalDates[sentinel] = try XCTUnwrap(signalDates[AgentProvider.codex.rawValue])
        object["lastHandledSignalByProvider"] = signalDates

        let decoded = try decoder.decode(
            AgentActivityIndex.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(
            decoded.lastHandledSignalByProvider,
            [AgentProvider.codex.rawValue: handledAt]
        )

        let reencoded = try encoder.encode(decoded)
        XCTAssertFalse(try XCTUnwrap(String(data: reencoded, encoding: .utf8)).contains(sentinel))
    }

    func testFreeFormValuesAndTranscriptSentinelNeverReachPersistedIndex() throws {
        let sentinel = "CHAT-BODY-SECRET-NEVER-PERSIST-7A31"
        let oversizedPath = "/tmp/" + String(repeating: "🧠", count: 1_100) + sentinel + ".jsonl"
        let reference = AgentSourceReference(
            kind: .file,
            path: oversizedPath,
            locator: sentinel
        )
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let entry = AgentSourceIndexEntry(
            id: sentinel,
            stableConversationID: sentinel,
            watchedFolderID: "folder \(sentinel)",
            watchedFolderName: "Label \(sentinel)",
            provider: .custom,
            reference: reference,
            relativePath: "label/\(sentinel).jsonl",
            sourceCreatedAt: observedAt,
            sourceModifiedAt: observedAt,
            firstIndexedAt: observedAt,
            lastObservedAt: observedAt,
            byteCount: 42,
            sha256: String(repeating: "a", count: 64),
            availability: .inaccessible,
            statusDetail: "database error included \(sentinel)"
        )
        var mutatedEntry = entry
        mutatedEntry.watchedFolderID = "mutated \(sentinel)"
        mutatedEntry.watchedFolderName = sentinel
        mutatedEntry.reference.path = "relative/\(sentinel)"
        mutatedEntry.reference.locator = sentinel
        mutatedEntry.relativePath = sentinel
        mutatedEntry.statusDetail = sentinel
        let record = AgentCaptureRecord(
            index: mutatedEntry,
            summary: AgentDocumentSummary(
                sessionID: sentinel,
                title: sentinel,
                excerpt: "full transcript \(sentinel)",
                projectPath: "/tmp/\(sentinel)",
                models: [sentinel],
                tools: [sentinel],
                touchedFiles: [sentinel],
                commands: [sentinel]
            )
        )
        let store = try AgentActivityStore(rootDirectory: try makeTemporaryDirectory("metadata-no-copy"))

        XCTAssertTrue(try store.upsert(record, maximumEntries: 100))
        let indexData = try Data(contentsOf: store.indexFile)
        let indexText = try XCTUnwrap(String(data: indexData, encoding: .utf8))

        XCTAssertFalse(indexText.contains(sentinel))
        XCTAssertFalse(indexText.contains("full transcript"))
        XCTAssertFalse(indexText.contains("excerpt"))
        XCTAssertFalse(indexText.contains("title"))
        XCTAssertEqual(store.entries().first?.watchedFolderName, AgentProvider.custom.displayName)
        XCTAssertEqual(store.entries().first?.statusDetail, AgentSourceStatusCode.sourceInaccessible.rawValue)
        XCTAssertNil(reference.locator, "File references must never persist a free-form locator")
    }

    func testPublicSummaryAndReferenceBoundsCountUTF8Bytes() {
        let unicode = String(repeating: "🧠", count: 20_000)
        let summary = AgentDocumentSummary(
            sessionID: unicode,
            title: unicode,
            excerpt: unicode,
            projectPath: unicode,
            models: Array(repeating: unicode, count: 100),
            tools: Array(repeating: unicode, count: 200),
            touchedFiles: Array(repeating: unicode, count: 300),
            commands: Array(repeating: unicode, count: 200)
        )
        let reference = AgentSourceReference(kind: .file, path: "/tmp/\(unicode)")

        XCTAssertLessThanOrEqual(summary.sessionID?.utf8.count ?? .max, AgentDocumentSummary.maximumSessionIDBytes)
        XCTAssertLessThanOrEqual(summary.title?.utf8.count ?? .max, AgentDocumentSummary.maximumTitleBytes)
        XCTAssertLessThanOrEqual(summary.excerpt?.utf8.count ?? .max, AgentDocumentSummary.maximumExcerptBytes)
        XCTAssertLessThanOrEqual(summary.projectPath?.utf8.count ?? .max, AgentDocumentSummary.maximumProjectPathBytes)
        XCTAssertEqual(summary.models.count, AgentDocumentSummary.maximumModelCount)
        XCTAssertEqual(summary.tools.count, AgentDocumentSummary.maximumToolCount)
        XCTAssertEqual(summary.touchedFiles.count, AgentDocumentSummary.maximumTouchedFileCount)
        XCTAssertEqual(summary.commands.count, AgentDocumentSummary.maximumCommandCount)
        XCTAssertTrue(summary.models.allSatisfy { $0.utf8.count <= AgentDocumentSummary.maximumIdentifierBytes })
        XCTAssertTrue(summary.tools.allSatisfy { $0.utf8.count <= AgentDocumentSummary.maximumIdentifierBytes })
        XCTAssertTrue(
            summary.touchedFiles.allSatisfy {
                $0.utf8.count <= AgentDocumentSummary.maximumTouchedFileBytes
            })
        XCTAssertTrue(summary.commands.allSatisfy { $0.utf8.count <= AgentDocumentSummary.maximumCommandBytes })
        XCTAssertLessThanOrEqual(reference.path.utf8.count, AgentSourceReference.maximumPathBytes)
        XCTAssertFalse(reference.path.contains(unicode))
    }

    func testTransientSummaryCacheHasStrictByteCardinalityAndTTLBounds() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_787_472_100))
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("metadata-cache-bounds"),
            currentDate: { clock.now }
        )
        let largeValue = String(repeating: "é", count: AgentDocumentSummary.maximumTouchedFileBytes / 2)
        let records = (0..<100).map { index in
            makeRecord(
                stableID: "cache-\(index)",
                observedAt: clock.now,
                summary: AgentDocumentSummary(
                    title: "cache-\(index)",
                    excerpt: largeValue,
                    touchedFiles: Array(
                        repeating: largeValue,
                        count: AgentDocumentSummary.maximumTouchedFileCount
                    ),
                    commands: Array(repeating: largeValue, count: AgentDocumentSummary.maximumCommandCount)
                )
            )
        }

        _ = try store.upsertBatch(records, maximumEntries: 200)

        XCTAssertLessThan(store.transientSummaryCount(), records.count)
        XCTAssertLessThanOrEqual(store.transientSummaryCount(), AgentActivityStore.maximumTransientRecords)
        XCTAssertLessThanOrEqual(
            store.transientSummaryByteCount(),
            AgentActivityStore.maximumTransientSummaryBytes
        )
        XCTAssertGreaterThan(store.transientSummaryByteCount(), 0)

        clock.advance(by: AgentActivityStore.transientSummaryTTL + 1)
        XCTAssertNil(store.cachedRecord(id: records.last!.id))
        XCTAssertEqual(store.transientSummaryCount(), 0)
        XCTAssertEqual(store.transientSummaryByteCount(), 0)
        XCTAssertEqual(store.transientAnalysisCount(), records.count)

        _ = try store.upsert(makeRecord(stableID: "after-expiry", observedAt: clock.now), maximumEntries: 200)
        XCTAssertEqual(store.transientSummaryCount(), 1)
        store.clearTransientAnalyses()
        XCTAssertEqual(store.transientSummaryCount(), 0)
        XCTAssertEqual(store.transientSummaryByteCount(), 0)
        XCTAssertEqual(store.transientAnalysisCount(), 0)
    }

    func testIndexByteMeasurementTracksAtomicReplacementGrowth() throws {
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let store = try AgentActivityStore(
            rootDirectory: try makeTemporaryDirectory("metadata-index-byte-measurement")
        )
        _ = try store.upsert(
            makeRecord(stableID: "initial", observedAt: observedAt),
            maximumEntries: 1_000
        )
        let initialBytes = Int64(try Data(contentsOf: store.indexFile).count)
        XCTAssertEqual(store.indexBytes(), initialBytes)

        let additions = (0..<300).map {
            makeRecord(stableID: "growth-\($0)", observedAt: observedAt)
        }
        _ = try store.upsertBatch(additions, maximumEntries: 1_000)
        let grownBytes = Int64(try Data(contentsOf: store.indexFile).count)

        XCTAssertGreaterThan(grownBytes, initialBytes)
        XCTAssertEqual(store.indexBytes(), grownBytes)
        XCTAssertEqual(store.storageBytes(), grownBytes)
    }

    func testTenThousandLongMetadataEntriesTrimExactlyUnderTwelveMiBWithoutRewriteLoop() throws {
        let observedAt = Date(timeIntervalSince1970: 1_787_472_100)
        let root = try makeTemporaryDirectory("metadata-serialized-bound")
        let store = try AgentActivityStore(rootDirectory: root)
        let padding = String(repeating: "p", count: 900)
        let records = (0..<10_000).map { index -> AgentCaptureRecord in
            let relativePath = "\(padding)-\(String(format: "%05d", index)).jsonl"
            let reference = AgentSourceReference(
                kind: .file,
                path: "/fixture/\(relativePath)"
            )
            let entry = AgentSourceIndexEntry(
                id: "entry-\(index)",
                stableConversationID: "long-metadata-\(index)",
                watchedFolderID: "long-metadata-folder",
                watchedFolderName: "Custom",
                provider: .custom,
                reference: reference,
                relativePath: relativePath,
                sourceCreatedAt: observedAt,
                sourceModifiedAt: observedAt,
                firstIndexedAt: observedAt.addingTimeInterval(Double(index)),
                lastObservedAt: observedAt.addingTimeInterval(Double(index)),
                byteCount: 1,
                sha256: String(repeating: "c", count: 64)
            )
            return AgentCaptureRecord(index: entry, isAnalyzed: false)
        }

        _ = try store.upsertBatch(records, maximumEntries: 10_000)

        XCTAssertLessThanOrEqual(store.indexBytes(), 12 * 1_024 * 1_024)
        XCTAssertLessThan(store.indexEntryCount(), records.count)
        XCTAssertTrue(store.indexIsValid(maximumEntries: 10_000))
        let reloaded = try AgentActivityStore(rootDirectory: root)
        XCTAssertTrue(reloaded.indexIsValid(maximumEntries: 10_000))
        XCTAssertEqual(reloaded.indexEntryCount(), store.indexEntryCount())

        let retained = try XCTUnwrap(reloaded.entries().last)
        let bytesBefore = try Data(contentsOf: reloaded.indexFile)
        let writesBefore = reloaded.indexWriteCountForTesting()
        XCTAssertFalse(
            try reloaded.upsert(
                AgentCaptureRecord(index: retained, isAnalyzed: false),
                maximumEntries: 10_000
            )
        )
        XCTAssertEqual(reloaded.indexWriteCountForTesting(), writesBefore)
        XCTAssertEqual(try Data(contentsOf: reloaded.indexFile), bytesBefore)
    }

    private func makeRecord(
        stableID: String,
        observedAt: Date,
        summary: AgentDocumentSummary = AgentDocumentSummary(title: "bounded")
    ) -> AgentCaptureRecord {
        let reference = AgentSourceReference(kind: .file, path: "/fixture/\(stableID).jsonl")
        return AgentCaptureRecord(
            index: AgentSourceIndexEntry(
                id: stableID,
                stableConversationID: stableID,
                watchedFolderID: "privacy-fixture",
                watchedFolderName: "Fixture",
                provider: .custom,
                reference: reference,
                relativePath: "\(stableID).jsonl",
                sourceCreatedAt: observedAt,
                sourceModifiedAt: observedAt,
                firstIndexedAt: observedAt,
                lastObservedAt: observedAt,
                byteCount: 64,
                sha256: String(repeating: "b", count: 64)
            ),
            summary: summary
        )
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Goalong-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
