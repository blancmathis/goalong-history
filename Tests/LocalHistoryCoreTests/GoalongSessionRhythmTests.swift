import XCTest
@testable import LocalHistoryCore

final class GoalongSessionRhythmTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_789_200_000)
    func event(_ seconds: Double, _ app: String?, kind: EventKind = .applicationActivated) -> HistoryEvent {
        .init(sessionID: "test", timestamp: start.addingTimeInterval(seconds), kind: kind,
              app: app.map { .init(name: $0, bundleIdentifier: nil, processIdentifier: 0) })
    }
    func testExactChangesMergeProjectToolsAndPreserveShortConsultations() throws {
        var a = GoalongSessionRhythm(project: "Goalong", applications: ["Codex", "Safari"])
        for row in [event(0, "Codex"), event(60, "Safari"), event(120, "WhatsApp"), event(120.5, "Codex"), event(180.5, "Codex"), event(500, nil, kind: .systemSleep)] { a.ingest(row) }
        let r = try XCTUnwrap(a.result(includeTimeline: true, includeTimes: false))
        XCTAssertEqual(r.project_ms, 180000)
        XCTAssertEqual(r.longest_project_ms, 120000)
        XCTAssertEqual(r.brief_consultations, 1)
        XCTAssertEqual(r.observed_ms, 180500)
        XCTAssertEqual(r.episodes?.last?.relation, "unknown")
        XCTAssertNil(r.start)
        XCTAssertNil(a.result(includeTimeline: false, includeTimes: false)?.episodes)
    }
    func testObservationBoundaryAndOutOfOrderDataNeverInventContinuity() throws {
        var a = GoalongSessionRhythm(project: "Projet", applications: ["Codex"])
        for row in [event(0, "Codex"), event(30, nil, kind: .captureSuppressed), event(60, "Codex"), event(90, "Codex")] { a.ingest(row) }
        let r = try XCTUnwrap(a.result(includeTimeline: true, includeTimes: true))
        XCTAssertEqual(r.project_ms, 60000)
        XCTAssertEqual(r.longest_project_ms, 30000)
        XCTAssertEqual(r.episodes?[1].relation, "unknown")
        a.ingest(event(70, "Codex"))
        XCTAssertNil(a.result(includeTimeline: true, includeTimes: true))
    }
    func testFractionalMillisecondsKeepAContiguousTimeline() throws {
        var a = GoalongSessionRhythm(project: "Projet", applications: ["Codex"])
        for row in [event(0, "Codex"), event(0.0004, "Safari"), event(0.0008, "Codex"), event(0.0012, "Safari"), event(1, "Codex")] { a.ingest(row) }
        let r = try XCTUnwrap(a.result(includeTimeline: true, includeTimes: false))
        var end = 0
        for episode in try XCTUnwrap(r.episodes) {
            XCTAssertEqual(episode.offset_ms, end)
            end += episode.duration_ms
        }
        XCTAssertEqual(end, r.window_ms)
        XCTAssertEqual(r.window_ms, 1000)
    }
}
