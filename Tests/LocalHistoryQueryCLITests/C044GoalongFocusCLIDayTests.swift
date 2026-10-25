#if os(macOS)
import XCTest
@testable import LocalHistoryQueryCLI

/// T-044 C1: the Focus CLI accepts a day that has no midnight (America/Santiago, 2026-09-06).
final class C044GoalongFocusCLIDayTests: XCTestCase {
    func testFocusCLIAcceptsADayWithoutMidnight() throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Santiago")!
        defer { NSTimeZone.default = saved }
        XCTAssertNoThrow(try GoalongFocusCLI.parse(command: "sessions", arguments: ["2026-09-06"]))
        XCTAssertNoThrow(try GoalongFocusCLI.parse(command: "plan", arguments: ["add", "Devis", "--day", "2026-09-06", "--estimate", "30"]))
    }
}
#endif
