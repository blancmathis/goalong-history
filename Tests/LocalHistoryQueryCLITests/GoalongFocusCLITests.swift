#if os(macOS)
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongFocusCLITests: XCTestCase {
    func testEveryCommandAndNormalizedRequestRoundTrip() throws {
        let id = UUID().uuidString
        let examples: [(String, [String])] = [
            ("focus", ["status"]), ("focus", ["watch"]),
            ("session", ["start", "--intent", "Écrire", "--minutes", "50"]),
            ("session", ["start", "--intent", "Lire", "--open", "--plan-item", id]),
            ("session", ["start", "--intent", "Code", "--pomodoro", "50/10/20/3", "--cycles", "4", "--block", id, "--lock", "--ambiance"]),
            ("session", ["start", "--intent", "Code", "--pomodoro"]),
            ("session", ["current"]), ("session", ["skip"]), ("session", ["stop", "--outcome", "done", "--note", "Fait"]),
            ("sessions", ["yesterday"]), ("plan", ["show", "today"]),
            ("plan", ["add", "Devis", "--day", "2026-10-05", "--project", "Client", "--estimate", "30"]),
            ("plan", ["done", id]), ("plan", ["drop", id]), ("plan", ["move", id, "--to", "2026-10-06"]),
            ("plan", ["set", "--file", "-"]), ("review", ["show"]), ("review", ["set", "--file", "-"]),
            ("limits", []), ("block-lists", []), ("friction", ["2026-10-05"])
        ]
        for (command, args) in examples {
            let request = try GoalongFocusCLI.parse(command: command, arguments: args, readFile: { _ in Data("{\"items\":[]}".utf8) })
            XCTAssertEqual(try request.validated(), request, "\(command) \(args)")
        }
    }
    func testEveryInvalidArgumentClassAndBoundedFile() {
        let invalid: [(String, [String])] = [
            ("focus", []), ("focus", ["status", "extra"]), ("session", ["start", "--intent", "a\nb", "--minutes", "25"]),
            ("session", ["start", "--intent", "a", "--minutes", "4"]), ("session", ["start", "--intent", "a", "--open", "--lock"]),
            ("session", ["start", "--intent", "a", "--minutes", "25", "--pomodoro"]),
            ("session", ["start", "--intent", "a", "--pomodoro", "1/5/15/4"]), ("session", ["stop", "--outcome", "guessed"]),
            ("sessions", ["2026-02-30"]), ("plan", ["add", "a", "--estimate", "601"]), ("plan", ["move", "bad", "--to", "today"]),
            ("review", ["set"]), ("limits", ["--unknown"]), ("friction", ["today", "yesterday"])
        ]
        for (command, args) in invalid { XCTAssertThrowsError(try GoalongFocusCLI.parse(command: command, arguments: args)) { XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument) } }
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "plan", arguments: ["set", "--file", "-"], readFile: { _ in Data(repeating: 0, count: 65537) }))
        XCTAssertThrowsError(try GoalongFocusRequest(command: "plan add", options: ["title": "a", "--minutes": "25"]).validated())
    }
    func testRevisionedPlanMutationsNormalizeAndRoundTrip() throws {
        for action in ["patch", "reflow", "undo"] {
            var arguments = [action, "--day", "tomorrow", "--if-revision", "7", "--request-id", "evening-plan-7"]
            if action == "patch" { arguments += ["--file", "-"] }
            let request = try GoalongFocusCLI.parse(command: "plan", arguments: arguments,
                readFile: { _ in Data(#"{"reason":"Préparer demain","items":[]}"#.utf8) })
            XCTAssertEqual(request.options["--day"], "tomorrow")
            XCTAssertEqual(request.options["--if-revision"], "7")
            XCTAssertNil(request.options["--file"])
            XCTAssertEqual(request.body != nil, action == "patch")
            XCTAssertEqual(try request.validated(), request)
        }
        let show = try GoalongFocusCLI.parse(command: "routine", arguments: ["show"])
        XCTAssertEqual(try show.validated(), show)
    }

    func testRevisionedMutationsRequireCompleteUnambiguousConcurrencyGuards() {
        let valid = ["--day", "2026-11-26", "--if-revision", "0", "--request-id", "request-1"]
        var invalid: [[String]] = [
            ["patch"] + valid,
            ["reflow", "--if-revision", "0", "--request-id", "a"],
            ["undo", "--day", "today", "--request-id", "a"],
            ["reflow", "--day", "today", "--if-revision", "0"],
            ["reflow"] + valid + ["--file", "-"],
            ["undo"] + valid + ["--request-id", "duplicate"],
            ["undo"] + valid + ["extra"],
            ["reflow"] + valid + ["--lock"],
            ["patch"] + valid + ["--file", "-", "--project", "hidden"],
        ]
        for revision in ["-1", "+1", "00", "1.5", "1000000001", "999999999999999999999999999"] {
            invalid.append(["reflow", "--day", "today", "--if-revision", revision, "--request-id", "a"])
        }
        invalid.append(["undo", "--day", "today", "--if-revision", "0", "--request-id", String(repeating: "x", count: 129)])
        for arguments in invalid {
            XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "plan", arguments: arguments,
                readFile: { _ in Data("{}".utf8) }), "\(arguments)") { XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument) }
        }
        for body in [Data("[]".utf8), Data("null".utf8), Data(repeating: 32, count: 65537)] {
            XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "plan", arguments: ["patch"] + valid + ["--file", "-"], readFile: { _ in body }))
        }
    }

    func testRoutineJSONRejectsUnknownFieldsAtEveryLevelAndOversizeInput() throws {
        let accepted = [
            #"{"agenda":null}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris"}}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris","reminderLimit":32}}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[{"title":"Déjeuner","startMinute":720,"endMinute":780,"fixed":true}]}}"#,
        ]
        for source in accepted {
            let request = try GoalongFocusCLI.parse(command: "routine", arguments: ["set", "--file", "-"], readFile: { _ in Data(source.utf8) })
            XCTAssertEqual(try request.validated(), request)
        }
        let refused = [
            #"{}"#, #"{"agenda":"none"}"#, #"{"agenda":{},"hidden":true}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris","usePlanContext":true}}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[{"title":"A","startMinute":600,"endMinute":630,"secret":true}]}}"#,
            #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[null]}}"#,
        ]
        for source in refused {
            XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "routine", arguments: ["set", "--file", "-"], readFile: { _ in Data(source.utf8) }))
        }
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "routine", arguments: ["set", "--day", "tomorrow", "--file", "-"], readFile: { _ in Data(accepted[0].utf8) }))
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "routine", arguments: ["set", "--file", "-"], readFile: { _ in Data(repeating: 32, count: 65537) }))
        XCTAssertThrowsError(try GoalongFocusRequest(command: "plan reflow", options: ["--day": "today", "--if-revision": "0", "--request-id": "a"], body: Data("{}".utf8)).validated())
    }

    func testTomorrowIsAvailableForTheEveningPlan() throws {
        let id = UUID().uuidString
        let arguments = [
            ["show", "tomorrow"], ["add", "Documenter", "--day", "tomorrow"],
            ["done", id, "--day", "tomorrow"], ["move", id, "--to", "tomorrow"],
            ["set", "--day", "tomorrow", "--file", "-"],
        ]
        for args in arguments {
            let request = try GoalongFocusCLI.parse(command: "plan", arguments: args, readFile: { _ in Data(#"{"items":[]}"#.utf8) })
            XCTAssertEqual(try request.validated(), request)
        }
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "plan", arguments: ["show", "2026-02-30"]))
    }

    func testRevisionErrorsExposeActionableHintsWithoutChangingErrorCodes() throws {
        for code in [GoalongFocusError.conflict, .requestConflict] {
            let data = try XCTUnwrap(GoalongQueryCLI.errorEnvelopeData(for: code))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["error"] as? String, code.rawValue)
            XCTAssertFalse((object["hint"] as? String ?? "").isEmpty)
        }
    }

    func testHubEmitsOnlyChangesEightWatchersAndRestart() throws {
        let hub = GoalongFocusStatusHub(), id = UUID().uuidString
        hub.publish(Data("{\"state\":\"active\"}".utf8))
        let first = try hub.poll(id: id, cursor: nil, timeout: 0); XCTAssertEqual(first.lines.count, 1)
        XCTAssertTrue(try hub.poll(id: id, cursor: first.cursor, timeout: 0).lines.isEmpty)
        hub.publish(Data("{\"state\":\"focus\"}".utf8)); hub.publish(Data("{\"state\":\"focus\"}".utf8))
        XCTAssertEqual(try hub.poll(id: id, cursor: first.cursor, timeout: 0).lines.count, 1)
        for _ in 0..<7 { _ = try hub.poll(id: UUID().uuidString, cursor: nil, timeout: 0) }
        XCTAssertThrowsError(try hub.poll(id: UUID().uuidString, cursor: nil, timeout: 0)) { XCTAssertEqual($0 as? GoalongFocusError, .tooManyWatchers) }
        hub.remove(id); _ = try hub.poll(id: UUID().uuidString, cursor: nil, timeout: 0)
        let restarted = GoalongFocusStatusHub(); restarted.publish(Data("{\"state\":\"active\"}".utf8))
        XCTAssertEqual(try restarted.poll(id: id, cursor: first.cursor, timeout: 0).lines.count, 1)
    }
    func testSocketFocusWritesRoundTripOwnerModeAndErrors() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-socket-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = GoalongReadOnlyQueryServer(rootDirectory: root, screenTimeHandler: { _, _, _ in throw GoalongFocusError.moduleDisabled }, focusHandler: { request in
            if request.command == "focus status" { return Data("{\"schema\":1,\"state\":\"off\"}".utf8) }
            if let code = GoalongFocusError(rawValue: request.command) { throw code }
            return try JSONEncoder().encode(request)
        })
        try server.start(); defer { server.stop() }
        let request = try GoalongFocusCLI.parse(command: "plan", arguments: ["set", "--file", "-"], readFile: { _ in Data("{\"items\":[]}".utf8) })
        XCTAssertEqual(try JSONDecoder().decode(GoalongFocusRequest.self, from: GoalongReadOnlyQueryBroker.requestFocus(rootDirectory: root, request: request)), request)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for code in [GoalongFocusError.moduleDisabled, .invalidArgument, .locked, .notFound, .storageFailed, .tooManyWatchers, .conflict, .requestConflict] {
            XCTAssertThrowsError(try GoalongReadOnlyQueryBroker.requestFocus(rootDirectory: root, request: .init(command: code.rawValue))) { XCTAssertEqual($0 as? GoalongFocusError, code) }
        }
        server.stop()
        XCTAssertEqual(try GoalongFocusCLI.execute(.init(command: "focus status"), root: root), GoalongFocusCLI.unavailable)
        XCTAssertThrowsError(try GoalongFocusCLI.execute(.init(command: "session current"), root: root)) { XCTAssertEqual($0 as? GoalongFocusError, .appNotRunning) }
    }
    func testWatchSurvivesRealSocketRestartAndOnlyEmitsTransitions() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-watch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var polls = 0, retries = 0, lines: [Data] = [], server: GoalongReadOnlyQueryServer?
        func makeServer(_ instance: Int) throws -> GoalongReadOnlyQueryServer {
            let value = GoalongReadOnlyQueryServer(rootDirectory: root, screenTimeHandler: { _, _, _ in Data("{}".utf8) }, focusHandler: { request in
                if request.command == "focus unwatch" { return Data("{}".utf8) }
                polls += 1
                return try JSONEncoder().encode(GoalongFocusWatchBatch(cursor: "\(instance):\(polls)", lines: [Data("{\"schema\":1,\"state\":\"active\"}".utf8)]))
            }); try value.start(); return value
        }
        try GoalongFocusCLI.watch(root: root, emit: { line in
            lines.append(line)
            if lines.count == 2 { server?.stop(); server = nil }
        }, shouldContinue: { lines.count < 4 }, retry: {
            retries += 1; server = try? makeServer(retries)
        })
        server?.stop()
        XCTAssertEqual(retries, 2); XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], GoalongFocusCLI.unavailable); XCTAssertEqual(lines[2], GoalongFocusCLI.unavailable)
    }
    func testOldServerSecondStopCannotUnlinkReplacementSocket() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = GoalongReadOnlyQueryServer(rootDirectory: root, screenTimeHandler: { _, _, _ in Data("{}".utf8) })
        try old.start(); old.stop()
        let replacement = GoalongReadOnlyQueryServer(rootDirectory: root, screenTimeHandler: { _, _, _ in Data("{}".utf8) })
        try replacement.start(); defer { replacement.stop() }; old.stop()
        XCTAssertTrue(GoalongReadOnlyQueryBroker.isRunning(rootDirectory: root))
    }

}
#endif
