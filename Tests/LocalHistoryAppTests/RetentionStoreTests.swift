#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    final class RetentionStoreTests: XCTestCase {
        private var temporaryDirectories: [URL] = []

        override func tearDownWithError() throws {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            temporaryDirectories.removeAll()
            try super.tearDownWithError()
        }

        func testJSONLStoreConstructionNeverPurgesRegardlessOfLegacyValue() throws {
            for legacyValue in [1, Int.max, Int.min] {
                let root = try makeTemporaryDirectory()
                let events = root.appendingPathComponent("events", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: events,
                    withIntermediateDirectories: true
                )
                let oldEvent = events.appendingPathComponent("2020-01-01.jsonl")
                try Data("old-event\n".utf8).write(to: oldEvent)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1)],
                    ofItemAtPath: oldEvent.path
                )

                _ = try JSONLStore(
                    retentionDays: legacyValue,
                    eventsDirectory: events,
                    prepareApplicationStorage: false
                )

                XCTAssertTrue(FileManager.default.fileExists(atPath: oldEvent.path))
                XCTAssertEqual(try Data(contentsOf: oldEvent), Data("old-event\n".utf8))
            }
        }

        func testJSONLStoreStillAppendsThroughBoundedNoFollowHandle() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(
                at: events,
                withIntermediateDirectories: true
            )
            let timestamp = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let store = try JSONLStore(
                retentionDays: Int.min,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )

            store.append(
                HistoryEvent(
                    sessionID: "retention-test",
                    timestamp: timestamp,
                    kind: .recorderStarted
                )
            )
            store.flush()
            store.close()

            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let data = try Data(contentsOf: file)
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(data.last, 0x0A)
        }

        func testJSONLExplicitDeletionPreservesUnknownLinkedAndNonRegularEntries() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(
                at: events,
                withIntermediateDirectories: true
            )
            let known = events.appendingPathComponent("2020-01-01.jsonl")
            let unknown = events.appendingPathComponent("notes.jsonl")
            let invalidDay = events.appendingPathComponent("2020-99-99.jsonl")
            let directory = events.appendingPathComponent("2020-01-02.jsonl")
            let target = root.appendingPathComponent("protected.txt")
            let link = events.appendingPathComponent("2020-01-03.jsonl")
            try Data("known\n".utf8).write(to: known)
            try Data("unknown\n".utf8).write(to: unknown)
            try Data("invalid\n".utf8).write(to: invalidDay)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("target\n".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let store = try JSONLStore(
                retentionDays: 1,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            let completion = expectation(description: "explicit deletion")
            store.deleteAll { result in
                XCTAssertEqual(try? result.get(), 1)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)
            store.close()

            XCTAssertFalse(FileManager.default.fileExists(atPath: known.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: invalidDay.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
            XCTAssertEqual(try Data(contentsOf: target), Data("target\n".utf8))
        }

        func testJSONLDeleteAllRevalidatesCandidateImmediatelyBeforeUnlink() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let moved = root.appendingPathComponent("original.jsonl")
            let original = Data("original-event\n".utf8)
            let replacement = Data("replacement-must-survive\n".utf8)
            try original.write(to: file)
            var didReplace = false
            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false,
                beforeDeleteAllUnlink: { candidate in
                    guard !didReplace else { return }
                    didReplace = true
                    XCTAssertEqual(candidate.lastPathComponent, file.lastPathComponent)
                    XCTAssertEqual(rename(file.path, moved.path), 0)
                    XCTAssertTrue(
                        FileManager.default.createFile(
                            atPath: file.path,
                            contents: replacement,
                            attributes: [.posixPermissions: 0o600]
                        ))
                }
            )

            let completion = expectation(description: "delete all source substitution")
            store.deleteAll { result in
                guard case .failure(let error) = result else {
                    XCTFail("Delete All must reject a substituted source")
                    completion.fulfill()
                    return
                }
                XCTAssertTrue(error.localizedDescription.contains("changed"))
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            XCTAssertTrue(didReplace)
            XCTAssertEqual(try Data(contentsOf: file), replacement)
            XCTAssertEqual(try Data(contentsOf: moved), original)
        }

        func testJSONLAppendFailsClosedBeforeWritingWhenPermissionRepairFails() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let original = Data("incomplete-private-tail".utf8)
            try original.write(to: file)
            XCTAssertEqual(chmod(file.path, mode_t(0o644)), 0)
            var permissionAttempts = 0
            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false,
                eventFilePermissionSetter: { _, mode in
                    permissionAttempts += 1
                    XCTAssertEqual(mode, mode_t(0o600))
                    return -1
                }
            )

            XCTAssertThrowsError(
                try store.appendAndWait(
                    HistoryEvent(
                        sessionID: "must-not-append",
                        timestamp: Self.date(year: 2026, month: 8, day: 23, hour: 12),
                        kind: .heartbeat
                    )
                )
            )
            XCTAssertEqual(permissionAttempts, 1)
            XCTAssertEqual(try Data(contentsOf: file), original)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        }

        func testJSONLAppendRepairsExistingEventFilePermissions() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-23.jsonl")
            try Data("legacy-row\n".utf8).write(to: file)
            XCTAssertEqual(chmod(file.path, mode_t(0o644)), 0)
            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )

            _ = try store.appendAndWait(
                HistoryEvent(
                    sessionID: "owner-only-after-append",
                    timestamp: Self.date(year: 2026, month: 8, day: 23, hour: 12),
                    kind: .heartbeat
                )
            )
            try store.closeAndWait()

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }

        func testJSONLDeleteDetailsStreamsLargeFilesAndSkipsOlderDays() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let olderFile = events.appendingPathComponent("2026-08-21.jsonl")
            let affectedFile = events.appendingPathComponent("2026-08-23.jsonl")
            let olderPayload = Data(repeating: 0x6F, count: 4 * 1_024 * 1_024)
            try olderPayload.write(to: olderFile)
            let olderDigest = SHA256Digest.hashHex(olderPayload)
            var olderStatusBefore = stat()
            XCTAssertEqual(lstat(olderFile.path, &olderStatusBefore), 0)
            XCTAssertEqual(chmod(olderFile.path, mode_t(0o000)), 0)

            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let before = cutoff.addingTimeInterval(-60)
            let after = cutoff.addingTimeInterval(60)
            let payload = String(repeating: "x", count: 300_000)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            FileManager.default.createFile(atPath: affectedFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: affectedFile)
            for index in 0..<40 {
                let event = HistoryEvent(
                    sessionID: "streaming-delete",
                    timestamp: index.isMultiple(of: 2) ? before : after,
                    kind: .heartbeat,
                    metadata: ["fixture_index": String(index), "payload": payload]
                )
                var row = try encoder.encode(event)
                row.append(0x0A)
                try handle.write(contentsOf: row)
            }
            let malformedRecentSentinel = "malformed-recent-private-detail-sentinel"
            try handle.write(contentsOf: Data("\(malformedRecentSentinel)\n".utf8))
            try handle.close()
            let affectedAttributes = try FileManager.default.attributesOfItem(
                atPath: affectedFile.path
            )
            let affectedBytesBefore = try XCTUnwrap(
                affectedAttributes[.size] as? NSNumber
            )
            XCTAssertGreaterThan(affectedBytesBefore.intValue, 10 * 1_024 * 1_024)

            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            let completion = expectation(description: "streaming delete")
            store.deleteEvents(since: cutoff) { result in
                XCTAssertEqual(try? result.get(), 21)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 10)

            var olderStatusAfter = stat()
            XCTAssertEqual(lstat(olderFile.path, &olderStatusAfter), 0)
            XCTAssertEqual(olderStatusAfter.st_ino, olderStatusBefore.st_ino)
            XCTAssertEqual(olderStatusAfter.st_size, olderStatusBefore.st_size)
            XCTAssertEqual(chmod(olderFile.path, mode_t(0o600)), 0)
            XCTAssertEqual(
                SHA256Digest.hashHex(try Data(contentsOf: olderFile)),
                olderDigest
            )

            let rows = try Data(contentsOf: affectedFile).split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            )
            let remainingEvents = rows.compactMap { row in
                try? JSONDecoder.iso8601.decode(HistoryEvent.self, from: Data(row))
            }
            XCTAssertEqual(remainingEvents.count, 20)
            XCTAssertTrue(remainingEvents.allSatisfy { $0.timestamp < cutoff })
            XCTAssertFalse(rows.contains { $0 == Data(malformedRecentSentinel.utf8) })
            XCTAssertNil(try Data(contentsOf: affectedFile).range(of: Data(malformedRecentSentinel.utf8)))

            let metrics = store.deletionMetrics
            XCTAssertEqual(metrics.filesConsidered, 2)
            XCTAssertEqual(metrics.filesSkippedBeforeCutoff, 1)
            XCTAssertEqual(metrics.filesOpened, 1)
            XCTAssertEqual(metrics.filesReplaced, 1)
            XCTAssertEqual(metrics.filesRemoved, 0)
            XCTAssertEqual(metrics.rowsDeleted, 21)
            XCTAssertEqual(metrics.malformedRowsPreserved, 0)
            XCTAssertEqual(metrics.malformedRowsDiscarded, 1)
            XCTAssertGreaterThan(metrics.sourceBytesRead, 10 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(
                metrics.peakBufferedBytes,
                JSONLStore.deletionMemoryBoundBytes
            )
        }

        func testJSONLDeleteDetailsDoesNotReplaceAnUnchangedAffectedFile() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let event = HistoryEvent(
                sessionID: "unchanged-delete",
                timestamp: cutoff.addingTimeInterval(-60),
                kind: .heartbeat
            )
            var data = try JSONEncoder.iso8601.encode(event)
            data.append(0x0A)
            try data.write(to: file)
            var before = stat()
            XCTAssertEqual(lstat(file.path, &before), 0)

            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            let completion = expectation(description: "no-op delete")
            store.deleteEvents(since: cutoff) { result in
                XCTAssertEqual(try? result.get(), 0)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            var after = stat()
            XCTAssertEqual(lstat(file.path, &after), 0)
            XCTAssertEqual(after.st_ino, before.st_ino)
            XCTAssertEqual(after.st_size, before.st_size)
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertEqual(store.deletionMetrics.filesUnchanged, 1)
            XCTAssertEqual(store.deletionMetrics.filesReplaced, 0)
        }

        func testJSONLDeleteDetailsDiscardsOversizedLegacyRowAndContinues() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let retained = HistoryEvent(
                sessionID: "retained-after-oversize",
                timestamp: cutoff.addingTimeInterval(-60),
                kind: .heartbeat
            )
            let deleted = HistoryEvent(
                sessionID: "deleted-after-oversize",
                timestamp: cutoff.addingTimeInterval(60),
                kind: .heartbeat
            )
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(
                contentsOf: Data(repeating: 0x78, count: JSONLStore.maximumEventLineBytes + 1)
            )
            try handle.write(contentsOf: Data([0x0A]))
            for event in [retained, deleted] {
                var row = try JSONEncoder.iso8601.encode(event)
                row.append(0x0A)
                try handle.write(contentsOf: row)
            }
            try handle.close()

            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            let completion = expectation(description: "oversized delete")
            store.deleteEvents(
                since: cutoff
            ) { result in
                XCTAssertEqual(try? result.get(), 2)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            let remainingRows = try Data(contentsOf: file).split(separator: 0x0A)
            let remainingEvents = remainingRows.compactMap {
                try? JSONDecoder.iso8601.decode(HistoryEvent.self, from: Data($0))
            }
            XCTAssertEqual(remainingEvents.map(\.sessionID), [retained.sessionID])
            XCTAssertEqual(store.deletionMetrics.oversizedRows, 1)
            XCTAssertEqual(store.deletionMetrics.oversizedRowsDiscarded, 1)
            XCTAssertEqual(store.deletionMetrics.rowsDeleted, 2)
            XCTAssertLessThanOrEqual(
                store.deletionMetrics.peakBufferedBytes,
                JSONLStore.deletionMemoryBoundBytes
            )
        }

        func testJSONLDeleteDetailsReadsPreviousDayForTimeZoneChanges() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let file = events.appendingPathComponent("2026-08-22.jsonl")
            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let retained = HistoryEvent(
                sessionID: "previous-day-retained",
                timestamp: cutoff.addingTimeInterval(-60),
                kind: .heartbeat
            )
            let deleted = HistoryEvent(
                sessionID: "previous-day-deleted",
                timestamp: cutoff.addingTimeInterval(60),
                kind: .heartbeat
            )
            var journal = Data()
            for event in [retained, deleted] {
                journal.append(try JSONEncoder.iso8601.encode(event))
                journal.append(0x0A)
            }
            try journal.write(to: file)

            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            let completion = expectation(description: "previous day delete")
            store.deleteEvents(since: cutoff) { result in
                XCTAssertEqual(try? result.get(), 1)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            let rows = try Data(contentsOf: file).split(separator: 0x0A)
            let remaining = rows.compactMap {
                try? JSONDecoder.iso8601.decode(HistoryEvent.self, from: Data($0))
            }
            XCTAssertEqual(remaining.map(\.sessionID), [retained.sessionID])
            XCTAssertEqual(store.deletionMetrics.filesSkippedBeforeCutoff, 0)
            XCTAssertEqual(store.deletionMetrics.filesOpened, 1)
        }

        func testConcurrentAppenderReopensPathAfterDeletionCommit() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let appender = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            _ = try appender.appendAndWait(
                HistoryEvent(
                    sessionID: "retained-before-commit",
                    timestamp: cutoff.addingTimeInterval(-60),
                    kind: .heartbeat
                )
            )
            _ = try appender.appendAndWait(
                HistoryEvent(
                    sessionID: "deleted-by-commit",
                    timestamp: cutoff.addingTimeInterval(60),
                    kind: .heartbeat
                )
            )
            try appender.flushAndWait()

            let commitEntered = DispatchSemaphore(value: 0)
            let releaseCommit = DispatchSemaphore(value: 0)
            let deletingStore = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false,
                beforeDeletionCommit: {
                    commitEntered.signal()
                    releaseCommit.wait()
                }
            )
            let deletionFinished = expectation(description: "deletion finished")
            deletingStore.deleteEvents(since: cutoff) { result in
                XCTAssertEqual(try? result.get(), 1)
                deletionFinished.fulfill()
            }
            XCTAssertEqual(commitEntered.wait(timeout: .now() + 2), .success)

            let appendFinished = DispatchSemaphore(value: 0)
            let appendQueue = DispatchQueue(label: "retention-test-concurrent-append")
            var appendError: Error?
            appendQueue.async {
                do {
                    _ = try appender.appendAndWait(
                        HistoryEvent(
                            sessionID: "appended-after-commit",
                            timestamp: cutoff.addingTimeInterval(120),
                            kind: .heartbeat
                        )
                    )
                } catch {
                    appendError = error
                }
                appendFinished.signal()
            }
            XCTAssertEqual(appendFinished.wait(timeout: .now() + 0.1), .timedOut)
            releaseCommit.signal()
            wait(for: [deletionFinished], timeout: 2)
            XCTAssertEqual(appendFinished.wait(timeout: .now() + 2), .success)
            appendQueue.sync {}
            XCTAssertNil(appendError)
            try appender.flushAndWait()

            let file = events.appendingPathComponent("2026-08-23.jsonl")
            let sessions = try Data(contentsOf: file).split(separator: 0x0A).compactMap {
                try? JSONDecoder.iso8601.decode(HistoryEvent.self, from: Data($0)).sessionID
            }
            XCTAssertEqual(sessions, ["retained-before-commit", "appended-after-commit"])
        }

        func testJSONLStoreRejectsFinalAndAncestorDirectorySymlinks() throws {
            let root = try makeTemporaryDirectory()
            let actualParent = root.appendingPathComponent("actual", isDirectory: true)
            let actualEvents = actualParent.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(
                at: actualEvents,
                withIntermediateDirectories: true
            )
            let finalLink = root.appendingPathComponent("events-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: finalLink,
                withDestinationURL: actualEvents
            )
            XCTAssertThrowsError(
                try JSONLStore(
                    retentionDays: 0,
                    eventsDirectory: finalLink,
                    prepareApplicationStorage: false
                )
            )

            let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: parentLink,
                withDestinationURL: actualParent
            )
            XCTAssertThrowsError(
                try JSONLStore(
                    retentionDays: 0,
                    eventsDirectory: parentLink.appendingPathComponent("events"),
                    prepareApplicationStorage: false
                )
            )
        }

        func testJSONLStoreRejectsHardLinkedEventForAppendAndDeletion() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let cutoff = Self.date(year: 2026, month: 8, day: 23, hour: 12)
            let external = root.appendingPathComponent("external.jsonl")
            var original = try JSONEncoder.iso8601.encode(
                HistoryEvent(
                    sessionID: "hard-linked",
                    timestamp: cutoff.addingTimeInterval(60),
                    kind: .heartbeat
                )
            )
            original.append(0x0A)
            try original.write(to: external)
            let linked = events.appendingPathComponent("2026-08-23.jsonl")
            XCTAssertEqual(link(external.path, linked.path), 0)

            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false
            )
            XCTAssertThrowsError(
                try store.appendAndWait(
                    HistoryEvent(
                        sessionID: "must-not-append",
                        timestamp: cutoff,
                        kind: .heartbeat
                    )
                )
            )

            let detailsCompletion = expectation(description: "hardlink details rejection")
            store.deleteEvents(since: cutoff) { result in
                guard case .failure(let error) = result else {
                    XCTFail("Delete Details must reject a hard-linked event journal")
                    detailsCompletion.fulfill()
                    return
                }
                XCTAssertTrue(error.localizedDescription.contains("linked"))
                detailsCompletion.fulfill()
            }
            wait(for: [detailsCompletion], timeout: 2)

            let allCompletion = expectation(description: "hardlink delete all rejection")
            store.deleteAll { result in
                guard case .failure(let error) = result else {
                    XCTFail("Delete All must reject a hard-linked event journal")
                    allCompletion.fulfill()
                    return
                }
                XCTAssertTrue(error.localizedDescription.contains("linked"))
                allCompletion.fulfill()
            }
            wait(for: [allCompletion], timeout: 2)
            XCTAssertEqual(try Data(contentsOf: external), original)
            XCTAssertEqual(try Data(contentsOf: linked), original)
        }

        func testJSONLStoreScavengesOnlyBoundedStrictStaleTemporaries() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            var staleFiles: [URL] = []
            for _ in 0...JSONLStore.maximumScavengedDeletionTemporaries {
                let file = events.appendingPathComponent(
                    ".2026-08-23.jsonl.delete-\(UUID().uuidString).tmp"
                )
                try Data("stale".utf8).write(to: file)
                staleFiles.append(file)
            }
            let now = Date().addingTimeInterval(48 * 60 * 60)
            let fresh = events.appendingPathComponent(
                ".2026-08-23.jsonl.delete-\(UUID().uuidString).tmp"
            )
            try Data("fresh".utf8).write(to: fresh)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
            let nearMiss = events.appendingPathComponent(".2026-08-23.jsonl.delete-not-a-uuid.tmp")
            try Data("near-miss".utf8).write(to: nearMiss)
            let external = root.appendingPathComponent("external-temp")
            try Data("hard-linked".utf8).write(to: external)
            let hardLinked = events.appendingPathComponent(
                ".2026-08-23.jsonl.delete-\(UUID().uuidString).tmp"
            )
            XCTAssertEqual(link(external.path, hardLinked.path), 0)

            _ = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false,
                scavengerNow: now
            )

            XCTAssertEqual(
                staleFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
                1
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: hardLinked.path))
            XCTAssertEqual(try Data(contentsOf: external), Data("hard-linked".utf8))
        }

        func testJSONLStoreScavengerSkipsLockedDeletionTemporary() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let stale = events.appendingPathComponent(
                ".2026-08-23.jsonl.delete-\(UUID().uuidString).tmp"
            )
            try Data("active-temporary".utf8).write(to: stale)
            let descriptor = open(stale.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { _ = close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { _ = flock(descriptor, LOCK_UN) }
            let now = Date().addingTimeInterval(48 * 60 * 60)

            _ = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: events,
                prepareApplicationStorage: false,
                scavengerNow: now
            )

            XCTAssertEqual(try Data(contentsOf: stale), Data("active-temporary".utf8))
        }

        func testJSONLStoreScavengerRevalidatesLockedCandidateBeforeUnlink() throws {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let stale = events.appendingPathComponent(
                ".2026-08-23.jsonl.delete-\(UUID().uuidString).tmp"
            )
            let moved = root.appendingPathComponent("original-temp")
            let original = Data("original-temporary".utf8)
            let replacement = Data("replacement-must-survive".utf8)
            try original.write(to: stale)
            let now = Date().addingTimeInterval(48 * 60 * 60)
            var didReplace = false

            XCTAssertThrowsError(
                try JSONLStore(
                    retentionDays: 0,
                    eventsDirectory: events,
                    prepareApplicationStorage: false,
                    scavengerNow: now,
                    beforeScavengerUnlink: { candidate in
                        guard !didReplace else { return }
                        didReplace = true
                        XCTAssertEqual(candidate.lastPathComponent, stale.lastPathComponent)
                        XCTAssertEqual(rename(stale.path, moved.path), 0)
                        XCTAssertTrue(
                            FileManager.default.createFile(
                                atPath: stale.path,
                                contents: replacement,
                                attributes: [.posixPermissions: 0o600]
                            ))
                    }
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed"))
            }

            XCTAssertTrue(didReplace)
            XCTAssertEqual(try Data(contentsOf: stale), replacement)
            XCTAssertEqual(try Data(contentsOf: moved), original)
        }

        func testMigratedPolicyCannotDeleteUntilExplicitlyActivated() throws {
            let fixture = try makeFixture()
            let oldEvent = fixture.events.appendingPathComponent("2020-01-01.jsonl")
            try Data("event\n".utf8).write(to: oldEvent)
            // This is the pre-hardening marker. It must not activate a newly
            // migrated policy because it is not bound to the policy contents.
            try Data("explicit-settings-save\n".utf8).write(to: fixture.activation)

            let store = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            store.applyCleanup(now: fixture.now)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldEvent.path))

            try store.updateDetailedRetention(fromLegacyDays: 1)
            store.applyCleanup(now: fixture.now)
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldEvent.path))
        }

        func testCleanupOnlyUnlinksKnownRegularArtifacts() throws {
            let fixture = try makeFixture()
            let oldEvent = fixture.events.appendingPathComponent("2020-01-01.jsonl")
            let unknown = fixture.events.appendingPathComponent("2020-01-01.jsonl.backup")
            let invalidDay = fixture.events.appendingPathComponent("2020-99-99.jsonl")
            let disguisedDirectory = fixture.events.appendingPathComponent(
                "2020-01-02.jsonl",
                isDirectory: true
            )
            let externalTarget = fixture.root.appendingPathComponent("protected-target.txt")
            let linkedEvent = fixture.events.appendingPathComponent("2020-01-03.jsonl")
            let currentEvent = fixture.events.appendingPathComponent("2026-08-23.jsonl")

            try Data("event\n".utf8).write(to: oldEvent)
            try Data("unknown\n".utf8).write(to: unknown)
            try Data("invalid\n".utf8).write(to: invalidDay)
            try FileManager.default.createDirectory(
                at: disguisedDirectory,
                withIntermediateDirectories: false
            )
            try Data("do-not-delete\n".utf8).write(to: externalTarget)
            try FileManager.default.createSymbolicLink(
                at: linkedEvent,
                withDestinationURL: externalTarget
            )
            try Data("today\n".utf8).write(to: currentEvent)

            let store = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            try store.updateDetailedRetention(fromLegacyDays: 1)
            store.applyCleanup(now: fixture.now)

            XCTAssertFalse(FileManager.default.fileExists(atPath: oldEvent.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: invalidDay.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: disguisedDirectory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkedEvent.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: currentEvent.path))
            XCTAssertEqual(
                try Data(contentsOf: externalTarget),
                Data("do-not-delete\n".utf8)
            )
        }

        func testNegativeExplicitPolicyIsActivatedAsIndefiniteRetention() throws {
            let fixture = try makeFixture()
            let oldEvent = fixture.events.appendingPathComponent("2020-01-01.jsonl")
            try Data("event\n".utf8).write(to: oldEvent)

            let store = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            try store.updateDetailedRetention(fromLegacyDays: Int.min)
            store.applyCleanup(now: fixture.now)

            XCTAssertNil(store.policy.detailedEvents.days)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldEvent.path))
        }

        func testActivationSymlinkCannotAuthorizeCleanup() throws {
            let fixture = try makeFixture()
            let oldEvent = fixture.events.appendingPathComponent("2020-01-01.jsonl")
            try Data("event\n".utf8).write(to: oldEvent)

            var store: HistoryRetentionStore? = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            try store?.updateDetailedRetention(fromLegacyDays: 1)
            let externalActivation = fixture.root.appendingPathComponent("external-activation.json")
            try FileManager.default.moveItem(
                at: fixture.activation,
                to: externalActivation
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.activation,
                withDestinationURL: externalActivation
            )
            store = nil

            let relaunched = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            relaunched.applyCleanup(now: fixture.now)

            XCTAssertTrue(FileManager.default.fileExists(atPath: oldEvent.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.activation.path))
            XCTAssertFalse(try Data(contentsOf: externalActivation).isEmpty)
        }

        func testUnsupportedPersistedPolicyFailsClosedAndCannotBeSaved() throws {
            let fixture = try makeFixture()
            let oldEvent = fixture.events.appendingPathComponent("2020-01-01.jsonl")
            try Data("event\n".utf8).write(to: oldEvent)
            let unsupported = HistoryRetentionPolicy(
                schemaVersion: 999,
                detailedEvents: RetentionDuration(days: 1),
                semanticSnapshots: .indefinite,
                memories: .indefinite,
                analysisCaches: .indefinite,
                minuteSeals: .indefinite,
                anchorReceipts: .indefinite
            )
            try JSONEncoder().encode(unsupported).write(to: fixture.policy)

            let store = HistoryRetentionStore(
                legacyRetentionDays: 1,
                storage: fixture.storage,
                diagnostics: { _ in }
            )
            store.applyCleanup(now: fixture.now)

            XCTAssertTrue(FileManager.default.fileExists(atPath: oldEvent.path))
            XCTAssertThrowsError(try store.save(unsupported))
        }

        private func makeFixture() throws -> Fixture {
            let root = try makeTemporaryDirectory()
            let events = root.appendingPathComponent("events", isDirectory: true)
            let policy = root.appendingPathComponent("retention-policy.json")
            let activation = root.appendingPathComponent("retention-policy-activated")
            let prepare = {
                try FileManager.default.createDirectory(
                    at: events,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try prepare()
            let storage = HistoryRetentionStorage(
                policyFile: policy,
                activationFile: activation,
                artifactDirectories: [
                    HistoryRetentionArtifactDirectory(
                        directory: events,
                        dataClass: .detailedEvents,
                        allowedSuffixes: [".jsonl"]
                    )
                ],
                prepare: prepare
            )
            return Fixture(
                root: root,
                events: events,
                policy: policy,
                activation: activation,
                storage: storage,
                now: Self.date(year: 2026, month: 8, day: 23, hour: 12)
            )
        }

        private func makeTemporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-retention-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            temporaryDirectories.append(directory)
            return directory
        }

        private static func date(
            year: Int,
            month: Int,
            day: Int,
            hour: Int
        ) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(
                    timeZone: .current,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                )
            )!
        }

        private struct Fixture {
            let root: URL
            let events: URL
            let policy: URL
            let activation: URL
            let storage: HistoryRetentionStorage
            let now: Date
        }
    }

    extension JSONEncoder {
        fileprivate static var iso8601: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return encoder
        }
    }

    extension JSONDecoder {
        fileprivate static var iso8601: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }
#endif
