#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class GoalongMotionTests: XCTestCase {
    private func equal(_ a: GoalongMotion.Sample, _ b: GoalongMotion.Sample, file: StaticString = #filePath, line: UInt = #line) {
        for (left, right) in [(a.p, b.p), (a.v, b.v), (a.a, b.a)] {
            for (x, y) in zip(left, right) { XCTAssertEqual(x, y, accuracy: 1e-10, file: file, line: line) }
        }
    }
    func testApprovedVectorReference() {
        // Independent samples from the approved JS (SHA-256 701f2deb…31866).
        equal(GoalongMotion.activity(0.1), .init(
            p: [0.21259682287721116, 0.01192596079882609],
            v: [2.1818940720978715, 0.23715533645510134],
            a: [0.5157503931636604, 2.317122934162474]))
        equal(GoalongMotion.activity(0.6), .init(
            p: [0.9400000000000001, 0.3499999999999999],
            v: [0, 0.916297857297023],
            a: [-7.539281139721037, 0]))
        equal(GoalongMotion.activity(1.7), .init(
            p: [-0.6041401122027181, 0.44058666578588224],
            v: [-0.3190780967177632, -0.8850757649365297],
            a: [3.2644677149740655, -0.620871218972468]))
    }
    func testSeamAndGAttachmentAcrossNineCycles() {
        for frame in 0...1296 {
            let t = Double(frame) / 60
            equal(GoalongMotion.activity(t), GoalongMotion.activity(t + GoalongMotion.cycle))
            let sample = GoalongMotion.activity(t)
            let loop = GoalongMotion.geometry(GoalongMotion.loop, q: sample.p[0], b: sample.p[1])
            let arm = GoalongMotion.geometry(GoalongMotion.arm, q: sample.p[0], b: sample.p[1])
            XCTAssertEqual(loop[0][0], arm[0][0])
        }
    }
    func testInterruptionAndReentryPreservePositionVelocityAcceleration() {
        for t in [0, 0.025, 0.1, 0.2, 0.299, 0.3, 0.4, 0.6, 1.2, 1.7, 2.4, 2.699, 20] {
            var state = GoalongMotion.State()
            state.setBusy(true, at: 100)
            let before = state.sample(at: 100 + t)
            state.setBusy(false, at: 100 + t)
            XCTAssertFalse(state.busy, "Logical completion is immediate, not delayed by motion")
            equal(before, state.sample(at: 100 + t))
            let resuming = state.sample(at: 100 + t + 0.12)
            state.setBusy(true, at: 100 + t + 0.12)
            equal(resuming, state.sample(at: 100 + t + 0.12))
            state.setBusy(false, at: 100 + t + 0.19)
            equal(state.sample(at: 100 + t + 0.5), .rest)
        }
    }
    func testIdleAndRepeatedBusyDoNotRestart() {
        var state = GoalongMotion.State()
        state.setBusy(false, at: 1)
        XCTAssertEqual(state.phase, .idle)
        state.setBusy(true, at: 1)
        state.setBusy(true, at: 2)
        XCTAssertEqual(state.since, 1)
        equal(state.sample(at: 2), GoalongMotion.entry(1))
        state.settle()
        XCTAssertEqual(state.phase, .idle)
        equal(state.sample(at: 3), .rest)
    }
}
#endif
