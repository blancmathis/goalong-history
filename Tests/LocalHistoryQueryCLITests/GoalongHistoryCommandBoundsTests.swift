import XCTest
import AgentActivity
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

final class GoalongHistoryCommandBoundsTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        return root
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Writes one event per listed day offset (days before today), just after local midnight, so every event is in the past.
    private func writeEvents(root: URL, daysAgo: [Int], title: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let today = Calendar.current.startOfDay(for: Date())
        for offset in daysAgo {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            let event = HistoryEvent(
                sessionID: "fixture",
                timestamp: day.addingTimeInterval(60),
                kind: .applicationActivated,
                app: .init(name: "Safari", bundleIdentifier: "test.Safari", processIdentifier: 0),
                window: .init(title: "\(title) day\(offset)", role: nil, subrole: nil)
            )
            var line = try encoder.encode(event)
            line.append(10)
            try line.write(to: root.appendingPathComponent("events/\(dayString(day)).jsonl"))
        }
    }

    private func output(_ arguments: [String]) throws -> [String: Any] {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var failure: Error?
        do { try GoalongQueryCLI.run(arguments: arguments) } catch { failure = error }
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let failure { throw failure }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hitCount(_ json: [String: Any]) -> Int {
        ((json["result"] as? [String: Any])?["hits"] as? [Any])?.count ?? -1
    }

    func testSearchWithoutBoundsReadsOnlyTheDefaultWindowAndReportsIt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEvents(root: root, daysAgo: [0, 2, 20, 35], title: "Zephyrfoo")
        let json = try output(["--root", root.path, "search", "Zephyrfoo"])
        XCTAssertEqual(hitCount(json), 2)
        let window = try XCTUnwrap(json["window"] as? [String: Any])
        XCTAssertEqual(window["isDefault"] as? Bool, true)
        XCTAssertEqual(window["maximumDays"] as? Int, 31)
        let limitations = ((json["result"] as? [String: Any])?["limitations"] as? [String]) ?? []
        XCTAssertTrue(limitations.contains { $0.contains("last 7 days") })

        let widened = try output([
            "--root", root.path, "search", "Zephyrfoo",
            "--start", dayString(Calendar.current.date(byAdding: .day, value: -25, to: Date())!),
        ])
        XCTAssertEqual(hitCount(widened), 3)
        XCTAssertEqual((widened["window"] as? [String: Any])?["isDefault"] as? Bool, false)
    }

    func testExplicitRangeLongerThanTheMaximumIsShortenedAndReported() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEvents(root: root, daysAgo: [0, 20, 35], title: "Zephyrfoo")
        let json = try output(["--root", root.path, "search", "Zephyrfoo", "--start", "2000-01-01"])
        XCTAssertEqual(hitCount(json), 2)
        XCTAssertEqual((json["window"] as? [String: Any])?["isClamped"] as? Bool, true)
        XCTAssertThrowsError(try output([
            "--root", root.path, "gaps", "--start", "2026-01-02", "--end", "2026-01-01",
        ]))
    }

    func testWindowResolutionUsesSevenLocalDaysByDefault() throws {
        let calendar = Calendar.current
        let now = Date()
        let window = try GoalongQueryWindow.resolve(start: nil, end: nil, now: now, calendar: calendar)
        let expected = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(window.start, expected)
        XCTAssertEqual(window.end, now)
        XCTAssertTrue(window.isDefault)
        XCTAssertFalse(window.isClamped)
    }

    func testRecentRejectsOutOfRangeMinutesInsteadOfTrapping() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["9223372036854775807", "525601", "0", "-5"] {
            XCTAssertThrowsError(
                try GoalongQueryCLI.run(arguments: ["--root", root.path, "recent", "--minutes", value]),
                value
            )
        }
        XCTAssertNoThrow(try output(["--root", root.path, "recent", "--minutes", "60", "--actions-only"]))
    }

    func testHistoryCommandsRejectUnknownOrExtraArguments() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected: [[String]] = [
            ["recent", "--minute", "15"], ["recent", "--minutes"], ["day", "2026-10-01", "--json"],
            ["day", "today", "extra"], ["summary", "today", "extra"], ["gaps", "--from", "yesterday"],
            ["memories", "x"], ["sources", "id", "extra"],
        ]
        for arguments in rejected {
            XCTAssertThrowsError(
                try GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments),
                arguments.joined(separator: " ")
            )
        }
        XCTAssertNoThrow(try output(["--root", root.path, "day", "today"]))
        XCTAssertNoThrow(try output(["--root", root.path, "gaps", "--start", "yesterday", "--end", "today"]))
        XCTAssertNoThrow(try output(["--root", root.path, "memories"]))
    }

    func testAgentEntryPriorityDoesNotTrapWithoutAnyDate() {
        let now = Date()
        let entry = AgentSourceIndexEntry(
            id: "undated", stableConversationID: "undated", watchedFolderID: "f", watchedFolderName: "F",
            provider: .custom, reference: .init(kind: .file, path: "/nonexistent/session.jsonl"),
            relativePath: "session.jsonl", sourceCreatedAt: nil, sourceModifiedAt: nil, firstIndexedAt: now,
            lastObservedAt: now, byteCount: 1, sha256: String(repeating: "0", count: 64))
        let start = Calendar.current.startOfDay(for: now)
        let score = GoalongQueryCLI.agentEntryPriority(
            entry, dayStart: start, dayEnd: start.addingTimeInterval(86_400), liveModifiedAt: nil)
        XCTAssertEqual(score, 0)
    }
}
