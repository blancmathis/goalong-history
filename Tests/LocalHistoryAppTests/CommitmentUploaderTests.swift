#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class CommitmentUploaderTests: XCTestCase {
        func testHTTPResponseAccumulatorRejectsBeforeExceedingItsByteCap() throws {
            var body = BoundedHTTPResponseBody()
            try body.reserve(expectedBytes: Int64(BoundedHTTPResponseBody.maximumBytes))
            for _ in 0..<BoundedHTTPResponseBody.maximumBytes {
                try body.append(0x78)
            }
            XCTAssertEqual(body.data.count, BoundedHTTPResponseBody.maximumBytes)
            XCTAssertThrowsError(try body.append(0x79))
            XCTAssertEqual(body.data.count, BoundedHTTPResponseBody.maximumBytes)

            var declaredOversized = BoundedHTTPResponseBody()
            XCTAssertThrowsError(
                try declaredOversized.reserve(
                    expectedBytes: Int64(BoundedHTTPResponseBody.maximumBytes + 1)
                )
            )
            XCTAssertTrue(declaredOversized.data.isEmpty)
        }

        func testNetworkRetryBackoffIsExponentialAndCapped() {
            let delays = (1...8).map {
                CommitmentUploader.exponentialRetryDelay(
                    base: 30,
                    maximum: 900,
                    failureCount: $0
                )
            }
            XCTAssertEqual(delays, [30, 60, 120, 240, 480, 900, 900, 900])
        }

        func testProductionReplayHasNoWholeFileCapAndMatchesWriterLineLimit() {
            let limits = CommitmentReplayLimits.production
            XCTAssertNil(limits.wholeFileByteLimit)
            XCTAssertEqual(
                limits.maximumLineBytes,
                MinuteSealer.maximumEncodedSealRowBytes
            )
        }

        func testReplayStreamsValidPrefixFromSparseJournalAboveFormerFileCap() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try line(seal(1)).write(to: sealFile)
            let handle = try FileHandle(forWritingTo: sealFile)
            try handle.truncate(atOffset: UInt64(128 * 1_024 * 1_024 + 1))
            try handle.synchronize()
            try handle.close()
            let attributes = try FileManager.default.attributesOfItem(atPath: sealFile.path)
            XCTAssertGreaterThan(
                try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
                Int64(128 * 1_024 * 1_024)
            )

            let limits = CommitmentReplayLimits.production
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: limits
            )
            let first = scanner.nextBatch(maximumCount: 1, maximumBytes: limits.queueByteCapacity)

            XCTAssertEqual(first.seals.map(\.seal.anchorSequence), [1])
            XCTAssertEqual(first.status, .ready)
            XCTAssertLessThanOrEqual(scanner.scannedBytes, UInt64(limits.maximumBytesPerPass))
        }

        func testReceiptJournalRepairsIncompleteTailBeforeAppendingRetry() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let name = "2026-08-24.receipts.jsonl"
            let receiptFile = fixture.receipts.appendingPathComponent(name)
            let first = try line(receipt(1))
            let interrupted = try line(receipt(2))
            try (first + interrupted.prefix(interrupted.count / 2)).write(to: receiptFile)

            try SecureReceiptJournal.append(
                row: try line(receipt(3)),
                fileName: name,
                directory: fixture.receipts
            )

            let rows = try decodedReceiptRows(at: receiptFile)
            XCTAssertEqual(rows.map(\.anchorSequence), [1, 3])

            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try (try line(seal(1)) + line(seal(2)) + line(seal(3))).write(to: sealFile)
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )
            let batch = scanner.nextBatch(maximumCount: 8, maximumBytes: 64 * 1_024)
            XCTAssertEqual(batch.seals.map(\.seal.anchorSequence), [2])
            XCTAssertEqual(batch.status, .exhausted)
        }

        func testReceiptJournalSeparatesCompleteTailMissingOnlyNewline() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let name = "2026-08-24.receipts.jsonl"
            let receiptFile = fixture.receipts.appendingPathComponent(name)
            let first = try line(receipt(1))
            let second = try line(receipt(2))
            try (first + second.dropLast()).write(to: receiptFile)

            try SecureReceiptJournal.append(
                row: try line(receipt(3)),
                fileName: name,
                directory: fixture.receipts
            )

            XCTAssertEqual(
                try decodedReceiptRows(at: receiptFile).map(\.anchorSequence),
                [1, 2, 3]
            )
        }

        func testReceiptJournalRejectsHardLinkedDestination() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appendingPathComponent("outside.jsonl")
            let original = try line(receipt(1))
            try original.write(to: outside)
            let name = "2026-08-24.receipts.jsonl"
            try FileManager.default.linkItem(
                at: outside,
                to: fixture.receipts.appendingPathComponent(name)
            )

            XCTAssertThrowsError(
                try SecureReceiptJournal.append(
                    row: try line(receipt(2)),
                    fileName: name,
                    directory: fixture.receipts
                )
            )
            XCTAssertEqual(try Data(contentsOf: outside), original)
        }

        func testRegistrationStateIsOriginBoundAndUnknownDeviceInvalidatesIt() throws {
            let suiteName = "CommitmentUploaderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let first = CommitmentRegistrationStore(
                baseURL: try XCTUnwrap(URL(string: "https://EXAMPLE.invalid/api")),
                defaults: defaults
            )
            let sameOrigin = CommitmentRegistrationStore(
                baseURL: try XCTUnwrap(URL(string: "https://example.invalid:443/other")),
                defaults: defaults
            )
            let otherOrigin = CommitmentRegistrationStore(
                baseURL: try XCTUnwrap(URL(string: "https://example.invalid:8443/api")),
                defaults: defaults
            )

            XCTAssertEqual(
                first.preferenceKey(deviceID: "device"),
                sameOrigin.preferenceKey(deviceID: "device")
            )
            XCTAssertNotEqual(
                first.preferenceKey(deviceID: "device"),
                otherOrigin.preferenceKey(deviceID: "device")
            )
            first.markRegistered(deviceID: "device")
            XCTAssertTrue(sameOrigin.isRegistered(deviceID: "device"))
            XCTAssertFalse(otherOrigin.isRegistered(deviceID: "device"))

            let unknownDevice = UploadError.httpResponse(
                statusCode: 404,
                body: Data(#"{"error":"unknown_device"}"#.utf8)
            )
            XCTAssertTrue(
                first.invalidateIfUnknownDevice(unknownDevice, deviceID: "device")
            )
            XCTAssertFalse(first.isRegistered(deviceID: "device"))

            first.markRegistered(deviceID: "device")
            XCTAssertFalse(
                first.invalidateIfUnknownDevice(
                    UploadError.httpResponse(
                        statusCode: 500,
                        body: Data(#"{"error":"not_found"}"#.utf8)
                    ),
                    deviceID: "device"
                )
            )
            XCTAssertTrue(first.isRegistered(deviceID: "device"))
        }

        func testChallenge404InvalidatesCachedRegistrationBeforeRetry() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try line(seal(1)).write(to: sealFile)

            let suiteName = "CommitmentUploaderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let baseURL = try XCTUnwrap(URL(string: "https://commitments.example.invalid"))
            let registration = CommitmentRegistrationStore(
                baseURL: baseURL,
                defaults: defaults
            )
            registration.markRegistered(deviceID: "device")

            let challengeRequested = expectation(description: "challenge requested")
            CommitmentUnknownDeviceURLProtocol.onRequest = { request in
                if request.url?.path == "/v1/challenge" { challengeRequested.fulfill() }
            }
            defer { CommitmentUnknownDeviceURLProtocol.onRequest = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CommitmentUnknownDeviceURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let uploader = CommitmentUploader(
                testingBaseURL: baseURL,
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits(),
                retryDelay: 5,
                maximumRetryDelay: 5,
                testingSession: session,
                testingDefaults: defaults
            )

            uploader.replayPending()
            wait(for: [challengeRequested], timeout: 2)
            let invalidationDeadline = Date().addingTimeInterval(2)
            while registration.isRegistered(deviceID: "device"), Date() < invalidationDeadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            XCTAssertFalse(registration.isRegistered(deviceID: "device"))
            XCTAssertEqual(uploader.runtimeSnapshot.status, .networkRetry)
        }

        func testUploaderReschedulesDirectoryDiscoveryBeyondEachPassBudget() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            for sequence in 1...30 {
                let file = fixture.seals.appendingPathComponent(
                    String(format: "%04d.seals.jsonl", sequence)
                )
                try line(seal(UInt64(sequence))).write(to: file)
            }
            let limits = testLimits(
                queueCapacity: 8,
                maximumDirectoryEntriesPerPass: 5,
                maximumFilesOpenedPerPass: 4,
                fileNameChunkCapacity: 4
            )
            let lock = NSLock()
            var uploaded: [UInt64] = []
            let uploader = CommitmentUploader(
                testingBaseURL: try XCTUnwrap(URL(string: "https://example.invalid")),
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: limits,
                uploadAttempt: { seal, completion in
                    lock.lock()
                    uploaded.append(seal.anchorSequence)
                    lock.unlock()
                    completion(true)
                }
            )

            uploader.replayPending()
            XCTAssertTrue(uploader.waitUntilSettledForTesting(timeout: 10))
            lock.lock()
            let observed = uploaded
            lock.unlock()
            XCTAssertEqual(observed, Array(1...30).map(UInt64.init))
            XCTAssertEqual(uploader.runtimeSnapshot.status, .exhausted)
        }

        func testStreamingReplayKeepsBatchesBoundedOrderedAndDeduplicated() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let receiptFile = fixture.receipts.appendingPathComponent(
                "2026-08-24.receipts.jsonl"
            )

            var sealData = Data()
            for sequence in 1...3_000 {
                let row = try line(seal(UInt64(sequence)))
                sealData.append(row)
                if sequence.isMultiple(of: 113) { sealData.append(row) }
            }
            try sealData.write(to: sealFile)

            var receiptData = Data()
            for sequence in 1...1_500 {
                let row = try line(receipt(UInt64(sequence)))
                receiptData.append(row)
                if sequence.isMultiple(of: 97) { receiptData.append(row) }
            }
            try receiptData.write(to: receiptFile)
            let originalSeals = try Data(contentsOf: sealFile)
            let originalReceipts = try Data(contentsOf: receiptFile)

            let limits = testLimits(
                queueCapacity: 128,
                queueByteCapacity: 64 * 1_024,
                maximumBytesPerPass: 32 * 1_024,
                maximumLinesPerPass: 256
            )
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: limits
            )
            var discovered: [UInt64] = []
            var largestBatchCount = 0
            var largestBatchBytes = 0
            var exhausted = false

            for _ in 0..<20_000 {
                let batch = scanner.nextBatch(
                    maximumCount: limits.queueCapacity,
                    maximumBytes: limits.queueByteCapacity
                )
                largestBatchCount = max(largestBatchCount, batch.seals.count)
                largestBatchBytes = max(
                    largestBatchBytes,
                    batch.seals.reduce(0) { $0 + $1.sourceBytes }
                )
                discovered.append(contentsOf: batch.seals.map(\.seal.anchorSequence))
                switch batch.status {
                case .exhausted:
                    exhausted = true
                case .blocked(let reason), .invalidated(let reason):
                    XCTFail("Unexpected replay failure: \(reason)")
                    return
                default:
                    break
                }
                if exhausted { break }
            }

            XCTAssertTrue(exhausted)
            XCTAssertEqual(discovered, Array(1_501...3_000).map(UInt64.init))
            XCTAssertEqual(discovered, Array(Set(discovered)).sorted())
            XCTAssertLessThanOrEqual(largestBatchCount, limits.queueCapacity)
            XCTAssertLessThanOrEqual(largestBatchBytes, limits.queueByteCapacity)
            XCTAssertEqual(try Data(contentsOf: sealFile), originalSeals)
            XCTAssertEqual(try Data(contentsOf: receiptFile), originalReceipts)
            XCTAssertGreaterThan(scanner.scannedLines, 4_500)
        }

        func testNetworkFailureKeepsHeadThenRefillsWithoutLosingOrder() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            var sealData = Data()
            for sequence in 1...700 { sealData.append(try line(seal(UInt64(sequence)))) }
            try sealData.write(to: sealFile)
            let original = try Data(contentsOf: sealFile)

            let limits = testLimits(
                queueCapacity: 16,
                queueByteCapacity: 16 * 1_024,
                maximumBytesPerPass: 128 * 1_024,
                maximumLinesPerPass: 1_024
            )
            let lock = NSLock()
            var attempts: [UInt64] = []
            var failedFirst = false
            let uploader = CommitmentUploader(
                testingBaseURL: try XCTUnwrap(URL(string: "https://example.invalid")),
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: limits,
                // Keep a wide margin between the enqueue assertion below and the retry.
                // Busy CI runners can otherwise suspend this test past a 100 ms deadline.
                retryDelay: 1,
                uploadAttempt: { seal, completion in
                    lock.lock()
                    attempts.append(seal.anchorSequence)
                    let shouldFail = seal.anchorSequence == 1 && !failedFirst
                    if shouldFail { failedFirst = true }
                    lock.unlock()
                    completion(!shouldFail)
                }
            )

            uploader.replayPending()
            let firstAttemptDeadline = Date().addingTimeInterval(1)
            while Date() < firstAttemptDeadline {
                lock.lock()
                let count = attempts.count
                lock.unlock()
                if count == 1 { break }
                Thread.sleep(forTimeInterval: 0.002)
            }
            for _ in 0..<20 { uploader.enqueue(seal(700)) }
            Thread.sleep(forTimeInterval: 0.03)
            lock.lock()
            XCTAssertEqual(attempts, [1], "enqueue must not bypass the retry deadline")
            lock.unlock()
            XCTAssertTrue(uploader.waitUntilSettledForTesting(timeout: 10))
            lock.lock()
            let observedAttempts = attempts
            lock.unlock()
            let expected = [UInt64(1), UInt64(1)] + Array(2...700).map(UInt64.init)

            XCTAssertEqual(observedAttempts, expected)
            let snapshot = uploader.runtimeSnapshot
            XCTAssertEqual(snapshot.status, .exhausted)
            XCTAssertEqual(snapshot.pendingCount, 0)
            XCTAssertFalse(snapshot.inFlight)
            XCTAssertEqual(snapshot.lastUploadedSequence, 700)
            XCTAssertLessThanOrEqual(snapshot.maximumObservedPendingCount, 16)
            XCTAssertLessThanOrEqual(snapshot.maximumObservedPendingBytes, 16 * 1_024)
            XCTAssertEqual(try Data(contentsOf: sealFile), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).isEmpty)
        }

        func testAppendGrowthIsVisibleWithoutRestartOrDuplicate() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try (try line(seal(1)) + line(seal(2)) + line(seal(3))).write(to: sealFile)
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )

            let first = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertEqual(first.seals.map(\.seal.anchorSequence), [1, 2, 3])
            XCTAssertEqual(first.status, .exhausted)

            try append(try line(seal(4)) + line(seal(5)), to: sealFile)
            let second = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertEqual(second.seals.map(\.seal.anchorSequence), [4, 5])
            XCTAssertEqual(second.status, .exhausted)

            let laterFile = fixture.seals.appendingPathComponent("2026-08-25.seals.jsonl")
            try line(seal(6)).write(to: laterFile)
            let third = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertEqual(third.seals.map(\.seal.anchorSequence), [6])
            XCTAssertEqual(third.status, .exhausted)
        }

        func testPartialTailResumesAndSameInodeRewriteInvalidates() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            let firstLine = try line(seal(1))
            let secondLine = try line(seal(2))
            var partial = firstLine
            partial.append(secondLine.prefix(secondLine.count / 2))
            try partial.write(to: sealFile)
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )

            let first = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertEqual(first.seals.map(\.seal.anchorSequence), [1])
            guard case .budgetExhausted(let reason) = first.status else {
                return XCTFail("Expected retryable partial tail, got \(first.status)")
            }
            XCTAssertTrue(reason.contains("awaiting append"))
            try append(Data(secondLine.dropFirst(secondLine.count / 2)), to: sealFile)
            let completed = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertEqual(completed.seals.map(\.seal.anchorSequence), [2])
            XCTAssertEqual(completed.status, .exhausted)

            let handle = try FileHandle(forWritingTo: sealFile)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: try line(seal(3)))
            try handle.synchronize()
            try handle.close()
            let rewritten = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertTrue(rewritten.seals.isEmpty)
            guard case .invalidated(let invalidation) = rewritten.status else {
                return XCTFail("Expected same-inode invalidation, got \(rewritten.status)")
            }
            XCTAssertTrue(invalidation.contains("changed"))
        }

        func testDiscoveryContinuesBeyondBoundedFilenameChunks() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            for sequence in 1...130 {
                let file = fixture.seals.appendingPathComponent(
                    String(format: "%04d.seals.jsonl", sequence)
                )
                try line(seal(UInt64(sequence))).write(to: file)
            }
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits(
                    maximumFilesOpenedPerPass: 16,
                    fileNameChunkCapacity: 8
                )
            )
            var sequences: [UInt64] = []
            for _ in 0..<1_000 {
                let batch = scanner.nextBatch(maximumCount: 32, maximumBytes: 64 * 1_024)
                sequences.append(contentsOf: batch.seals.map(\.seal.anchorSequence))
                if batch.status == .exhausted { break }
                if case .blocked(let reason) = batch.status {
                    return XCTFail("Unexpected block: \(reason)")
                }
            }
            XCTAssertEqual(sequences, Array(1...130).map(UInt64.init))
        }

        func testReplacementAfterHighWaterIsExplicitlyInvalidated() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try (try line(seal(1)) + line(seal(2))).write(to: sealFile)
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )
            XCTAssertEqual(
                scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024).status,
                .exhausted
            )

            let replacement = fixture.root.appendingPathComponent("replacement.jsonl")
            try line(seal(2)).write(to: replacement)
            try FileManager.default.removeItem(at: sealFile)
            try FileManager.default.moveItem(at: replacement, to: sealFile)

            let batch = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertTrue(batch.seals.isEmpty)
            guard case .invalidated(let reason) = batch.status else {
                return XCTFail("Expected invalidation, got \(batch.status)")
            }
            XCTAssertTrue(reason.contains("replaced") || reason.contains("changed"))
        }

        func testSymlinkedSourceIsBlockedWithoutReadingTarget() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appendingPathComponent("outside.jsonl")
            let outsideData = try line(seal(999))
            try outsideData.write(to: outside)
            let link = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )

            let batch = scanner.nextBatch(maximumCount: 16, maximumBytes: 64 * 1_024)
            XCTAssertTrue(batch.seals.isEmpty)
            guard case .blocked(let reason) = batch.status else {
                return XCTFail("Expected blocked status, got \(batch.status)")
            }
            XCTAssertTrue(reason.contains("unsafe"))
            XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        }

        func testByteAndLineBudgetsProduceExplicitBoundedStates() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let sealFile = fixture.seals.appendingPathComponent("2026-08-24.seals.jsonl")
            try (try line(seal(1)) + line(seal(2))).write(to: sealFile)
            let byteBudgetScanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits(maximumBytesPerPass: 128)
            )
            var sawByteBudget = false
            var discovered: [UInt64] = []
            for _ in 0..<32 {
                let batch = byteBudgetScanner.nextBatch(
                    maximumCount: 8,
                    maximumBytes: 64 * 1_024
                )
                discovered.append(contentsOf: batch.seals.map(\.seal.anchorSequence))
                if case .budgetExhausted(let reason) = batch.status,
                    reason == "source bytes"
                {
                    sawByteBudget = true
                }
                if batch.status == .exhausted { break }
            }
            XCTAssertTrue(sawByteBudget)
            XCTAssertEqual(discovered, [1, 2])

            let lineCountScanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits(maximumLinesPerPass: 1)
            )
            var lineBounded: [UInt64] = []
            for _ in 0..<16 {
                let batch = lineCountScanner.nextBatch(
                    maximumCount: 8,
                    maximumBytes: 64 * 1_024
                )
                lineBounded.append(contentsOf: batch.seals.map(\.seal.anchorSequence))
                if batch.status == .exhausted { break }
            }
            XCTAssertEqual(lineBounded, [1, 2])

            let oversizedFile = fixture.seals.appendingPathComponent(
                "2026-08-25.seals.jsonl"
            )
            var oversized = seal(3)
            oversized = LocalMinuteSeal(
                anchorSequence: oversized.anchorSequence,
                minuteStart: oversized.minuteStart,
                minuteEnd: oversized.minuteEnd,
                minuteFields: oversized.minuteFields,
                eventRoots: [String(repeating: "x", count: 4_096)],
                minuteRoot: oversized.minuteRoot,
                previousAnchorHash: oversized.previousAnchorHash,
                anchorHash: oversized.anchorHash,
                deviceID: oversized.deviceID,
                publicKeyBase64: oversized.publicKeyBase64,
                trustTier: oversized.trustTier,
                signatureBase64: oversized.signatureBase64,
                signatureAlgorithm: oversized.signatureAlgorithm
            )
            try line(oversized).write(to: oversizedFile)
            let lineBudgetScanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits(maximumLineBytes: 512)
            )
            _ = lineBudgetScanner.nextBatch(maximumCount: 8, maximumBytes: 64 * 1_024)
            let lineBudgetBatch = lineBudgetScanner.nextBatch(
                maximumCount: 8,
                maximumBytes: 64 * 1_024
            )
            guard case .blocked(let reason) = lineBudgetBatch.status else {
                return XCTFail("Expected a line-budget block, got \(lineBudgetBatch.status)")
            }
            XCTAssertTrue(reason.contains("exceeds 512 bytes"))
        }

        func testSymlinkedSourceDirectoryIsUnavailableWithoutFollowingIt() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: true
            )
            let outsideFile = outsideDirectory.appendingPathComponent(
                "2026-08-24.seals.jsonl"
            )
            let original = try line(seal(88))
            try original.write(to: outsideFile)
            try FileManager.default.removeItem(at: fixture.seals)
            try FileManager.default.createSymbolicLink(
                at: fixture.seals,
                withDestinationURL: outsideDirectory
            )
            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: fixture.receipts,
                limits: testLimits()
            )

            let batch = scanner.nextBatch(maximumCount: 8, maximumBytes: 64 * 1_024)
            guard case .blocked(let reason) = batch.status else {
                return XCTFail("Expected unavailable source, got \(batch.status)")
            }
            XCTAssertTrue(reason.contains("open seal directory"))
            XCTAssertEqual(try Data(contentsOf: outsideFile), original)
        }

        private func testLimits(
            queueCapacity: Int = 64,
            queueByteCapacity: Int = 64 * 1_024,
            maximumBytesPerPass: Int = 256 * 1_024,
            maximumLinesPerPass: Int = 4_096,
            maximumLineBytes: Int = 64 * 1_024,
            maximumDirectoryEntriesPerPass: Int = 8_192,
            maximumFilesOpenedPerPass: Int = 128,
            fileNameChunkCapacity: Int = 128
        ) -> CommitmentReplayLimits {
            CommitmentReplayLimits(
                queueCapacity: queueCapacity,
                queueByteCapacity: queueByteCapacity,
                maximumBytesPerPass: maximumBytesPerPass,
                maximumLinesPerPass: maximumLinesPerPass,
                maximumDirectoryEntriesPerPass: maximumDirectoryEntriesPerPass,
                maximumFilesOpenedPerPass: maximumFilesOpenedPerPass,
                maximumLineBytes: maximumLineBytes,
                wholeFileByteLimit: nil,
                maximumPassDuration: 5,
                fileNameChunkCapacity: fileNameChunkCapacity
            )
        }

        private func makeFixture() throws -> ReplayFixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CommitmentUploaderTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let seals = root.appendingPathComponent("seals", isDirectory: true)
            let receipts = root.appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(at: seals, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            return ReplayFixture(root: root, seals: seals, receipts: receipts)
        }

        private func seal(_ sequence: UInt64) -> LocalMinuteSeal {
            let minuteStart = Date(timeIntervalSince1970: TimeInterval(sequence * 60))
            return LocalMinuteSeal(
                anchorSequence: sequence,
                minuteStart: minuteStart,
                minuteEnd: minuteStart.addingTimeInterval(60),
                minuteFields: [],
                eventRoots: ["event-root-\(sequence)"],
                minuteRoot: "minute-root-\(sequence)",
                previousAnchorHash: "previous-\(sequence)",
                anchorHash: "anchor-\(sequence)",
                deviceID: "device",
                publicKeyBase64: "public-key",
                trustTier: "software",
                signatureBase64: "signature-\(sequence)",
                signatureAlgorithm: "p256"
            )
        }

        private func receipt(_ sequence: UInt64) -> AnchorReceipt {
            AnchorReceipt(
                deviceID: "device",
                anchorSequence: sequence,
                anchorHash: "anchor-\(sequence)",
                receiptID: "receipt-\(sequence)",
                receivedAt: Date(timeIntervalSince1970: TimeInterval(sequence * 60)),
                appAttestAccepted: true
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
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }

        private func decodedReceiptRows(at url: URL) throws -> [AnchorReceipt] {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try data.split(separator: 0x0A).map {
                try decoder.decode(AnchorReceipt.self, from: Data($0))
            }
        }
    }

    private struct ReplayFixture {
        let root: URL
        let seals: URL
        let receipts: URL

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class CommitmentUnknownDeviceURLProtocol: URLProtocol {
        static var onRequest: ((URLRequest) -> Void)?

        override class func canInit(with _: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.onRequest?(request)
            let body = Data(#"{"error":"unknown_device"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(body.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
