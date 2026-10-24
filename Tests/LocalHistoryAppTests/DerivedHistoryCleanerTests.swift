#if os(macOS)
    import Foundation
    import Security
    import XCTest
    @testable import LocalHistoryApp

    final class DerivedHistoryCleanerTests: XCTestCase {
        func testCutoffDeletesOnlyOwnedDerivedFilesAndPreservesOtherHistoryClasses() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }

            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let memories = root.appendingPathComponent("memories", isDirectory: true)
            let computerHistory = root.appendingPathComponent("computer-history", isDirectory: true)
            let screenTime = root.appendingPathComponent("apple-screen-time", isDirectory: true)
            let agentActivity = root.appendingPathComponent("agent-activity-v2", isDirectory: true)
            let events = root.appendingPathComponent("events", isDirectory: true)
            let receipts = root.appendingPathComponent("receipts", isDirectory: true)
            let shares = root.appendingPathComponent("shares", isDirectory: true)
            let chatGPT = root.appendingPathComponent("chatgpt", isDirectory: true)
            let seals = root.appendingPathComponent("seals", isDirectory: true)
            for directory in [
                analysis, memories, computerHistory, screenTime, agentActivity,
                events, receipts, shares, chatGPT, seals, codex,
            ] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            for key in ["2026-08-19", "2026-08-20"] {
                for suffix in [".analysis.json", ".agent.md"] {
                    try writeFixture(to: analysis.appendingPathComponent(key + suffix))
                }
                for suffix in [".memory.json", ".memory.md"] {
                    try writeFixture(to: memories.appendingPathComponent(key + suffix))
                }
                try writeFixture(
                    to: computerHistory.appendingPathComponent(key + ".computer-history.json")
                )
                try writeFixture(
                    to: codex.appendingPathComponent(key + "-goalong-computer-history.md")
                )
            }

            let preserved = [
                analysis.appendingPathComponent("notes.txt"),
                memories.appendingPathComponent("2026-08-20.memory.json.backup"),
                computerHistory.appendingPathComponent("2026-08-20-other.json"),
                screenTime.appendingPathComponent("2026-08-20.json"),
                agentActivity.appendingPathComponent("index.json"),
                events.appendingPathComponent("2026-08-20.jsonl"),
                receipts.appendingPathComponent("2026-08-20.receipts.jsonl"),
                shares.appendingPathComponent("2026-08-20.goalongshare"),
                chatGPT.appendingPathComponent("account.json"),
                seals.appendingPathComponent("2026-08-20.jsonl"),
            ]
            for URL in preserved { try writeFixture(to: URL) }

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            let result = try cleaner.delete(since: makeDay(year: 2026, month: 8, day: 20))

            XCTAssertEqual(
                result,
                DerivedHistoryDeletionResult(
                    activityAnalysisFiles: 2,
                    activityMemoryFiles: 2,
                    computerHistoryFiles: 2
                )
            )
            XCTAssertEqual(result.total, 6)
            XCTAssertTrue(preserved.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("2026-08-19.analysis.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("2026-08-20.analysis.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("2026-08-19-goalong-computer-history.md").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent("2026-08-20-goalong-computer-history.md").path))
        }

        func testExecuteAfterSemanticFailureStillRemovesDerivedFiles() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let memories = root.appendingPathComponent("memories", isDirectory: true)
            let computerHistory = root.appendingPathComponent("computer-history", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            for directory in [analysis, memories, computerHistory, codex] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let file = analysis.appendingPathComponent("2026-08-20.analysis.json")
            try writeFixture(to: file)
            let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: codex)
            let plan = try cleaner.prepareDeletion(since: nil)
            XCTAssertNotNil(plan.executeAfterSemanticFailure())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            // A second run (retry) must not crash or throw.
            _ = plan.executeAfterSemanticFailure()
        }

        func testExactDayDeletionPreservesEarlierAndLaterDerivedMemories() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let memories = root.appendingPathComponent("memories", isDirectory: true)
            let computerHistory = root.appendingPathComponent("computer-history", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            for directory in [analysis, memories, computerHistory, codex] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for key in ["2026-08-19", "2026-08-20", "2026-08-21"] {
                try writeFixture(to: analysis.appendingPathComponent(key + ".analysis.json"))
                try writeFixture(to: memories.appendingPathComponent(key + ".memory.json"))
                try writeFixture(
                    to: computerHistory.appendingPathComponent(key + ".computer-history.json")
                )
                try writeFixture(
                    to: codex.appendingPathComponent(key + "-goalong-computer-history.md")
                )
            }

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            let plan = try cleaner.prepareDeletion(
                days: [makeDay(year: 2026, month: 8, day: 20)]
            )
            XCTAssertEqual(plan.expectedResult.total, 4)
            _ = try plan.execute()

            for key in ["2026-08-19", "2026-08-21"] {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: analysis.appendingPathComponent(key + ".analysis.json").path
                    )
                )
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: computerHistory
                            .appendingPathComponent(key + ".computer-history.json").path
                    )
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: analysis.appendingPathComponent("2026-08-20.analysis.json").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: codex
                        .appendingPathComponent("2026-08-20-goalong-computer-history.md").path
                )
            )
        }

        func testMatchingSymlinkFailsClosedBeforeDeletingSiblingFiles() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)

            let regular = analysis.appendingPathComponent("2026-08-19.analysis.json")
            let external = container.appendingPathComponent("external.txt")
            let linked = analysis.appendingPathComponent("2026-08-20.agent.md")
            try writeFixture(to: regular)
            try writeFixture(to: external)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            XCTAssertThrowsError(try cleaner.delete(since: nil))
            XCTAssertTrue(FileManager.default.fileExists(atPath: regular.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
            XCTAssertEqual(try Data(contentsOf: external), Data("fixture".utf8))
        }

        func testSymlinkedManagedRootCannotDeleteExternalOwnedFile() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let externalAnalysis = container.appendingPathComponent("external-analysis", isDirectory: true)
            let linkedAnalysis = root.appendingPathComponent("analysis", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalAnalysis, withIntermediateDirectories: true)

            let externalOwnedFile = externalAnalysis.appendingPathComponent("2026-08-20.analysis.json")
            try writeFixture(to: externalOwnedFile)
            try FileManager.default.createSymbolicLink(
                at: linkedAnalysis,
                withDestinationURL: externalAnalysis
            )

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            XCTAssertThrowsError(try cleaner.delete(since: nil))
            XCTAssertEqual(try Data(contentsOf: externalOwnedFile), Data("fixture".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkedAnalysis.path))
        }

        func testSymlinkedAncestorOfManagedRootCannotDeleteExternalOwnedFile() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let externalRoot = container.appendingPathComponent("external-history", isDirectory: true)
            let externalAnalysis = externalRoot.appendingPathComponent("analysis", isDirectory: true)
            let linkedRoot = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(
                at: externalAnalysis,
                withIntermediateDirectories: true
            )

            let externalOwnedFile = externalAnalysis.appendingPathComponent("2026-08-20.analysis.json")
            try writeFixture(to: externalOwnedFile)
            try FileManager.default.createSymbolicLink(
                at: linkedRoot,
                withDestinationURL: externalRoot
            )

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: linkedRoot,
                codexMemoryDirectory: codex
            )
            XCTAssertThrowsError(try cleaner.delete(since: nil))
            XCTAssertEqual(try Data(contentsOf: externalOwnedFile), Data("fixture".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkedRoot.path))
        }

        func testLaterCategoryPreflightFailureDoesNotPartiallyDeleteEarlierCategory() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let memories = root.appendingPathComponent("memories", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)

            let earlierValidTarget = analysis.appendingPathComponent("2026-08-20.analysis.json")
            let external = container.appendingPathComponent("external.txt")
            let laterUnsafeTarget = memories.appendingPathComponent("2026-08-20.memory.json")
            try writeFixture(to: earlierValidTarget)
            try writeFixture(to: external)
            try FileManager.default.createSymbolicLink(
                at: laterUnsafeTarget,
                withDestinationURL: external
            )

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            XCTAssertThrowsError(try cleaner.delete(since: nil))
            XCTAssertEqual(try Data(contentsOf: earlierValidTarget), Data("fixture".utf8))
            XCTAssertEqual(try Data(contentsOf: external), Data("fixture".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: laterUnsafeTarget.path))
        }

        func testPreparedPlanDoesNotDeleteAndRevalidatesAllTargetsBeforeExecution() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-cleaner-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let memories = root.appendingPathComponent("memories", isDirectory: true)
            let codex = container.appendingPathComponent("codex-memory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)

            let earlierTarget = analysis.appendingPathComponent("2026-08-20.analysis.json")
            let laterTarget = memories.appendingPathComponent("2026-08-20.memory.json")
            let external = container.appendingPathComponent("external.txt")
            try writeFixture(to: earlierTarget)
            try writeFixture(to: laterTarget)
            try writeFixture(to: external)

            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: codex
            )
            let plan = try cleaner.prepareDeletion(since: nil)

            XCTAssertEqual(
                plan.expectedResult,
                DerivedHistoryDeletionResult(
                    activityAnalysisFiles: 1,
                    activityMemoryFiles: 1,
                    computerHistoryFiles: 0
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: earlierTarget.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: laterTarget.path))

            try FileManager.default.removeItem(at: laterTarget)
            try FileManager.default.createSymbolicLink(
                at: laterTarget,
                withDestinationURL: external
            )

            XCTAssertThrowsError(try plan.execute())
            XCTAssertEqual(try Data(contentsOf: earlierTarget), Data("fixture".utf8))
            XCTAssertEqual(try Data(contentsOf: external), Data("fixture".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: laterTarget.path))
        }

        func testPartialClearsKeepTheDayNoteAndFullClearRemovesIt() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-scope-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let today = Date(), key = dayKey(today)
            let note = root.appendingPathComponent("notes/\(key).json")
            let calls = root.appendingPathComponent("calls/\(key).jsonl")
            let developer = root.appendingPathComponent("developer/\(key).jsonl")
            let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: container.appendingPathComponent("codex"))
            func seed() throws {
                for URL in [note, calls, developer] {
                    try FileManager.default.createDirectory(at: URL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try writeFixture(to: URL)
                }
            }

            try seed()
            _ = try cleaner.prepareDeletion(since: today.addingTimeInterval(-600)).execute()
            XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: developer.path))

            try seed()
            _ = try cleaner.prepareDeletion(days: [today]).execute()
            XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))

            try seed()
            _ = try cleaner.prepareDeletion(since: nil).execute()
            for URL in [note, calls, developer] { XCTAssertFalse(FileManager.default.fileExists(atPath: URL.path)) }
        }

        func testHistoryClearsEraseTheChatGPTRecapsOfTheClearedDays() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-recaps-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let recaps = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            func files(_ day: Date) -> [URL] {
                [".chatgpt-recap.json", ".chatgpt-recap.md"].map {
                    recaps.appendingPathComponent(dayKey(day) + $0)
                }
            }
            let foreign = recaps.appendingPathComponent("notes.txt")
            let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: container.appendingPathComponent("codex"))
            func seed() throws {
                try FileManager.default.createDirectory(at: recaps, withIntermediateDirectories: true)
                for URL in files(today) + files(yesterday) + [foreign] { try writeFixture(to: URL) }
            }
            func exists(_ URLs: [URL]) -> [Bool] { URLs.map { FileManager.default.fileExists(atPath: $0.path) } }

            try seed()
            _ = try cleaner.prepareDeletion(since: today).execute()
            XCTAssertEqual(exists(files(today)), [false, false])
            XCTAssertEqual(exists(files(yesterday)), [true, true])

            try seed()
            _ = try cleaner.prepareDeletion(days: [yesterday]).execute()
            XCTAssertEqual(exists(files(today)), [true, true])
            XCTAssertEqual(exists(files(yesterday)), [false, false])

            try seed()
            _ = try cleaner.prepareDeletion(since: nil).execute()
            XCTAssertEqual(exists(files(today) + files(yesterday)), [false, false, false, false])
            XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        }

        func testHistoryClearsEraseTheProofPackagesOfTheClearedRecaps() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-proofs-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let recaps = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
            let proofs = root.appendingPathComponent("chatgpt/proofs", isDirectory: true)
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let todayID = UUID().uuidString.lowercased()
            let yesterdayID = UUID().uuidString.lowercased()
            let orphanID = UUID().uuidString.lowercased()
            let chainHead = proofs.appendingPathComponent("chain-head.json")
            let fm = FileManager.default
            func proofFile(_ id: String) -> URL { proofs.appendingPathComponent(id + "/result.json") }
            func seed() throws {
                try? fm.removeItem(at: container)
                try fm.createDirectory(at: recaps, withIntermediateDirectories: true)
                for (day, id) in [(today, todayID), (yesterday, yesterdayID)] {
                    try Data("{\"proof\":{\"executionID\":\"\(id)\"}}".utf8)
                        .write(to: recaps.appendingPathComponent(dayKey(day) + ".chatgpt-recap.json"))
                    try writeFixture(to: recaps.appendingPathComponent(dayKey(day) + ".chatgpt-recap.md"))
                }
                for id in [todayID, yesterdayID, orphanID] {
                    try fm.createDirectory(at: proofs.appendingPathComponent(id), withIntermediateDirectories: true)
                    try writeFixture(to: proofFile(id))
                    try writeFixture(to: proofs.appendingPathComponent(id + "/run.jws"))
                }
                // The orphan's own manifest dates it: yesterday.
                try Data("{\"day\":\"\(dayKey(yesterday))\"}".utf8)
                    .write(to: proofs.appendingPathComponent(orphanID + "/context-manifest.json"))
                try writeFixture(to: chainHead)
            }
            let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: container.appendingPathComponent("codex"))

            try seed()
            _ = try cleaner.prepareDeletion(since: today).execute()
            XCTAssertFalse(fm.fileExists(atPath: proofs.appendingPathComponent(todayID).path))
            XCTAssertTrue(fm.fileExists(atPath: proofFile(yesterdayID).path))
            XCTAssertTrue(fm.fileExists(atPath: proofFile(orphanID).path))
            XCTAssertTrue(fm.fileExists(atPath: chainHead.path))

            try seed()
            _ = try cleaner.prepareDeletion(days: [yesterday]).execute()
            XCTAssertFalse(fm.fileExists(atPath: proofs.appendingPathComponent(yesterdayID).path))
            XCTAssertFalse(fm.fileExists(atPath: proofFile(orphanID).path))
            XCTAssertTrue(fm.fileExists(atPath: proofFile(todayID).path))

            try seed()
            _ = try cleaner.prepareDeletion(since: nil).execute()
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: proofs.path), [])

            // A symbolic link inside a proof package aborts the whole clear before any unlink.
            try seed()
            let target = container.appendingPathComponent("outside.txt")
            try writeFixture(to: target)
            try fm.removeItem(at: proofs.appendingPathComponent(todayID + "/run.jws"))
            try fm.createSymbolicLink(at: proofs.appendingPathComponent(todayID + "/run.jws"), withDestinationURL: target)
            XCTAssertThrowsError(try cleaner.prepareDeletion(since: today))
            XCTAssertTrue(fm.fileExists(atPath: proofFile(todayID).path))
            XCTAssertTrue(fm.fileExists(atPath: recaps.appendingPathComponent(dayKey(today) + ".chatgpt-recap.json").path))
            XCTAssertTrue(fm.fileExists(atPath: target.path))
        }

        func testFullClearRemovesOrphanSummaryTemporariesAndKeepsForeignFiles() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-derived-temp-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let days = root.appendingPathComponent("activity-days", isDirectory: true)
            try FileManager.default.createDirectory(at: days, withIntermediateDirectories: true)
            let summary = days.appendingPathComponent("2026-08-10.json")
            let orphan = days.appendingPathComponent(".activity-" + UUID().uuidString)
            try writeFixture(to: summary); try writeFixture(to: orphan)
            let cleaner = DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: container.appendingPathComponent("codex"))

            // A targeted clear never touches temporaries: a live writer may own them.
            _ = try cleaner.prepareDeletion(days: [makeDay(year: 2026, month: 8, day: 10)]).execute()
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

            let result = try cleaner.delete(since: nil)
            XCTAssertEqual(result.activitySummaryFiles, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: days.path))

            // An unknown hidden file is never deleted, and the clear still succeeds.
            try FileManager.default.createDirectory(at: days, withIntermediateDirectories: true)
            let foreign = days.appendingPathComponent(".DS_Store")
            try writeFixture(to: foreign); try writeFixture(to: summary)
            XCTAssertEqual(try cleaner.delete(since: nil).activitySummaryFiles, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: summary.path))

            // A symbolic link with the temporary name fails preflight.
            try FileManager.default.removeItem(at: foreign)
            try FileManager.default.createSymbolicLink(
                at: days.appendingPathComponent(".activity-" + UUID().uuidString), withDestinationURL: foreign)
            XCTAssertThrowsError(try cleaner.prepareDeletion(since: nil))
            XCTAssertFalse(DerivedHistoryCleaner.isActivityTemporaryName(".activity-not-a-uuid"))
            XCTAssertFalse(DerivedHistoryCleaner.isActivityTemporaryName(".activity-" + UUID().uuidString.lowercased()))
        }

        private func dayKey(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        func testFullClearDeletesEveryFileEvenWhenTheKeychainFailsThenReportsTheError() throws {
            // The capsule store opens every path component without following links, and /var and /tmp are links
            // on macOS: build in the package's own .build folder, which has none.
            let container = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/derived-cleaner-tests", isDirectory: true)
                .appendingPathComponent("goalong-derived-keychain-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let fm = FileManager.default
            let proofs = root.appendingPathComponent("chatgpt/proofs", isDirectory: true)
            let evidence = proofs.appendingPathComponent("private-evidence", isDirectory: true)
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            let id = UUID().uuidString.lowercased()
            let stagingID = UUID().uuidString.lowercased()
            let staging = proofs.appendingPathComponent(".\(stagingID).tmp", isDirectory: true)
            for directory in [analysis, evidence, proofs.appendingPathComponent(id), staging] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // The store refuses folders that other users can read: make each one private (0700).
            for directory in [root, root.appendingPathComponent("chatgpt"), proofs, evidence,
                              proofs.appendingPathComponent(id), staging] {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let files = [
                analysis.appendingPathComponent("2026-08-20.analysis.json"),
                evidence.appendingPathComponent(id + ".capsule"),
                proofs.appendingPathComponent(id + "/result.json"),
                staging.appendingPathComponent("result.json"),
                proofs.appendingPathComponent("chain-head.json"),
            ]
            for file in files { try writeFixture(to: file) }
            var deleteCalls = 0
            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: container.appendingPathComponent("codex"),
                deleteEvidenceKeyItem: { _ in deleteCalls += 1; return errSecAuthFailed }
            )

            XCTAssertThrowsError(try cleaner.prepareDeletion(since: nil).execute()) { error in
                guard case AnalysisEvidenceCapsuleError.keychainFailure(let status) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(status, errSecAuthFailed)
            }
            XCTAssertGreaterThan(deleteCalls, 0)
            XCTAssertEqual(files.map { fm.fileExists(atPath: $0.path) }, Array(repeating: false, count: files.count))
            XCTAssertFalse(fm.fileExists(atPath: staging.path))
        }

        func testPartialClearErasesTheOrphanProofsOfTheErasedDaysWithTheirKeys() throws {
            // Same .build container as above: /var and /tmp are symbolic links on macOS.
            let container = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/derived-cleaner-tests", isDirectory: true)
                .appendingPathComponent("goalong-derived-orphans-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let fm = FileManager.default
            let recaps = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
            let proofs = root.appendingPathComponent("chatgpt/proofs", isDirectory: true)
            let evidence = proofs.appendingPathComponent("private-evidence", isDirectory: true)
            let erasedDay = makeDay(year: 2026, month: 8, day: 20)
            let keptDay = makeDay(year: 2026, month: 8, day: 10)
            // Orphans: a regenerated recap replaced their proof, or the recap write never happened.
            let erasedOrphan = UUID().uuidString.lowercased()
            let keptOrphan = UUID().uuidString.lowercased()
            let referenced = UUID().uuidString.lowercased()
            let erasedStaging = UUID().uuidString.lowercased()
            let erasedCapsuleOnly = UUID().uuidString.lowercased()
            let keptCapsuleOnly = UUID().uuidString.lowercased()
            func package(_ id: String) -> URL { proofs.appendingPathComponent(id, isDirectory: true) }
            let staging = proofs.appendingPathComponent(".\(erasedStaging).tmp", isDirectory: true)
            // A stale staging copy of a kept recap's proof, with no manifest: its date is today.
            let referencedStaging = proofs.appendingPathComponent(".\(referenced).tmp", isDirectory: true)
            for directory in [recaps, evidence, package(erasedOrphan), package(keptOrphan), package(referenced), staging,
                              referencedStaging] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for directory in [root, root.appendingPathComponent("chatgpt"), recaps, proofs, evidence] {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            func writeManifest(day: Date, in directory: URL) throws {
                try Data("{\"day\":\"\(dayKey(day))\",\"executionID\":\"x\"}".utf8)
                    .write(to: directory.appendingPathComponent("context-manifest.json"))
                try writeFixture(to: directory.appendingPathComponent("result.json"))
            }
            try writeManifest(day: erasedDay, in: package(erasedOrphan))
            try writeManifest(day: keptDay, in: package(keptOrphan))
            try writeManifest(day: keptDay, in: package(referenced))
            try writeManifest(day: erasedDay, in: staging)
            try writeFixture(to: referencedStaging.appendingPathComponent("result.json"))
            try Data("{\"proof\":{\"executionID\":\"\(referenced)\"}}".utf8)
                .write(to: recaps.appendingPathComponent(dayKey(keptDay) + ".chatgpt-recap.json"))
            for id in [erasedOrphan, keptOrphan, referenced, erasedStaging, erasedCapsuleOnly, keptCapsuleOnly] {
                try writeFixture(to: evidence.appendingPathComponent(id + ".capsule"))
            }
            // A capsule with no package has no day of its own: its date is the generation time.
            try fm.setAttributes([.modificationDate: erasedDay],
                                 ofItemAtPath: evidence.appendingPathComponent(erasedCapsuleOnly + ".capsule").path)
            try fm.setAttributes([.modificationDate: makeDay(year: 2026, month: 8, day: 5)],
                                 ofItemAtPath: evidence.appendingPathComponent(keptCapsuleOnly + ".capsule").path)
            var erasedKeys: Set<String> = []
            let cleaner = DerivedHistoryCleaner(
                rootDirectory: root,
                codexMemoryDirectory: container.appendingPathComponent("codex"),
                deleteEvidenceKeyItem: { query in
                    if let account = (query as NSDictionary)[kSecAttrAccount as String] as? String {
                        erasedKeys.insert(account)
                    }
                    return errSecItemNotFound
                }
            )

            _ = try cleaner.prepareDeletion(days: [erasedDay]).execute()

            XCTAssertEqual(erasedKeys, [erasedOrphan, erasedStaging, erasedCapsuleOnly])
            XCTAssertFalse(fm.fileExists(atPath: package(erasedOrphan).appendingPathComponent("result.json").path))
            XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("result.json").path))
            XCTAssertFalse(fm.fileExists(atPath: referencedStaging.appendingPathComponent("result.json").path))
            for id in [erasedOrphan, erasedStaging, erasedCapsuleOnly] {
                XCTAssertFalse(fm.fileExists(atPath: evidence.appendingPathComponent(id + ".capsule").path), id)
            }
            for id in [keptOrphan, referenced, keptCapsuleOnly] {
                XCTAssertTrue(fm.fileExists(atPath: evidence.appendingPathComponent(id + ".capsule").path), id)
            }
            XCTAssertTrue(fm.fileExists(atPath: package(keptOrphan).appendingPathComponent("result.json").path))
            XCTAssertTrue(fm.fileExists(atPath: package(referenced).appendingPathComponent("result.json").path))

            // A cutoff clear dates orphans the same way: the kept day's orphan is older than the cutoff.
            _ = try cleaner.prepareDeletion(since: makeDay(year: 2026, month: 8, day: 15)).execute()
            XCTAssertTrue(fm.fileExists(atPath: package(keptOrphan).appendingPathComponent("result.json").path))
            _ = try cleaner.prepareDeletion(since: keptDay).execute()
            XCTAssertFalse(fm.fileExists(atPath: package(keptOrphan).appendingPathComponent("result.json").path))
            XCTAssertTrue(fm.fileExists(atPath: evidence.appendingPathComponent(keptCapsuleOnly + ".capsule").path))
        }

        private func writeFixture(to URL: URL) throws {
            try Data("fixture".utf8).write(to: URL, options: [.atomic])
        }

        private func makeDay(year: Int, month: Int, day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: 12)
            )!
        }
    }
#endif
