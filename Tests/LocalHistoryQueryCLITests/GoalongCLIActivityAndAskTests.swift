import XCTest
import LocalHistoryCore

@testable import LocalHistoryQueryCLI

final class GoalongCLIActivityAndAskTests: XCTestCase {
    private let day = "2026-08-31"
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
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

    /// One journal for the fixed day: three apps used one after another, each with several window changes.
    private func makeRoot(midnight: Date? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-activity-ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        cleanup.append(root)
        let midnight = midnight ?? Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let fileDay = DateFormatter()
        fileDay.calendar = Calendar(identifier: .gregorian)
        fileDay.locale = Locale(identifier: "en_US_POSIX")
        fileDay.dateFormat = "yyyy-MM-dd"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines = Data()
        let apps = [("Safari", "test.Safari"), ("Xcode", "test.Xcode"), ("Notes", "test.Notes")]
        for (appIndex, app) in apps.enumerated() {
            for step in 0..<4 {
                let event = HistoryEvent(
                    sessionID: "fixture",
                    timestamp: midnight.addingTimeInterval(Double(36_000 + appIndex * 1_800 + step * 60)),
                    kind: step == 0 ? .applicationActivated : .windowChanged,
                    app: .init(name: app.0, bundleIdentifier: app.1, processIdentifier: 0),
                    window: .init(title: "Zephyrfoo \(app.0) \(step)", role: nil, subrole: nil)
                )
                lines.append(try encoder.encode(event))
                lines.append(10)
            }
        }
        try lines.write(to: root.appendingPathComponent("events/\(fileDay.string(from: midnight)).jsonl"))
        return root
    }

    func testActivitiesPagesAndActivityReturnsOrderedInteractionPages() throws {
        let root = try makeRoot()
        let all = try output(["--root", root.path, "activities", day])
        let total = try XCTUnwrap(all["totalActivityCount"] as? Int)
        XCTAssertGreaterThanOrEqual(total, 2)
        XCTAssertNil(all["nextActivityOffset"] as? Int)

        let firstPage = try output(["--root", root.path, "activities", day, "--limit", "1"])
        XCTAssertEqual(firstPage["returnedActivityCount"] as? Int, 1)
        XCTAssertEqual(firstPage["nextActivityOffset"] as? Int, 1)
        XCTAssertTrue((firstPage["nextStep"] as? String ?? "").contains("--offset 1"))
        let pageTwo = try output(["--root", root.path, "activities", day, "--limit", "1", "--offset", "1"])
        let firstID = try XCTUnwrap((firstPage["activities"] as? [[String: Any]])?.first?["id"] as? String)
        let secondID = try XCTUnwrap((pageTwo["activities"] as? [[String: Any]])?.first?["id"] as? String)
        XCTAssertNotEqual(firstID, secondID)

        let detail = try output(["--root", root.path, "activity", firstID, day])
        XCTAssertNil(detail["error"] as? String)
        XCTAssertEqual(detail["day"] as? String, day)
        let interactions = try XCTUnwrap(detail["totalInteractionCount"] as? Int)
        XCTAssertGreaterThan(interactions, 0)
        XCTAssertEqual(detail["interactionOffset"] as? Int, 0)
        XCTAssertNotNil(detail["activity"] as? [String: Any])

        let paged = try output(["--root", root.path, "activity", firstID, day, "--limit", "1", "--offset", "0"])
        XCTAssertEqual(paged["returnedInteractionCount"] as? Int, 1)
        if interactions > 1 {
            XCTAssertEqual(paged["nextInteractionOffset"] as? Int, 1)
        } else {
            XCTAssertNil(paged["nextInteractionOffset"] as? Int)
        }
        let beyond = try output(["--root", root.path, "activity", firstID, day, "--offset", "\(interactions)"])
        XCTAssertEqual(beyond["returnedInteractionCount"] as? Int, 0)
        XCTAssertNil(beyond["nextInteractionOffset"] as? Int)
    }

    func testActivityWithAnUnknownIDOrAnEmptyDayExplainsWhyNothingWasReturned() throws {
        let root = try makeRoot()
        let unknown = try output(["--root", root.path, "activity", "no-such-activity", day])
        XCTAssertNil(unknown["activity"] as? [String: Any])
        XCTAssertEqual(unknown["totalInteractionCount"] as? Int, 0)
        XCTAssertTrue((unknown["error"] as? String ?? "").contains("No activity with ID no-such-activity"))

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-activity-empty-\(UUID().uuidString)", isDirectory: true)
        cleanup.append(emptyRoot)
        let empty = try output(["--root", emptyRoot.path, "activities", day])
        XCTAssertEqual(empty["totalActivityCount"] as? Int, 0)
        XCTAssertTrue((empty["nextStep"] as? String ?? "").contains("goalong activity ACTIVITY_ID"))
    }

    func testAskAnswersFromYesterdaysJournalAndRejectsAMissingQuestion() throws {
        // "yesterday" is resolved against the real clock, so the journal is written for the same relative day.
        let yesterday = Calendar.current.date(
            byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let root = try makeRoot(midnight: yesterday)
        XCTAssertThrowsError(try output(["--root", root.path, "ask"])) {
            XCTAssertTrue(GoalongQueryCLI.errorMessage(for: $0).contains("natural-language question"))
        }
        XCTAssertThrowsError(try output(["--root", root.path, "ask", "--days", "abc", "Zephyrfoo"]))
        let json = try output(["--root", root.path, "ask", "Zephyrfoo", "yesterday"])
        let answer = try XCTUnwrap(json["answer"] as? [String: Any])
        XCTAssertEqual(answer["query"] as? String, "Zephyrfoo yesterday")
        XCTAssertFalse((answer["answer"] as? String ?? "").isEmpty)
        XCTAssertEqual(json["reconstructedDays"] as? Int, 1)
        XCTAssertNotNil(json["screenTime"] as? [String: Any])
        XCTAssertFalse(((answer["limitations"] as? [String]) ?? []).isEmpty)
    }

    func testAskClampsTheDayWindowAndStillAnswersWithoutEvidence() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-ask-empty-\(UUID().uuidString)", isDirectory: true)
        cleanup.append(emptyRoot)
        for days in ["0", "5000"] {
            let json = try output(["--root", emptyRoot.path, "ask", "--days", days, "Zephyrfoo"])
            XCTAssertEqual((json["answer"] as? [String: Any])?["hits"] as? [Any] == nil, false)
            XCTAssertEqual(json["retainedProjectionBytes"] as? Int, 0, "days \(days)")
        }
    }
}
