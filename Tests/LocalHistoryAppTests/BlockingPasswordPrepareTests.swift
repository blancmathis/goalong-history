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

    // T-057 C4: the rule switch's sheet (unlock) and the red screen's sheet derive off main through one helper.
    func testWithPreparedPasswordRunsTheSameCheckAndCountsAWrongTry() async {
        let (c, now) = controller()
        let wrong = await c.withPreparedPassword("wrong") { c.verifyRedScreenPassword("wrong") }
        XCTAssertEqual(wrong, .wrong(remaining: 4))
        for _ in 0..<3 { _ = await c.withPreparedPassword("wrong") { c.verifyRedScreenPassword("wrong") } }
        let wait = await c.withPreparedPassword("wrong") { c.verifyRedScreenPassword("wrong") }
        guard case .wait(let until) = wait else { return XCTFail("fifth miss must wait") }
        XCTAssertEqual(until.timeIntervalSince(now), 60, accuracy: 1)
        let right = await c.withPreparedPassword("fixture") { c.verifyRedScreenPassword("fixture") }
        XCTAssertEqual(right, .wait(until: until), "the wait still wins over a right password")
    }

    func testWithPreparedPasswordAcceptsTheRightPasswordAndLeavesNoMemo() async {
        let (c, _) = controller()
        let ok = await c.withPreparedPassword("fixture") { c.verifyRedScreenPassword("fixture") }
        XCTAssertEqual(ok, .ok)
        // The memo is gone: a later wrong password is judged by its own derivation.
        XCTAssertEqual(c.verifyRedScreenPassword("nope"), .wrong(remaining: 4))
        XCTAssertEqual(c.verifyRedScreenPassword("fixture"), .ok)
    }

    func testPromptWithoutAControllerStillAnswersSynchronously() {
        XCTAssertEqual(BlockingPasswordPrompt.answer("", submit: { _ in "x" }), BlockingController.emptyPasswordText)
        XCTAssertNil(BlockingPasswordPrompt.answer("a", submit: { _ in nil }))
    }
}
#endif
