import XCTest
import LocalHistoryCore
@testable import AgentActivity

final class GoalongAgentProjectsTests: XCTestCase {
    func testDayScopedCountsAndTokensDoNotDuplicateSourceEvents() throws {
        let day = Calendar.current.startOfDay(for: Date()), interval = Calendar.current.dateInterval(of: .day, for: day)!
        func capture(_ id: String, scoped: Bool) -> AgentCaptureRecord {
            var summary = AgentDocumentSummary(projectPath: "/tmp/goalong-project-fixture", startedAt: day.addingTimeInterval(100), endedAt: day.addingTimeInterval(700), toolCallCount: 3, errorCount: 1)
            summary.tokenUsage.events = [.init(id: "shared-token-event", date: day.addingTimeInterval(200), model: "fixture", input: 80, output: 20, cacheRead: nil, cacheWrite: nil, reasoning: nil, total: 100)]
            let index = AgentSourceIndexEntry(id: id, stableConversationID: id, watchedFolderID: "folder", watchedFolderName: "Codex", provider: .codex, reference: .init(kind: .file, path: "/tmp/" + id), relativePath: id, sourceCreatedAt: nil, sourceModifiedAt: day, firstIndexedAt: day, lastObservedAt: day, byteCount: 1, sha256: "fixture")
            return .init(index: index, summary: summary, analysisInterval: scoped ? interval : nil)
        }
        let first = capture("a", scoped: true), second = capture("b", scoped: false)
        let value = GoalongAgentProjectGrouping.group(.init(day: day, captures: [first, first, second]))
        XCTAssertEqual(value.status, .partial); XCTAssertEqual(value.projects.count, 1)
        let project = try XCTUnwrap(value.projects.first)
        XCTAssertEqual(project.sessions, 2); XCTAssertEqual(project.tokens, 100)
        XCTAssertEqual(project.toolCalls, 3); XCTAssertEqual(project.errors, 1); XCTAssertEqual(project.documentSpanSeconds, 600)
        XCTAssertEqual(GoalongAgentProjectGrouping.group(.init(day: day, captures: [first]), enabled: false).status, .disabled)
    }
}
