#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// the deletion limit must read like the count beside it.
    final class TargetedHistoryDeletionLimitMessageTests: XCTestCase {
        func testDeletionLimitMessageFormatsTheMaximumLikeTheCount() {
            let message = TargetedHistoryDeletionError.selectionExceedsLimit(40_000, 32_768).errorDescription ?? ""
            XCTAssertFalse(message.contains("32768"), "message: \(message)")
            XCTAssertTrue(message.contains(GoalongUIFormat.count(32_768, "événement")), "message: \(message)")
        }
    }
#endif
