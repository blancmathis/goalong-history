#if os(macOS)
    import Foundation
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
