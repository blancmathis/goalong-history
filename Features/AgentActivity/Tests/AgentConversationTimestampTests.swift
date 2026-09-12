import XCTest
@testable import AgentActivity

final class AgentConversationTimestampTests: XCTestCase {
    let file = URL(fileURLWithPath: "/synthetic/session.jsonl")
    func testCodexEnvelopeTimestampsSurviveBothParsersAndBounds() throws {
        let text = """
        {"timestamp":"2026-09-11T08:01:02.345Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Choisissons le projet Atlas"}]}}
        {"timestamp":"2026-09-11T08:03:04.567Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Proposition pour Atlas"}]}}
        """ + "\n"
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = [formatter.date(from: "2026-09-11T08:01:02.345Z"), formatter.date(from: "2026-09-11T08:03:04.567Z")]
        let full = AgentTranscriptParser.parse(data: Data(text.utf8), fileURL: file, provider: .codex)
        XCTAssertEqual(full.visibleMessages.map(\.timestamp), expected)
        XCTAssertEqual(full.boundedForTransientCache().visibleMessages.map(\.timestamp), expected)
        var parser = AgentTranscriptParser.IncrementalJSONLines(fileURL: file, provider: .codex, analysisInterval: .init(start: formatter.date(from: "2026-09-11T00:00:00.000Z")!, duration: 86400))
        parser.consume(Data(text.utf8))
        XCTAssertEqual(parser.finish().visibleMessages.map(\.timestamp), expected)
    }
    func testClaudeMessageTimestampAndUnknownMessagesStayDistinct() throws {
        let text = """
        {"type":"user","timestamp":"2026-09-11T08:01:02.345Z","message":{"role":"user","content":"Décision passée"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Proposition non datée"}]}}
        """ + "\n"
        let summary = AgentTranscriptParser.parse(data: Data(text.utf8), fileURL: file, provider: .claudeCode)
        XCTAssertNotNil(summary.visibleMessages.first?.timestamp)
        XCTAssertNil(summary.visibleMessages.last?.timestamp)
    }
    func testParentConversationCreationDateIsNotUsedAsEveryMessageTime() {
        let text = """
        {"created_at":"2025-01-01T00:00:00Z","messages":[{"role":"user","content":"Question non datée"},{"role":"assistant","phase":"final_answer","content":"Réponse non datée"}]}
        """
        let result = AgentTranscriptParser.parse(data: Data(text.utf8), fileURL: URL(fileURLWithPath: "/synthetic/conversation.json"), provider: .custom)
        XCTAssertEqual(result.visibleMessages.count, 2)
        XCTAssertTrue(result.visibleMessages.allSatisfy { $0.timestamp == nil })
    }
}
