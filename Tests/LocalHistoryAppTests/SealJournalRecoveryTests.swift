#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    /// T-057 d4-01..d4-04: injected disk-full, partial write, unreadable seal and unreadable
    /// chain-head failures. The chain is never restarted or forked; in doubt, signing waits.
    final class SealJournalRecoveryTests: XCTestCase {
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

        private var root: URL!
        private var seals: URL { root.appendingPathComponent("seals", isDirectory: true) }
        private var stateFile: URL { root.appendingPathComponent("integrity-state.json") }

        override func setUpWithError() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-journal-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: seals, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: seals.path) {
                for name in names { chmod(seals.appendingPathComponent(name).path, 0o600) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        private func makeState() -> IntegrityStateStore {
            IntegrityStateStore(fileURL: stateFile, prepareStorage: {})
        }

        private func makeSealer(
            _ state: IntegrityStateStore,
            initialDate: Date = Date(timeIntervalSince1970: 120),
            appender: @escaping MinuteSealer.SealAppender
        ) -> MinuteSealer {
            MinuteSealer(
                stateStore: state,
                identity: FixtureIdentity(),
                initialDate: initialDate,
                sealDirectory: seals,
                prepareStorage: {},
                sealAppender: appender
            )
        }

        private func event(_ seconds: TimeInterval, root: String) -> HistoryEvent {
            HistoryEvent(
                schemaVersion: 4,
                sessionID: "seal-journal-fixture",
                timestamp: Date(timeIntervalSince1970: seconds),
                kind: .typingBurst,
                integrity: EventIntegrity(
                    sequence: 1,
                    previousEventHash: String(repeating: "0", count: 64),
                    eventRoot: root,
                    eventHash: root,
                    fieldCommitments: []
                )
            )
        }

        private func diskSeals() throws -> [LocalMinuteSeal] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let names = try FileManager.default.contentsOfDirectory(atPath: seals.path).sorted()
            return try names.flatMap { name -> [LocalMinuteSeal] in
                let data = try Data(contentsOf: seals.appendingPathComponent(name))
                return data.split(separator: 0x0A).compactMap {
                    try? decoder.decode(LocalMinuteSeal.self, from: Data($0))
                }
            }
        }

        private func coverageStates(_ seal: LocalMinuteSeal) -> String? {
            seal.minuteFields.first { $0.name == "coverage" }?.opening.fields["states"]
        }

        private static func diskFull(_ url: URL) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSFilePathErrorKey: url.path])
        }

        // d4-01: ENOSPC ten times, then the disk frees up: sealing goes on in the same launch.
        func testDiskFullTenTimesThenSealsInTheSameLaunch() throws {
            let state = makeState()
            var failures = 0
            let sealer = makeSealer(state) { seal, url in
                if failures < 10 {
                    failures += 1
                    throw Self.diskFull(url)
                }
                try MinuteSealer.appendJSONLine(seal, to: url)
            }
            sealer.receiveForTesting(event(150, root: "before-full"), now: Date(timeIntervalSince1970: 150))
            var now = 181.1
            while failures < 10, now < 1_000 {
                _ = sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: now))
                now += 31
            }
            XCTAssertEqual(failures, 10)
            XCTAssertFalse(sealer.runtimeSnapshot.signingSuspended, "a full disk never stops signing")

            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: now + 31)))
            let written = try diskSeals()
            XCTAssertEqual(written.map(\.anchorSequence), Array(1...UInt64(written.count)))
            XCTAssertEqual(written.first?.eventRoots, ["before-full"])
            for (previous, next) in zip(written, written.dropFirst()) {
                XCTAssertEqual(next.previousAnchorHash, previous.anchorHash)
            }
            XCTAssertEqual(state.snapshot.nextAnchorSequence, UInt64(written.count) + 1)
            XCTAssertFalse(sealer.runtimeSnapshot.journalRecoveryPending)
        }

        // d4-01: a full disk longer than the 3-minute buffer drops roots; the minutes that lost
        // roots say so in their coverage instead of being signed as complete.
        func testLongDiskFullMarksMinutesThatLostRoots() throws {
            let state = makeState()
            var full = true
            let sealer = makeSealer(state) { seal, url in
                if full { throw Self.diskFull(url) }
                try MinuteSealer.appendJSONLine(seal, to: url)
            }
            for minute in 0..<6 {
                let at = 150 + Double(minute * 60)
                sealer.receiveForTesting(event(at, root: "root-\(minute)"), now: Date(timeIntervalSince1970: at))
            }
            XCTAssertGreaterThan(sealer.runtimeSnapshot.unbufferedRootCount, 0)
            full = false
            var now = 600.0
            while sealer.runtimeSnapshot.pendingMinuteCount > 0, now < 2_000 {
                _ = sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: now))
                now += 31
            }
            let written = try diskSeals()
            XCTAssertFalse(written.isEmpty)
            XCTAssertTrue(
                written.contains { coverageStates($0)?.contains(MinuteSealer.rootsDroppedCoverageState) == true },
                "a minute that lost roots must not be signed as complete"
            )
            XCTAssertEqual(written.map(\.anchorSequence), Array(1...UInt64(written.count)))
        }

        // d4-01: partial write whose row did reach disk: recovery adopts it, no second signature.
        func testPartialWriteThatLandedIsAdoptedNotSignedTwice() throws {
            let state = makeState()
            var attempts = 0
            let sealer = makeSealer(state) { seal, url in
                attempts += 1
                try MinuteSealer.appendJSONLine(seal, to: url)
                if attempts == 1 {
                    throw MinuteSealPersistenceError.durabilityUncertain("injected fsync failure")
                }
            }
            sealer.receiveForTesting(event(150, root: "uncertain"), now: Date(timeIntervalSince1970: 150))
            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertTrue(sealer.runtimeSnapshot.journalRecoveryPending)

            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 242.5)))
            let written = try diskSeals()
            XCTAssertEqual(written.map(\.anchorSequence), [1, 2])
            XCTAssertEqual(written[0].eventRoots, ["uncertain"])
            XCTAssertEqual(written[1].previousAnchorHash, written[0].anchorHash)
            XCTAssertEqual(written[1].minuteStart, Date(timeIntervalSince1970: 180))
            XCTAssertEqual(sealer.runtimeSnapshot.pendingRootCount, 0)
        }

        // d4-01: partial write that left a torn row: the same sequence is signed once, after it.
        func testTornPartialWriteResignsTheSameSequenceOnce() throws {
            let state = makeState()
            var attempts = 0
            let sealer = makeSealer(state) { seal, url in
                attempts += 1
                if attempts == 1 {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let row = try encoder.encode(seal)
                    try row.prefix(row.count / 2).write(to: url)
                    throw MinuteSealPersistenceError.durabilityUncertain("injected short write")
                }
                try MinuteSealer.appendJSONLine(seal, to: url)
            }
            sealer.receiveForTesting(event(150, root: "torn"), now: Date(timeIntervalSince1970: 150))
            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 182.5)))

            let written = try diskSeals()
            XCTAssertEqual(written.map(\.anchorSequence), [1])
            XCTAssertEqual(written[0].eventRoots, ["torn"])
            XCTAssertEqual(state.snapshot.nextAnchorSequence, 2)
        }

        // d4-02: an unreadable seal file may hold the tail: signing waits (shown), then follows
        // the true tail once the file is readable again. Nothing is signed from a doubtful cursor.
        func testUnreadableSealFilePausesSigningUntilReadable() throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            func row(_ sequence: UInt64, _ hash: String) throws -> Data {
                var data = try encoder.encode(LocalMinuteSeal(
                    anchorSequence: sequence,
                    minuteStart: Date(timeIntervalSince1970: 60),
                    minuteEnd: Date(timeIntervalSince1970: 120),
                    minuteFields: [], eventRoots: [], minuteRoot: "m\(sequence)",
                    previousAnchorHash: "p\(sequence)", anchorHash: hash,
                    deviceID: "fixture-device", publicKeyBase64: "k", trustTier: "test",
                    signatureBase64: "s", signatureAlgorithm: "test-signature"
                ))
                data.append(0x0A)
                return data
            }
            let hidden = seals.appendingPathComponent("1970-01-02.seals.jsonl")
            try row(7, "hidden-tail").write(to: hidden)
            try row(3, "readable-older").write(to: seals.appendingPathComponent("1970-01-01.seals.jsonl"))
            XCTAssertEqual(chmod(hidden.path, 0), 0)
            try XCTSkipIf(FileManager.default.isReadableFile(atPath: hidden.path), "running as root")

            let state = makeState()
            var signed: [LocalMinuteSeal] = []
            let sealer = makeSealer(state) { seal, _ in signed.append(seal) }
            var notices: [String?] = []
            sealer.setSuspensionObserver { notices.append($0) }
            sealer.receiveForTesting(event(150, root: "waiting"), now: Date(timeIntervalSince1970: 150))
            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertTrue(signed.isEmpty, "never sign from a doubtful tail")
            XCTAssertTrue(sealer.runtimeSnapshot.journalRecoveryPending)
            XCTAssertEqual(notices.count, 1)
            XCTAssertNotNil(notices.first ?? nil)

            XCTAssertEqual(chmod(hidden.path, 0o600), 0)
            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 600)))
            XCTAssertEqual(signed.first?.anchorSequence, 8)
            XCTAssertEqual(signed.first?.previousAnchorHash, "hidden-tail")
            XCTAssertEqual(signed.first?.eventRoots, ["waiting"])
            XCTAssertEqual(notices.last ?? "not-cleared", nil)
        }

        // d4-02: an unreadable checkpoint with no seal to confirm the cursor never restarts at 1;
        // its bytes are kept aside. A readable seal tail then confirms the cursor.
        func testUnreadableChainHeadCheckpointPausesUntilASealConfirmsIt() throws {
            try Data("{ torn".utf8).write(to: stateFile)
            let state = makeState()
            XCTAssertTrue(state.anchorCursorIsDoubtful)
            let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix("integrity-state.damaged-") }
            XCTAssertEqual(kept.count, 1)

            var signed: [LocalMinuteSeal] = []
            let sealer = makeSealer(state) { seal, _ in signed.append(seal) }
            sealer.receiveForTesting(event(150, root: "r"), now: Date(timeIntervalSince1970: 150))
            XCTAssertFalse(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 181.1)))
            XCTAssertTrue(signed.isEmpty, "a lost checkpoint must not restart the chain at 1")
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))

            var data = try { () -> Data in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(LocalMinuteSeal(
                    anchorSequence: 41, minuteStart: Date(timeIntervalSince1970: 60),
                    minuteEnd: Date(timeIntervalSince1970: 120), minuteFields: [], eventRoots: [],
                    minuteRoot: "m", previousAnchorHash: "p", anchorHash: "tail-41",
                    deviceID: "fixture-device", publicKeyBase64: "k", trustTier: "test",
                    signatureBase64: "s", signatureAlgorithm: "test-signature"))
            }()
            data.append(0x0A)
            try data.write(to: seals.appendingPathComponent("1970-01-01.seals.jsonl"))
            XCTAssertTrue(sealer.sealElapsedMinutesForTesting(now: Date(timeIntervalSince1970: 600)))
            XCTAssertEqual(signed.first?.anchorSequence, 42)
            XCTAssertEqual(signed.first?.previousAnchorHash, "tail-41")
            XCTAssertFalse(state.anchorCursorIsDoubtful)
        }

        // d4-02: retention never removes the newest seal file (chain tail).
        func testRetentionKeepsTheNewestSealFile() throws {
            func artifact(_ day: String) throws -> HistoryStoredArtifact {
                let url = seals.appendingPathComponent("\(day).seals.jsonl")
                try Data("x\n".utf8).write(to: url)
                let start = ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")!
                return HistoryStoredArtifact(
                    id: url.path, dataClass: .minuteSeals, start: start,
                    end: start.addingTimeInterval(86_399), localPath: url.path)
            }
            let old = try artifact("2026-01-01")
            let newest = try artifact("2026-01-03")
            let middle = try artifact("2026-01-02")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: newest.localPath)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: middle.localPath)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: old.localPath)
            let kept = HistoryRetentionStore.sealChainTailPaths(in: [old, middle, newest])
            XCTAssertEqual(kept, [newest.localPath, old.localPath])
        }

        // d4-04: an unreadable chain head refuses the proof (file kept); a head whose run was
        // erased keeps its number; no head = new chain.
        func testAnalysisProofChainHeadIsNeverRestartedSilently() throws {
            let proofs = root.appendingPathComponent("proofs", isDirectory: true)
            try FileManager.default.createDirectory(at: proofs, withIntermediateDirectories: true)
            let store = AnalysisProofStore(rootDirectory: proofs)
            XCTAssertEqual(try store.nextChainLinkForTesting().sequence, 0)

            let head = proofs.appendingPathComponent("chain-head.json")
            let digest = GoalongProofDigest.sha256(Data("run".utf8))
            let json = """
                {"executionID":"\(UUID().uuidString.lowercased())","runJWSSHA256":"\(digest)","schemaVersion":1,"sequence":4}
                """
            try Data(json.utf8).write(to: head)
            let link = try store.nextChainLinkForTesting()
            XCTAssertEqual(link.sequence, 5, "an erased run keeps its number taken")
            XCTAssertEqual(link.previousDigest, digest)

            let executionID = UUID().uuidString.lowercased()
            let runDirectory = proofs.appendingPathComponent(executionID, isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            try Data("another run".utf8).write(to: runDirectory.appendingPathComponent("run.jws"))
            let contradicting = """
                {"executionID":"\(executionID)","runJWSSHA256":"\(digest)","schemaVersion":1,"sequence":9}
                """
            try Data(contradicting.utf8).write(to: head)
            XCTAssertThrowsError(try store.nextChainLinkForTesting(), "a head that contradicts its run is refused")
            XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent("run.jws").path))

            try Data("{ torn".utf8).write(to: head)
            XCTAssertThrowsError(try store.nextChainLinkForTesting()) { error in
                guard case AnalysisProofStoreError.chainHeadUnreadable = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: head), Data("{ torn".utf8), "the damaged head is kept")
        }
    }
#endif
