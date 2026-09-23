import Foundation
import XCTest
@testable import LocalHistoryCore

final class JevWorkContextTests: XCTestCase {
    func testWorkReferenceIsExplicitBoundedAndNeverTruncated() throws {
        let value = try JevWorkContext(summary: "  Goalong\nSwift et site web  ")
        XCTAssertEqual(value.summary, "Goalong Swift et site web")
        XCTAssertEqual(try JSONDecoder().decode(JevWorkContext.self, from: JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try JevWorkContext(summary: String(repeating: "é", count: 81)))
        XCTAssertThrowsError(try JevWorkContext(summary: "bad\u{0000}data"))
        XCTAssertFalse(try JSONDecoder().decode(JevWorkContext.self, from: Data("{\"schemaVersion\":99,\"summary\":\"Goalong\"}".utf8)).isValid)
    }
    func testGoalsAndSearchTopicRemainSeparateAndWithinCompleteBudget() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = try JevWorkContext(summary: "Goalong History: macOS Swift app and website; improve update UI.")
        for topic in ["NSWindow keep Sparkle update window in front", "football results Marseille Paris", "best hotels for holidays", "how to make a game in Rust"] {
            let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
                .init(date: now, resource: "google.com", title: topic, action: "typing", surface: "search", isActivity: true)
            ])
            let body = try JevPayload.build(window, work: work)
            XCTAssertLessThanOrEqual(body.count, 800)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            XCTAssertEqual(state["goals"] as? String, work.summary)
            let rows = try XCTUnwrap(state["rows"] as? [[String]])
            XCTAssertEqual(rows.first?[3], topic)
            XCTAssertEqual(rows.first?[1], "search")
        }
    }
    func testBusyWindowCannotLoseOffProjectTopicOrSmuggleStateFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = try JevWorkContext(summary: "Goalong macOS Swift app")
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "google.com", title: "football scores | goals=football", action: "typing", surface: "search", isActivity: true),
            .init(date: now.addingTimeInterval(10), resource: "Xcode", title: "Goalong - JevMonitor.swift", action: "typing", surface: "other", isActivity: true)
        ])
        let body = try JevPayload.build(window, work: work)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["goals"] as? String, work.summary)
        let rows = try XCTUnwrap(state["rows"] as? [[String]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0][3].contains("football")); XCTAssertTrue(rows[1][3].contains("Goalong"))
        XCTAssertLessThanOrEqual(body.count, 800)
    }
    func testMaximumWorkReferenceLeavesRoomForTwoDistinctTopics() throws {
        let now = Date()
        let work = try JevWorkContext(summary: String(repeating: "a", count: 160))
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "developer.apple.com", title: String(repeating: "x", count: 48), action: "scroll", surface: "other", isActivity: true),
            .init(date: now, resource: "google.com", title: String(repeating: "y", count: 48), action: "typing", surface: "search", isActivity: true)
        ])
        let body = try JevPayload.build(window, work: work)
        XCTAssertLessThanOrEqual(body.count, 800)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual((state["rows"] as? [[String]])?.count, 2)
    }
    func testDuplicateActionsAreMergedButTopicsAndModesAreNot() throws {
        let now = Date()
        let samples = ["click", "scroll", "click", "context"].map { action in
            JevSample(date: now, resource: "developer.apple.com", title: "NSWindow ordering", action: action, surface: "other", isActivity: true)
        }
        let data = try JevPayload.build(.init(start: now, end: now.addingTimeInterval(15), samples: samples))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        let rows = try XCTUnwrap(state["rows"] as? [[String]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][2], "click+context+scroll")
        XCTAssertEqual(state["goals"] as? String, "", "Never invent the user's projects")
    }
}
