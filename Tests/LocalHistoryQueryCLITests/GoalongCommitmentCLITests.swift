#if os(macOS)
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongCommitmentCLITests: XCTestCase {
    func testEveryCommandNormalizesAndValidates() throws {
        let id = UUID().uuidString, other = UUID().uuidString
        let commands: [(String, [String])] = [
            ("commitment", ["show"]), ("commitment", ["show", "--day", "tomorrow", "--week", "next"]),
            ("commitment", ["set", "--day", "today", "--kind", "work", "--target", "7h30", "--stake", id, "--stake", other, "--until", "23:59"]),
            ("commitment", ["set", "--week", "2020-W53", "--kind", "task", "--target", "80h", "--task", "Goalong"]),
            ("commitment", ["set", "--week", "this", "--kind", "sessions", "--target", "60"]),
            ("commitment", ["set", "--day", "today", "--kind", "plan", "--target", "10"]),
            ("commitment", ["set", "--day", "today", "--file", "-"]),
            ("commitment", ["delete", "--day", "today"]), ("commitment", ["joker", "--week", "this"]),
            ("commitment", ["declare", "--day", "2026-10-04"]),
            ("commitments", []), ("commitments", ["--from", "2026-10-01", "--to", "2026-10-04"])
        ]
        for (command, arguments) in commands {
            let request = try GoalongFocusCLI.parse(command: command, arguments: arguments, readFile: { _ in Data("{\"kind\":\"work\",\"target\":30}".utf8) })
            XCTAssertEqual(try request.validated(), request)
        }
        for (input, expected) in [("7h", 420), ("7h30", 450), ("7h30m", 450), ("90m", 90), ("90", 90)] { XCTAssertEqual(GoalongCommitmentCLI.target(input, kind: "work"), expected) }
        for input in ["7h60", "-1m", "+30", "1.5h", "9999999999999999999999999m"] { XCTAssertNil(GoalongCommitmentCLI.target(input, kind: "work")) }
    }
    func testEveryInvalidSyntaxBoundsAndControlCharacter() {
        let commands: [(String, [String])] = [
            ("commitment", []), ("commitment", ["unknown"]), ("commitment", ["show", "--day", "2026-02-30"]),
            ("commitment", ["show", "--week", "2021-W53"]), ("commitment", ["delete"]),
            ("commitment", ["joker", "--day", "today", "--week", "this"]),
            ("commitment", ["declare", "--day", "today", "--target", "1"]),
            ("commitment", ["set", "--day", "today", "--week", "this", "--kind", "work", "--target", "30m"]),
            ("commitment", ["set", "--day", "today", "--kind", "task", "--target", "15m"]),
            ("commitment", ["set", "--day", "today", "--kind", "work", "--target", "31m"]),
            ("commitment", ["set", "--week", "this", "--kind", "work", "--target", "30m"]),
            ("commitment", ["set", "--day", "today", "--kind", "work", "--target", "17h"]),
            ("commitment", ["set", "--week", "this", "--kind", "sessions", "--target", "61"]),
            ("commitment", ["set", "--day", "today", "--kind", "plan", "--target", "0"]),
            ("commitment", ["set", "--day", "today", "--kind", "plan", "--target", "1h"]),
            ("commitment", ["set", "--day", "today", "--kind", "task", "--target", "15m", "--task", "a\nb"]),
            ("commitment", ["set", "--day", "today", "--kind", "work", "--target", "30m", "--until", "12:00"]),
            ("commitment", ["set", "--day", "today", "--kind", "work", "--target", "30m", "--stake", "invalid"]),
            ("commitment", ["set", "--day", "today", "--file", "-", "--kind", "work"]),
            ("commitments", ["--from", "2026-10-04", "--to", "2026-10-03"]), ("commitments", ["--from", "today"])
        ]
        for (command, args) in commands { XCTAssertThrowsError(try GoalongFocusCLI.parse(command: command, arguments: args)) { XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument) } }
        let id = UUID().uuidString
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "commitment", arguments: ["set", "--day", "today", "--kind", "work", "--target", "30m", "--stake", id, "--stake", id]))
        XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "commitment", arguments: ["show", "--day", "today", "--day", "tomorrow"]))
    }
    func testFileBoundJSONObjectAndForgedNormalizedRequests() throws {
        for body in [Data(repeating: 0, count: 65537), Data("[]".utf8), Data("null".utf8)] {
            XCTAssertThrowsError(try GoalongFocusCLI.parse(command: "commitment", arguments: ["set", "--day", "today", "--file", "-"], readFile: { _ in body }))
        }
        let body = Data("{\"kind\":\"work\",\"target\":30}".utf8)
        let request = try GoalongFocusCLI.parse(command: "commitment", arguments: ["set", "--day", "today", "--file", "-"], readFile: { _ in body })
        XCTAssertEqual(try request.validated().body, body)
        XCTAssertThrowsError(try GoalongFocusRequest(command: "commitment joker", options: ["--day": "today"], flags: ["--lock"]).validated())
        XCTAssertThrowsError(try GoalongFocusRequest(command: "commitment show", options: ["--stake": ","]).validated())
    }
    func testSocketRoundTripForEveryRouteAndAppNotRunning() throws {
        let root = URL(fileURLWithPath: "/private/tmp/commitment-socket-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = GoalongReadOnlyQueryServer(rootDirectory: root, screenTimeHandler: { _, _, _ in throw GoalongFocusError.moduleDisabled }, focusHandler: { request in
            _ = try request.validated()
            return try JSONEncoder().encode(request)
        })
        try server.start(); defer { server.stop() }
        for action in ["show", "set", "delete", "joker", "declare"] {
            let args = action == "set" ? [action, "--day", "today", "--file", "-"] : [action, "--day", "today"]
            let request = try GoalongFocusCLI.parse(command: "commitment", arguments: args, readFile: { _ in Data("{\"kind\":\"plan\",\"target\":1}".utf8) })
            XCTAssertEqual(try JSONDecoder().decode(GoalongFocusRequest.self, from: GoalongFocusCLI.execute(request, root: root)), request)
        }
        let history = try GoalongFocusCLI.parse(command: "commitments", arguments: [])
        XCTAssertEqual(try JSONDecoder().decode(GoalongFocusRequest.self, from: GoalongFocusCLI.execute(history, root: root)), history)
        server.stop()
        XCTAssertThrowsError(try GoalongFocusCLI.execute(history, root: root)) { XCTAssertEqual($0 as? GoalongFocusError, .appNotRunning) }
    }
    func testHelpAndCapabilitiesDeclareWritesAndHistoryIsReadOnly() throws {
        XCTAssertEqual(GoalongCLIContract.definition(named: "commitment")?.effect, .writesExplicitFocusState)
        XCTAssertEqual(GoalongCLIContract.definition(named: "commitments")?.effect, GoalongCLIEffect.none)
        XCTAssertTrue(GoalongCLIContract.usageText.contains("commitment show"))
        let object = try JSONSerialization.jsonObject(with: GoalongQueryCLI.capabilitiesPayload()) as! [String: Any]
        let commands = object["commands"] as! [[String: Any]]
        XCTAssertTrue(commands.contains { $0["name"] as? String == "commitment" }); XCTAssertTrue(commands.contains { $0["name"] as? String == "commitments" })
        XCTAssertTrue((object["sourceMutationPolicy"] as! String).contains("locked Blocking block"))
    }
}
#endif
