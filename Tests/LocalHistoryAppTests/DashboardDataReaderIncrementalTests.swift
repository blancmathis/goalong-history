#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class DashboardDataReaderIncrementalTests: XCTestCase {
        func testLargeJournalUnchangedRefreshReadsZeroBytesAndCacheStaysBounded() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let eventCount = 12_000
            var journal = Data()
            for index in 0..<eventCount {
                journal.append(
                    try line(
                        event(
                            id: "large-\(index)",
                            timestamp: day.addingTimeInterval(TimeInterval(index) * 0.05)
                        )
                    )
                )
            }
            try journal.write(to: eventURL)

            var limits = DashboardDataReader.Limits.production
            limits.maximumEventFiles = 2
            limits.maximumSealFiles = 1
            limits.maximumReceiptFiles = 2
            limits.maximumCachedRows = 15_000
            limits.readChunkBytes = 4 * 1_024
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            let first = reader.snapshot(for: day)
            let firstDiagnostics = reader.diagnostics
            XCTAssertEqual(first.eventCount, eventCount)
            XCTAssertEqual(firstDiagnostics.bytesRead, Int64(journal.count + 256))
            XCTAssertEqual(firstDiagnostics.transitions[eventURL.path], .initial)
            XCTAssertEqual(firstDiagnostics.cachedEventFiles, 1)
            XCTAssertLessThanOrEqual(firstDiagnostics.cachedRows, limits.maximumCachedRows)
            XCTAssertLessThanOrEqual(
                firstDiagnostics.cachedEstimatedBytes,
                limits.maximumCachedEstimatedBytes
            )
            XCTAssertLessThanOrEqual(
                firstDiagnostics.cachedDerivedEstimatedBytes,
                limits.maximumDerivedEstimatedBytes
            )

            let second = reader.snapshot(for: day)
            let secondDiagnostics = reader.diagnostics
            XCTAssertEqual(second.eventCount, first.eventCount)
            XCTAssertEqual(second.activeMinutes, first.activeMinutes)
            XCTAssertEqual(second.sessions.count, first.sessions.count)
            XCTAssertEqual(secondDiagnostics.bytesRead, 0)
            XCTAssertEqual(secondDiagnostics.rowsDecoded, 0)
            XCTAssertEqual(secondDiagnostics.transitions[eventURL.path], .unchanged)

            let appended = try line(
                event(
                    id: "appended",
                    timestamp: day.addingTimeInterval(TimeInterval(eventCount) * 0.05)
                )
            )
            try append(appended, to: eventURL)
            let third = reader.snapshot(for: day)
            let thirdDiagnostics = reader.diagnostics
            XCTAssertEqual(third.eventCount, eventCount + 1)
            XCTAssertGreaterThanOrEqual(thirdDiagnostics.bytesRead, Int64(appended.count))
            XCTAssertLessThanOrEqual(
                thirdDiagnostics.bytesRead,
                Int64(appended.count + (3 * 256)),
                "Append validation may read only three bounded 256-byte prefix guards."
            )
            XCTAssertEqual(thirdDiagnostics.transitions[eventURL.path], .appended)
            XCTAssertEqual(
                thirdDiagnostics.appendCacheMutationCount,
                1,
                "A journal suffix must extend the uniquely-held cache buffer in place."
            )

            for date in [
                makeDay(year: 2026, month: 8, day: 22),
                makeDay(year: 2026, month: 8, day: 23),
            ] {
                let key = dayKey(date)
                try line(event(id: key, timestamp: date)).write(
                    to: fixture.events.appendingPathComponent("\(key).jsonl")
                )
                _ = reader.snapshot(for: date)
            }
            let bounded = reader.diagnostics
            XCTAssertLessThanOrEqual(bounded.cachedEventFiles, limits.maximumEventFiles)
            XCTAssertLessThanOrEqual(bounded.cachedSealFiles, limits.maximumSealFiles)
            XCTAssertLessThanOrEqual(
                bounded.cachedRows,
                limits.maximumCachedRows,
                "All three typed journal caches share one explicit row ceiling."
            )
            XCTAssertLessThanOrEqual(
                bounded.cachedEstimatedBytes,
                limits.maximumCachedEstimatedBytes,
                "All retained decoded rows share one encoded-byte ceiling."
            )
            print(
                "Dashboard incremental fixture bytes=\(journal.count) "
                    + "unchanged-read=\(secondDiagnostics.bytesRead) "
                    + "append-read=\(thirdDiagnostics.bytesRead) "
                    + "cached-files=\(bounded.cachedEventFiles + bounded.cachedSealFiles + bounded.cachedReceiptFiles) "
                    + "peak-cached-rows=\(firstDiagnostics.cachedRows) "
                    + "peak-estimated-cache-bytes=\(firstDiagnostics.cachedEstimatedBytes)"
            )
            reader.discardTransientCaches()
            let discarded = reader.diagnostics
            XCTAssertEqual(discarded.cachedEventFiles, 0)
            XCTAssertEqual(discarded.cachedSealFiles, 0)
            XCTAssertEqual(discarded.cachedReceiptFiles, 0)
            XCTAssertEqual(discarded.cachedDaySnapshots, 0)
            XCTAssertEqual(discarded.cachedRows, 0)
            XCTAssertEqual(discarded.cachedEstimatedBytes, 0)
            XCTAssertEqual(discarded.cachedReceiptDirectoryEntries, 0)
            XCTAssertEqual(discarded.cachedReceiptDirectoryEstimatedBytes, 0)
        }

        func testTypedJournalsShareOneGlobalBudgetWithoutLosingIncrementalRefresh() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let receiptURL = fixture.receipts.appendingPathComponent("2026-08-24.receipts.jsonl")
            var eventJournal = Data()
            var sealJournal = Data()
            var receiptJournal = Data()
            for index in 0..<4 {
                let sequence = UInt64(index + 1)
                eventJournal.append(
                    try line(
                        event(
                            id: "global-budget-\(index)",
                            timestamp: day.addingTimeInterval(TimeInterval(index))
                        )
                    )
                )
                sealJournal.append(try line(seal(sequence: sequence, day: day, minute: index)))
                receiptJournal.append(try line(receipt(sequence: sequence, receivedAt: day)))
            }
            try eventJournal.write(to: eventURL)
            try sealJournal.write(to: sealURL)
            try receiptJournal.write(to: receiptURL)

            var limits = DashboardDataReader.Limits.production
            limits.maximumCachedRows = 8
            limits.maximumCachedEstimatedBytes = .max
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            let first = reader.snapshot(for: day)
            let firstDiagnostics = reader.diagnostics
            XCTAssertEqual(first.eventCount, 4)
            XCTAssertEqual(first.sealedMinutes, 4)
            XCTAssertEqual(first.liveAnchoredMinutes, 4)
            XCTAssertEqual(firstDiagnostics.cachedEventFiles, 1)
            XCTAssertEqual(firstDiagnostics.cachedSealFiles, 1)
            XCTAssertEqual(
                firstDiagnostics.cachedReceiptFiles,
                0,
                "Receipt rows are reconstructed cheaply and should yield to the shared budget."
            )
            XCTAssertLessThanOrEqual(firstDiagnostics.cachedRows, limits.maximumCachedRows)
            XCTAssertLessThanOrEqual(
                firstDiagnostics.cachedEstimatedBytes,
                limits.maximumCachedEstimatedBytes
            )

            let unchanged = reader.snapshot(for: day)
            XCTAssertEqual(unchanged.eventCount, first.eventCount)
            XCTAssertEqual(unchanged.liveAnchoredMinutes, first.liveAnchoredMinutes)
            XCTAssertEqual(
                reader.diagnostics.bytesRead,
                0,
                "The retained event/seal cursors and bounded receipt lookup must keep refresh incremental."
            )

            reader.discardTransientCaches()
            var byteLimits = DashboardDataReader.Limits.production
            byteLimits.maximumCachedRows = 100
            byteLimits.maximumCachedEstimatedBytes = Int64(
                eventJournal.count + sealJournal.count
            )
            let byteBoundReader = DashboardDataReader(
                rootDirectory: fixture.root,
                limits: byteLimits
            )
            let byteBoundSnapshot = byteBoundReader.snapshot(for: day)
            XCTAssertEqual(byteBoundSnapshot.liveAnchoredMinutes, 4)
            XCTAssertEqual(byteBoundReader.diagnostics.cachedEventFiles, 1)
            XCTAssertEqual(byteBoundReader.diagnostics.cachedSealFiles, 1)
            XCTAssertEqual(
                byteBoundReader.diagnostics.cachedReceiptFiles,
                1,
                "The compact dashboard event projection may leave room for the receipt cursor."
            )
            XCTAssertLessThanOrEqual(
                byteBoundReader.diagnostics.cachedEstimatedBytes,
                byteLimits.maximumCachedEstimatedBytes,
                "Encoded-byte estimates from all typed journals must share one ceiling."
            )
        }

        func testReceiptIndexAppendsIncrementallyAndStorageScanIsSeparateAndRateLimited() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let receiptURL = fixture.receipts.appendingPathComponent("2026-08-24.receipts.jsonl")
            try line(seal(sequence: 1, day: day, minute: 0)).write(to: sealURL)
            try line(receipt(sequence: 1, receivedAt: day)).write(to: receiptURL)

            var clock = day
            var limits = DashboardDataReader.Limits.production
            limits.metadataRefreshInterval = 900
            let reader = DashboardDataReader(
                rootDirectory: fixture.root,
                limits: limits,
                now: { clock }
            )

            let first = reader.snapshot(for: day)
            let firstDiagnostics = reader.diagnostics
            XCTAssertEqual(first.sealedMinutes, 1)
            XCTAssertEqual(first.liveAnchoredMinutes, 1)
            XCTAssertEqual(first.storageBytes, 0, "Normal data refresh must not walk storage.")
            XCTAssertEqual(firstDiagnostics.receiptDirectoryScanCount, 1)
            XCTAssertEqual(firstDiagnostics.cachedReceiptDirectoryEntries, 1)

            let unchanged = reader.snapshot(for: day)
            let unchangedDiagnostics = reader.diagnostics
            XCTAssertEqual(unchanged.liveAnchoredMinutes, 1)
            XCTAssertEqual(unchangedDiagnostics.bytesRead, 0)
            XCTAssertEqual(
                transition(for: receiptURL.lastPathComponent, in: unchangedDiagnostics),
                .unchanged
            )
            XCTAssertEqual(unchangedDiagnostics.storageScanCount, 0)
            XCTAssertEqual(
                unchangedDiagnostics.receiptDirectoryScanCount,
                0,
                "An unchanged directory identity must reuse the bounded receipt inventory."
            )

            let appendedSeal = try line(seal(sequence: 2, day: day, minute: 1))
            let appendedReceipt = try line(
                receipt(sequence: 2, receivedAt: day.addingTimeInterval(60))
            )
            try append(appendedSeal, to: sealURL)
            try append(appendedReceipt, to: receiptURL)
            let appended = reader.snapshot(for: day)
            let appendedDiagnostics = reader.diagnostics
            XCTAssertEqual(appended.sealedMinutes, 2)
            XCTAssertEqual(appended.liveAnchoredMinutes, 2)
            let appendedPayloadBytes = Int64(appendedSeal.count + appendedReceipt.count)
            XCTAssertGreaterThanOrEqual(appendedDiagnostics.bytesRead, appendedPayloadBytes)
            XCTAssertLessThanOrEqual(
                appendedDiagnostics.bytesRead,
                appendedPayloadBytes + Int64(6 * 256),
                "Each appended journal may read only three bounded 256-byte prefix guards."
            )
            XCTAssertEqual(appendedDiagnostics.transitions[sealURL.path], .appended)
            XCTAssertEqual(
                transition(for: receiptURL.lastPathComponent, in: appendedDiagnostics),
                .appended
            )
            XCTAssertEqual(
                appendedDiagnostics.receiptDirectoryScanCount,
                0,
                "Appending a receipt must invalidate only the watched file cursor."
            )

            XCTAssertTrue(reader.refreshMetadataIfNeeded(force: false))
            XCTAssertEqual(reader.diagnostics.storageScanCount, 1)
            let withMetadata = reader.applyingCachedMetadata(to: appended)
            XCTAssertGreaterThan(withMetadata.storageBytes, 0)
            XCTAssertEqual(withMetadata.availableDays.map(dayKey), ["2026-08-24"])

            clock = clock.addingTimeInterval(899)
            XCTAssertFalse(reader.refreshMetadataIfNeeded(force: false))
            XCTAssertEqual(reader.diagnostics.storageScanCount, 1)
            clock = clock.addingTimeInterval(2)
            XCTAssertTrue(reader.refreshMetadataIfNeeded(force: false))
            XCTAssertEqual(reader.diagnostics.storageScanCount, 2)
        }

        func testReplacementAndTruncationResetTheCursorWithoutDuplicatingEvents() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let rotatedURL = fixture.events.appendingPathComponent("2026-08-24.rotated.jsonl")
            try
                (try line(event(id: "one", timestamp: day))
                + line(event(id: "two", timestamp: day.addingTimeInterval(1))))
                .write(to: eventURL)
            let reader = DashboardDataReader(rootDirectory: fixture.root)
            XCTAssertEqual(reader.snapshot(for: day).eventCount, 2)

            try FileManager.default.moveItem(at: eventURL, to: rotatedURL)
            try line(event(id: "replacement", timestamp: day.addingTimeInterval(2))).write(to: eventURL)
            let replaced = reader.snapshot(for: day)
            XCTAssertEqual(replaced.eventCount, 1)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .replaced)

            let handle = try FileHandle(forWritingTo: eventURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: line(event(id: "short", timestamp: day)))
            try handle.close()
            let truncated = reader.snapshot(for: day)
            XCTAssertEqual(truncated.eventCount, 1)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .truncated)
            XCTAssertEqual(truncated.sessions.first?.latestMessage, "short")
        }

        func testSameSizeRewriteWithRestoredModificationDateInvalidatesWarmRevision() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let original = try line(event(id: "same-1", timestamp: day))
            let replacement = try line(event(id: "same-2", timestamp: day))
            XCTAssertEqual(original.count, replacement.count)
            try original.write(to: eventURL)
            let originalDate = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: eventURL.path)[.modificationDate]
                    as? Date
            )
            let reader = DashboardDataReader(rootDirectory: fixture.root)
            XCTAssertEqual(reader.snapshot(for: day).sessions.first?.latestMessage, "same-1")
            XCTAssertEqual(reader.snapshot(for: day).sessions.first?.latestMessage, "same-1")
            XCTAssertEqual(reader.diagnostics.bytesRead, 0)

            try replacement.write(to: eventURL)
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: eventURL.path
            )
            let rewritten = reader.snapshot(for: day)
            XCTAssertEqual(rewritten.eventCount, 1)
            XCTAssertEqual(rewritten.sessions.first?.latestMessage, "same-2")
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .rewritten)
        }

        func testPartialFinalLineIsDeferredAndPublishedExactlyOnceWhenCompleted() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let completeLine = try line(event(id: "partial", timestamp: day))
            try Data(completeLine.dropLast()).write(to: eventURL)
            let reader = DashboardDataReader(rootDirectory: fixture.root)

            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(reader.diagnostics.bytesRead, 0)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .unchanged)

            try append(Data([0x0A]), to: eventURL)
            XCTAssertEqual(reader.snapshot(for: day).eventCount, 1)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .appended)
            XCTAssertEqual(reader.snapshot(for: day).eventCount, 1)
            XCTAssertEqual(reader.diagnostics.bytesRead, 0)
        }

        func testUnavailableSymlinkSourceKeepsLastKnownSnapshotWithoutFollowingIt() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let externalURL = fixture.root.appendingPathComponent("external.jsonl")
            try line(event(id: "trusted", timestamp: day)).write(to: eventURL)
            try line(event(id: "outside", timestamp: day.addingTimeInterval(1))).write(
                to: externalURL
            )
            let reader = DashboardDataReader(rootDirectory: fixture.root)
            XCTAssertEqual(reader.snapshot(for: day).sessions.first?.latestMessage, "trusted")

            try FileManager.default.removeItem(at: eventURL)
            try FileManager.default.createSymbolicLink(at: eventURL, withDestinationURL: externalURL)
            let unavailable = reader.snapshot(for: day)
            XCTAssertEqual(unavailable.eventCount, 1)
            XCTAssertEqual(unavailable.sessions.first?.latestMessage, "trusted")
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .unavailable)
            XCTAssertEqual(reader.diagnostics.snapshotState, .lastKnownGood)
            XCTAssertEqual(reader.diagnostics.partialSourcePaths, [eventURL.path])
        }

        func testFreshEventsAreNotMixedWithUnavailableLastKnownSeals() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let externalURL = fixture.root.appendingPathComponent("external-seals.jsonl")
            let firstEvent = try line(event(id: "first", timestamp: day))
            let secondEvent = try line(
                event(id: "second", timestamp: day.addingTimeInterval(1))
            )
            let firstSeal = try line(seal(sequence: 1, day: day, minute: 0))
            let secondSeal = try line(seal(sequence: 2, day: day, minute: 1))
            try firstEvent.write(to: eventURL)
            try firstSeal.write(to: sealURL)
            try secondSeal.write(to: externalURL)
            let reader = DashboardDataReader(rootDirectory: fixture.root)
            let baseline = reader.snapshot(for: day)
            XCTAssertEqual(baseline.eventCount, 1)
            XCTAssertEqual(baseline.sealedMinutes, 1)

            try append(secondEvent, to: eventURL)
            try FileManager.default.removeItem(at: sealURL)
            try FileManager.default.createSymbolicLink(
                at: sealURL,
                withDestinationURL: externalURL
            )
            let lastKnown = reader.snapshot(for: day)
            XCTAssertEqual(lastKnown.eventCount, 1)
            XCTAssertEqual(lastKnown.sealedMinutes, 1)
            XCTAssertEqual(reader.diagnostics.snapshotState, .lastKnownGood)
            XCTAssertEqual(reader.diagnostics.partialSourcePaths, [sealURL.path])

            try FileManager.default.removeItem(at: sealURL)
            try (firstSeal + secondSeal).write(to: sealURL)
            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.eventCount, 2)
            XCTAssertEqual(recovered.sealedMinutes, 2)
            XCTAssertEqual(reader.diagnostics.snapshotState, .fresh)
            XCTAssertTrue(reader.diagnostics.partialSourcePaths.isEmpty)
        }

        func testUnstableSealReadKeepsWholePreviousSnapshotUntilRecovery() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let displacedURL = fixture.seals.appendingPathComponent("displaced.seals.jsonl")
            let firstEvent = try line(event(id: "first", timestamp: day))
            let secondEvent = try line(
                event(id: "second", timestamp: day.addingTimeInterval(1))
            )
            let firstSeal = try line(seal(sequence: 1, day: day, minute: 0))
            let secondSeal = try line(seal(sequence: 2, day: day, minute: 1))
            try firstEvent.write(to: eventURL)
            try firstSeal.write(to: sealURL)

            var replaceSealDuringRead = false
            let reader = DashboardDataReader(
                rootDirectory: fixture.root,
                afterJournalReadForTesting: { url in
                    guard replaceSealDuringRead, url.path == sealURL.path else { return }
                    replaceSealDuringRead = false
                    let bytes = try! Data(contentsOf: sealURL)
                    try! FileManager.default.moveItem(at: sealURL, to: displacedURL)
                    try! bytes.write(to: sealURL)
                }
            )
            XCTAssertEqual(reader.snapshot(for: day).eventCount, 1)

            try append(secondEvent, to: eventURL)
            try append(secondSeal, to: sealURL)
            replaceSealDuringRead = true
            let lastKnown = reader.snapshot(for: day)
            XCTAssertEqual(lastKnown.eventCount, 1)
            XCTAssertEqual(lastKnown.sealedMinutes, 1)
            XCTAssertEqual(reader.diagnostics.transitions[sealURL.path], .unstable)
            XCTAssertEqual(reader.diagnostics.snapshotState, .lastKnownGood)
            XCTAssertEqual(reader.diagnostics.partialSourcePaths, [sealURL.path])

            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.eventCount, 2)
            XCTAssertEqual(recovered.sealedMinutes, 2)
            XCTAssertEqual(reader.diagnostics.snapshotState, .fresh)
        }

        func testNegativeReceiptLookupDoesNotThrashWhenFileCacheIsSmallerThanDirectory() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            try line(seal(sequence: 999, day: day, minute: 0)).write(
                to: fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            )
            for index in 0..<40 {
                try line(receipt(sequence: UInt64(index + 1), receivedAt: day)).write(
                    to: fixture.receipts.appendingPathComponent(
                        String(format: "receipt-%03d.jsonl", index)
                    )
                )
            }
            var limits = DashboardDataReader.Limits.production
            limits.maximumReceiptFiles = 4
            limits.maximumReceiptLookups = 2
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 0)
            let cold = reader.diagnostics
            XCTAssertGreaterThan(cold.bytesRead, 0)
            XCTAssertEqual(cold.receiptDirectoryScanCount, 1)
            XCTAssertEqual(cold.cachedReceiptDirectoryEntries, 40)
            XCTAssertLessThan(
                cold.cachedReceiptDirectoryEstimatedBytes,
                64 * 1_024,
                "The retained receipt inventory contains only bounded file references."
            )
            XCTAssertLessThanOrEqual(cold.receiptFilesExamined, 40)
            XCTAssertLessThanOrEqual(cold.cachedReceiptFiles, 4)
            print(
                "Dashboard receipt inventory entries=\(cold.cachedReceiptDirectoryEntries) "
                    + "estimated-bytes=\(cold.cachedReceiptDirectoryEstimatedBytes)"
            )

            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 0)
            let warm = reader.diagnostics
            XCTAssertEqual(
                warm.bytesRead,
                0,
                "A bounded negative receipt lookup must avoid rereading evicted files."
            )
            XCTAssertEqual(warm.receiptDirectoryScanCount, 0)
            XCTAssertEqual(warm.receiptFilesExamined, 0)

            let newest = fixture.receipts.appendingPathComponent("receipt-039.jsonl")
            try append(line(receipt(sequence: 999, receivedAt: day)), to: newest)
            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 1)
            XCTAssertLessThanOrEqual(reader.diagnostics.cachedReceiptFiles, 4)
        }

        func testReceiptDirectoryEntryBudgetKeepsLastKnownGoodAndSkipsWarmRescan() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let receiptURL = fixture.receipts.appendingPathComponent(
                "2026-08-24.receipts.jsonl"
            )
            try line(seal(sequence: 1, day: day, minute: 0)).write(to: sealURL)
            try line(receipt(sequence: 1, receivedAt: day)).write(to: receiptURL)

            var limits = DashboardDataReader.Limits.production
            limits.maximumReceiptDirectoryEntries = 3
            limits.maximumReceiptDirectoryEnumerationSeconds = 0
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)
            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 1)

            var decoys = [URL]()
            for index in 0..<3 {
                let url = fixture.receipts.appendingPathComponent("decoy-\(index).jsonl")
                try line(receipt(sequence: UInt64(index + 10), receivedAt: day)).write(to: url)
                decoys.append(url)
            }
            try append(line(seal(sequence: 2, day: day, minute: 1)), to: sealURL)

            let lastKnown = reader.snapshot(for: day)
            let overBudget = reader.diagnostics
            XCTAssertEqual(lastKnown.sealedMinutes, 1)
            XCTAssertEqual(lastKnown.liveAnchoredMinutes, 1)
            XCTAssertEqual(overBudget.snapshotState, .lastKnownGood)
            XCTAssertEqual(
                overBudget.budgetExceeded[fixture.receipts.path],
                .directoryEntries
            )
            XCTAssertEqual(overBudget.receiptDirectoryScanCount, 1)

            let warm = reader.snapshot(for: day)
            let warmDiagnostics = reader.diagnostics
            XCTAssertEqual(warm.sealedMinutes, 1)
            XCTAssertEqual(warmDiagnostics.bytesRead, 0)
            XCTAssertEqual(warmDiagnostics.receiptDirectoryScanCount, 0)
            XCTAssertGreaterThanOrEqual(warmDiagnostics.skippedOverBudgetRevisions, 1)

            for decoy in decoys {
                try FileManager.default.removeItem(at: decoy)
            }
            try append(line(receipt(sequence: 2, receivedAt: day)), to: receiptURL)
            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.sealedMinutes, 2)
            XCTAssertEqual(recovered.liveAnchoredMinutes, 2)
            XCTAssertEqual(reader.diagnostics.snapshotState, .fresh)
            XCTAssertLessThanOrEqual(
                reader.diagnostics.cachedReceiptDirectoryEntries,
                limits.maximumReceiptDirectoryEntries
            )

            try FileManager.default.removeItem(at: receiptURL)
            let deleted = reader.snapshot(for: day)
            XCTAssertEqual(deleted.sealedMinutes, 2)
            XCTAssertEqual(deleted.liveAnchoredMinutes, 0)
            XCTAssertEqual(reader.diagnostics.snapshotState, .fresh)
            XCTAssertEqual(reader.diagnostics.cachedReceiptDirectoryEntries, 0)
        }

        func testReceiptFileBudgetIsWarmAndWatchedAppendRecoversWithoutDirectoryScan() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let sealURL = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let receiptURL = fixture.receipts.appendingPathComponent(
                "2026-08-24.receipts.jsonl"
            )
            try line(seal(sequence: 1, day: day, minute: 0)).write(to: sealURL)
            try line(receipt(sequence: 1, receivedAt: day)).write(to: receiptURL)
            for index in 0..<4 {
                try line(receipt(sequence: UInt64(index + 10), receivedAt: day)).write(
                    to: fixture.receipts.appendingPathComponent("older-\(index).jsonl")
                )
            }

            var limits = DashboardDataReader.Limits.production
            limits.maximumReceiptFilesPerLookup = 2
            limits.maximumReceiptDirectoryEnumerationSeconds = 0
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)
            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 1)

            try append(line(seal(sequence: 2, day: day, minute: 1)), to: sealURL)
            let lastKnown = reader.snapshot(for: day)
            XCTAssertEqual(lastKnown.sealedMinutes, 1)
            XCTAssertEqual(reader.diagnostics.snapshotState, .lastKnownGood)
            XCTAssertEqual(
                reader.diagnostics.budgetExceeded[fixture.receipts.path],
                .receiptFiles
            )
            XCTAssertLessThanOrEqual(reader.diagnostics.receiptFilesExamined, 2)

            XCTAssertEqual(reader.snapshot(for: day).sealedMinutes, 1)
            let warm = reader.diagnostics
            XCTAssertEqual(warm.bytesRead, 0)
            XCTAssertEqual(warm.receiptFilesExamined, 0)
            XCTAssertGreaterThanOrEqual(warm.skippedOverBudgetRevisions, 1)

            try append(line(receipt(sequence: 2, receivedAt: day)), to: receiptURL)
            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.sealedMinutes, 2)
            XCTAssertEqual(recovered.liveAnchoredMinutes, 2)
            XCTAssertEqual(reader.diagnostics.receiptDirectoryScanCount, 0)
            XCTAssertEqual(reader.diagnostics.snapshotState, .fresh)
        }

        func testReceiptLookupPrioritizesAdjacentDayBeforeDistantHistory() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            try line(seal(sequence: 99, day: day, minute: 0)).write(
                to: fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            )
            try line(receipt(sequence: 99, receivedAt: day.addingTimeInterval(86_400))).write(
                to: fixture.receipts.appendingPathComponent("2026-08-25.receipts.jsonl")
            )
            for date in ["2026-09-01", "2026-10-01", "2027-01-01"] {
                try line(receipt(sequence: 1, receivedAt: day)).write(
                    to: fixture.receipts.appendingPathComponent("\(date).receipts.jsonl")
                )
            }

            var limits = DashboardDataReader.Limits.production
            limits.maximumReceiptFilesPerLookup = 1
            limits.maximumReceiptDirectoryEnumerationSeconds = 0
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            let snapshot = reader.snapshot(for: day)
            XCTAssertEqual(snapshot.liveAnchoredMinutes, 1)
            XCTAssertEqual(reader.diagnostics.receiptFilesExamined, 1)
            XCTAssertTrue(reader.diagnostics.budgetExceeded.isEmpty)
        }

        func testUnavailableReceiptDirectoryKeepsLastKnownSnapshotWithoutFollowingSymlink() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let receiptURL = fixture.receipts.appendingPathComponent(
                "2026-08-24.receipts.jsonl"
            )
            try line(seal(sequence: 1, day: day, minute: 0)).write(
                to: fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            )
            try line(receipt(sequence: 1, receivedAt: day)).write(to: receiptURL)
            let reader = DashboardDataReader(rootDirectory: fixture.root)
            XCTAssertEqual(reader.snapshot(for: day).liveAnchoredMinutes, 1)

            let displaced = fixture.root.appendingPathComponent(
                "receipts-displaced",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: fixture.receipts, to: displaced)
            try FileManager.default.createSymbolicLink(
                at: fixture.receipts,
                withDestinationURL: displaced
            )

            let lastKnown = reader.snapshot(for: day)
            XCTAssertEqual(lastKnown.liveAnchoredMinutes, 1)
            XCTAssertEqual(reader.diagnostics.snapshotState, .lastKnownGood)
            XCTAssertEqual(reader.diagnostics.transitions[fixture.receipts.path], .unavailable)
            XCTAssertEqual(reader.diagnostics.partialSourcePaths, [fixture.receipts.path])
            XCTAssertEqual(reader.diagnostics.cachedReceiptDirectoryEntries, 0)
        }

        func testCancellationDoesNotPublishOrCacheAPartialRead() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            var journal = Data()
            for index in 0..<2_000 {
                journal.append(
                    try line(
                        event(
                            id: "cancel-\(index)",
                            timestamp: day.addingTimeInterval(TimeInterval(index))
                        )
                    )
                )
            }
            try journal.write(to: eventURL)
            var limits = DashboardDataReader.Limits.production
            limits.readChunkBytes = 1_024
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)
            var cancellationChecks = 0

            let cancelled = reader.snapshot(for: day) {
                cancellationChecks += 1
                return cancellationChecks > 6
            }
            XCTAssertNil(cancelled)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .cancelled)
            XCTAssertEqual(reader.diagnostics.cachedEventFiles, 0)

            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.eventCount, 2_000)
            XCTAssertEqual(reader.diagnostics.transitions[eventURL.path], .initial)
        }

        func testDashboardProjectionSkipsUnusedPayloadsWithoutChangingEvidenceSelection() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let detailed = HistoryEvent(
                schemaVersion: 2,
                id: "projected-detail",
                sessionID: "source-session-is-not-retained",
                timestamp: day,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "Projection App",
                    bundleIdentifier: "test.projection",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Useful title", role: "AXWindow", subrole: nil),
                element: ElementSnapshot(
                    role: "AXButton",
                    subrole: nil,
                    title: "Unused element payload",
                    label: nil,
                    identifier: nil,
                    isSecure: false
                ),
                url: URLSnapshot(
                    value: "https://example.test/private/path",
                    host: "example.test",
                    redactionApplied: false
                ),
                pointer: PointerSnapshot(button: "left", x: 20, y: 40, clickCount: 1),
                semanticContext: SemanticContextReference(
                    snapshotID: "semantic-payload",
                    capturedAt: day,
                    source: .visibleText,
                    contentSHA256: String(repeating: "a", count: 64),
                    characterCount: 500,
                    redacted: false,
                    truncated: false
                ),
                classification: LocalClassification(
                    category: "work",
                    isWork: true,
                    confidence: 0.9,
                    classifierVersion: "fixture"
                ),
                message: "Useful message",
                metadata: ["unused": String(repeating: "metadata", count: 64)],
                integrity: EventIntegrity(
                    sequence: 1,
                    previousEventHash: String(repeating: "b", count: 64),
                    eventRoot: String(repeating: "c", count: 64),
                    eventHash: String(repeating: "d", count: 64),
                    fieldCommitments: []
                )
            )
            let permissionGap = HistoryEvent(
                id: "permission-gap",
                sessionID: "fixture",
                timestamp: day.addingTimeInterval(1),
                kind: .permissionStatus,
                metadata: ["accessibility": "false"]
            )
            let healthyPermission = HistoryEvent(
                id: "permission-healthy",
                sessionID: "fixture",
                timestamp: day.addingTimeInterval(2),
                kind: .permissionStatus,
                metadata: ["accessibility": "true", "input_monitoring": "true"]
            )
            let observationGap = HistoryEvent(
                id: "observation-gap",
                sessionID: "fixture",
                timestamp: day.addingTimeInterval(3),
                kind: .recorderHealth,
                metadata: ["observation_gap": "true"]
            )
            let diagnostic = HistoryEvent(
                id: "diagnostic",
                sessionID: "fixture",
                timestamp: day.addingTimeInterval(4),
                kind: .diagnostic,
                message: "Not user-facing evidence"
            )
            var journal = Data()
            for event in [detailed, permissionGap, healthyPermission, observationGap, diagnostic] {
                journal.append(try line(event))
            }
            try journal.write(to: eventURL)

            let snapshot = DashboardDataReader(rootDirectory: fixture.root).snapshot(for: day)

            XCTAssertEqual(snapshot.eventCount, 3)
            XCTAssertEqual(snapshot.activeMinutes, 1)
            let projectedSession = try XCTUnwrap(
                snapshot.sessions.first { $0.id == detailed.id }
            )
            XCTAssertEqual(projectedSession.appName, "Projection App")
            XCTAssertEqual(projectedSession.windowTitle, "Useful title")
            XCTAssertEqual(projectedSession.host, "example.test")
            XCTAssertEqual(projectedSession.inputEventCount, 1)
            XCTAssertEqual(projectedSession.latestMessage, "Useful message")
        }

        func testRowBudgetStopsDuringStreamingAndWarmRevisionIsNotRescanned() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            var source = Data()
            for index in 0..<3 {
                source.append(
                    try line(
                        event(
                            id: "row-budget-\(index)",
                            timestamp: day.addingTimeInterval(TimeInterval(index))
                        )
                    )
                )
            }
            try source.write(to: eventURL)

            var limits = DashboardDataReader.Limits.production
            limits.maximumCachedRows = 2
            limits.maximumCachedEstimatedBytes = .max
            limits.readChunkBytes = 128
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            let first = reader.diagnostics
            XCTAssertEqual(first.transitions[eventURL.path], .budgetExceeded)
            XCTAssertEqual(first.budgetExceeded[eventURL.path], .retainedRows)
            XCTAssertGreaterThan(first.bytesRead, 0)
            XCTAssertEqual(first.cachedEventFiles, 0)
            XCTAssertEqual(try Data(contentsOf: eventURL), source)

            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            let warm = reader.diagnostics
            XCTAssertEqual(warm.bytesRead, 0)
            XCTAssertEqual(warm.transitions[eventURL.path], .budgetExceeded)
            XCTAssertGreaterThanOrEqual(warm.skippedOverBudgetRevisions, 1)
            XCTAssertEqual(try Data(contentsOf: eventURL), source)

            let replacement = try line(event(id: "recovered", timestamp: day))
            try replacement.write(to: eventURL)
            let recovered = reader.snapshot(for: day)
            XCTAssertEqual(recovered.eventCount, 1)
            XCTAssertEqual(recovered.sessions.first?.latestMessage, "recovered")
            XCTAssertNotEqual(reader.diagnostics.transitions[eventURL.path], .budgetExceeded)
            XCTAssertEqual(try Data(contentsOf: eventURL), replacement)
        }

        func testEncodedByteAndOversizedLineBudgetsAreExplicitAndLeaveSourceUntouched() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let ordinary = try line(event(id: "encoded-budget", timestamp: day))
            try ordinary.write(to: eventURL)

            var byteLimits = DashboardDataReader.Limits.production
            byteLimits.maximumCachedEstimatedBytes = Int64(ordinary.count / 2)
            let byteReader = DashboardDataReader(
                rootDirectory: fixture.root,
                limits: byteLimits
            )
            XCTAssertEqual(byteReader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(
                byteReader.diagnostics.budgetExceeded[eventURL.path],
                .retainedBytes
            )
            XCTAssertEqual(try Data(contentsOf: eventURL), ordinary)

            var huge = event(id: "line-budget", timestamp: day)
            huge = HistoryEvent(
                id: huge.id,
                sessionID: huge.sessionID,
                timestamp: huge.timestamp,
                kind: huge.kind,
                app: huge.app,
                window: huge.window,
                pointer: huge.pointer,
                classification: huge.classification,
                message: String(repeating: "x", count: 4_096)
            )
            let oversized = try line(huge)
            try oversized.write(to: eventURL)
            var lineLimits = DashboardDataReader.Limits.production
            lineLimits.maximumLineBytes = 512
            lineLimits.readChunkBytes = 64
            let lineReader = DashboardDataReader(
                rootDirectory: fixture.root,
                limits: lineLimits
            )
            XCTAssertEqual(lineReader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(lineReader.diagnostics.budgetExceeded[eventURL.path], .lineBytes)
            XCTAssertEqual(try Data(contentsOf: eventURL), oversized)
            XCTAssertEqual(lineReader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(lineReader.diagnostics.bytesRead, 0)
        }

        func testDerivedSnapshotBudgetIsBoundedAndWarmFailureDoesNotRebuild() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let day = makeDay(year: 2026, month: 8, day: 24)
            let eventURL = fixture.events.appendingPathComponent("2026-08-24.jsonl")
            let source = try line(event(id: "derived-budget", timestamp: day))
            try source.write(to: eventURL)

            var limits = DashboardDataReader.Limits.production
            limits.maximumDerivedEstimatedBytes = 64
            let reader = DashboardDataReader(rootDirectory: fixture.root, limits: limits)

            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            XCTAssertEqual(reader.diagnostics.transitions["snapshot"], .budgetExceeded)
            XCTAssertEqual(reader.diagnostics.budgetExceeded["snapshot"], .derivedBytes)
            XCTAssertEqual(reader.diagnostics.cachedDaySnapshots, 0)
            XCTAssertLessThanOrEqual(
                reader.diagnostics.cachedDerivedEstimatedBytes,
                limits.maximumDerivedEstimatedBytes
            )

            XCTAssertEqual(reader.snapshot(for: day).eventCount, 0)
            let warm = reader.diagnostics
            XCTAssertEqual(warm.bytesRead, 0)
            XCTAssertGreaterThanOrEqual(warm.skippedOverBudgetRevisions, 1)
            XCTAssertEqual(try Data(contentsOf: eventURL), source)
        }

        func testOptInRealDashboardRootLoadsExistingDayWithoutEmptyReplacement() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let root = environment["GOALONG_TEST_REAL_DASHBOARD_ROOT"],
                let rawDay = environment["GOALONG_TEST_REAL_DASHBOARD_DAY"]
            else {
                throw XCTSkip(
                    "Set GOALONG_TEST_REAL_DASHBOARD_ROOT and GOALONG_TEST_REAL_DASHBOARD_DAY for the local read-only probe."
                )
            }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let day = try XCTUnwrap(formatter.date(from: rawDay))
            let reader = DashboardDataReader(rootDirectory: URL(fileURLWithPath: root))

            let snapshot = reader.snapshot(for: day)
            let diagnostics = reader.diagnostics
            let transitions = diagnostics.transitions.values.map(\.rawValue).sorted()
            let limits = diagnostics.budgetExceeded.values.map(\.rawValue).sorted()
            print(
                "Real dashboard probe events=\(snapshot.eventCount) active=\(snapshot.activeMinutes) "
                    + "sessions=\(snapshot.sessions.count) state=\(diagnostics.snapshotState.rawValue) "
                    + "transitions=\(transitions.joined(separator: ",")) "
                    + "limits=\(limits.joined(separator: ",")) bytes=\(diagnostics.bytesRead) "
                    + "cache=\(diagnostics.cachedEstimatedBytes) derived=\(diagnostics.cachedDerivedEstimatedBytes)"
            )

            XCTAssertGreaterThan(snapshot.eventCount, 0)
            XCTAssertGreaterThan(snapshot.activeMinutes, 0)
            XCTAssertEqual(diagnostics.snapshotState, .fresh)
            XCTAssertTrue(diagnostics.budgetExceeded.isEmpty)
        }

        private func makeFixture() throws -> (
            root: URL,
            events: URL,
            seals: URL,
            receipts: URL
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dashboard-reader-\(UUID().uuidString)", isDirectory: true)
            let events = root.appendingPathComponent("events", isDirectory: true)
            let seals = root.appendingPathComponent("seals", isDirectory: true)
            let receipts = root.appendingPathComponent("receipts", isDirectory: true)
            for directory in [root, events, seals, receipts] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            return (root, events, seals, receipts)
        }

        private func event(id: String, timestamp: Date) -> HistoryEvent {
            HistoryEvent(
                id: id,
                sessionID: "dashboard-test",
                timestamp: timestamp,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "Fixture App",
                    bundleIdentifier: "test.fixture",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Fixture", role: "AXWindow", subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1),
                classification: LocalClassification(
                    category: "work",
                    isWork: true,
                    confidence: 1,
                    classifierVersion: "fixture"
                ),
                message: id
            )
        }

        private func seal(sequence: UInt64, day: Date, minute: Int) -> LocalMinuteSeal {
            let start = day.addingTimeInterval(TimeInterval(minute * 60))
            let coverage = CommitmentBuilder.makeMinute(
                name: "coverage",
                fields: ["states": "captured"],
                salt: Data(repeating: UInt8(sequence % 255), count: 32)
            )
            return LocalMinuteSeal(
                anchorSequence: sequence,
                minuteStart: start,
                minuteEnd: start.addingTimeInterval(60),
                minuteFields: [coverage],
                eventRoots: [],
                minuteRoot: "minute-\(sequence)",
                previousAnchorHash: "previous-\(sequence)",
                anchorHash: "anchor-\(sequence)",
                deviceID: "fixture-device",
                publicKeyBase64: "key",
                trustTier: "fixture",
                signatureBase64: "signature",
                signatureAlgorithm: "fixture"
            )
        }

        private func receipt(sequence: UInt64, receivedAt: Date) -> AnchorReceipt {
            AnchorReceipt(
                deviceID: "fixture-device",
                anchorSequence: sequence,
                anchorHash: "anchor-\(sequence)",
                receiptID: "receipt-\(sequence)",
                receivedAt: receivedAt,
                appAttestAccepted: false
            )
        }

        private func line<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(0x0A)
            return data
        }

        private func append(_ data: Data, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        }

        private func makeDay(year: Int, month: Int, day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: 12)
            )!
        }

        private func dayKey(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        private func transition(
            for filename: String,
            in diagnostics: DashboardDataReader.Diagnostics
        ) -> DashboardDataReader.JournalTransition? {
            diagnostics.transitions.first {
                URL(fileURLWithPath: $0.key).lastPathComponent == filename
            }?.value
        }
    }
#endif
