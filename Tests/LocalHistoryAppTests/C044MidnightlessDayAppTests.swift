#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-044 C1: America/Santiago skips 00:00 on 2026-09-06 (00:00 → 01:00).
final class C044MidnightlessDayAppTests: XCTestCase {
    func testConcentrationAcceptsADayWithoutMidnight() {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Santiago")!
        defer { NSTimeZone.default = saved }
        XCTAssertTrue(FocusValidation.day("2026-09-05"))
        XCTAssertTrue(FocusValidation.day("2026-09-06"), "the plan of 2026-09-06 is refused in Chile")
    }
}
#endif
