#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-057 (bugs-concurrence-06): PBKDF2 runs off the main actor; every check and counter stays on it.
@MainActor final class BlockingPasswordPrepareTests: XCTestCase {
    private func controller() -> (BlockingController, Date) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = BlockingController(document: .init(lists: [BlockList(name: "Sites")]), clock: { now })
        XCTAssertTrue(c.setPassword("fixture"))
        return (c, now)
    }

    func testOneDerivationTakesLongEnoughToJustifyMovingItOffMain() {
        let lock = BlockPasswordLock.make("fixture", at: Date())!
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(lock.matches("fixture"))
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("[T-057] verifyPassword derivation: \(ms) ms")
        XCTAssertEqual(lock.iterations, 200_000, "the iteration count is unchanged")
    }

    func testPreparedRightPasswordGrantsAndChangesThePasswordAsBefore() async {
        let (c, _) = controller()
        await c.prepareDerivations(old: "fixture", new: "replacement")
        XCTAssertEqual(c.changePassword(old: "fixture", new: "replacement"), .ok)
        XCTAssertEqual(c.removePassword(old: "replacement"), .ok)
    }

    func testPreparedWrongPasswordStillCountsAndWaitsExactlyAsBefore() async {
        let (c, now) = controller()
        for attempt in 1...4 {
            await c.prepareDerivations(old: "wrong", new: nil)
            XCTAssertEqual(c.removePassword(old: "wrong"), .wrong(remaining: 5 - attempt))
        }
        await c.prepareDerivations(old: "wrong", new: nil)
        guard case .wait(let until) = c.removePassword(old: "wrong") else { return XCTFail("fifth miss must wait") }
        XCTAssertEqual(until.timeIntervalSince(now), 60, accuracy: 1)
        await c.prepareDerivations(old: "fixture", new: nil)
        XCTAssertEqual(c.removePassword(old: "fixture"), .wait(until: until), "the wait still wins over a right password")
    }

    func testAMemoForAnotherPasswordIsNeverUsed() async {
        let (c, _) = controller()
        await c.prepareDerivations(old: "fixture", new: nil)
        XCTAssertEqual(c.removePassword(old: "other"), .wrong(remaining: 4))
        XCTAssertTrue(c.hasPassword)
    }

    func testAMemoIsSingleUseAndIgnoredWhenTheSecretChangedMeanwhile() async {
        let (c, _) = controller()
        await c.prepareDerivations(old: "fixture", new: nil)
        XCTAssertEqual(c.changePassword(old: "fixture", new: "second"), .ok)
        // The old memo was used up; a new secret is always checked against its own hash.
        XCTAssertEqual(c.removePassword(old: "fixture"), .wrong(remaining: 4))
        await c.prepareDerivations(old: "fixture", new: nil)   // memo taken from the secret "second": answer false
        XCTAssertEqual(c.removePassword(old: "fixture"), .wrong(remaining: 3))
        XCTAssertEqual(c.removePassword(old: "second"), .ok)
    }
}
#endif
