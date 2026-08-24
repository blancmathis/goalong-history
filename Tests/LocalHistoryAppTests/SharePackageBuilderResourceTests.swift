#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class SharePackageBuilderResourceTests: XCTestCase {
        func testWarmCacheReadsZeroBytesAndRetainsOnlySmallSummaries() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let first = event(root: "root-one", application: "Codex", category: "work", padding: 16_384)
            let second = event(root: "root-two", application: "Terminal", category: "work", padding: 16_384)
            try writeLines([first, second], to: fixture.events)
            try writeLines(
                [
                    seal(sequence: 1, root: "root-one", day: fixture.day),
                    seal(sequence: 2, root: "root-two", day: fixture.day),
                ],
                to: fixture.seals
            )

            let builder = fixture.builder()
            let initialRows = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(initialRows.map(\.appSummary), ["Codex", "Terminal"])
            let cold = builder.readDiagnostics
            XCTAssertTrue(cold.usedFullScan)
            XCTAssertGreaterThan(cold.bytesRead, 32_000)
            XCTAssertEqual(cold.retainedSummaries, 2)
            XCTAssertEqual(cold.retainedEstimatedBytes, 565)
            XCTAssertLessThan(cold.retainedEstimatedBytes, 2_000)
            XCTAssertLessThan(cold.retainedEstimatedBytes, cold.bytesRead / 10)

            XCTAssertEqual(try builder.minuteRows(for: fixture.day).count, 2)
            let warm = builder.readDiagnostics
            XCTAssertTrue(warm.usedWarmCache)
            XCTAssertEqual(warm.bytesRead, 0)
            XCTAssertEqual(warm.decodedRows, 0)
            XCTAssertEqual(warm.retainedSummaries, 2)
        }

        func testAppendReadsOnlyNewEventAndDoesNotDuplicateRows() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writeLines(
                [event(root: "root-one", application: "Codex", category: "work", padding: 8_192)],
                to: fixture.events
            )
            try writeLines(
                [seal(sequence: 1, root: "root-one", day: fixture.day)],
                to: fixture.seals
            )
            let builder = fixture.builder()
            XCTAssertEqual(try builder.minuteRows(for: fixture.day).count, 1)

            try appendLine(
                event(root: "root-two", application: "Claude", category: "work", padding: 8_192),
                to: fixture.events
            )
            try appendLine(
                seal(sequence: 2, root: "root-two", day: fixture.day),
                to: fixture.seals
            )

            let rows = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map(\.anchorSequence), [1, 2])
            XCTAssertEqual(rows.map(\.appSummary), ["Codex", "Claude"])
            let append = builder.readDiagnostics
            XCTAssertTrue(append.usedAppendScan)
            XCTAssertFalse(append.usedFullScan)
            XCTAssertEqual(append.decodedRows, 1)
            XCTAssertEqual(append.retainedSummaries, 2)
        }

        func testReplacementIsVisibleAndDeletionNeverServesStaleDetails() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writeLines(
                [event(root: "stable-root", application: "Old App", category: "old")],
                to: fixture.events
            )
            try writeLines(
                [seal(sequence: 1, root: "stable-root", day: fixture.day)],
                to: fixture.seals
            )
            let builder = fixture.builder()
            let initial = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(initial.count, 1)
            XCTAssertEqual(initial.first?.appSummary, "Old App")

            try appendLine(
                event(root: "stable-root", application: "Appended App", category: "updated"),
                to: fixture.events
            )
            let appended = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(appended.count, 1)
            XCTAssertEqual(appended.first?.appSummary, "Appended App")
            XCTAssertTrue(builder.readDiagnostics.usedAppendScan)

            try writeLines(
                [event(root: "stable-root", application: "New App", category: "new")],
                to: fixture.events,
                atomically: true
            )
            let replaced = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(replaced.count, 1)
            XCTAssertEqual(replaced.first?.appSummary, "New App")
            XCTAssertTrue(builder.readDiagnostics.usedFullScan)
            XCTAssertFalse(builder.readDiagnostics.usedWarmCache)

            try FileManager.default.removeItem(at: fixture.events)
            let missing = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(missing.count, 1)
            XCTAssertFalse(try XCTUnwrap(missing.first).canRevealDetails)
            XCTAssertEqual(try XCTUnwrap(missing.first).level, .privateOnly)
            XCTAssertEqual(builder.readDiagnostics.retainedSummaries, 0)
            XCTAssertFalse(builder.readDiagnostics.usedWarmCache)
        }

        func testCancellationAndOversizedSourceFailWithoutPartialCache() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writeLines(
                [event(root: "large-root", application: "Codex", category: "work", padding: 32_768)],
                to: fixture.events
            )
            try writeLines(
                [seal(sequence: 1, root: "large-root", day: fixture.day)],
                to: fixture.seals
            )

            let cancellableBuilder = fixture.builder()
            XCTAssertThrowsError(
                try cancellableBuilder.minuteRows(for: fixture.day, cancellation: { true })
            ) { error in
                guard let buildError = error as? ShareBuildError,
                    case .cancelled = buildError
                else { return XCTFail("Expected cancellation, got \(error)") }
            }
            XCTAssertEqual(cancellableBuilder.readDiagnostics.retainedSummaries, 0)

            var limits = ShareEventReadLimits.production
            limits.maximumSourceBytes = 4_096
            limits.readChunkBytes = 4_096
            let boundedBuilder = fixture.builder(limits: limits)
            XCTAssertThrowsError(try boundedBuilder.minuteRows(for: fixture.day)) { error in
                guard let buildError = error as? ShareBuildError,
                    case .sourceIncomplete(let detail) = buildError
                else { return XCTFail("Expected an explicit source error, got \(error)") }
                XCTAssertTrue(detail.contains("exceeds"))
            }
            XCTAssertEqual(boundedBuilder.readDiagnostics.retainedSummaries, 0)
        }

        func testNonRegularEventSourceProducesExplicitState() throws {
            let fixture = try makeFixture(createEventFile: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.createDirectory(at: fixture.events, withIntermediateDirectories: false)
            try writeLines(
                [seal(sequence: 1, root: "root", day: fixture.day)],
                to: fixture.seals
            )

            XCTAssertThrowsError(try fixture.builder().minuteRows(for: fixture.day)) { error in
                guard let buildError = error as? ShareBuildError,
                    case .sourceIncomplete(let detail) = buildError
                else { return XCTFail("Expected an explicit source error, got \(error)") }
                XCTAssertTrue(detail.contains("not a regular file"))
            }
        }

        func testMalformedTailFailsClosedAndNeverCachesPartialRows() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let valid = event(root: "valid-root", application: "Codex", category: "work")
            try writeLines([valid], to: fixture.events)
            try appendRaw(Data("{not-json}\n".utf8), to: fixture.events)
            try writeLines(
                [seal(sequence: 1, root: "valid-root", day: fixture.day)],
                to: fixture.seals
            )
            let builder = fixture.builder()

            XCTAssertThrowsError(try builder.minuteRows(for: fixture.day)) { error in
                guard let buildError = error as? ShareBuildError,
                    case .sourceIncomplete(let detail) = buildError
                else { return XCTFail("Expected an explicit source error, got \(error)") }
                XCTAssertTrue(detail.contains("invalid JSONL row"))
            }
            XCTAssertEqual(builder.readDiagnostics.retainedSummaries, 0)

            try writeLines([valid], to: fixture.events, atomically: true)
            let recovered = try builder.minuteRows(for: fixture.day)
            XCTAssertEqual(recovered.count, 1)
            XCTAssertEqual(recovered.first?.appSummary, "Codex")
            XCTAssertTrue(builder.readDiagnostics.usedFullScan)
        }

        func testConcurrentAppendDuringReadFailsClosedWithoutCachingMixedSource() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writeLines(
                [event(root: "root", application: "Codex", category: "work", padding: 8_192)],
                to: fixture.events
            )
            try writeLines(
                [seal(sequence: 1, root: "root", day: fixture.day)],
                to: fixture.seals
            )
            var mutated = false
            let builder = fixture.builder(afterSourceReadForTesting: { file in
                guard file.standardizedFileURL == fixture.events.standardizedFileURL,
                    !mutated
                else { return }
                mutated = true
                try self.appendRaw(Data("\n".utf8), to: file)
            })

            XCTAssertThrowsError(try builder.minuteRows(for: fixture.day)) { error in
                guard let buildError = error as? ShareBuildError,
                    case .sourceIncomplete(let detail) = buildError
                else { return XCTFail("Expected a changed-source error, got \(error)") }
                XCTAssertTrue(detail.contains("changed while it was read"))
            }
            XCTAssertTrue(mutated)
            XCTAssertEqual(builder.readDiagnostics.retainedSummaries, 0)
        }

        func testShareWindowCoordinatorCancelAtPanelSchedulesNoWork() {
            var scheduled = 0
            var started = 0
            var built = 0
            var completed = 0
            let coordinator = ShareWindowWorkCoordinator(
                schedule: { work in
                    scheduled += 1
                    work()
                },
                deliver: { $0() }
            )

            let accepted = coordinator.startAfterChoosingDestination(
                chooseDestination: { nil },
                onStart: { started += 1 },
                work: { _, _ in
                    built += 1
                    return 1
                },
                completion: { _ in completed += 1 }
            )

            XCTAssertFalse(accepted)
            XCTAssertEqual(scheduled, 0)
            XCTAssertEqual(started, 0)
            XCTAssertEqual(built, 0)
            XCTAssertEqual(completed, 0)
            XCTAssertFalse(coordinator.hasActiveWork)
        }

        func testCancelledPackageBuildCreatesNoExportFile() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try writeLines(
                [seal(sequence: 1, root: "root", day: fixture.day)],
                to: fixture.seals
            )
            let destination = fixture.root.appendingPathComponent("cancelled-export.json")
            let builder = fixture.builder()

            XCTAssertThrowsError(
                try {
                    let package = try builder.build(
                        for: fixture.day,
                        levels: [1: .privateOnly],
                        cancellation: { true }
                    )
                    try builder.write(package, to: destination, cancellation: { true })
                }()
            ) { error in
                guard let buildError = error as? ShareBuildError,
                    case .cancelled = buildError
                else { return XCTFail("Expected cancellation, got \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }

        func testShareWindowCoordinatorRunsOffMainAndIgnoresCancelledLateResult() throws {
            let coordinator = ShareWindowWorkCoordinator()
            let workStarted = expectation(description: "background work started")
            let completion = expectation(description: "cancelled completion ignored")
            completion.isInverted = true
            let releaseWork = DispatchSemaphore(value: 0)
            let stateLock = NSLock()
            var ranOffMain = false
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-share-\(UUID().uuidString).json")

            XCTAssertTrue(
                coordinator.startAfterChoosingDestination(
                    chooseDestination: { destination },
                    work: { _, cancellation in
                        stateLock.lock()
                        ranOffMain = !Thread.isMainThread
                        stateLock.unlock()
                        workStarted.fulfill()
                        _ = releaseWork.wait(timeout: .now() + 2)
                        if cancellation() { throw ShareBuildError.cancelled }
                        return 1
                    },
                    completion: { _ in completion.fulfill() }
                )
            )
            wait(for: [workStarted], timeout: 1)
            coordinator.cancel()
            releaseWork.signal()
            wait(for: [completion], timeout: 0.2)

            stateLock.lock()
            let observedOffMain = ranOffMain
            stateLock.unlock()
            XCTAssertTrue(observedOffMain)
            XCTAssertFalse(coordinator.hasActiveWork)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }

        func testDashboardTabLeaveKeepsCompactCacheButHideReleasesIt() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf:
                    repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardViewModel.swift"),
                encoding: .utf8
            )
            let hidden = try XCTUnwrap(
                slice(
                    source,
                    from: "        func dashboardDidBecomeHidden()",
                    through: "        func togglePause()"
                )
            )
            let sectionSelection = try XCTUnwrap(
                slice(
                    source,
                    from: "        func selectSection(_ section: DashboardSection)",
                    through: "        func refreshEverything()"
                )
            )
            let reload = try XCTUnwrap(
                slice(
                    source,
                    from: "        func reloadShareSegments()",
                    through: "        func exportSharePackage()"
                )
            )
            let cancellation = try XCTUnwrap(
                slice(
                    source,
                    from: "        private func cancelShareRequest()",
                    through: "        private func cancelShareExport()"
                )
            )
            let cacheDiscard = try XCTUnwrap(
                slice(
                    source,
                    from: "        private func discardShareCache()",
                    through: "        private static func makeShareSegments"
                )
            )

            XCTAssertTrue(hidden.contains("cancelShareRequest()"))
            XCTAssertTrue(hidden.contains("discardShareCache()"))
            XCTAssertTrue(hidden.contains("shareSegments = []"))
            XCTAssertTrue(sectionSelection.contains("cancelShareRequest()"))
            XCTAssertFalse(sectionSelection.contains("discardShareCache()"))
            XCTAssertTrue(reload.contains("shareRefreshPending = true"))
            XCTAssertTrue(reload.contains("cancellation: { token.isCancelled }"))
            XCTAssertTrue(cancellation.contains("activeShareRequest?.token.cancel()"))
            XCTAssertFalse(cancellation.contains("discardTransientCaches()"))
            XCTAssertTrue(cacheDiscard.contains("builder.discardTransientCaches()"))
        }

        func testValidExportEnforcesBoundariesReceiptIdentityAndMissingEvents() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let zeroHash = String(repeating: "0", count: 64)
            let sourceEvent = validEvent(
                application: "Codex",
                category: "work",
                sequence: 2
            )
            let eventRoot = try XCTUnwrap(sourceEvent.integrity?.eventRoot)
            let boundary = validSeal(
                sequence: 1,
                eventRoots: [],
                previousAnchorHash: zeroHash,
                day: fixture.day
            )
            let current = validSeal(
                sequence: 2,
                eventRoots: [eventRoot],
                previousAnchorHash: boundary.anchorHash,
                day: fixture.day
            )
            let boundaryFile = fixture.seals.deletingLastPathComponent()
                .appendingPathComponent("boundary.seals.jsonl")
            let receiptFile = fixture.receipts.appendingPathComponent("fixture.receipts.jsonl")
            let matchingReceipt = AnchorReceipt(
                deviceID: current.deviceID,
                anchorSequence: current.anchorSequence,
                anchorHash: current.anchorHash,
                receiptID: "matching-receipt",
                receivedAt: fixture.day,
                appAttestAccepted: true
            )
            try writeLines([sourceEvent], to: fixture.events)
            try writeLines([current], to: fixture.seals)
            try writeLines([boundary], to: boundaryFile)
            try writeLines([matchingReceipt], to: receiptFile)

            let builder = fixture.builder()
            let package = try builder.build(
                for: fixture.day,
                sharingRules: [:],
                defaultVisibility: .identity
            )
            XCTAssertEqual(package.minutes.count, 1)
            XCTAssertEqual(package.boundaryBefore?.anchorSequence, boundary.anchorSequence)
            XCTAssertEqual(package.boundaryBefore?.anchorHash, current.previousAnchorHash)
            XCTAssertTrue(try XCTUnwrap(package.boundaryBefore).verifiesStructure())
            let minute = try XCTUnwrap(package.minutes.first)
            XCTAssertTrue(minute.verifiesStructure())
            XCTAssertEqual(minute.shareLevel, .applicationOnly)
            XCTAssertEqual(minute.trustTier, "app_attest")
            XCTAssertEqual(minute.liveReceiptID, matchingReceipt.receiptID)

            let mismatchedReceipt = AnchorReceipt(
                deviceID: "another-device",
                anchorSequence: current.anchorSequence,
                anchorHash: current.anchorHash,
                receiptID: "mismatched-receipt",
                receivedAt: fixture.day,
                appAttestAccepted: true
            )
            try writeLines([mismatchedReceipt], to: receiptFile, atomically: true)
            let receiptRejected = try builder.build(
                for: fixture.day,
                sharingRules: [:],
                defaultVisibility: .identity
            )
            XCTAssertEqual(receiptRejected.minutes.first?.trustTier, current.trustTier)
            XCTAssertNil(receiptRejected.minutes.first?.liveReceiptID)

            let unrelatedBoundary = validSeal(
                sequence: 1,
                eventRoots: [],
                previousAnchorHash: SHA256Digest.hashHex("unrelated-chain"),
                day: fixture.day
            )
            try writeLines([unrelatedBoundary], to: boundaryFile, atomically: true)
            XCTAssertThrowsError(
                try builder.build(
                    for: fixture.day,
                    sharingRules: [:],
                    defaultVisibility: .identity
                )
            ) { error in
                guard let buildError = error as? ShareBuildError,
                    case .sourceIncomplete(let detail) = buildError
                else { return XCTFail("Expected a boundary error, got \(error)") }
                XCTAssertTrue(detail.contains("previous boundary"))
            }

            try writeLines([boundary], to: boundaryFile, atomically: true)
            try FileManager.default.removeItem(at: fixture.events)
            XCTAssertThrowsError(
                try builder.build(
                    for: fixture.day,
                    sharingRules: [:],
                    defaultVisibility: .identity
                )
            ) { error in
                guard let buildError = error as? ShareBuildError,
                    case .missingEvents(current.anchorSequence) = buildError
                else { return XCTFail("Expected a missing-events error, got \(error)") }
            }
        }

        private struct Fixture {
            let root: URL
            let events: URL
            let seals: URL
            let receipts: URL
            let day: Date

            func builder(
                limits: ShareEventReadLimits = .production,
                afterSourceReadForTesting: ((URL) throws -> Void)? = nil
            ) -> SharePackageBuilder {
                SharePackageBuilder(
                    eventFileURL: { _ in events },
                    sealFileURL: { _ in seals },
                    sealsDirectory: seals.deletingLastPathComponent(),
                    receiptsDirectory: receipts,
                    limits: limits,
                    afterSourceReadForTesting: afterSourceReadForTesting
                )
            }
        }

        private func makeFixture(createEventFile: Bool = true) throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-builder-\(UUID().uuidString)", isDirectory: true)
            let sealsDirectory = root.appendingPathComponent("seals", isDirectory: true)
            let receipts = root.appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: sealsDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: receipts,
                withIntermediateDirectories: true
            )
            let events = root.appendingPathComponent("events.jsonl")
            if createEventFile { FileManager.default.createFile(atPath: events.path, contents: nil) }
            return Fixture(
                root: root,
                events: events,
                seals: sealsDirectory.appendingPathComponent("fixture.seals.jsonl"),
                receipts: receipts,
                day: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        private func event(
            root: String,
            application: String,
            category: String,
            padding: Int = 0
        ) -> HistoryEvent {
            let applicationCommitment = CommitmentBuilder.make(
                name: "application",
                fields: ["name": application],
                salt: Data(repeating: 1, count: 32)
            )
            let classificationCommitment = CommitmentBuilder.make(
                name: "classification",
                fields: ["category": category],
                salt: Data(repeating: 2, count: 32)
            )
            return HistoryEvent(
                schemaVersion: 4,
                id: root,
                sessionID: "share-resource-test",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                kind: .mouseClick,
                message: String(repeating: "x", count: padding),
                integrity: EventIntegrity(
                    sequence: 1,
                    previousEventHash: String(repeating: "0", count: 64),
                    eventRoot: root,
                    eventHash: SHA256Digest.hashHex(root),
                    fieldCommitments: [applicationCommitment, classificationCommitment]
                )
            )
        }

        private func seal(sequence: UInt64, root: String, day: Date) -> LocalMinuteSeal {
            let start = day.addingTimeInterval(TimeInterval(sequence * 60))
            return LocalMinuteSeal(
                anchorSequence: sequence,
                minuteStart: start,
                minuteEnd: start.addingTimeInterval(60),
                minuteFields: [],
                eventRoots: [root],
                minuteRoot: "minute-\(sequence)",
                previousAnchorHash: "previous-\(sequence)",
                anchorHash: "anchor-\(sequence)",
                deviceID: "fixture-device",
                publicKeyBase64: "fixture-key",
                trustTier: "fixture",
                signatureBase64: "fixture-signature",
                signatureAlgorithm: "fixture"
            )
        }

        private func validEvent(
            application: String,
            category: String,
            sequence: UInt64
        ) -> HistoryEvent {
            let schemaVersion = 2
            let fieldOrder = IntegrityDomains.eventFieldOrder(for: schemaVersion)
            let commitments = fieldOrder.enumerated().map { index, name in
                let fields: [String: String]
                switch name {
                case "application": fields = ["name": application]
                case "classification": fields = ["category": category]
                default: fields = ["value": name]
                }
                return CommitmentBuilder.make(
                    name: name,
                    fields: fields,
                    salt: Data(repeating: UInt8(index + 20), count: 32)
                )
            }
            let commitmentsByName = Dictionary(
                uniqueKeysWithValues: commitments.map { ($0.name, $0.commitmentHex) }
            )
            let eventRoot = MerkleTree.root(
                labeledHexValues: fieldOrder.map { ($0, commitmentsByName[$0]!) }
            )
            let previousEventHash = String(repeating: "0", count: 64)
            let integrity = EventIntegrity(
                sequence: sequence,
                previousEventHash: previousEventHash,
                eventRoot: eventRoot,
                eventHash: ChainHash.event(
                    sequence: sequence,
                    previous: previousEventHash,
                    eventRoot: eventRoot
                ),
                fieldCommitments: commitments
            )
            return HistoryEvent(
                schemaVersion: schemaVersion,
                id: "event-\(sequence)",
                sessionID: "share-resource-test",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                kind: .mouseClick,
                app: AppSnapshot(
                    name: application,
                    bundleIdentifier: "test.\(application.lowercased())",
                    processIdentifier: 42
                ),
                classification: LocalClassification(
                    category: category,
                    isWork: true,
                    confidence: 1,
                    classifierVersion: "fixture"
                ),
                integrity: integrity
            )
        }

        private func validSeal(
            sequence: UInt64,
            eventRoots: [String],
            previousAnchorHash: String,
            day: Date
        ) -> LocalMinuteSeal {
            let start = day.addingTimeInterval(TimeInterval(sequence * 60))
            let eventsRoot = MerkleTree.root(
                labeledHexValues: eventRoots.enumerated().map {
                    ("event:\($0.offset)", $0.element)
                }
            )
            let minuteFields = IntegrityDomains.minuteFieldOrder.enumerated().map { index, name in
                let fields: [String: String]
                switch name {
                case "time":
                    fields = [
                        "start": String(start.timeIntervalSince1970),
                        "end": String(start.addingTimeInterval(60).timeIntervalSince1970),
                    ]
                case "events_root": fields = ["events_root": eventsRoot]
                case "event_count": fields = ["count": String(eventRoots.count)]
                case "coverage": fields = ["states": "captured"]
                default: fields = ["value": name]
                }
                return CommitmentBuilder.makeMinute(
                    name: name,
                    fields: fields,
                    salt: Data(repeating: UInt8(index + 40), count: 32)
                )
            }
            let commitmentsByName = Dictionary(
                uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) }
            )
            let minuteRoot = MerkleTree.root(
                labeledHexValues: IntegrityDomains.minuteFieldOrder.map {
                    ($0, commitmentsByName[$0]!)
                }
            )
            return LocalMinuteSeal(
                anchorSequence: sequence,
                minuteStart: start,
                minuteEnd: start.addingTimeInterval(60),
                minuteFields: minuteFields,
                eventRoots: eventRoots,
                minuteRoot: minuteRoot,
                previousAnchorHash: previousAnchorHash,
                anchorHash: ChainHash.anchor(
                    sequence: sequence,
                    previous: previousAnchorHash,
                    minuteRoot: minuteRoot
                ),
                deviceID: "fixture-device",
                publicKeyBase64: "fixture-key",
                trustTier: "fixture",
                signatureBase64: "fixture-signature",
                signatureAlgorithm: "fixture"
            )
        }

        private func writeLines<Value: Encodable>(
            _ values: [Value],
            to url: URL,
            atomically: Bool = false
        ) throws {
            var data = Data()
            for value in values { data.append(try line(value)) }
            try data.write(to: url, options: atomically ? [.atomic] : [])
        }

        private func appendLine<Value: Encodable>(_ value: Value, to url: URL) throws {
            try appendRaw(try line(value), to: url)
        }

        private func appendRaw(_ data: Data, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }

        private func line<Value: Encodable>(_ value: Value) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(0x0A)
            return data
        }

        private func slice(_ source: String, from start: String, through end: String) -> String? {
            guard let startRange = source.range(of: start),
                let endRange = source.range(
                    of: end,
                    range: startRange.upperBound..<source.endIndex
                )
            else { return nil }
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }
    }

#endif
