import CryptoKit
import Foundation
import XCTest

@testable import AgentActivity

final class AgentSourceCapabilityTests: XCTestCase {
    func testPinnedRootNeverEscapesThroughAncestorSymlinkSwapAndDirectReadFailsClosed() throws {
        let fixture = try makeTemporaryDirectory("ancestor-swap")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let authorizedAncestor = fixture.appendingPathComponent("authorized", isDirectory: true)
        let sourceRoot = authorizedAncestor.appendingPathComponent("source", isDirectory: true)
        let parkedAncestor = fixture.appendingPathComponent("authorized-parked", isDirectory: true)
        let attackerAncestor = fixture.appendingPathComponent("attacker", isDirectory: true)
        let attackerRoot = attackerAncestor.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attackerRoot, withIntermediateDirectories: true)

        let safeData = Data("SAFE-ORIGINAL-SOURCE\n".utf8)
        let attackerData = Data("ATTACKER-SYMLINK-SOURCE-MUST-NEVER-BE-READ\n".utf8)
        try safeData.write(to: sourceRoot.appendingPathComponent("session.txt"))
        try attackerData.write(to: attackerRoot.appendingPathComponent("session.txt"))

        let store = try AgentActivityStore(
            rootDirectory: fixture.appendingPathComponent("store", isDirectory: true)
        )
        let folder = watchedFolder(root: sourceRoot, mode: .everyFile)
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let initial = AgentActivityScanner(store: store).scan(
            configuration: configuration,
            forceFullDiscovery: true
        )
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        let entry = try XCTUnwrap(store.entries().first)
        let pinnedSession = try AgentDirectSourceReader.makeScanSession(folder: folder)

        try FileManager.default.moveItem(at: authorizedAncestor, to: parkedAncestor)
        try FileManager.default.createSymbolicLink(
            at: authorizedAncestor,
            withDestinationURL: attackerAncestor
        )

        let pinnedCandidate = try pinnedSession.candidate(for: entry)
        let pinnedRead = try pinnedSession.read(
            candidate: pinnedCandidate,
            previous: entry,
            maximumBytes: 1 * 1_024 * 1_024
        )
        XCTAssertEqual(pinnedRead.sha256, digest(safeData))
        XCTAssertNotEqual(pinnedRead.sha256, digest(attackerData))

