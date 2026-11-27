#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// bugs-cycle-de-vie-03: after a screen change rebuilds the freeze shields, they go back behind the front app only
/// when the current freeze allows it. Any other app keeps them in front.
final class BlockingFreezeShieldLevelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1791201600)
    private func freeze(_ mode: BlockFreeze.Mode = .shield, allowed: [String]) -> BlockFreeze {
        BlockFreeze(start: now, end: now.addingTimeInterval(3600), mode: mode,
                    allowedApps: allowed.map { BlockAppRule(bundleIdentifier: $0, name: $0) })
    }

    func testAllowedFrontAppKeepsTheShieldsBehindAfterARebuild() {
        XCTAssertTrue(StandardBlockingBackend.shieldsStayBehind(frontmost: "com.apple.TextEdit", freeze: freeze(allowed: ["com.apple.TextEdit"])))
    }

    func testAnyOtherFrontAppKeepsTheShieldsInFront() {
        let value = freeze(allowed: ["com.apple.TextEdit"])
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: "com.apple.Safari", freeze: value))
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: "ai.goalong.localhistory", freeze: value))
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: nil, freeze: value))
    }

    func testAPermissionNoLongerInTheRulesDoesNotLowerTheShields() {
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: "com.apple.TextEdit", freeze: freeze(allowed: [])))
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: "com.apple.TextEdit", freeze: nil))
        XCTAssertFalse(StandardBlockingBackend.shieldsStayBehind(frontmost: "com.apple.TextEdit", freeze: freeze(.lockScreen, allowed: ["com.apple.TextEdit"])))
    }
}
#endif
