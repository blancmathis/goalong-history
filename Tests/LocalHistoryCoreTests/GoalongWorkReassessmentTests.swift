import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongWorkReassessmentTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))! }
    private let label = GoalongWorkContext.Label(application: "Editor", bundleIdentifier: "fixture.editor", host: nil, title: "Project")
    private func observation(seconds: Int = 300) -> GoalongWorkClassification.Observation {
        let rows = stride(from: 0, through: seconds, by: 60).map {
            HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(Double($0)), kind: .heartbeat,
                app: .init(name: label.application, bundleIdentifier: label.bundleIdentifier, processIdentifier: 1),
                window: .init(title: label.title, role: nil, subrole: nil))
        }
        return GoalongWorkClassification.observation(events: rows, day: day, now: day.addingTimeInterval(86400), calendar: calendar)
    }
    func testUnclearRequiresFiveMinutesAnotherDayAndFewerThanThreeAutomaticAttempts() {
        let observation = observation()
        func keys(_ state: GoalongWorkRetryState, byOwner: Bool = false, seconds: Int = 300) -> [String] {
            let o = self.observation(seconds: seconds)
            return GoalongWorkClassification.pending(day: o.day, labels: o.labels,
                verdicts: .init([label.key: .init(verdict: .unclear, byOwner: byOwner)], retries: [label.key: state]), calendar: calendar).keys
        }
        XCTAssertEqual(keys(.init(attempts: 1, lastAskedDay: "2026-08-09")), [label.key])
        XCTAssertTrue(keys(.init(attempts: 1, lastAskedDay: "2026-08-10")).isEmpty)
        XCTAssertTrue(keys(.init(attempts: 3, lastAskedDay: "2026-08-09")).isEmpty)
        XCTAssertTrue(keys(.init(attempts: 1, lastAskedDay: "2026-08-09"), byOwner: true).isEmpty)
        XCTAssertTrue(keys(.init(attempts: 1, lastAskedDay: "2026-08-09"), seconds: 240).isEmpty)
        let known = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels,
            verdicts: .init([label.key: .init(verdict: .work)]), calendar: calendar)
        XCTAssertTrue(known.keys.isEmpty)
    }
    func testLatestSemanticExcerptIsBoundedRedactedAndFiltered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-reask-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("semantic"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = Data(); let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for (index, text) in ["older", "newer " + String(repeating: "x", count: 400)].enumerated() {
            let payload = SemanticContextPayload(id: "snapshot-\(index)", capturedAt: day.addingTimeInterval(Double(index) * 60),
                application: .init(name: label.application, bundleIdentifier: label.bundleIdentifier, processIdentifier: 1),
                window: .init(title: label.title, role: nil, subrole: nil), url: nil, focusedRole: nil, source: .visibleText,
                text: text, contentSHA256: SHA256Digest.hashHex(text), redacted: true, truncated: false)
            bytes.append(try encoder.encode(payload)); bytes.append(10)
        }
        try bytes.write(to: root.appendingPathComponent("semantic/2026-08-10.semantic.jsonl"))
        XCTAssertTrue(GoalongWorkReassessment.excerpts(root: root, day: day, keys: [label.key], calendar: calendar, permits: { _ in false }).isEmpty)
        let excerpts = GoalongWorkReassessment.excerpts(root: root, day: day, keys: [label.key], calendar: calendar, permits: { _ in true })
        XCTAssertEqual(excerpts[label.key]?.count, 240)
        XCTAssertTrue(excerpts[label.key]?.hasPrefix("newer ") == true)
        let o = observation(), pending = GoalongWorkClassification.pending(day: o.day, labels: o.labels, verdicts: .init(), calendar: calendar)
        let request = GoalongWorkClassification.request(date: "2026-08-10", definition: .init(goals: "Project"), pending: pending,
            batch: pending.keys, day: o.day, verdicts: .init(), knownTasks: [], examples: [], calendar: calendar,
            contextExcerpts: excerpts, dayNote: String(repeating: "n", count: 400))
        XCTAssertEqual(request.contexts.first?.visible_context_excerpt?.count, 240)
        XCTAssertEqual(request.day_note?.count, 280)
        XCTAssertTrue(GoalongWorkClassification.prompt(request, definition: .init(goals: "Project")).contains("day_note"))
    }
}
