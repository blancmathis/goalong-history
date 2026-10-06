#if os(macOS)
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongBraiseCLITests: XCTestCase {
    func testAllCommandsValidateAgainAtAppBoundary() throws {
        let id = UUID().uuidString
        let examples = [
            ["enable"], ["disable"], ["quit"], ["status"], ["probe"], ["show"], ["on"], ["off"], ["auto"], ["pause"], ["resume"],
            ["intensity", "0"], ["intensity", "100"], ["brightness", "20"], ["brightness", "100"],
            ["schedule", "list"], ["schedule", "add", "2,3,4,5,6", "22:00", "08:00"],
            ["schedule", "remove", id], ["schedule", "enable", id], ["schedule", "disable", id], ["login", "on"], ["login", "off"]
        ]
        for args in examples {
            let request = try GoalongFocusCLI.parse(command: "braise", arguments: args)
            XCTAssertEqual(try request.validated(), request, "\(args)")
        }
        XCTAssertEqual(GoalongCLIContract.definition(named: "braise")?.effect, .writesExplicitBraiseState)
    }
    func testMalformedNumbersTimesDaysIDsAndForgedOptionsAreRefused() {
        for args in [[], ["on", "extra"], ["intensity", "nan"], ["intensity", "101"], ["brightness", "19"],
                     ["schedule", "add", "2,,3", "22:00", "08:00"], ["schedule", "add", "8", "22:00", "08:00"],
                     ["schedule", "add", "2", "22::00", "08:00"], ["schedule", "add", "2", "22:00", "22:00"],
                     ["schedule", "remove", "bad"], ["login", "yes"], ["--shell", "anything"]] {
            XCTAssertThrowsError(try GoalongBraiseCLI.parse(args))
        }
        for request in [GoalongFocusRequest(command: "braise enable", options: ["arbitrary": "x"]),
                        .init(command: "braise on", flags: ["--open"]), .init(command: "braise on", body: Data()),
                        .init(command: "braise rule-add", options: ["days": "2", "start": "22:00", "end": "08:00", "path": "/tmp/a"])] {
            XCTAssertThrowsError(try request.validated())
        }
    }
}
#endif
