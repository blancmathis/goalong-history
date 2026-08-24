#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AbandonedTemporaryScavengerTests: XCTestCase {
        func testDeletesOnlyExactOldOwnedFilesAndPreservesHistorySources() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }

            let analysis = try fixture.directory("analysis")
            let memories = try fixture.directory("memories")
            let computerHistory = try fixture.directory("computer-history")
            let agentActivity = try fixture.directory("agent-activity-v2")
            let chatGPTHistory = try fixture.directory("chatgpt/history")
            let chatGPTRecaps = try fixture.directory("chatgpt/recaps")
            let codex = try fixture.externalDirectory("codex-goalong")
            let uuid = UUID().uuidString
            let owned = [
                analysis.appendingPathComponent(".2026-08-20.analysis.json.\(uuid).tmp"),
                analysis.appendingPathComponent(".runtime-input-cache.json.\(uuid).tmp"),
                memories.appendingPathComponent(".2026-08-20.memory.md.\(uuid).tmp"),
                computerHistory.appendingPathComponent(
                    ".2026-08-20.computer-history.json.\(uuid).tmp"
                ),
                agentActivity.appendingPathComponent(".index.json.migration-\(uuid)"),
                chatGPTHistory.appendingPathComponent(
                    ".normalized-conversations.json.\(uuid).tmp"
                ),
                chatGPTRecaps.appendingPathComponent(
                    ".2026-08-20.chatgpt-recap.json.\(uuid).tmp"
                ),
                chatGPTRecaps.appendingPathComponent(
                    ".2026-08-20.chatgpt-recap.md.\(uuid).tmp"
                ),
                codex.appendingPathComponent(
                    ".2026-08-20-goalong-computer-history.md.\(uuid).tmp"
                ),
            ]
            for file in owned { try write("owned", to: file) }

            let young = analysis.appendingPathComponent(
                ".2026-08-21.agent.md.\(UUID().uuidString).tmp"
            )
            try write("young", to: young)
            let now = Date().addingTimeInterval(25 * 60 * 60)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-60 * 60)],
                ofItemAtPath: young.path
            )

            let preserved = [
                analysis.appendingPathComponent(".2026-08-20.analysis.json.not-a-uuid.tmp"),
                memories.appendingPathComponent("2026-08-20.memory.json"),
                try fixture.file("events/2026-08-20.jsonl"),
                try fixture.file("semantic/2026-08-20.jsonl"),
                try fixture.file("seals/2026-08-20.jsonl"),
                try fixture.file("receipts/2026-08-20.jsonl"),
                try fixture.file("apple-screen-time/2026-08-20.json"),
                agentActivity.appendingPathComponent("index.json"),
                chatGPTHistory.appendingPathComponent("normalized-conversations.json"),
                chatGPTRecaps.appendingPathComponent("2026-08-20.chatgpt-recap.json"),
                chatGPTRecaps.appendingPathComponent("2026-08-20.chatgpt-recap.md"),
            ]
            for file in preserved { try write("preserve", to: file) }

            let report = AbandonedTemporaryScavenger(
                rootDirectory: fixture.root,
                codexMemoryDirectory: codex
            ).scavenge(now: now)

            XCTAssertEqual(report.deletedFiles, owned.count)
            XCTAssertEqual(report.deletedBytes, Int64(owned.count * "owned".utf8.count))
            XCTAssertEqual(report.preservedYoungFiles, 1)
            XCTAssertTrue(owned.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: young.path))
            XCTAssertTrue(preserved.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

        func testMatchingSymlinkFailsClosedForItsDirectory() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let analysis = try fixture.directory("analysis")
            let external = fixture.container.appendingPathComponent("external.txt")
            try write("external", to: external)
            let uuid = UUID().uuidString
            let symlink = analysis.appendingPathComponent(".2026-08-20.agent.md.\(uuid).tmp")
            let sibling = analysis.appendingPathComponent(
                ".2026-08-20.analysis.json.\(UUID().uuidString).tmp"
            )
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
            try write("sibling", to: sibling)

            let report = AbandonedTemporaryScavenger(rootDirectory: fixture.root)
                .scavenge(now: Date().addingTimeInterval(25 * 60 * 60))

            XCTAssertEqual(report.deletedFiles, 0)
            XCTAssertGreaterThanOrEqual(report.preservedUnsafeFiles, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
            XCTAssertEqual(try String(contentsOf: external), "external")
        }

        func testDirectorySwapBeforeUnlinkPreservesBothDirectories() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let analysis = try fixture.directory("analysis")
            let name = ".2026-08-20.analysis.json.\(UUID().uuidString).tmp"
            let originalFile = analysis.appendingPathComponent(name)
            try write("original", to: originalFile)
            let moved = fixture.root.appendingPathComponent("analysis-moved", isDirectory: true)
            var swapped = false

            let report = AbandonedTemporaryScavenger(
                rootDirectory: fixture.root,
                beforeUnlink: { _ in
                    guard !swapped else { return }
                    swapped = true
                    try? FileManager.default.moveItem(at: analysis, to: moved)
                    try? FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: false)
                    try? Data("replacement".utf8).write(to: analysis.appendingPathComponent(name))
                }
            ).scavenge(now: Date().addingTimeInterval(25 * 60 * 60))

            XCTAssertEqual(report.deletedFiles, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(name).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent(name).path))
        }

        func testIdempotenceAndEntryBudgetAreBounded() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let analysis = try fixture.directory("analysis")
            let file = analysis.appendingPathComponent(
                ".2026-08-20.analysis.json.\(UUID().uuidString).tmp"
            )
            try write("owned", to: file)
            let now = Date().addingTimeInterval(25 * 60 * 60)
            let cleaner = AbandonedTemporaryScavenger(rootDirectory: fixture.root)
            XCTAssertEqual(cleaner.scavenge(now: now).deletedFiles, 1)
            XCTAssertEqual(cleaner.scavenge(now: now).deletedFiles, 0)

            for index in 0..<8 {
                try write("neighbor", to: analysis.appendingPathComponent("neighbor-\(index)"))
            }
            let bounded = AbandonedTemporaryScavenger(
                rootDirectory: fixture.root,
                limits: .init(maximumDirectoryEntries: 1)
            ).scavenge(now: now)
            XCTAssertTrue(bounded.reachedEntryBudget)
            XCTAssertLessThanOrEqual(bounded.visitedEntries, 1)
        }

        func testTimeBudgetStopsWithoutDeletingAndAtomicWriterRejectsSymlink() throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let analysis = try fixture.directory("analysis")
            let file = analysis.appendingPathComponent(
                ".2026-08-20.analysis.json.\(UUID().uuidString).tmp"
            )
            try write("owned", to: file)
            var tick = 0
            let cleaner = AbandonedTemporaryScavenger(
                rootDirectory: fixture.root,
                limits: .init(maximumElapsedSeconds: 0.001),
                monotonicClock: {
                    defer { tick += 1 }
                    return tick == 0 ? 0 : 1
                }
            )
            let report = cleaner.scavenge(now: Date().addingTimeInterval(25 * 60 * 60))
            XCTAssertTrue(report.reachedTimeBudget)
            XCTAssertEqual(report.deletedFiles, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

            let regularTarget = analysis.appendingPathComponent("2026-08-22.analysis.json")
            try GoalongOwnedAtomicFileWriter.write(Data("derived".utf8), to: regularTarget)
            XCTAssertEqual(try String(contentsOf: regularTarget), "derived")
            let permissions =
                try FileManager.default.attributesOfItem(atPath: regularTarget.path)[
                    .posixPermissions
                ] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: analysis.path).contains {
                    $0.hasPrefix(".2026-08-22.analysis.json.") && $0.hasSuffix(".tmp")
                }
            )

            let target = analysis.appendingPathComponent("runtime-input-cache.json")
            let external = fixture.container.appendingPathComponent("external.json")
            try write("external", to: external)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            XCTAssertThrowsError(
                try GoalongOwnedAtomicFileWriter.write(Data("new".utf8), to: target)
            )
            XCTAssertEqual(try String(contentsOf: external), "external")
        }

        private struct Fixture {
            let container: URL
            let root: URL

            func directory(_ relative: String) throws -> URL {
                let result = root.appendingPathComponent(relative, isDirectory: true)
                try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
                return result
            }

            func externalDirectory(_ relative: String) throws -> URL {
                let result = container.appendingPathComponent(relative, isDirectory: true)
                try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
                return result
            }

            func file(_ relative: String) throws -> URL {
                let result = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: result.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return result
            }
        }

        private func makeFixture() throws -> Fixture {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-temp-scavenger-\(UUID().uuidString)", isDirectory: true)
            let root = container.appendingPathComponent("LocalHistory", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return Fixture(container: container, root: root)
        }

        private func write(_ value: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }
    }
#endif
