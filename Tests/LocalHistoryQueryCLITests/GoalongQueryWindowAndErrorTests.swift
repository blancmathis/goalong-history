import XCTest
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

final class GoalongQueryWindowAndErrorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()
    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testNoBoundReadsTheLastSevenLocalDays() throws {
        let now = date(20, 15)
        let window = try GoalongQueryWindow.resolve(start: nil, end: nil, now: now, calendar: calendar)
        XCTAssertEqual(window.start, calendar.startOfDay(for: date(14)))
        XCTAssertEqual(window.end, now)
        XCTAssertTrue(window.isDefault)
        XCTAssertFalse(window.isClamped)
        XCTAssertTrue(window.limitation.hasPrefix("Only the last 7 days were read"))
    }

    func testDefaultWindowFollowsABareDayEnd() throws {
        // `--end 2026-10-10` is the next midnight; the default start is counted from that day.
        let endDay = calendar.startOfDay(for: date(10))
        let end = calendar.date(byAdding: .day, value: 1, to: endDay)!
        let window = try GoalongQueryWindow.resolve(start: nil, end: end, endDay: endDay, now: date(20), calendar: calendar)
        XCTAssertEqual(window.start, calendar.startOfDay(for: date(4)))
        XCTAssertEqual(window.end, end)
    }

    func testLongRangeIsShortenedToThirtyOneDays() throws {
        let end = date(20)
        let window = try GoalongQueryWindow.resolve(start: date(1).addingTimeInterval(-90 * 86_400), end: end, calendar: calendar)
        XCTAssertTrue(window.isClamped)
        XCTAssertFalse(window.isDefault)
        XCTAssertEqual(window.start, calendar.date(byAdding: .day, value: -31, to: end))
        XCTAssertTrue(window.limitation.contains("shortened"))
    }

    func testRangeOfExactlyThirtyOneDaysIsNotClamped() throws {
        let end = date(20)
        let start = calendar.date(byAdding: .day, value: -31, to: end)!
        let window = try GoalongQueryWindow.resolve(start: start, end: end, calendar: calendar)
        XCTAssertFalse(window.isClamped)
        XCTAssertEqual(window.start, start)
        XCTAssertTrue(window.limitation.hasPrefix("Only the requested period was read"))
    }

    func testStartAfterEndIsRejectedAlsoForBareDays() {
        XCTAssertThrowsError(try GoalongQueryWindow.resolve(start: date(12), end: date(10), calendar: calendar)) {
            XCTAssertEqual(String(describing: $0), "--start must not be after --end")
        }
        let endDay = calendar.startOfDay(for: date(10))
        XCTAssertThrowsError(try GoalongQueryWindow.resolve(start: date(12), end: date(11), endDay: endDay, calendar: calendar))
    }

    func testStartEqualToEndIsAnEmptyButValidWindow() throws {
        let window = try GoalongQueryWindow.resolve(start: date(10), end: date(10), calendar: calendar)
        XCTAssertEqual(window.start, window.end)
        XCTAssertFalse(window.isClamped)
    }

    func testCLIErrorTextsForTheCommandLineAndForPeople() {
        XCTAssertEqual(CLIError.invalidDate("x").description, "Invalid date: x")
        XCTAssertEqual(CLIError.invalidInteger("y").description, "Invalid integer: y")
        XCTAssertEqual(CLIError.missingHealth.description, "capture-health.json is not available")
        XCTAssertEqual(CLIError.usage("u").errorDescription, "Une valeur n’est pas valide. Vérifiez la sélection, puis réessayez.")
        XCTAssertEqual(CLIError.missingHealth.errorDescription, "Les données de santé ne sont pas disponibles.")
        let known: [String: String] = [
            "Apple Screen Time is off": "Temps d’écran Apple",
            "No saved Screen Time data": "Aucune donnée Apple",
            "Computer History is off": "historique de ce Mac",
            "Website details are unavailable": "sites ne sont pas disponibles",
            "Saved ChatGPT analysis access is off": "analyses ChatGPT",
            "No saved recap exists for day": "Aucun récap",
            "The saved recap belongs to another day": "ne correspondent pas",
            "The saved record does not match": "ne correspondent pas",
            "The saved day uses a different timezone": "autre fuseau",
            "Rhythm is not calculable": "rythme n’est pas calculable",
            "Rename the project": "Renommez le projet",
            "Select fewer details": "2 Mio",
            "Conversation source authorization changed": "autorisation",
        ]
        for (english, fragment) in known {
            let text = CLIError.unsafeSource(english).errorDescription ?? ""
            XCTAssertTrue(text.contains(fragment), "\(english) → \(text)")
            XCTAssertFalse(text.contains(english), "an English message must not reach people")
        }
        XCTAssertEqual(CLIError.unsafeSource("Déjà écrit en français : précis").errorDescription, "Déjà écrit en français : précis")
        XCTAssertTrue(CLIError.unsafeSource("Something unexpected").errorDescription?.hasPrefix("Une source nécessaire") == true)
    }

    func testErrorEnvelopeCarriesAReadableMessageAndAFocusHint() throws {
        XCTAssertEqual(GoalongQueryCLI.errorMessage(for: GoalongGlobalPause.PauseError.active),
                       "Global pause is active; this command reads nothing until Goalong is resumed.")
        XCTAssertTrue(GoalongQueryCLI.errorMessage(for: GoalongGlobalPause.PauseError.unreadable).contains("stays paused"))
        XCTAssertEqual(GoalongQueryCLI.errorMessage(for: GoalongFocusError.locked), "locked")
        XCTAssertEqual(GoalongQueryCLI.errorMessage(for: CLIError.usage("bad flag")), "bad flag")

        let plain = try XCTUnwrap(GoalongQueryCLI.errorEnvelopeData(for: CLIError.usage("bad flag")))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "error")
        XCTAssertEqual(object["error"] as? String, "bad flag")
        XCTAssertEqual(object["usage"] as? String, "goalong help")
        XCTAssertNil(object["hint"])
        XCTAssertEqual(plain.last, 0x0A)

        let unknown = try XCTUnwrap(GoalongQueryCLI.errorEnvelopeData(for: GoalongFocusError.outcomeUnknown))
        let hinted = try XCTUnwrap(JSONSerialization.jsonObject(with: unknown) as? [String: Any])
        XCTAssertEqual(hinted["error"] as? String, "outcomeUnknown")
        XCTAssertTrue((hinted["hint"] as? String)?.contains("goalong focus status") == true)
    }
}
