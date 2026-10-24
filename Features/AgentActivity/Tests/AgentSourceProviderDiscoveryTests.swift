import Foundation
import XCTest

@testable import AgentActivity

final class AgentSourceProviderDiscoveryTests: XCTestCase {
    private let uuidA = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    private let uuidB = "11111111-2222-4333-8444-555555555555"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-provider-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func touch(_ root: URL, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
    }

    private func discover(_ provider: AgentProvider, in root: URL) throws -> [AgentSourceCandidate] {
        let folder = AgentWatchedFolder(
            id: "folder-\(provider.rawValue)", displayName: provider.displayName,
            path: root.path, provider: provider)
        return try AgentDirectSourceReader.discover(folder: folder)
    }

    func testCodexDiscoversRolloutJSONLInLiveAndArchivedFoldersOnly() throws {
        let root = try makeRoot()
        try touch(root, "sessions/2026/10/24/rollout-2026-10-24T10-00-00-\(uuidA).jsonl")
        try touch(root, "archived_sessions/rollout-old-\(uuidB).jsonl")
        try touch(root, "sessions/2026/10/24/notes.jsonl")
        try touch(root, "sessions/2026/10/24/rollout-2026-\(uuidA).txt")
        try touch(root, "other/rollout-elsewhere-\(uuidA).jsonl")

        let candidates = try discover(.codex, in: root)
        XCTAssertEqual(
            Set(candidates.map(\.relativePath)),
            [
                "sessions/2026/10/24/rollout-2026-10-24T10-00-00-\(uuidA).jsonl",
                "archived_sessions/rollout-old-\(uuidB).jsonl",
            ])
        let ids = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.relativePath.hasPrefix("sessions") ? "live" : "archived", $0.stableConversationID) })
        XCTAssertEqual(ids["live"], uuidA.lowercased())
        XCTAssertEqual(ids["archived"], uuidB)
    }

    func testCodexRolloutWithoutAUUIDSuffixHasNoStableConversationID() throws {
        let root = try makeRoot()
        try touch(root, "sessions/rollout-not-a-uuid.jsonl")
        let candidates = try discover(.codex, in: root)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates[0].stableConversationID)
    }

    func testClaudeDiscoversJSONLUnderProjectsAndNormalizesUUIDNames() throws {
        let root = try makeRoot()
        try touch(root, "projects/-Users-me-app/\(uuidA).jsonl")
        try touch(root, "projects/-Users-me-app/nested/agent-note.jsonl")
        try touch(root, "projects/-Users-me-app/sessions-index.json")
        try touch(root, "elsewhere/\(uuidB).jsonl")

        let candidates = try discover(.claudeCode, in: root)
        let byName = Dictionary(
            uniqueKeysWithValues: candidates.map { (URL(fileURLWithPath: $0.relativePath).lastPathComponent, $0) })
        XCTAssertEqual(Set(byName.keys), ["\(uuidA).jsonl", "agent-note.jsonl"])
        XCTAssertEqual(byName["\(uuidA).jsonl"]?.stableConversationID, uuidA.lowercased())
        XCTAssertNil(byName["agent-note.jsonl"]?.stableConversationID)
    }

    func testClaudeWithoutAProjectsFolderDiscoversNothing() throws {
        let root = try makeRoot()
        try touch(root, "\(uuidA).jsonl")
        XCTAssertTrue(try discover(.claudeCode, in: root).isEmpty)
    }

    func testGeminiNeedsA64HexProjectFolderAndSessionJSONInChats() throws {
        let root = try makeRoot()
        let project = String(repeating: "ab12", count: 16)
        try touch(root, "\(project)/chats/session-2026-10-24.json")
        try touch(root, "\(project)/chats/summary.json")
        try touch(root, "\(project)/chats/session-notes.txt")
        try touch(root, "\(project)/chats/deeper/session-hidden.json")
        try touch(root, "\(project)/session-outside-chats.json")
        try touch(root, "\(String(repeating: "ab12", count: 15))/chats/session-short.json")
        try touch(root, "\(String(repeating: "zz12", count: 16))/chats/session-nothex.json")

        let candidates = try discover(.gemini, in: root)
        XCTAssertEqual(candidates.map(\.relativePath), ["\(project)/chats/session-2026-10-24.json"])
        XCTAssertNil(candidates.first?.stableConversationID)
    }

    func testCopilotNeedsAHexWorkspaceFolderOfPlausibleLengthWithChatSessions() throws {
        let root = try makeRoot()
        let workspace = "0123456789abcdef0123456789ABCDEF"
        try touch(root, "\(workspace)/chatSessions/\(uuidA).json")
        try touch(root, "\(workspace)/chatSessions/\(uuidB).JSONL")
        try touch(root, "\(workspace)/chatSessions/readme.md")
        try touch(root, "\(workspace)/chatSessions/more/\(uuidA).json")
        try touch(root, "\(workspace)/other/\(uuidA).json")
        try touch(root, "0123456789abcde/chatSessions/\(uuidA).json")
        try touch(root, "not-hex-workspace-xyz/chatSessions/\(uuidA).json")

        let candidates = try discover(.copilot, in: root)
        XCTAssertEqual(
            Set(candidates.map(\.relativePath)),
            ["\(workspace)/chatSessions/\(uuidA).json", "\(workspace)/chatSessions/\(uuidB).JSONL"])
        XCTAssertEqual(
            Set(candidates.compactMap(\.stableConversationID)), [uuidA.lowercased(), uuidB])
    }

    func testDiscoveryOfAMissingRootFailsInsteadOfReportingAnEmptyHistory() throws {
        let root = try makeRoot().appendingPathComponent("absent", isDirectory: true)
        XCTAssertThrowsError(try discover(.codex, in: root))
    }
}
