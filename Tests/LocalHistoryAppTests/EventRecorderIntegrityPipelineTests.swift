#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    final class EventRecorderIntegrityPipelineTests: XCTestCase {
        private enum FixtureError: Error {
            case injectedSealFailure
        }

        private final class FixtureIdentity: MinuteSealSigningIdentity {
            let info = DeviceIdentityInfo(
                deviceID: "fixture-device",
                publicKeyBase64: Data("fixture-public-key".utf8).base64EncodedString(),
                trustTier: "test",
                algorithm: "test-signature"
            )

            func sign(_ message: Data) throws -> Data {
                Data(SHA256Digest.hashHex(message).utf8)
            }
        }

        private final class OneShotPersistenceGate {
            let started = DispatchSemaphore(value: 0)
            private let releaseSemaphore = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var didBlock = false

            func blockFirstNonGapEvent(_ event: HistoryEvent) {
                guard event.kind != .recorderHealth else { return }
                lock.lock()
                guard !didBlock else {
                    lock.unlock()
                    return
                }
                didBlock = true
                lock.unlock()
                started.signal()
                _ = releaseSemaphore.wait(timeout: .now() + 5)
            }

            func release() {
                releaseSemaphore.signal()
            }
        }

        private var temporaryDirectories: [URL] = []

        override func tearDownWithError() throws {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            temporaryDirectories.removeAll()
            try super.tearDownWithError()
        }

        func testAppendFailureDoesNotAdvanceStateOrPublishSealRoot() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            let target = fixture.root.appendingPathComponent("external-target")
            try Data("protected".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: eventFile, withDestinationURL: target)

            let components = try makeRecorder(fixture: fixture, initialDate: timestamp)
            XCTAssertTrue(components.recorder.record(kind: .mouseClick, timestamp: timestamp))
            components.recorder.flush()
            components.sealer.waitUntilIdleForTesting()

            XCTAssertEqual(components.state.snapshot.nextEventSequence, 1)
            XCTAssertEqual(components.recorder.persistenceSnapshot.persistedEventCount, 0)
            XCTAssertEqual(components.recorder.persistenceSnapshot.failureCount, 1)
            XCTAssertEqual(components.recorder.persistenceSnapshot.lastFailureOperation, "append")
            XCTAssertEqual(components.sealer.runtimeSnapshot.pendingRootCount, 0)
            XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))

            try FileManager.default.removeItem(at: eventFile)
            XCTAssertTrue(components.recorder.record(kind: .mouseClick, timestamp: timestamp))
            try components.recorder.flushAndWait()
            components.sealer.waitUntilIdleForTesting()

            let events = try decodeEvents(at: eventFile)
            XCTAssertEqual(events.map { $0.integrity?.sequence }, [1])
            XCTAssertEqual(components.state.snapshot.nextEventSequence, 2)
            XCTAssertEqual(components.sealer.runtimeSnapshot.pendingRootCount, 1)
            try components.recorder.closeAndWait()
        }

        func testConcurrentCallersProduceOneOrderedHashChainWithoutDuplicates() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let components = try makeRecorder(fixture: fixture, initialDate: timestamp)

            DispatchQueue.concurrentPerform(iterations: 200) { index in
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        metadata: ["fixture_index": String(index)],
                        timestamp: timestamp.addingTimeInterval(Double(index) / 1_000)
                    )
                )
            }
            try components.recorder.flushAndWait()

            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            let events = try decodeEvents(at: eventFile)
            XCTAssertEqual(events.count, 200)
            XCTAssertEqual(events.compactMap { $0.integrity?.sequence }, Array(1...200).map(UInt64.init))
            XCTAssertEqual(Set(events.map(\.id)).count, 200)

            var previousHash = String(repeating: "0", count: 64)
            for event in events {
                let integrity = try XCTUnwrap(event.integrity)
                XCTAssertEqual(integrity.previousEventHash, previousHash)
                previousHash = integrity.eventHash
            }
            XCTAssertEqual(components.state.snapshot.nextEventSequence, 201)
            XCTAssertEqual(components.recorder.persistenceSnapshot.persistedEventCount, 200)
            XCTAssertEqual(components.recorder.persistenceSnapshot.failureCount, 0)
            XCTAssertLessThanOrEqual(
                components.recorder.persistenceSnapshot.writerQueueHighWaterMark,
                EventRecorder.defaultWriterQueueCapacity
            )
            try components.recorder.closeAndWait()
        }

        func testMainThreadSaturationIsNonBlockingAndPersistsOneOrderedGap() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let gate = OneShotPersistenceGate()
            let components = try makeRecorder(
                fixture: fixture,
                initialDate: timestamp,
                writerQueueCapacity: 4,
                isMainThread: { true },
                beforePersist: gate.blockFirstNonGapEvent
            )
            defer { gate.release() }

            XCTAssertTrue(
                components.recorder.record(
                    kind: .heartbeat,
                    metadata: ["fixture_index": "0"],
                    timestamp: timestamp
                )
            )
            XCTAssertEqual(gate.started.wait(timeout: .now() + 2), .success)
            for index in 1...2 {
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        metadata: ["fixture_index": String(index)],
                        timestamp: timestamp.addingTimeInterval(Double(index))
                    )
                )
            }

            let refusalStartedAt = Date()
            XCTAssertFalse(
                components.recorder.record(
                    kind: .heartbeat,
                    metadata: ["fixture_index": "3"],
                    timestamp: timestamp.addingTimeInterval(3)
                )
            )
            XCTAssertLessThan(Date().timeIntervalSince(refusalStartedAt), 0.25)
            XCTAssertFalse(
                components.recorder.record(
                    kind: .heartbeat,
                    metadata: ["fixture_index": "4"],
                    timestamp: timestamp.addingTimeInterval(4)
                )
            )

            var snapshot = components.recorder.persistenceSnapshot
            XCTAssertEqual(snapshot.acceptedEventCount, 3)
            XCTAssertEqual(snapshot.droppedEventCount, 2)
            XCTAssertEqual(snapshot.pendingEventCount, 3)
            XCTAssertEqual(snapshot.writerQueueDepth, 4)
            XCTAssertEqual(snapshot.writerQueueHighWaterMark, 4)
            XCTAssertEqual(snapshot.writerQueueCapacity, 4)
            XCTAssertEqual(snapshot.failureCount, 1)
            XCTAssertEqual(snapshot.lastFailureOperation, "writer_overflow")

            gate.release()
            try components.recorder.flushAndWait()

            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            let events = try decodeEvents(at: eventFile)
            XCTAssertEqual(
                events.compactMap { $0.integrity?.sequence },
                Array(1...4).map(UInt64.init)
            )
            XCTAssertEqual(
                events.prefix(3).compactMap { $0.metadata?["fixture_index"] },
                ["0", "1", "2"]
            )
            let gap = try XCTUnwrap(events.last)
            XCTAssertEqual(gap.kind, .recorderHealth)
            XCTAssertEqual(gap.metadata?["observation_gap"], "true")
            XCTAssertEqual(gap.metadata?["gap_reason"], "writer_queue_capacity")
            XCTAssertEqual(gap.metadata?["dropped_event_count"], "2")
            XCTAssertTrue(gap.isObservationContinuityBoundary)

            snapshot = components.recorder.persistenceSnapshot
            XCTAssertEqual(snapshot.persistedEventCount, 3)
            XCTAssertEqual(snapshot.persistedObservationGapCount, 1)
            XCTAssertEqual(snapshot.pendingEventCount, 0)
            XCTAssertEqual(snapshot.writerQueueDepth, 0)
            try components.recorder.closeAndWait()
        }

        func testOffMainProducersBackpressureAndDrainWithoutDropping() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let gate = OneShotPersistenceGate()
            let components = try makeRecorder(
                fixture: fixture,
                initialDate: timestamp,
                writerQueueCapacity: 3,
                isMainThread: { false },
                beforePersist: gate.blockFirstNonGapEvent
            )
            defer { gate.release() }

            let callers = DispatchQueue(
                label: "event-recorder-backpressure-callers",
                attributes: .concurrent
            )
            let completed = DispatchGroup()
            let thirdReturned = DispatchSemaphore(value: 0)

            completed.enter()
            callers.async {
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        metadata: ["fixture_index": "0"],
                        timestamp: timestamp
                    )
                )
                completed.leave()
            }
            XCTAssertEqual(gate.started.wait(timeout: .now() + 2), .success)

            completed.enter()
            callers.async {
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        metadata: ["fixture_index": "1"],
                        timestamp: timestamp.addingTimeInterval(1)
                    )
                )
                completed.leave()
            }
            XCTAssertTrue(
                waitUntil {
                    components.recorder.persistenceSnapshot.pendingEventCount == 2
                }
            )

            completed.enter()
            callers.async {
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        metadata: ["fixture_index": "2"],
                        timestamp: timestamp.addingTimeInterval(2)
                    )
                )
                thirdReturned.signal()
                completed.leave()
            }
            XCTAssertEqual(thirdReturned.wait(timeout: .now() + 0.05), .timedOut)

            var snapshot = components.recorder.persistenceSnapshot
            XCTAssertEqual(snapshot.pendingEventCount, 2)
            XCTAssertEqual(snapshot.writerQueueDepth, 2)
            XCTAssertEqual(snapshot.droppedEventCount, 0)
            XCTAssertLessThanOrEqual(snapshot.writerQueueHighWaterMark, 3)

            gate.release()
            XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
            try components.recorder.flushAndWait()

            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            let events = try decodeEvents(at: eventFile)
            XCTAssertEqual(
                events.compactMap { $0.integrity?.sequence },
                Array(1...3).map(UInt64.init)
            )
            XCTAssertEqual(events.compactMap { $0.metadata?["fixture_index"] }, ["0", "1", "2"])

            snapshot = components.recorder.persistenceSnapshot
            XCTAssertEqual(snapshot.acceptedEventCount, 3)
            XCTAssertEqual(snapshot.persistedEventCount, 3)
            XCTAssertEqual(snapshot.droppedEventCount, 0)
            XCTAssertEqual(snapshot.pendingEventCount, 0)
            XCTAssertEqual(snapshot.writerQueueDepth, 0)
            try components.recorder.closeAndWait()
        }

        func testDurableTailRecoversCheckpointLagBeforeNextSequence() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)

            let firstStore = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: fixture.events,
                prepareApplicationStorage: false
            )
            let firstState = makeState(fixture)
            let firstJournal = IntegrityJournal(stateStore: firstState)
            let firstBase = HistoryEvent(
                schemaVersion: 4,
                sessionID: "crash-proxy",
                timestamp: timestamp,
                kind: .mouseClick
            )
            let durableButUncheckpointed = firstJournal.prepare(firstBase)
            _ = try firstStore.appendAndWait(durableButUncheckpointed)
            try firstStore.flushAndWait()
            try firstStore.closeAndWait()
            XCTAssertEqual(firstState.snapshot.nextEventSequence, 1)

            let secondStore = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: fixture.events,
                prepareApplicationStorage: false
            )
            let secondState = makeState(fixture)
            let secondJournal = IntegrityJournal(stateStore: secondState)
            let secondSealer = makeSealer(
                state: secondState,
                fixture: fixture,
                initialDate: timestamp
            )
            let recorder = EventRecorder(
                store: secondStore,
                integrityJournal: secondJournal,
                minuteSealer: secondSealer
            )

            XCTAssertEqual(secondState.snapshot.nextEventSequence, 2)
            XCTAssertTrue(recorder.record(kind: .keyboardShortcut, timestamp: timestamp))
            try recorder.flushAndWait()

            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            let events = try decodeEvents(at: eventFile)
            XCTAssertEqual(events.compactMap { $0.integrity?.sequence }, [1, 2])
            XCTAssertEqual(events[1].integrity?.previousEventHash, events[0].integrity?.eventHash)
            try recorder.closeAndWait()
        }

        func testIncompleteCrashTailIsIsolatedBeforeNextValidRow() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".jsonl"
            )
            try Data("{\"partial_crash_row\"".utf8).write(to: eventFile)

            let components = try makeRecorder(fixture: fixture, initialDate: timestamp)
            XCTAssertTrue(components.recorder.record(kind: .mouseClick, timestamp: timestamp))
            try components.recorder.flushAndWait()

            let rows = try Data(contentsOf: eventFile).split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            )
            XCTAssertEqual(rows.count, 2)
            XCTAssertThrowsError(try eventDecoder().decode(HistoryEvent.self, from: Data(rows[0])))
            XCTAssertNoThrow(try eventDecoder().decode(HistoryEvent.self, from: Data(rows[1])))
            try components.recorder.closeAndWait()
        }

        func testStateIOIsGroupedBehindJournalSynchronization() throws {
            let fixture = try makeFixture()
            let timestamp = Date(timeIntervalSince1970: 1_787_480_000)
            let components = try makeRecorder(fixture: fixture, initialDate: timestamp)

            for index in 0..<20 {
                XCTAssertTrue(
                    components.recorder.record(
                        kind: .heartbeat,
                        timestamp: timestamp.addingTimeInterval(Double(index) / 100)
                    )
                )
            }
            try components.recorder.flushAndWait()

            XCTAssertEqual(components.store.metrics.appendedLineCount, 20)
            XCTAssertEqual(components.store.metrics.synchronizationCount, 1)
            XCTAssertEqual(components.state.persistenceCount, 1)
            XCTAssertEqual(components.recorder.persistenceSnapshot.persistedEventCount, 20)
            try components.recorder.closeAndWait()
            XCTAssertEqual(components.store.metrics.synchronizationCount, 1)
            XCTAssertEqual(components.state.persistenceCount, 1)
        }

        func testPersistedSealDiscoveryReadsRegularFilesButNeverFollowsSymlinks() throws {
            let fixture = try makeFixture()
            let regularSeal = fixtureSeal(sequence: 3, anchorHash: "regular-anchor")
            try sealLine(regularSeal).write(
                to: fixture.seals.appendingPathComponent("2026-08-23.seals.jsonl")
            )

            let outside = fixture.root.appendingPathComponent("outside.seals.jsonl")
            try sealLine(fixtureSeal(sequence: 999, anchorHash: "symlink-anchor")).write(
                to: outside
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.seals.appendingPathComponent("2099-01-01.seals.jsonl"),
                withDestinationURL: outside
            )

            let state = makeState(fixture)
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            )

            XCTAssertEqual(state.snapshot.nextAnchorSequence, 4)
            XCTAssertEqual(state.snapshot.previousAnchorHash, regularSeal.anchorHash)
            XCTAssertNil(sealer.runtimeSnapshot.lastErrorDescription)
        }

        func testPersistedSealDiscoveryClosesEachFileBeforeOpeningTheNext() throws {
            let fixture = try makeFixture()
            for index in 0..<384 {
                try Data().write(
                    to: fixture.seals.appendingPathComponent(
                        String(format: "2026-08-%03d.seals.jsonl", index)
                    )
                )
            }

            let state = makeState(fixture)
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            )

            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)
            XCTAssertNil(sealer.runtimeSnapshot.lastErrorDescription)
        }

        func testDefaultSealAppendIsNoFollowAndSeparatesAnIncompleteTail() throws {
            let fixture = try makeFixture()
            let minute = Date(timeIntervalSince1970: 120)
            let sealFile = fixture.seals.appendingPathComponent(
                AppPaths.localDayString(for: minute) + ".seals.jsonl"
            )
            try Data("{\"partial_crash_row\"".utf8).write(to: sealFile)

            let state = makeState(fixture)
            let sealer = MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: minute,
                sealDirectory: fixture.seals,
                prepareStorage: {}
            )
            sealer.receive(
                fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "root")
            )

            XCTAssertTrue(
                sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1))
            )
            let rows = try Data(contentsOf: sealFile).split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            )
            XCTAssertEqual(rows.count, 2)
            XCTAssertThrowsError(
                try sealDecoder().decode(LocalMinuteSeal.self, from: Data(rows[0]))
            )
            XCTAssertEqual(
                try sealDecoder().decode(LocalMinuteSeal.self, from: Data(rows[1])).anchorSequence,
                1
            )
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 2)
        }

        func testCreatedSealFileSynchronizesFileThenParentBeforeCheckpoint() throws {
            let fixture = try makeFixture()
            let minute = Date(timeIntervalSince1970: 120)
            let sealFile = fixture.seals.appendingPathComponent(
                AppPaths.localDayString(for: minute) + ".seals.jsonl"
            )
            let state = makeState(fixture)
            var durabilitySteps: [MinuteSealer.AppendDurabilityStep] = []
            var checkpointSequences: [UInt64] = []
            var fileExistedWhenCreationWasObserved = false
            let sealer = MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: minute,
                sealDirectory: fixture.seals,
                prepareStorage: {},
                sealAppender: { seal, url in
                    try MinuteSealer.appendJSONLine(
                        seal,
                        to: url,
                        durabilityObserver: { step in
                            durabilitySteps.append(step)
                            checkpointSequences.append(state.snapshot.nextAnchorSequence)
                            if step == .fileCreated {
                                fileExistedWhenCreationWasObserved =
                                    FileManager.default.fileExists(atPath: sealFile.path)
                            }
                        }
                    )
                }
            )
            sealer.receive(
                fixtureEvent(timestamp: minute.addingTimeInterval(59.9), root: "root")
            )

            XCTAssertTrue(
                sealer.sealElapsedMinutesForTesting(now: minute.addingTimeInterval(61.1))
            )
            XCTAssertEqual(
                durabilitySteps,
                [.fileCreated, .fileSynchronized, .parentDirectorySynchronized]
            )
            XCTAssertEqual(checkpointSequences, [1, 1, 1])
            XCTAssertTrue(fileExistedWhenCreationWasObserved)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 2)
            XCTAssertEqual(try Data(contentsOf: sealFile).last, 0x0A)
        }

        func testEmptySealFileRetrySynchronizesParentBeforeCheckpoint() throws {
            let fixture = try makeFixture()
            let minute = Date(timeIntervalSince1970: 120)
            let sealFile = fixture.seals.appendingPathComponent(
                AppPaths.localDayString(for: minute) + ".seals.jsonl"
            )
            let state = makeState(fixture)
            var durabilitySteps: [MinuteSealer.AppendDurabilityStep] = []
            var checkpointSequences: [UInt64] = []
            var failAfterInitialCreation = true
            let sealer = MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: minute,
                sealDirectory: fixture.seals,
                prepareStorage: {},
                sealAppender: { seal, url in
                    try MinuteSealer.appendJSONLine(
                        seal,
                        to: url,
                        durabilityObserver: { step in
                            durabilitySteps.append(step)
                            checkpointSequences.append(state.snapshot.nextAnchorSequence)
                        },
                        afterFileCreationForTesting: {
                            if failAfterInitialCreation {
                                failAfterInitialCreation = false
                                throw FixtureError.injectedSealFailure
                            }
                        }
                    )
                }
            )
            sealer.receive(
                fixtureEvent(timestamp: minute.addingTimeInterval(59.9), root: "root")
            )

            XCTAssertFalse(
                sealer.sealElapsedMinutesForTesting(now: minute.addingTimeInterval(61.1))
            )
            XCTAssertFalse(failAfterInitialCreation)
            XCTAssertEqual(durabilitySteps, [.fileCreated])
            XCTAssertEqual(checkpointSequences, [1])
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)
            XCTAssertEqual(try Data(contentsOf: sealFile).count, 0)

            XCTAssertTrue(
                sealer.sealElapsedMinutesForTesting(now: minute.addingTimeInterval(62.2))
            )
            XCTAssertEqual(
                durabilitySteps,
                [.fileCreated, .fileSynchronized, .parentDirectorySynchronized]
            )
            XCTAssertEqual(checkpointSequences, [1, 1, 1])
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 2)
            XCTAssertEqual(try Data(contentsOf: sealFile).last, 0x0A)
        }

        func testPersistedSealTailUsesTheByteBeforeItsWindowAsTheRowBoundary() throws {
            let fixture = try makeFixture()
            let seal = fixtureSeal(
                sequence: 41,
                anchorHash: "large-tail-anchor",
                eventRoots: Array(
                    repeating: String(repeating: "a", count: 64),
                    count: MinuteSealer.maximumBufferedRoots
                )
            )
            let sealRow = try sealLine(seal)
            XCTAssertGreaterThan(sealRow.count, 1 * 1_024 * 1_024)

            let tailWindowByteCount = MinuteSealer.maximumEncodedSealRowBytes + 2
            let partialTailByteCount = tailWindowByteCount - sealRow.count
            XCTAssertGreaterThan(partialTailByteCount, 512 * 1_024)

            var persistedData = Data("discarded-prefix\n".utf8)
            let expectedTailOffset = persistedData.count
            persistedData.append(sealRow)
            persistedData.append(Data(repeating: 0x7B, count: partialTailByteCount))
            XCTAssertEqual(
                persistedData.count - tailWindowByteCount,
                expectedTailOffset,
                "the bounded read must start exactly after the preceding newline"
            )
            try persistedData.write(
                to: fixture.seals.appendingPathComponent("2026-08-23.seals.jsonl")
            )

            let state = makeState(fixture)
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            )

            XCTAssertEqual(state.snapshot.nextAnchorSequence, 42)
            XCTAssertEqual(state.snapshot.previousAnchorHash, seal.anchorHash)
            XCTAssertNil(sealer.runtimeSnapshot.lastErrorDescription)
        }

        func testDefaultSealAppendRefusesASymlinkTarget() throws {
            let fixture = try makeFixture()
            let minute = Date(timeIntervalSince1970: 120)
            let target = fixture.root.appendingPathComponent("outside-target")
            try Data("protected".utf8).write(to: target)
            let sealFile = fixture.seals.appendingPathComponent(
                AppPaths.localDayString(for: minute) + ".seals.jsonl"
            )
            try FileManager.default.createSymbolicLink(at: sealFile, withDestinationURL: target)

            let state = makeState(fixture)
            let sealer = MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: minute,
                sealDirectory: fixture.seals,
                prepareStorage: {}
            )
            sealer.receive(
                fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "root")
            )

            XCTAssertFalse(
                sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1))
            )
            XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 1)
        }

        func testUncertainSealDurabilitySuspendsBeforeReusingAnchorSequence() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var attempts = 0
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            ) { _, _ in
                attempts += 1
                throw MinuteSealPersistenceError.durabilityUncertain("fixture sync failure")
            }
            sealer.receive(
                fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "root")
            )

            XCTAssertFalse(
                sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1))
            )
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 1)
            XCTAssertTrue(sealer.runtimeSnapshot.signingSuspended)

            XCTAssertFalse(
                sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 240))
            )
            XCTAssertEqual(attempts, 1, "an uncertain append must never be retried in-process")
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)
        }

        func testFailedSealRetainsRootsAndRetriesWithBackoff() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var attempts = 0
            var persistedSeals: [LocalMinuteSeal] = []
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            ) { seal, _ in
                attempts += 1
                if attempts == 1 { throw FixtureError.injectedSealFailure }
                persistedSeals.append(seal)
            }
            sealer.receive(fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "late-root"))
            sealer.waitUntilIdleForTesting()

            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 1)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 1)

            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.5)))
            XCTAssertEqual(attempts, 1, "retry must not busy-loop before its backoff deadline")
            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 182.2)))
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(persistedSeals.single?.eventRoots, ["late-root"])
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 0)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 2)
        }

        func testPreviousMinuteRootReceivedAfterWakeGetsSupplementalSeal() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var persistedSeals: [LocalMinuteSeal] = []
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            ) { seal, _ in
                persistedSeals.append(seal)
            }

            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertEqual(persistedSeals.count, 1)
            XCTAssertTrue(persistedSeals[0].eventRoots.isEmpty)

            // The 1.1-second typing debounce can deliver an event timestamped 179.9
            // after the boundary+grace wake already sealed minute 120.
            sealer.receive(fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "typing-root"))
            sealer.waitUntilIdleForTesting()

            XCTAssertEqual(persistedSeals.count, 2)
            XCTAssertEqual(persistedSeals[1].minuteStart, Date(timeIntervalSince1970: 120))
            XCTAssertEqual(persistedSeals[1].eventRoots, ["typing-root"])
            XCTAssertEqual(persistedSeals[1].anchorSequence, 2)
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 0)
            XCTAssertEqual(sealer.runtimeSnapshot.unbufferedRootCount, 0)
        }

        func testLateBucketQueuedBehindFailedSealIsEventuallyDrained() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var attempts = 0
            var persistedSeals: [LocalMinuteSeal] = []
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            ) { seal, _ in
                attempts += 1
                if attempts == 1 { throw FixtureError.injectedSealFailure }
                persistedSeals.append(seal)
            }

            sealer.receive(fixtureEvent(timestamp: Date(timeIntervalSince1970: 179.9), root: "base-root"))
            sealer.waitUntilIdleForTesting()
            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))

            sealer.receive(fixtureEvent(timestamp: Date(timeIntervalSince1970: 119.9), root: "late-root"))
            sealer.waitUntilIdleForTesting()
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 2)

            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 182.2)))
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(persistedSeals.map(\.eventRoots), [["base-root"], ["late-root"]])
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 0)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 3)
        }

        func testPersistentSealFailureHasBoundedRetriesAndMinuteBuffer() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var attempts = 0
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            ) { _, _ in
                attempts += 1
                throw FixtureError.injectedSealFailure
            }

            for minute in 0..<8 {
                sealer.receive(
                    fixtureEvent(
                        timestamp: Date(timeIntervalSince1970: 179.9 + Double(minute * 60)),
                        root: "root-\(minute)"
                    )
                )
            }
            sealer.waitUntilIdleForTesting()
            for now in [181.1, 182.2, 184.3, 188.4, 196.5, 212.6, 244.7] {
                _ = sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: now))
            }

            let snapshot = sealer.runtimeSnapshot
            XCTAssertLessThanOrEqual(snapshot.pendingMinuteCount, 3)
            XCTAssertEqual(attempts, 6)
            XCTAssertTrue(snapshot.signingSuspended)
            XCTAssertGreaterThan(snapshot.unbufferedRootCount, 0)
        }

        func testPendingSealRootBufferHasAHardMemoryBound() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: Date(timeIntervalSince1970: 120)
            )

            for index in 0..<MinuteSealer.maximumBufferedRoots + 25 {
                sealer.receive(
                    fixtureEvent(
                        timestamp: Date(timeIntervalSince1970: 179.9),
                        root: "root-\(index)"
                    )
                )
            }
            sealer.waitUntilIdleForTesting()

            let snapshot = sealer.runtimeSnapshot
            XCTAssertEqual(snapshot.pendingRootCount, MinuteSealer.maximumBufferedRoots)
            XCTAssertEqual(snapshot.unbufferedRootCount, 25)
        }

        func testMaximumRootSealFitsTheSharedWriterAndReplayLimit() throws {
            let fixture = try makeFixture()
            let receipts = fixture.root.appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            let state = makeState(fixture)
            let initialMinute = Date(timeIntervalSince1970: 120)
            let sealer = MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: initialMinute,
                sealDirectory: fixture.seals,
                prepareStorage: {}
            )

            for index in 0..<MinuteSealer.maximumBufferedRoots {
                sealer.receive(
                    fixtureEvent(
                        timestamp: initialMinute.addingTimeInterval(59.9),
                        root: String(format: "%064llx", UInt64(index))
                    )
                )
            }
            sealer.waitUntilIdleForTesting()
            XCTAssertTrue(
                sealer.sealElapsedMinutesForTesting(
                    now: initialMinute.addingTimeInterval(61.1)
                )
            )

            let file = fixture.seals.appendingPathComponent(
                AppPaths.localDayString(for: initialMinute) + ".seals.jsonl"
            )
            let rows = try Data(contentsOf: file).split(
                separator: 0x0A,
                omittingEmptySubsequences: true
            )
            XCTAssertEqual(rows.count, 1)
            XCTAssertGreaterThan(
                rows[0].count,
                1 * 1_024 * 1_024,
                "the fixture must prove the former 1 MiB replay limit was too small"
            )
            XCTAssertLessThanOrEqual(
                rows[0].count,
                MinuteSealer.maximumEncodedSealRowBytes
            )

            let scanner = CommitmentReplayScanner(
                sealsDirectory: fixture.seals,
                receiptsDirectory: receipts,
                limits: .production
            )
            var replayed: [LocalMinuteSeal] = []
            for _ in 0..<4 {
                let batch = scanner.nextBatch(
                    maximumCount: 1,
                    maximumBytes: CommitmentReplayLimits.production.queueByteCapacity
                )
                replayed.append(contentsOf: batch.seals.map(\.seal))
                if !replayed.isEmpty { break }
            }
            let replayedSeal = try XCTUnwrap(replayed.single)
            XCTAssertEqual(replayedSeal.eventRoots.count, MinuteSealer.maximumBufferedRoots)
            XCTAssertEqual(replayedSeal.anchorHash, state.snapshot.previousAnchorHash)
        }

        func testMultiDayEmptyCatchupIsCoalescedAndPreservesAnchorChain() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let initialMinute = try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        timeZone: .current,
                        year: 2026,
                        month: 8,
                        day: 10
                    )
                )
            )
            let end = try XCTUnwrap(
                calendar.date(byAdding: .day, value: 10, to: initialMinute)
            )
            var persistedSeals: [LocalMinuteSeal] = []
            var sealFiles: [URL] = []
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: initialMinute
            ) { seal, file in
                persistedSeals.append(seal)
                sealFiles.append(file)
            }

            XCTAssertFalse(
                sealer.sealElapsedMinutesForTesting(now: end.addingTimeInterval(1.1)),
                "one wake must yield after its bounded batch"
            )
            XCTAssertEqual(persistedSeals.count, 8)
            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: end.addingTimeInterval(1.1)))
            XCTAssertEqual(persistedSeals.count, 10)
            XCTAssertEqual(persistedSeals.map(\.anchorSequence), Array(1...10).map(UInt64.init))

            var totalDuration: TimeInterval = 0
            for (index, seal) in persistedSeals.enumerated() {
                let nextDay = try XCTUnwrap(
                    calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: calendar.startOfDay(for: seal.minuteStart)
                    )
                )
                XCTAssertLessThanOrEqual(seal.minuteEnd, nextDay)
                XCTAssertEqual(
                    sealFiles[index].lastPathComponent,
                    AppPaths.localDayString(for: seal.minuteStart) + ".seals.jsonl"
                )
                let coverage = try XCTUnwrap(
                    seal.minuteFields.first { $0.name == "coverage" }
                )
                XCTAssertEqual(coverage.opening.fields["interval_kind"], "coalesced_empty")
                XCTAssertEqual(
                    seal.anchorHash,
                    ChainHash.anchor(
                        sequence: seal.anchorSequence,
                        previous: seal.previousAnchorHash,
                        minuteRoot: seal.minuteRoot
                    )
                )
                if index > 0 {
                    XCTAssertEqual(seal.previousAnchorHash, persistedSeals[index - 1].anchorHash)
                }
                totalDuration += seal.minuteEnd.timeIntervalSince(seal.minuteStart)
            }
            XCTAssertEqual(totalDuration, end.timeIntervalSince(initialMinute), accuracy: 0.001)
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 11)
        }

        func testSleepCatchupKeepsSleepCoverageUntilTheWakeEventMinute() throws {
            let fixture = try makeFixture()
            let state = makeState(fixture)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let initialMinute = try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        timeZone: .current,
                        year: 2026,
                        month: 8,
                        day: 10,
                        hour: 12
                    )
                )
            )
            let wakeMinute = initialMinute.addingTimeInterval(3 * 60 * 60)
            var persistedSeals: [LocalMinuteSeal] = []
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: initialMinute
            ) { seal, _ in
                persistedSeals.append(seal)
            }

            sealer.receive(
                fixtureEvent(
                    timestamp: initialMinute.addingTimeInterval(10),
                    root: "sleep-root",
                    kind: .systemSleep
                )
            )
            sealer.receive(
                fixtureEvent(
                    timestamp: wakeMinute.addingTimeInterval(5),
                    root: "wake-root",
                    kind: .systemWake
                )
            )
            sealer.waitUntilIdleForTesting()
            XCTAssertTrue(
                sealer.sealElapsedMinutesForTesting(
                    now: wakeMinute.addingTimeInterval(61.1)
                )
            )

            let emptySleepInterval = try XCTUnwrap(
                persistedSeals.first { $0.eventRoots.isEmpty }
            )
            let emptyCoverage = try XCTUnwrap(
                emptySleepInterval.minuteFields.first { $0.name == "coverage" }
            )
            XCTAssertEqual(emptyCoverage.opening.fields["states"], "systemSleep")
            XCTAssertEqual(emptyCoverage.opening.fields["interval_kind"], "coalesced_empty")

            let wakeSeal = try XCTUnwrap(
                persistedSeals.first { $0.eventRoots == ["wake-root"] }
            )
            let wakeCoverage = try XCTUnwrap(
                wakeSeal.minuteFields.first { $0.name == "coverage" }
            )
            XCTAssertTrue(wakeCoverage.opening.fields["states"]?.contains("captured") == true)
            XCTAssertEqual(wakeSeal.minuteStart, wakeMinute)
        }

        func testSlowCatchupSealNeverBlocksTheRawEventWriter() throws {
            let fixture = try makeFixture()
            let initialMinute = Date(timeIntervalSince1970: 120)
            let eventTimestamp = initialMinute.addingTimeInterval(3 * 60)
            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: fixture.events,
                prepareApplicationStorage: false
            )
            let state = makeState(fixture)
            let journal = IntegrityJournal(stateStore: state)
            let sealStarted = DispatchSemaphore(value: 0)
            let releaseSeal = DispatchSemaphore(value: 0)
            let sealer = makeSealer(
                state: state,
                fixture: fixture,
                initialDate: initialMinute
            ) { _, _ in
                sealStarted.signal()
                _ = releaseSeal.wait(timeout: .now() + 5)
            }
            let recorder = EventRecorder(
                store: store,
                integrityJournal: journal,
                minuteSealer: sealer
            )
            defer { releaseSeal.signal() }

            XCTAssertTrue(recorder.record(kind: .heartbeat, timestamp: eventTimestamp))
            XCTAssertEqual(sealStarted.wait(timeout: .now() + 2), .success)

            let secondWriterReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                XCTAssertTrue(
                    recorder.record(
                        kind: .keyboardShortcut,
                        timestamp: eventTimestamp.addingTimeInterval(1)
                    )
                )
                secondWriterReturned.signal()
            }
            XCTAssertEqual(
                secondWriterReturned.wait(timeout: .now() + 1),
                .success,
                "the durable raw-event writer must not wait for seal signing or fsync"
            )
            try recorder.flushAndWait()
            XCTAssertEqual(recorder.persistenceSnapshot.persistedEventCount, 2)

            releaseSeal.signal()
            sealer.waitUntilIdleForTesting()
            let eventFile = fixture.events.appendingPathComponent(
                AppPaths.localDayString(for: eventTimestamp) + ".jsonl"
            )
            XCTAssertEqual(try decodeEvents(at: eventFile).count, 2)
            try recorder.closeAndWait()
        }

        private struct Fixture {
            let root: URL
            let events: URL
            let seals: URL
            let stateFile: URL
        }

        private struct RecorderComponents {
            let store: JSONLStore
            let state: IntegrityStateStore
            let sealer: MinuteSealer
            let recorder: EventRecorder
        }

        private func makeFixture() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "event-recorder-integrity-\(UUID().uuidString)",
                isDirectory: true
            )
            let events = root.appendingPathComponent("events", isDirectory: true)
            let seals = root.appendingPathComponent("seals", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: seals, withIntermediateDirectories: true)
            temporaryDirectories.append(root)
            return Fixture(
                root: root,
                events: events,
                seals: seals,
                stateFile: root.appendingPathComponent("integrity-state.json")
            )
        }

        private func makeState(_ fixture: Fixture) -> IntegrityStateStore {
            IntegrityStateStore(
                fileURL: fixture.stateFile,
                prepareStorage: {}
            )
        }

        private func makeSealer(
            state: IntegrityStateStore,
            fixture: Fixture,
            initialDate: Date,
            sealAppender: MinuteSealer.SealAppender? = nil
        ) -> MinuteSealer {
            MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: initialDate,
                sealDirectory: fixture.seals,
                prepareStorage: {},
                sealAppender: sealAppender ?? { _, _ in }
            )
        }

        private func makeRecorder(
            fixture: Fixture,
            initialDate: Date,
            writerQueueCapacity: Int = EventRecorder.defaultWriterQueueCapacity,
            isMainThread: @escaping () -> Bool = { Thread.isMainThread },
            beforePersist: ((HistoryEvent) -> Void)? = nil
        ) throws -> RecorderComponents {
            let store = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: fixture.events,
                prepareApplicationStorage: false
            )
            let state = makeState(fixture)
            let journal = IntegrityJournal(stateStore: state)
            let sealer = makeSealer(state: state, fixture: fixture, initialDate: initialDate)
            let recorder = EventRecorder(
                store: store,
                integrityJournal: journal,
                minuteSealer: sealer,
                writerQueueCapacity: writerQueueCapacity,
                isMainThread: isMainThread,
                beforePersist: beforePersist
            )
            return RecorderComponents(store: store, state: state, sealer: sealer, recorder: recorder)
        }

        private func waitUntil(
            timeout: TimeInterval = 1,
            condition: () -> Bool
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return condition()
        }

        private func fixtureEvent(
            timestamp: Date,
            root: String,
            kind: EventKind = .typingBurst,
            metadata: [String: String]? = nil
        ) -> HistoryEvent {
            HistoryEvent(
                schemaVersion: 4,
                sessionID: "minute-sealer-fixture",
                timestamp: timestamp,
                kind: kind,
                metadata: metadata,
                integrity: EventIntegrity(
                    sequence: 1,
                    previousEventHash: String(repeating: "0", count: 64),
                    eventRoot: root,
                    eventHash: SHA256Digest.hashHex(root),
                    fieldCommitments: []
                )
            )
        }

        private func fixtureSeal(
            sequence: UInt64,
            anchorHash: String,
            eventRoots: [String] = []
        ) -> LocalMinuteSeal {
            LocalMinuteSeal(
                anchorSequence: sequence,
                minuteStart: Date(timeIntervalSince1970: 120),
                minuteEnd: Date(timeIntervalSince1970: 180),
                minuteFields: [],
                eventRoots: eventRoots,
                minuteRoot: "minute-\(sequence)",
                previousAnchorHash: "previous-\(sequence)",
                anchorHash: anchorHash,
                deviceID: "fixture-device",
                publicKeyBase64: "fixture-key",
                trustTier: "fixture",
                signatureBase64: "fixture-signature",
                signatureAlgorithm: "fixture"
            )
        }

        private func sealLine(_ seal: LocalMinuteSeal) throws -> Data {
            var data = try sealEncoder().encode(seal)
            data.append(0x0A)
            return data
        }

        private func sealEncoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        private func sealDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }

        private func decodeEvents(at url: URL) throws -> [HistoryEvent] {
            try Data(contentsOf: url)
                .split(separator: 0x0A, omittingEmptySubsequences: true)
                .map { try eventDecoder().decode(HistoryEvent.self, from: Data($0)) }
        }

        private func eventDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }

    extension Array {
        fileprivate var single: Element? { count == 1 ? self[0] : nil }
    }
#endif