        XCTAssertThrowsError(
            try store.directRead(entryID: entry.id, maximumBytes: 1 * 1_024 * 1_024)
        )
        let rescanned = AgentActivityScanner(store: store).scan(
            configuration: configuration,
            forceFullDiscovery: true
        )
        XCTAssertFalse(rescanned.failures.isEmpty)
        XCTAssertEqual(store.entries().first?.sha256, digest(safeData))
    }

    func testCustomParentPrunesEveryDedicatedProviderSubtreeInBothModes() throws {
        let fixture = try makeTemporaryDirectory("provider-pruning")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sourceRoot = fixture.appendingPathComponent("parent", isDirectory: true)
        let providerFiles = [
            ".codex/sessions/rollout-provider.jsonl",
            ".claude/projects/example/provider.jsonl",
            ".cursor/provider.jsonl",
            ".local/share/opencode/storage/session/provider.json",
            ".gemini/tmp/provider.jsonl",
            "Library/Application Support/Code/User/workspaceStorage/a/chatSessions/provider.json",
            "Library/Application Support/Cursor/User/globalStorage/provider.jsonl",
        ]
        for relativePath in providerFiles {
            let file = sourceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("PROVIDER-PRIVATE-BODY\n".utf8).write(to: file)
        }
        let ordinary = sourceRoot.appendingPathComponent("ordinary/session.txt")
        try FileManager.default.createDirectory(
            at: ordinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ordinary fixture\n".utf8).write(to: ordinary)

        for mode in [AgentCaptureMode.transcriptsAndLogs, .everyFile] {
            let store = try AgentActivityStore(
                rootDirectory: fixture.appendingPathComponent("store-\(mode.rawValue)", isDirectory: true)
            )
            let result = AgentActivityScanner(store: store).scan(
                configuration: AgentActivityConfiguration(
                    watchedFolders: [watchedFolder(root: sourceRoot, mode: mode)]
                ),
                forceFullDiscovery: true
            )
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertEqual(store.entries().map(\.relativePath), ["ordinary/session.txt"])
        }
    }

    func testDeepTraversalStopsWithExplicitDepthLimit() throws {
        let fixture = try makeTemporaryDirectory("depth")
        defer { try? FileManager.default.removeItem(at: fixture) }
        var cursor = fixture
        for index in 0..<70 {
            cursor.appendPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
        }
        try Data("too deep\n".utf8).write(to: cursor.appendingPathComponent("session.txt"))

        let discovery = try AgentDirectSourceReader.makeScanSession(
            folder: watchedFolder(root: fixture, mode: .everyFile)
        ).discover(maximumCandidates: 100)
        XCTAssertEqual(discovery.incompleteReason, .depthLimit)
        XCTAssertTrue(discovery.candidates.isEmpty)
    }

    func testEveryAdvertisedExtensionIsAnalyzedBelowLimitAndExplicitlyUnavailableAboveLimit() throws {
        let extensions = [
            "json", "jsonl", "ndjson", "md", "markdown", "txt", "log", "trace", "csv",
            "yaml", "yml", "toml", "session", "agent-event",
        ]
        let fixture = try makeTemporaryDirectory("formats")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let smallRoot = fixture.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: smallRoot, withIntermediateDirectories: true)
        for ext in extensions {
            let body =
                ["json", "agent-event"].contains(ext)
                ? "{\"role\":\"user\",\"content\":\"fixture\"}\n"
                : "user: fixture\n"
            try Data(body.utf8).write(to: smallRoot.appendingPathComponent("session.\(ext)"))
        }
        let smallStore = try AgentActivityStore(
            rootDirectory: fixture.appendingPathComponent("small-store", isDirectory: true)
        )
        let smallResult = AgentActivityScanner(store: smallStore).scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [watchedFolder(root: smallRoot, mode: .everyFile)]
            ),
            forceFullDiscovery: true
        )
        XCTAssertTrue(smallResult.failures.isEmpty, smallResult.failures.joined(separator: "\n"))
        XCTAssertEqual(smallResult.captures.count, extensions.count)
        XCTAssertTrue(smallResult.captures.allSatisfy(\.isAnalyzed))

        let largeRoot = fixture.appendingPathComponent("large", isDirectory: true)
        try FileManager.default.createDirectory(at: largeRoot, withIntermediateDirectories: true)
        for ext in extensions {
            try Data(repeating: 65, count: 65 * 1_024).write(
                to: largeRoot.appendingPathComponent("session.\(ext)")
            )
        }
        let largeStore = try AgentActivityStore(
            rootDirectory: fixture.appendingPathComponent("large-store", isDirectory: true)
        )
        let largeResult = AgentActivityScanner(store: largeStore).scan(
            configuration: AgentActivityConfiguration(
                watchedFolders: [watchedFolder(root: largeRoot, mode: .everyFile)],
                maximumFileBytes: 64 * 1_024
            ),
            forceFullDiscovery: true
        )
        XCTAssertEqual(largeStore.indexEntryCount(), extensions.count)
        XCTAssertTrue(largeStore.entries().allSatisfy { $0.availability == .inaccessible })
        XCTAssertEqual(largeResult.scannedSourceCount, extensions.count)
    }

    func testGrowingJSONReadsOnlyTheInitiallyAuthorizedBytesBeforeRejectingMutation() throws {
        let fixture = try makeTemporaryDirectory("growing-json")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("session.json")
        let initial = Data(#"{"role":"user","content":"fixture"}"#.utf8)
        let growth = Data(repeating: 0x20, count: 1 * 1_024 * 1_024)
        try initial.write(to: source)

        var didGrow = false
        var mutationError: Error?
        let bodyReadBudget = AgentSourceBodyReadBudget(
            limits: AgentSourceBodyReadLimits(
                maximumBytes: 2 * 1_024 * 1_024,
                maximumDurationNanoseconds: 5_000_000_000
            ),
            uptimeNanoseconds: { 0 },
            isCancelled: {
                guard !didGrow else { return false }
                didGrow = true
                do {
                    let handle = try FileHandle(forWritingTo: source)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: growth)
                    try handle.synchronize()
                } catch {
                    mutationError = error
                }
                return false
            }
        )
        let folder = watchedFolder(root: fixture, mode: .everyFile)
        let session = try AgentDirectSourceReader.makeScanSession(
            folder: folder,
            bodyReadBudget: bodyReadBudget
        )
        let candidate = try XCTUnwrap(session.discover(maximumCandidates: 10).candidates.first)

        XCTAssertThrowsError(
            try session.read(
                candidate: candidate,
                previous: nil,
                maximumBytes: 2 * 1_024 * 1_024
            )
        ) { error in
            guard case AgentSourceReadError.changedDuringRead = error else {
                return XCTFail("Expected changedDuringRead, received \(error)")
            }
        }
        XCTAssertTrue(didGrow)
        XCTAssertNil(mutationError)
        XCTAssertEqual(bodyReadBudget.usage().byteCount, Int64(initial.count))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int,
            initial.count + growth.count
        )
    }

    private func watchedFolder(root: URL, mode: AgentCaptureMode) -> AgentWatchedFolder {
        AgentWatchedFolder(
            id: "capability-fixture",
            displayName: "Capability fixture",
            path: root.path,
            provider: .custom,
            captureMode: mode
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentSourceCapabilityTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
