#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    import LocalHistoryCore

    final class TargetedHistoryDeletionTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDownWithError() throws {
            for root in roots { try? FileManager.default.removeItem(at: root) }
            roots.removeAll()
            try super.tearDownWithError()
        }

        func testEpisodeResolverRebuildsExactIDsAndSemanticReferencesFromOriginalJournal() throws {
            let root = try makeRoot()
            let start = makeDate(hour: 12)
            let payload = semanticPayload(id: "episode-semantic", timestamp: start)
            let app = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let events = [
                HistoryEvent(
                    id: "episode-event-1",
                    sessionID: "episode-session",
                    timestamp: start,
                    kind: .mouseClick,
                    app: app,
                    window: WindowSnapshot(title: "Deletion fixture", role: nil, subrole: nil),
                    pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                    semanticContext: payload.reference
                ),
                HistoryEvent(
                    id: "episode-event-2",
                    sessionID: "episode-session",
                    timestamp: start.addingTimeInterval(2),
                    kind: .mouseClick,
                    app: app,
                    window: WindowSnapshot(title: "Deletion fixture", role: nil, subrole: nil),
                    pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
                ),
            ]
            try write(events: events, payloads: [payload], root: root)
            let memory = ComputerHistoryEngine.analyze(
                events: events,
                semanticSnapshots: [payload.id: payload],
                day: start
            )
            let episode = try XCTUnwrap(memory.episodes.first)

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: episode.id, day: start)
            )

            XCTAssertEqual(selection.eventIDs, Set(events.map(\.id)))
            XCTAssertEqual(selection.semanticSnapshotIDs, [payload.id])
            XCTAssertEqual(selection.start, events.first?.timestamp)
            XCTAssertEqual(selection.end, events.last?.timestamp)
            XCTAssertEqual(selection.affectedDays, [Calendar.current.startOfDay(for: start)])
            XCTAssertEqual(selection.semanticDays, [Calendar.current.startOfDay(for: start)])
        }

        func testEpisodeResolverUsesSnapshotDayAcrossMidnightWithoutBroadeningDerivedDeletion()
            throws
        {
            let root = try makeRoot()
            let eventTime = makeDate(hour: 23).addingTimeInterval(59 * 60 + 59)
            let snapshotTime = eventTime.addingTimeInterval(2)
            let payload = semanticPayload(id: "midnight-semantic", timestamp: snapshotTime)
            let event = HistoryEvent(
                id: "midnight-event",
                sessionID: "midnight-session",
                timestamp: eventTime,
                kind: .mouseClick,
                app: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: WindowSnapshot(title: "Across midnight", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: payload.reference
            )
            try write(events: [event], payloads: [payload], root: root)
            let episode = try XCTUnwrap(
                ComputerHistoryEngine.analyze(events: [event], day: eventTime).episodes.first
            )

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: episode.id, day: eventTime)
            )

            XCTAssertEqual(
                selection.affectedDays,
                [Calendar.current.startOfDay(for: eventTime)]
            )
            XCTAssertEqual(
                selection.semanticDays,
                [Calendar.current.startOfDay(for: snapshotTime)]
            )

            let semanticStore = SemanticContextStore(
                semanticDirectory: root.appendingPathComponent("semantic", isDirectory: true)
            )
            try semanticStore.preflightSnapshotDeletion(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            )
            let completion = expectation(description: "cross-midnight semantic deletion")
            var deletedCount: Int?
            semanticStore.deleteSnapshots(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            ) { result in
                deletedCount = try? result.get()
                completion.fulfill()
            }
            wait(for: [completion], timeout: 2)

            XCTAssertEqual(deletedCount, 1)
            XCTAssertTrue(
                HistoryLocalStoreReader(rootDirectory: root).load().semanticSnapshots.isEmpty
            )
        }

        func testSessionResolverDoesNotSelectOverlappingOtherApplication() throws {
            let root = try makeRoot()
            let start = makeDate(hour: 13)
            let textEdit = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let safari = AppSnapshot(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 43
            )
            let selectedEvent = HistoryEvent(
                id: "session-selected",
                sessionID: "session-fixture",
                timestamp: start,
                kind: .mouseClick,
                app: textEdit,
                window: WindowSnapshot(title: "Selected window", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1)
            )
            let unrelated = HistoryEvent(
                id: "session-unrelated",
                sessionID: "session-fixture",
                timestamp: start,
                kind: .mouseClick,
                app: safari,
                window: WindowSnapshot(title: "Other window", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
            )
            try write(events: [selectedEvent, unrelated], payloads: [], root: root)
            let session = ActivitySession(
                id: "selected-session",
                start: start,
                end: start,
                appName: textEdit.name,
                bundleIdentifier: textEdit.bundleIdentifier,
                windowTitle: selectedEvent.window?.title,
                host: nil,
                category: nil,
                isWork: nil,
                confidence: nil,
                suppressionReason: nil,
                eventCount: 1,
                inputEventCount: 1,
                softwareAttributedEventCount: 0,
                kindCounts: [EventKind.mouseClick.rawValue: 1],
                latestMessage: nil
            )

            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .activitySession(session)
            )

            XCTAssertEqual(selection.eventIDs, [selectedEvent.id])
            XCTAssertFalse(selection.eventIDs.contains(unrelated.id))
        }

        func testTargetedDeletionPipelinePreservesUnrelatedSourceAndOtherDays() throws {
            let root = try makeRoot()
            let codex = root.appendingPathComponent("codex-memory", isDirectory: true)
            let computerHistory = root.appendingPathComponent(
                "computer-history",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: computerHistory,
                withIntermediateDirectories: true
            )
            let start = makeDate(hour: 12)
            let app = AppSnapshot(
                name: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 42
            )
            let targetedPayload = semanticPayload(id: "pipeline-targeted", timestamp: start)
            let retainedPayload = semanticPayload(
                id: "pipeline-retained",
                timestamp: start.addingTimeInterval(3_600)
            )
            let targeted = HistoryEvent(
                id: "pipeline-targeted-event",
                sessionID: "pipeline",
                timestamp: start,
                kind: .mouseClick,
                app: app,
                window: WindowSnapshot(title: "Targeted work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: targetedPayload.reference
            )
            let unrelated = HistoryEvent(
                id: "pipeline-unrelated-event",
                sessionID: "pipeline",
                timestamp: start.addingTimeInterval(3_600),
                kind: .mouseClick,
                app: app,
                window: WindowSnapshot(title: "Unrelated work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1),
                semanticContext: retainedPayload.reference
            )
            try write(
                events: [targeted, unrelated],
                payloads: [targetedPayload, retainedPayload],
                root: root
            )
            for key in ["2026-08-23", "2026-08-24"] {
                try Data("derived-\(key)".utf8).write(
                    to: root.appendingPathComponent("analysis/\(key).analysis.json")
                )
                try Data("derived-\(key)".utf8).write(
                    to: root.appendingPathComponent("memories/\(key).memory.json")
                )
                try Data("derived-\(key)".utf8).write(
                    to: computerHistory.appendingPathComponent(
                        "\(key).computer-history.json"
                    )
                )
                try Data("derived-\(key)".utf8).write(
                    to: codex.appendingPathComponent(
                        "\(key)-goalong-computer-history.md"
                    )
                )
            }
            let memory = ComputerHistoryEngine.analyze(
                events: [targeted, unrelated],
                semanticSnapshots: [
                    targetedPayload.id: targetedPayload,
                    retainedPayload.id: retainedPayload,
                ],
                day: start
            )
            let targetedEpisode = try XCTUnwrap(
                memory.episodes.first(where: { $0.provenance.sourceEventIDs.contains(targeted.id) })
            )
            let selection = try TargetedHistoryDeletionResolver(rootDirectory: root).resolve(
                .computerHistoryEpisode(id: targetedEpisode.id, day: start)
            )
            let semanticStore = SemanticContextStore(
                semanticDirectory: root.appendingPathComponent("semantic", isDirectory: true)
            )
            try semanticStore.preflightSnapshotDeletion(
                withIDs: selection.semanticSnapshotIDs,
                on: selection.semanticDays
            )
            let derivedPlan = try DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            ).prepareDeletion(days: selection.affectedDays)
            let rawStore = try JSONLStore(
                retentionDays: 0,
                eventsDirectory: root.appendingPathComponent("events", isDirectory: true),
                prepareApplicationStorage: false
            )
            let rawCompletion = expectation(description: "pipeline raw deletion")
            var rawOutcome: JSONLTargetedDeletionOutcome?
            rawStore.deleteEvents(
                withIDs: selection.eventIDs,
                from: selection.start,
                through: selection.end
            ) { result in
                rawOutcome = try? result.get()
                rawCompletion.fulfill()
            }
            wait(for: [rawCompletion], timeout: 2)
            let raw = try XCTUnwrap(rawOutcome)

            let semanticCompletion = expectation(description: "pipeline semantic deletion")
            var semanticDeleted: Int?
            semanticStore.deleteSnapshots(
                withIDs: selection.semanticSnapshotIDs.union(raw.semanticSnapshotIDs),
                on: selection.semanticDays
            ) { result in
                semanticDeleted = try? result.get()
                semanticCompletion.fulfill()
            }
            wait(for: [semanticCompletion], timeout: 2)
            let derived = try derivedPlan.execute()

            XCTAssertEqual(raw.eventCount, 1)
            XCTAssertEqual(semanticDeleted, 1)
            XCTAssertEqual(derived.total, 4)
            let remainingEvents = HistoryLocalStoreReader(rootDirectory: root).load().events
            XCTAssertEqual(remainingEvents.map(\.id), [unrelated.id])
            let remainingSemantic = HistoryLocalStoreReader(rootDirectory: root)
                .load().semanticSnapshots
            XCTAssertEqual(Set(remainingSemantic.keys), [retainedPayload.id])
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "computer-history/2026-08-23.computer-history.json"
                    ).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "computer-history/2026-08-24.computer-history.json"
                    ).path
                )
            )
        }

        // MARK: Failure paths: nothing deleted, or a failure and a retry that completes.

        func testSemanticFailureAfterPreflightIsCompletedByRetry() throws {
            let fixture = try makeEpisodeFixture()
            let semanticFile = fixture.root.appendingPathComponent("semantic/2026-08-23.semantic.jsonl")
            try setImmutable(semanticFile, true)
            defer { try? setImmutable(semanticFile, false) }

            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            try setImmutable(semanticFile, false)
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        func testSourceChangedDuringCommitIsCompletedByRetry() throws {
            let fixture = try makeEpisodeFixture()
            let first = commit(fixture.request, fixture: fixture) { outcome in
                JSONLTargetedDeletionOutcome(
                    eventCount: outcome.eventCount - 1,
                    semanticSnapshotIDs: outcome.semanticSnapshotIDs
                )
            }
            XCTAssertThrowsError(try first.get()) { error in
                guard case TargetedHistoryDeletionError.sourceChangedDuringCommit? =
                    error as? TargetedHistoryDeletionError
                else { return XCTFail("unexpected error \(error)") }
            }
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        func testSecondDayEventFileFailureIsCompletedByRetry() throws {
            let fixture = try makeMidnightSessionFixture()
            let root = fixture.root
            let secondDay = root.appendingPathComponent("events/2026-08-24.jsonl")
            try setImmutable(secondDay, true)
            defer { try? setImmutable(secondDay, false) }

            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            try setImmutable(secondDay, false)
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        /// Content goes first: when the raw step fails, the item's snapshots and derived
        /// files are already gone, and only the opaque raw rows wait for the retry.
        func testRawEventFailureComesAfterSnapshotsAndDerivedFilesAreGone() throws {
            let fixture = try makeEpisodeFixture()
            let eventFile = fixture.root.appendingPathComponent("events/2026-08-23.jsonl")
            try setImmutable(eventFile, true)
            defer { try? setImmutable(eventFile, false) }

            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            let loaded = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            XCTAssertTrue(fixture.deletedEventIDs.isSubset(of: Set(loaded.events.map(\.id))), "raw step failed")
            XCTAssertEqual(Set(loaded.semanticSnapshots.keys), fixture.keptSnapshotIDs)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("computer-history/2026-08-23.computer-history.json").path
                )
            )
            try setImmutable(eventFile, false)
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        func testDerivedFailureIsCompletedByRetry() throws {
            let fixture = try makeEpisodeFixture()
            let derived = fixture.root.appendingPathComponent("computer-history/2026-08-23.computer-history.json")
            try setImmutable(derived, true)
            defer { try? setImmutable(derived, false) }

            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            let loaded = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            XCTAssertEqual(Set(loaded.semanticSnapshots.keys), fixture.keptSnapshotIDs, "failure after the snapshots")
            XCTAssertTrue(fixture.deletedEventIDs.isSubset(of: Set(loaded.events.map(\.id))), "raw events go last")
            try setImmutable(derived, false)
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        // MARK: Journal lifetime: entries never outlive the data they point to.

        func testFullClearRemovesTheJournal() throws {
            let fixture = try makeEpisodeFixture()
            let journal = TargetedHistoryDeletionJournal(rootDirectory: fixture.root)
            try journal.record(journalSelection(hour: 12), for: "a")
            try journal.record(journalSelection(hour: -240), for: "b")

            _ = try DerivedHistoryCleaner(rootDirectory: fixture.root, codexMemoryDirectory: fixture.codex)
                .prepareDeletion(since: nil).execute()

            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        }

        func testClearSinceRemovesTheJournalEntriesOfTheErasedPeriod() throws {
            let fixture = try makeEpisodeFixture()
            let journal = TargetedHistoryDeletionJournal(rootDirectory: fixture.root)
            try journal.record(journalSelection(hour: 12), for: "erased")
            try journal.record(journalSelection(hour: -240), for: "kept")

            _ = try DerivedHistoryCleaner(rootDirectory: fixture.root, codexMemoryDirectory: fixture.codex)
                .prepareDeletion(since: makeDate(hour: 0)).execute()

            XCTAssertNil(journal.pendingSelection(for: "erased"))
            XCTAssertEqual(journal.pendingSelection(for: "kept"), journalSelection(hour: -240))
        }

        func testRetentionRemovesTheJournalEntriesOlderThanItsCutoff() throws {
            let fixture = try makeEpisodeFixture()
            let journal = TargetedHistoryDeletionJournal(rootDirectory: fixture.root)
            try journal.record(journalSelection(hour: -240), for: "expired")
            try journal.record(journalSelection(hour: -12), for: "kept")
            let store = HistoryRetentionStore(
                legacyRetentionDays: 0,
                storage: HistoryRetentionStorage(
                    policyFile: fixture.root.appendingPathComponent("retention-policy.json"),
                    activationFile: fixture.root.appendingPathComponent("retention-policy-activated"),
                    artifactDirectories: [],
                    prepare: {},
                    targetedDeletionJournalRoot: fixture.root
                )
            )
            try store.updateDetailedRetention(fromLegacyDays: 7)

            store.applyCleanup(now: makeDate(hour: 12))

            XCTAssertNil(journal.pendingSelection(for: "expired"))
            XCTAssertEqual(journal.pendingSelection(for: "kept"), journalSelection(hour: -12))
        }

        func testJournalEntryExpiresAfterSevenDaysAndRetryResolvesAgain() throws {
            let fixture = try makeEpisodeFixture()
            let semanticFile = fixture.root.appendingPathComponent("semantic/2026-08-23.semantic.jsonl")
            try setImmutable(semanticFile, true)
            defer { try? setImmutable(semanticFile, false) }
            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            try setImmutable(semanticFile, false)
            let key = fixture.request.journalKey
            XCTAssertNotNil(TargetedHistoryDeletionJournal(rootDirectory: fixture.root).pendingSelection(for: key))

            let later = TargetedHistoryDeletionJournal(
                rootDirectory: fixture.root,
                now: { Date().addingTimeInterval(TargetedHistoryDeletionJournal.maximumAge + 3_600) }
            )
            XCTAssertNil(later.pendingSelection(for: key))
            XCTAssertFalse(FileManager.default.fileExists(atPath: later.fileURL.path), "expired entry left on disk")
            assertNothingDeletedOrRetryCompletes(fixture)
        }

        func testTargetedDeletionRemovesLaterDayProfileAnalysisQuotingTheDeletedDay() throws {
            let fixture = try makeEpisodeFixture()
            let directory = fixture.root.appendingPathComponent("chatgpt/profile-analyses", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let quoting = directory.appendingPathComponent("quoting.analysis.json")
            let unrelated = directory.appendingPathComponent("unrelated.analysis.json")
            try profileAnalysis(date: "2026-08-25", evidence: [makeDate(hour: 12), makeDate(hour: 36)])
                .write(to: quoting)
            try profileAnalysis(date: "2026-08-25", evidence: [makeDate(hour: 36)])
                .write(to: unrelated)

            _ = try commit(fixture.request, fixture: fixture).get()

            XCTAssertFalse(FileManager.default.fileExists(atPath: quoting.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        }

        private struct EpisodeFixture {
            let root: URL
            let codex: URL
            let request: TargetedHistoryDeletionRequest
            let keptEventIDs: [String]
            let keptSnapshotIDs: Set<String>
            let deletedEventIDs: Set<String>
        }

        /// The rule: after a reported failure, either nothing was deleted, or a retry of the
        /// same request succeeds and leaves no event, snapshot, or derived file of the item.
        /// A second writer starts between the first one's read and write. Without the
        /// process-wide lock it finishes inside that window and the first write overwrites its
        /// entry. With the lock it waits, then reads the first entry and adds its own.
        func testConcurrentJournalWritersNeverLoseAnEntry() throws {
            let root = try makeRoot()
            let second = DispatchSemaphore(value: 0)
            var injected = false
            let first = TargetedHistoryDeletionJournal(rootDirectory: root, beforeWrite: {
                guard !injected else { return }
                injected = true
                DispatchQueue.global().async {
                    try? TargetedHistoryDeletionJournal(rootDirectory: root)
                        .record(self.journalSelection(hour: 14), for: "second")
                    second.signal()
                }
                _ = second.wait(timeout: .now() + 0.5)
            })

            try first.record(journalSelection(hour: 12), for: "first")
            XCTAssertEqual(second.wait(timeout: .now() + 10), .success)

            let journal = TargetedHistoryDeletionJournal(rootDirectory: root)
            XCTAssertEqual(journal.pendingSelection(for: "first"), journalSelection(hour: 12))
            XCTAssertEqual(journal.pendingSelection(for: "second"), journalSelection(hour: 14))
        }

        /// The cutoff is the most recent of the two retentions, the stricter one for privacy:
        /// an entry whose snapshots expired goes even while the raw events are still kept.
        func testRetentionJournalCutoffIsTheMostRecentOfTheDetailedAndSemanticCutoffs() throws {
            let fixture = try makeEpisodeFixture()
            let journal = TargetedHistoryDeletionJournal(rootDirectory: fixture.root)
            try journal.record(journalSelection(hour: -120), for: "snapshotsExpired")
            try journal.record(journalSelection(hour: -12), for: "kept")
            let store = HistoryRetentionStore(
                legacyRetentionDays: 0,
                storage: HistoryRetentionStorage(
                    policyFile: fixture.root.appendingPathComponent("retention-policy.json"),
                    activationFile: fixture.root.appendingPathComponent("retention-policy-activated"),
                    artifactDirectories: [],
                    prepare: {},
                    targetedDeletionJournalRoot: fixture.root
                )
            )
            var policy = store.policy
            policy.detailedEvents = RetentionDuration(days: 7)
            policy.semanticSnapshots = RetentionDuration(days: 2)
            try store.activate(policy)

            store.applyCleanup(now: makeDate(hour: 12))

            XCTAssertNil(journal.pendingSelection(for: "snapshotsExpired"))
            XCTAssertEqual(journal.pendingSelection(for: "kept"), journalSelection(hour: -12))
        }

        /// The raw step fails midway (the second day stays), then the entry is purged: the old
        /// request no longer resolves, and the item shown again resolves on what is left and
        /// is erased entirely.
        func testEntryPurgedAfterRawFailureLeavesTheOldKeyUnresolvableAndTheRedisplayedItemErasable() throws {
            let fixture = try makeMidnightSessionFixture()
            guard case .activitySession(let session) = fixture.request else { return XCTFail("session") }
            let secondDay = fixture.root.appendingPathComponent("events/2026-08-24.jsonl")
            try setImmutable(secondDay, true)
            defer { try? setImmutable(secondDay, false) }
            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get())
            try setImmutable(secondDay, false)
            let journal = TargetedHistoryDeletionJournal(rootDirectory: fixture.root)
            XCTAssertNotNil(journal.pendingSelection(for: fixture.request.journalKey))

            try journal.removeEntries(before: makeDate(hour: 23).addingTimeInterval(3_600 * 2))

            XCTAssertNil(journal.pendingSelection(for: fixture.request.journalKey))
            XCTAssertThrowsError(try commit(fixture.request, fixture: fixture).get()) { error in
                guard case TargetedHistoryDeletionError.selectionNoLongerExists = error else {
                    return XCTFail("expected selectionNoLongerExists, got \(error)")
                }
            }
            let loaded = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            let leftover = loaded.events.filter { fixture.deletedEventIDs.contains($0.id) }
            XCTAssertEqual(leftover.count, 1, "raw rows of the second day are left")
            let shown = ActivitySession(
                id: session.id, start: session.start, end: session.end, appName: session.appName,
                bundleIdentifier: session.bundleIdentifier, windowTitle: session.windowTitle, host: nil,
                category: nil, isWork: nil, confidence: nil, suppressionReason: nil,
                eventCount: leftover.count, inputEventCount: leftover.count,
                softwareAttributedEventCount: 0,
                kindCounts: [EventKind.mouseClick.rawValue: leftover.count], latestMessage: nil
            )
            let redisplayed = TargetedHistoryDeletionRequest.activitySession(shown)
            XCTAssertNotEqual(redisplayed.journalKey, fixture.request.journalKey)

            XCTAssertNoThrow(try commit(redisplayed, fixture: fixture).get())

            let after = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            XCTAssertEqual(after.events.map(\.id).sorted(), fixture.keptEventIDs.sorted())
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        }

        /// A two-day session (23:50 and 00:10) plus an unrelated event of another app.
        private func makeMidnightSessionFixture() throws -> EpisodeFixture {
            let root = try makeRoot()
            let codex = root.appendingPathComponent("codex-memory", isDirectory: true)
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("computer-history", isDirectory: true),
                withIntermediateDirectories: true
            )
            let app = AppSnapshot(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 42)
            let other = AppSnapshot(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 43)
            let window = WindowSnapshot(title: "Midnight work", role: nil, subrole: nil)
            let late = makeDate(hour: 23).addingTimeInterval(50 * 60)
            let early = late.addingTimeInterval(20 * 60)
            let latePayload = semanticPayload(id: "midnight-late", timestamp: late)
            let earlyPayload = semanticPayload(id: "midnight-early", timestamp: early)
            let lateEvent = HistoryEvent(
                id: "midnight-late-event", sessionID: "midnight", timestamp: late, kind: .mouseClick,
                app: app, window: window,
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: latePayload.reference
            )
            let earlyEvent = HistoryEvent(
                id: "midnight-early-event", sessionID: "midnight", timestamp: early, kind: .mouseClick,
                app: app, window: window,
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: earlyPayload.reference
            )
            let unrelated = HistoryEvent(
                id: "midnight-unrelated", sessionID: "midnight", timestamp: early, kind: .mouseClick,
                app: other, window: WindowSnapshot(title: "Other", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1)
            )
            try write(
                events: [lateEvent, earlyEvent, unrelated],
                payloads: [latePayload, earlyPayload],
                root: root
            )
            let session = ActivitySession(
                id: "midnight-session", start: late, end: early, appName: app.name,
                bundleIdentifier: app.bundleIdentifier, windowTitle: window.title, host: nil,
                category: nil, isWork: nil, confidence: nil, suppressionReason: nil,
                eventCount: 2, inputEventCount: 2, softwareAttributedEventCount: 0,
                kindCounts: [EventKind.mouseClick.rawValue: 2], latestMessage: nil
            )
            let fixture = EpisodeFixture(
                root: root, codex: codex, request: .activitySession(session),
                keptEventIDs: [unrelated.id], keptSnapshotIDs: [],
                deletedEventIDs: [lateEvent.id, earlyEvent.id]
            )
            return fixture
        }

        private func assertNothingDeletedOrRetryCompletes(
            _ fixture: EpisodeFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let loaded = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            let nothingDeleted = fixture.deletedEventIDs.isSubset(of: Set(loaded.events.map(\.id)))
                && loaded.semanticSnapshots.count == fixture.keptSnapshotIDs.count + fixture.deletedEventIDs.count
            let journal = fixture.root.appendingPathComponent(TargetedHistoryDeletionJournal.fileName)
            XCTAssertTrue(
                nothingDeleted || FileManager.default.fileExists(atPath: journal.path),
                "a partial deletion must leave its selection for the retry", file: file, line: line
            )
            let retry = commit(fixture.request, fixture: fixture)
            XCTAssertNoThrow(try retry.get(), "retry of the same request must complete", file: file, line: line)
            let after = HistoryLocalStoreReader(rootDirectory: fixture.root).load()
            XCTAssertEqual(after.events.map(\.id).sorted(), fixture.keptEventIDs.sorted(), file: file, line: line)
            XCTAssertEqual(Set(after.semanticSnapshots.keys), fixture.keptSnapshotIDs, file: file, line: line)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("computer-history/2026-08-23.computer-history.json").path
                ),
                file: file, line: line
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), file: file, line: line)
        }

        private func commit(
            _ request: TargetedHistoryDeletionRequest,
            fixture: EpisodeFixture,
            transformRawOutcome: ((JSONLTargetedDeletionOutcome) -> JSONLTargetedDeletionOutcome)? = nil
        ) -> Result<TargetedHistoryDeletionOutcome, Error> {
            let committer: TargetedHistoryDeletionCommitter
            do {
                committer = TargetedHistoryDeletionCommitter(
                    rootDirectory: fixture.root,
                    rawStore: try JSONLStore(
                        retentionDays: 0,
                        eventsDirectory: fixture.root.appendingPathComponent("events", isDirectory: true),
                        prepareApplicationStorage: false
                    ),
                    semanticStore: SemanticContextStore(
                        semanticDirectory: fixture.root.appendingPathComponent("semantic", isDirectory: true)
                    ),
                    derivedCleaner: DerivedHistoryCleaner(
                        rootDirectory: fixture.root,
                        codexMemoryDirectory: fixture.codex
                    ),
                    transformRawOutcome: transformRawOutcome
                )
            } catch {
                return .failure(error)
            }
            let done = expectation(description: "targeted commit")
            var result: Result<TargetedHistoryDeletionOutcome, Error> = .failure(
                TargetedHistoryDeletionError.sourceIncomplete
            )
            committer.commit(request) {
                result = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return result
        }

        private func makeEpisodeFixture() throws -> EpisodeFixture {
            let root = try makeRoot()
            let codex = root.appendingPathComponent("codex-memory", isDirectory: true)
            let computerHistory = root.appendingPathComponent("computer-history", isDirectory: true)
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: computerHistory, withIntermediateDirectories: true)
            let start = makeDate(hour: 12)
            let app = AppSnapshot(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 42)
            let targetedPayload = semanticPayload(id: "commit-targeted", timestamp: start)
            let retainedPayload = semanticPayload(id: "commit-retained", timestamp: start.addingTimeInterval(3_600))
            let targeted = HistoryEvent(
                id: "commit-targeted-event", sessionID: "commit", timestamp: start, kind: .mouseClick,
                app: app, window: WindowSnapshot(title: "Targeted work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 10, y: 10, clickCount: 1),
                semanticContext: targetedPayload.reference
            )
            let unrelated = HistoryEvent(
                id: "commit-unrelated-event", sessionID: "commit", timestamp: start.addingTimeInterval(3_600),
                kind: .mouseClick, app: app, window: WindowSnapshot(title: "Unrelated work", role: nil, subrole: nil),
                pointer: PointerSnapshot(button: "left", x: 20, y: 20, clickCount: 1),
                semanticContext: retainedPayload.reference
            )
            try write(events: [targeted, unrelated], payloads: [targetedPayload, retainedPayload], root: root)
            for key in ["2026-08-23", "2026-08-24"] {
                try Data("derived-\(key)".utf8).write(
                    to: computerHistory.appendingPathComponent("\(key).computer-history.json")
                )
            }
            let memory = ComputerHistoryEngine.analyze(
                events: [targeted, unrelated],
                semanticSnapshots: [targetedPayload.id: targetedPayload, retainedPayload.id: retainedPayload],
                day: start
            )
            let episode = try XCTUnwrap(
                memory.episodes.first(where: { $0.provenance.sourceEventIDs.contains(targeted.id) })
            )
            return EpisodeFixture(
                root: root, codex: codex, request: .computerHistoryEpisode(id: episode.id, day: start),
                keptEventIDs: [unrelated.id], keptSnapshotIDs: [retainedPayload.id],
                deletedEventIDs: [targeted.id]
            )
        }

        private func journalSelection(hour: Int) -> TargetedHistoryDeletionSelection {
            TargetedHistoryDeletionSelection(
                eventIDs: ["journal-\(hour)"], semanticSnapshotIDs: [],
                start: makeDate(hour: hour), end: makeDate(hour: hour + 1),
                affectedDays: [], semanticDays: []
            )
        }

        private func setImmutable(_ url: URL, _ immutable: Bool) throws {
            try FileManager.default.setAttributes([.immutable: immutable], ofItemAtPath: url.path)
        }

        private func profileAnalysis(date: String, evidence: [Date]) throws -> Data {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let rows = evidence.enumerated().map { index, time -> [String: Any] in
                let stamp = formatter.string(from: time)
                return ["id": "e\(index + 1)", "start": stamp, "end": stamp, "application": "TextEdit", "text": "{}"]
            }
            let context = try JSONSerialization.data(
                withJSONObject: ["date": date, "timezone": TimeZone.current.identifier, "modules": [String](),
                    "instructions": "", "evidence": rows]
            )
            return try JSONSerialization.data(
                withJSONObject: ["request": ["context_json": String(decoding: context, as: UTF8.self)]]
            )
        }

        private func makeRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-targeted-deletion-\(UUID().uuidString)",
                isDirectory: true
            )
            for name in ["events", "semantic", "memories", "analysis"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            roots.append(root)
            return root
        }

        private func write(
            events: [HistoryEvent],
            payloads: [SemanticContextPayload],
            root: URL
        ) throws {
            for (day, dayEvents) in Dictionary(
                grouping: events,
                by: { AppPaths.localDayString(for: $0.timestamp) }
            ) {
                var eventData = Data()
                for event in dayEvents {
                    eventData.append(try encoder.encode(event))
                    eventData.append(0x0A)
                }
                try eventData.write(
                    to: root.appendingPathComponent("events/\(day).jsonl")
                )
            }

            for (day, dayPayloads) in Dictionary(
                grouping: payloads,
                by: { AppPaths.localDayString(for: $0.capturedAt) }
            ) {
                var semanticData = Data()
                for payload in dayPayloads {
                    semanticData.append(try encoder.encode(payload))
                    semanticData.append(0x0A)
                }
                try semanticData.write(
                    to: root.appendingPathComponent("semantic/\(day).semantic.jsonl")
                )
            }
        }

        private func semanticPayload(id: String, timestamp: Date) -> SemanticContextPayload {
            let text = "targeted semantic fixture"
            return SemanticContextPayload(
                id: id,
                capturedAt: timestamp,
                application: AppSnapshot(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42
                ),
                window: nil,
                url: nil,
                focusedRole: nil,
                source: .visibleText,
                text: text,
                contentSHA256: SHA256Digest.hashHex(text),
                redacted: false,
                truncated: false
            )
        }

        private var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        private func makeDate(hour: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 23, hour: hour)
            )!
        }
    }
#endif
