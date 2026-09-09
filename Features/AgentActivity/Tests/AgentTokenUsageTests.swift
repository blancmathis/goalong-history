import XCTest
@testable import AgentActivity

final class AgentTokenUsageTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/usage-fixture.jsonl")
    private func line(_ timestamp: String, total: Int, last: Int? = nil) -> String {
        let lastField = last.map { ",\"last_token_usage\":{\"input_tokens\":\($0),\"output_tokens\":10,\"cached_input_tokens\":2,\"reasoning_output_tokens\":4,\"total_tokens\":\($0+10)}" } ?? ""
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":20,\"total_tokens\":\(total+20)}\(lastField)}}}"
    }
    func testCumulativeDuplicatesAndNoDoubleCount() {
        let first = line("2026-09-09T10:00:00Z", total: 100, last: 100)
        let second = line("2026-09-09T11:00:00Z", total: 150, last: 50)
        let summary = AgentTranscriptParser.parse(data: Data([first,first,second].joined(separator: "\n").utf8), fileURL: url, provider: .codex)
        XCTAssertEqual(summary.tokenUsage.events.count, 2)
        XCTAssertEqual(summary.tokenUsage.events.compactMap(\.total).reduce(0,+), 170)
        XCTAssertEqual(summary.tokenUsage.events.first?.reasoning, 4)
        XCTAssertEqual(summary.boundedForTransientCache().tokenUsage, summary.tokenUsage)
    }
    func testMidnightBaselineAndHalfOpenInterval() {
        let start = AgentUsageParser.date("2026-09-09T00:00:00Z")!
        var parser = AgentTranscriptParser.IncrementalJSONLines(fileURL: url, provider: .codex, analysisInterval: DateInterval(start: start, duration: 86400))
        parser.consume(Data([line("2026-09-08T23:59:00Z", total: 100, last: 100), line("2026-09-09T00:00:00Z", total: 150), line("2026-09-10T00:00:00Z", total: 200)].joined(separator: "\n").utf8))
        let events = parser.finish().tokenUsage.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.input, 50)
    }
    func testInitialCumulativeUnknownAndReset() {
        let data = [line("2026-09-09T10:00:00Z", total: 100), line("2026-09-09T11:00:00Z", total: 5, last: 5)].joined(separator: "\n")
        let summary = AgentTranscriptParser.parse(data: Data(data.utf8), fileURL: url, provider: .codex)
        XCTAssertTrue(summary.tokenUsage.partial)
        XCTAssertEqual(summary.tokenUsage.events.count, 1)
        XCTAssertEqual(summary.tokenUsage.events.first?.input, 5)
    }
    func testForkIsExplicitlyPartial() {
        let metadata = #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#
        let summary = AgentTranscriptParser.parse(data: Data((metadata + "\n" + line("2026-09-09T10:00:00Z", total: 100, last: 100)).utf8), fileURL: url, provider: .codex)
        XCTAssertTrue(summary.tokenUsage.partial)
        XCTAssertTrue(summary.tokenUsage.events.isEmpty)
    }
    func testClaudeCacheAndMessageDedupe() {
        let row = #"{"type":"assistant","timestamp":"2026-09-09T12:00:00+02:00","requestId":"r","message":{"id":"m","model":"claude","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":20,"cache_creation_input_tokens":3}}}"#
        let summary = AgentTranscriptParser.parse(data: Data((row + "\n" + row).utf8), fileURL: url, provider: .claudeCode)
        XCTAssertEqual(summary.tokenUsage.events.count, 1)
        XCTAssertEqual(summary.tokenUsage.events.first?.input, 33)
        XCTAssertEqual(summary.tokenUsage.events.first?.total, 38)
        XCTAssertNil(summary.tokenUsage.events.first?.reasoning)
    }
    func testOpenCodeMessageOnlyAndExplicitTotal() {
        var parser = AgentTranscriptParser.IncrementalJSONLines(fileURL: url, provider: .openCode)
        let row = Data(#"{"role":"assistant","time":{"completed":1788948000000},"modelID":"model","tokens":{"input":10,"output":5,"reasoning":2,"cache":{"read":3,"write":1}}}"#.utf8)
        parser.consumeOpenCodeRow(kind: "part", identifier: "part", messageID: "m", data: row)
        parser.consumeOpenCodeRow(kind: "message", identifier: "m", messageID: nil, data: row)
        let usage = parser.finish().tokenUsage
        XCTAssertEqual(usage.events.count, 1)
        XCTAssertEqual(usage.events.first?.input, 14)
        XCTAssertNil(usage.events.first?.total)
    }
    func testCountersRejectBooleansNegativeFractionAndOverflow() {
        XCTAssertTrue(AgentUsageParser.counters(["a": true, "b": -1, "c": 1.5, "d": 1e30]).isEmpty)
    }
    func testDailyAggregationDeduplicatesFilesAndRespectsDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let day = AgentUsageParser.date("2026-10-25T12:00:00Z")!
        let start = calendar.startOfDay(for: day)
        XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince(start), 25 * 3600)
        let summary = AgentTranscriptParser.parse(data: Data(line("2026-10-25T22:59:00Z", total: 100, last: 100).utf8), fileURL: url, provider: .codex)
        func record(_ id: String) -> AgentCaptureRecord {
            AgentCaptureRecord(index: AgentSourceIndexEntry(id: id, stableConversationID: id, watchedFolderID: "folder", watchedFolderName: "Codex", provider: .codex, reference: AgentSourceReference(kind: .file, path: "/tmp/" + id), relativePath: id, sourceCreatedAt: nil, sourceModifiedAt: day, firstIndexedAt: day, lastObservedAt: day, byteCount: 1, sha256: "fixture"), summary: summary)
        }
        let aggregate = AgentDailyTokenUsage(records: [record("a"), record("b")], day: day, calendar: calendar)
        XCTAssertEqual(aggregate.observedTotal, 110)
        XCTAssertEqual(aggregate.rows.count, 1)
        XCTAssertNil(AgentDailyTokenUsage(records: [record("a")], day: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar).observedTotal)
    }

    func testOptInRealCodexNumericEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_TEST_USAGE_FILE"] else { throw XCTSkip("Opt-in local numeric verification") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var parser = AgentTranscriptParser.IncrementalJSONLines(fileURL: URL(fileURLWithPath: path), provider: .codex)
        var bytes = 0
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
            bytes += chunk.count
            guard bytes <= 64 * 1024 * 1024 else { throw XCTSkip("Source exceeds smoke-test budget") }
            parser.consume(chunk)
        }
        let usage = parser.finish().tokenUsage
        XCTAssertFalse(usage.events.isEmpty)
        XCTAssertTrue(usage.events.allSatisfy { ($0.total ?? 0) >= ($0.output ?? 0) })
        print("Real local numeric evidence: events=\(usage.events.count), tokens=\(usage.events.compactMap(\.total).reduce(0,+)), partial=\(usage.partial)")
    }

}
