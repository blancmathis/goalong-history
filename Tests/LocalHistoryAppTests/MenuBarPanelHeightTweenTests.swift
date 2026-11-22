#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// The popover window follows the content's curve: same Bézier, same duration, sampled by time.
final class MenuBarPanelHeightTweenTests: XCTestCase {
    typealias Tween = PanelHeightTween

    func testBezierEndpointsAndMonotone() {
        XCTAssertEqual(Tween.bezier(0), 0, accuracy: 1e-4)
        XCTAssertEqual(Tween.bezier(1), 1, accuracy: 1e-4)
        var last = -1.0
        for step in 0...100 {
            let value = Tween.bezier(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
    }

    func testBezierMatchesTheSettleCurve() {
        // cubic-bezier(0.2, 0.8, 0.2, 1) is fast at the start: well past half at 30 % of the time.
        XCTAssertGreaterThan(Tween.bezier(0.3), 0.6)
        XCTAssertEqual(LHTheme.settleDuration, 0.24, accuracy: 1e-9)
    }

    func testGrowthMovesMonotonicallyToTarget() {
        let tween = Tween(from: 400, to: 470, now: 10)
        var last: CGFloat = 400
        for step in 0...30 {
            let height = tween.height(at: 10 + Double(step) * 0.01)
            XCTAssertGreaterThanOrEqual(height, last)
            last = height
        }
        XCTAssertEqual(last, 470)
        XCTAssertTrue(tween.isFinished(at: 10.25))
    }

    func testShrinkMovesMonotonicallyToTarget() {
        let tween = Tween(from: 470, to: 430, now: 10)
        XCTAssertEqual(tween.height(at: 10), 470)
        var last: CGFloat = 470
        for step in 0...30 {
            let height = tween.height(at: 10 + Double(step) * 0.01)
            XCTAssertLessThanOrEqual(height, last)
            last = height
        }
        XCTAssertEqual(last, 430)
        XCTAssertFalse(tween.isFinished(at: 10.2))
        XCTAssertTrue(tween.isFinished(at: 10.25))
    }

    func testGrowthLeadsByOneFrameShrinkStartsOnTime() {
        let grow = Tween(from: 400, to: 470, now: 5)
        XCTAssertGreaterThan(grow.height(at: 5), 400)
        let shrink = Tween(from: 470, to: 400, now: 5)
        XCTAssertEqual(shrink.height(at: 5), 470)
    }

    func testHeightsLandOnHalfPoints() {
        let tween = Tween(from: 400, to: 463, now: 0)
        for step in 0...24 {
            let height = tween.height(at: Double(step) * 0.01)
            XCTAssertEqual(height * 2, (height * 2).rounded())
        }
    }
}
#endif
