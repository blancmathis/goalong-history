#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    /// A full disk used to stop recording until the next launch: one uncertain write
    /// refused every later append. These tests pin the in-process recovery that
    /// replaced that restart, including the exact integrity chain afterwards.
    final class EventRecorderStorageRecoveryTests: XCTestCase {
        private final class FixtureIdentity: MinuteSealSigningIdentity {
            let info = DeviceIdentityInfo(deviceID: "fixture-device", publicKeyBase64: "", trustTier: "test", algorithm: "test")
            func sign(_ message: Data) throws -> Data { Data(SHA256Digest.hashHex(message).utf8) }
        }

        /// Scripted writer: each queued behaviour is used once, then writes succeed.
        private final class ScriptedWriter {
            enum Step { case partialThenFull, completeThenFail, fail }
            private let lock = NSLock()
            private var steps: [Step]
            private(set) var calls = 0
            var alwaysFail = false
            init(_ steps: [Step]) { self.steps = steps }

            func write(_ handle: FileHandle, _ data: Data) throws {
                lock.lock()
                calls += 1
                let step = alwaysFail ? .fail : (steps.isEmpty ? nil : steps.removeFirst())
                lock.unlock()
                let diskFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
                switch step {
                case .none: try handle.write(contentsOf: data)
                case .partialThenFull?:
                    try handle.write(contentsOf: data.prefix(data.count / 2))
                    throw diskFull
                case .completeThenFail?:
                    try handle.write(contentsOf: data)
                    throw diskFull
                case .fail?:
                    throw diskFull
                }
            }
        }

        private final class Clock {
            var now = Date(timeIntervalSince1970: 1_790_000_000)
        }

        private var roots: [URL] = []
        override func tearDownWithError() throws {
            for root in roots { try? FileManager.default.removeItem(at: root) }
            try super.tearDownWithError()
        }

        private func makeRecorder(writer: ScriptedWriter, clock: Clock) throws -> (EventRecorder, IntegrityStateStore, URL) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("event-recorder-storage-\(UUID().uuidString)")
            let events = root.appendingPathComponent("events", isDirectory: true)
            let seals = root.appendingPathComponent("seals", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: seals, withIntermediateDirectories: true)
            roots.append(root)
            let store = try JSONLStore(retentionDays: 0, eventsDirectory: events, prepareApplicationStorage: false,
                                       rowWriter: { try writer.write($0, $1) })
            let state = IntegrityStateStore(fileURL: root.appendingPathComponent("integrity-state.json"), prepareStorage: {})
            let sealer = MinuteSealer(stateStore: state, identity: FixtureIdentity(), initialDate: clock.now,
                                      sealDirectory: seals, prepareStorage: {}, sealAppender: { _, _ in })
            let recorder = EventRecorder(store: store, integrityJournal: IntegrityJournal(stateStore: state),
                                         minuteSealer: sealer, clock: { clock.now }, storageRetryDelays: [5, 30])
            return (recorder, state, events)
        }

        private func persistedEvents(in directory: URL) throws -> [HistoryEvent] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var events: [HistoryEvent] = []
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".jsonl") {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                for line in data.split(separator: 0x0A) {
                    if let event = try? decoder.decode(HistoryEvent.self, from: Data(line)) { events.append(event) }
                }
            }
            return events.sorted { ($0.integrity?.sequence ?? 0) < ($1.integrity?.sequence ?? 0) }
        }

        private func record(_ recorder: EventRecorder, at date: Date) {
            XCTAssertTrue(recorder.record(kind: .mouseClick, timestamp: date))
            recorder.flush()
        }

        func testPartialWriteOnFullDiskRecoversWithoutRestartAndRecordsTheGap() throws {
            let writer = ScriptedWriter([.partialThenFull]); let clock = Clock()
            let (recorder, state, events) = try makeRecorder(writer: writer, clock: clock)

            record(recorder, at: clock.now)
            var snapshot = recorder.persistenceSnapshot
            XCTAssertEqual(snapshot.storageFailureKind, .diskFull)
            XCTAssertNotNil(snapshot.storageInterruptedSince)
            XCTAssertEqual(snapshot.storageLostEventCount, 1)

            // Before the retry delay: counted, not retried against the disk.
            clock.now += 1
            record(recorder, at: clock.now)
            XCTAssertEqual(writer.calls, 1)
            XCTAssertEqual(recorder.persistenceSnapshot.storageLostEventCount, 2)

            clock.now += 10
            record(recorder, at: clock.now)
            snapshot = recorder.persistenceSnapshot
            XCTAssertNil(snapshot.storageInterruptedSince)
            XCTAssertEqual(snapshot.storageRecoveryCount, 1)

            let persisted = try persistedEvents(in: events)
            XCTAssertEqual(persisted.map { $0.integrity?.sequence }, [1, 2], "The partial row never consumed a sequence")
            let gap = try XCTUnwrap(persisted.first)
            XCTAssertEqual(gap.kind, .recorderHealth)
            XCTAssertEqual(gap.metadata?["gap_reason"], "storage_unavailable")
            XCTAssertEqual(gap.metadata?["storage_failure"], "diskFull")
            XCTAssertEqual(gap.metadata?["dropped_event_count"], "2")
            XCTAssertEqual(persisted[1].integrity?.previousEventHash, gap.integrity?.eventHash)
            XCTAssertEqual(state.snapshot.nextEventSequence, 3)
        }

        func testCompleteRowReportedAsFailedAdvancesTheChainInsteadOfDuplicatingASequence() throws {
            let writer = ScriptedWriter([.completeThenFail]); let clock = Clock()
            let (recorder, state, events) = try makeRecorder(writer: writer, clock: clock)

            record(recorder, at: clock.now)
            XCTAssertNotNil(recorder.persistenceSnapshot.storageInterruptedSince)
            clock.now += 6
            record(recorder, at: clock.now)

            let persisted = try persistedEvents(in: events)
            let sequences = persisted.compactMap { $0.integrity?.sequence }
            XCTAssertEqual(sequences, [1, 2, 3])
            XCTAssertEqual(Set(sequences).count, sequences.count)
            for (previous, next) in zip(persisted, persisted.dropFirst()) {
                XCTAssertEqual(next.integrity?.previousEventHash, previous.integrity?.eventHash)
            }
            XCTAssertEqual(state.snapshot.nextEventSequence, 4)
            XCTAssertEqual(persisted[1].metadata?["dropped_event_count"], "0", "The complete row is not reported as lost")
        }

        func testPersistentFailureBacksOffAndKeepsCountingWithoutWritingPartialState() throws {
            let writer = ScriptedWriter([]); writer.alwaysFail = true
            let clock = Clock()
            let (recorder, state, events) = try makeRecorder(writer: writer, clock: clock)

            for _ in 0..<20 { record(recorder, at: clock.now); clock.now += 1 }
            // First failure, then one retry after 5 s and the next only 30 s later.
            XCTAssertEqual(writer.calls, 2)
            XCTAssertEqual(recorder.persistenceSnapshot.storageLostEventCount, 20)
            XCTAssertEqual(state.snapshot.nextEventSequence, 1)
            XCTAssertTrue(try persistedEvents(in: events).isEmpty)

            writer.alwaysFail = false
            clock.now += 60
            record(recorder, at: clock.now)
            XCTAssertNil(recorder.persistenceSnapshot.storageInterruptedSince)
            let gap = try XCTUnwrap(try persistedEvents(in: events).first)
            XCTAssertEqual(gap.metadata?["dropped_event_count"], "20")
        }

        func testStorageFailureKindReadsOnlyNumericCodes() {
            XCTAssertEqual(StorageHealth.failureKind(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
            XCTAssertEqual(StorageHealth.failureKind(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))])), .diskFull)
            XCTAssertEqual(StorageHealth.failureKind(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)), .permissionDenied)
            XCTAssertEqual(StorageHealth.failureKind(for: NSError(domain: "other", code: 1)), .unavailable)
        }
    }
#endif
