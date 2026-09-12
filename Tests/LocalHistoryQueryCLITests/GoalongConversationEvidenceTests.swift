import XCTest
import AgentActivity
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

final class GoalongConversationEvidenceTests: XCTestCase {
    let start = Calendar.current.startOfDay(for: Date())
    func page(id: String = "one", role: String = "user", status: String = "available", next: Int? = nil, truncated: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": status, "nextCandidateOffset": next as Any? ?? NSNull(), "issues": [], "conversations": [[
            "id": id, "providerName": "Agent", "title": "Projet Atlas", "readStatus": "available", "messagesTruncated": truncated,
            "messages": [["role": role, "text": "Décision Atlas"]], "source": ["path": "/private/provider-owned-history"]
        ]]])
    }
    func testPreviousDaysAndPaginationPreserveRolesAndLimitsWithoutExportingLocators() throws {
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        var calls: [(Date, Int)] = []
        let selected = try GoalongConversationEvidence.collect(start: start, end: end) { day, offset in
            calls.append((day, offset))
            return try page(id: offset == 0 ? "one" : "two", role: offset == 0 ? "user" : "assistantFinal", next: offset == 0 ? 1 : nil, truncated: true)
        }
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(selected.evidence.count, 3, "Repeated overlapping conversation excerpts are deduplicated.")
        XCTAssertTrue(selected.notice.contains("Lecture partielle"))
        let text = selected.evidence.map(\.text).joined()
        XCTAssertTrue(text.contains("timestamp individuel indisponible"))
        XCTAssertTrue(text.contains("pas une décision utilisateur"))
        XCTAssertFalse(text.contains("provider-owned-history"))
        let request = try GoalongProfileAnalysis.prepare(date: "2026-09-12", timezone: "Europe/Paris", evidence: selected.evidence,
            policy: .init(replacements: [.init(term: "Atlas", replacement: "Projet secret")]), selected: ["projects"], includeConversations: true)
        XCTAssertFalse(try request.prompt().contains("Atlas"))
    }
    func testUnavailableSourceUnexpectedRolesAndBrokenPaginationFailBeforeAnalysis() throws {
        let end = start.addingTimeInterval(3600)
        XCTAssertThrowsError(try GoalongConversationEvidence.collect(start: start, end: end) { _, _ in try page(status: "consentRequired") })
        XCTAssertThrowsError(try GoalongConversationEvidence.collect(start: start, end: end) { _, _ in try page(role: "system") })
        XCTAssertThrowsError(try GoalongConversationEvidence.collect(start: start, end: end) { _, _ in try page(next: 0) })
    }
    func testReadOnlyIntegrationRequiresBothCapabilityAndEnabledWatchedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("session.jsonl")
        let bytes = Data("{\"role\":\"user\",\"content\":\"Atlas integration fixture\"}\n".utf8)
        try bytes.write(to: file)
        let store = try AgentActivityStore(rootDirectory: root.appendingPathComponent("agent-activity-v2"))
        var folder = AgentWatchedFolder(id: "test", displayName: "Fixture", path: sources.path, provider: .custom)
        _ = try store.saveConfiguration(.init(watchedFolders: [folder]))
        let entry = AgentSourceIndexEntry(id: "fixture", stableConversationID: "fixture", watchedFolderID: folder.id,
            watchedFolderName: folder.displayName, provider: folder.provider, reference: .init(kind: .file, path: file.path),
            relativePath: file.lastPathComponent, sourceCreatedAt: Date(), sourceModifiedAt: Date(), firstIndexedAt: Date(),
            lastObservedAt: Date(), byteCount: Int64(bytes.count), sha256: String(repeating: "0", count: 64))
        _ = try store.upsert(.init(index: entry, isAnalyzed: false), maximumEntries: 100)
        let end = start.addingTimeInterval(86399)
        XCTAssertThrowsError(try GoalongConversationEvidence.load(root: root, start: start, end: end))
        try Data("{\"schemaVersion\":1,\"policyVersion\":1,\"capabilities\":{\"aiConversations\":{\"enabled\":true}}}".utf8).write(to: root.appendingPathComponent("capability-consent.json"))
        let selected = try GoalongConversationEvidence.load(root: root, start: start, end: end)
        XCTAssertTrue(selected.evidence.contains { $0.text.contains("Atlas integration fixture") })
        folder.isEnabled = false
        _ = try store.saveConfiguration(.init(watchedFolders: [folder]))
        let disabled = try GoalongConversationEvidence.load(root: root, start: start, end: end)
        XCTAssertFalse(disabled.evidence.contains { $0.text.contains("Atlas integration fixture") })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
