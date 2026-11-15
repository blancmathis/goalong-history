#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-064 lot 11: state machines that must not wait on the disk or keep stale state.
final class T064EtatsConcurrenceTests: XCTestCase {
    func testCaptureHintNeverReadsTheGlobalPauseAndFollowsTheLastAuthoritativeRead() {
        var reads = 0
        var paused = false
        let state = CaptureState(isGloballyPaused: { reads += 1; return paused })
        XCTAssertTrue(state.isCapturingHint)
        XCTAssertEqual(reads, 0)

        paused = true
        XCTAssertFalse(state.isCapturing)
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(state.isCapturingHint)
        XCTAssertEqual(reads, 1, "the tap callback path must not touch the pause file")

        paused = false
        XCTAssertFalse(state.isCapturingHint, "stale until the next authoritative read")
        XCTAssertTrue(state.isCapturing)
        XCTAssertTrue(state.isCapturingHint)

        state.setManualPaused(true)
        XCTAssertFalse(state.isCapturingHint, "local flags apply at once")
        XCTAssertEqual(reads, 2)
    }

    func testIngressRearmsADrainTokenLeftOwnedByAnInterruptedStop() {
        let ingress = EventTapIngressBuffer(capacity: 8)
        XCTAssertTrue(ingress.enqueue(Self.input()))
        // The stop drain pops the input, then exits early without finishing the pass.
        XCTAssertNotNil(ingress.popFirst())
        XCTAssertFalse(ingress.enqueue(Self.input()), "token still owned")
        _ = ingress.discardPending()
        // discardPending released the token here; force the stuck state again.
        XCTAssertTrue(ingress.enqueue(Self.input()))
        XCTAssertNotNil(ingress.popFirst())

        XCTAssertFalse(ingress.rearmDrainScheduling(), "nothing waiting: no drain to schedule")
        XCTAssertTrue(ingress.enqueue(Self.input()), "the next input schedules a drain again")
        XCTAssertTrue(ingress.rearmDrainScheduling(), "waiting input asks the caller for one drain")
        XCTAssertFalse(ingress.enqueue(Self.input(at: Date().addingTimeInterval(5))))
    }

    private static func input(at date: Date = Date()) -> EventTapPendingInput {
        EventTapPendingInput(
            kind: .leftMouseDown, observedAt: date, keyActivity: .none,
            locationX: 1, locationY: 1, clickCount: 1, scrollDeltaX: 0, scrollDeltaY: 0,
            sourceProcessIdentifier: 0, sourceUserIdentifier: 0, sourceStateIdentifier: 0,
            targetProcessIdentifier: 0, observedContext: nil, capturingWasEnabled: true,
            secureInputWasEnabled: false)
    }
}
#endif
