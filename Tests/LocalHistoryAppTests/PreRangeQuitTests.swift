#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

/// T-057 Q3 (Mathis, 2026-11-27): « Quitter » in the 30 min before a « Mot de passe » or « Verrouillé » range follows
/// the range's rule. T-059 lot 2 already reads every protected rule, running or not, so the pre-range window is
/// covered (and stricter: the whole day). Injected clock, no window, no focus.
@MainActor final class PreRangeQuitTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04 in Paris (UTC+1); the range runs 21:00 → 23:00 on weekdays.
    private func paris(_ hour: Int, _ minute: Int) -> Date {
        paris.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour, minute: minute))!
    }
    private func list(_ lock: BlockLock) -> BlockList {
        BlockList(name: "Nuit", sites: [BlockSiteRule(pattern: "jeux.example")],
                  program: BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)]))
    }
    private func runtime(_ lock: BlockLock, at now: Date) throws -> (BlockingRuntime, BlockingController) {
        let credential = try XCTUnwrap(BlockPasswordLock.make("fixture", at: now))
        let c = BlockingController(document: .init(lists: [list(lock)], passwordLock: credential), clock: { now }, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 })
        addTeardownBlock { @MainActor in c.shutdown() }
        return (BlockingRuntime(controller: c, redScreenKeeper: { nil }), c)
    }

    /// 29, 10 and 1 min before a « Mot de passe » range: the range is not running, yet Quit asks the blocking password
    /// (rules prompt), and an installer's SIGTERM is ignored then opens the same prompt.
    func testPasswordRangeAboutToStartAsksThePassword() throws {
        for minute in [31, 50, 59] {
            let (runtime, c) = try runtime(.password, at: paris(20, minute))
            XCTAssertTrue(c.activeBlocks.isEmpty, "20:\(minute): the range has not begun")
            XCTAssertNil(c.protectedUntil, "20:\(minute): no guard-until marker meaning changed")
            XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .quit, "lists prompt: nothing running")
            XCTAssertEqual(runtime.protectedRuleStop(), .password, "20:\(minute)")
            XCTAssertTrue(AppDelegate.ruleQuitNeedsStop(.password, passwordGiven: false), "Quit asks the password")
            XCTAssertFalse(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: nil, installOverride: false))
            XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: true, senderPID: nil, installOverride: false),
                          "logout / shutdown still quit")
            XCTAssertTrue(AppDelegate.signalQuitAsks(prompt: .quit, ruleStop: .password, jevStep: .allow), "SIGTERM opens the prompt")
        }
    }

    /// Before a « Verrouillé » range: Quit is refused, like during it; SIGTERM stays ignored without a window.
    func testLockedRangeAboutToStartRefusesQuit() throws {
        let (runtime, c) = try runtime(.locked, at: paris(20, 45))
        XCTAssertTrue(c.activeBlocks.isEmpty)
        XCTAssertEqual(runtime.protectedRuleStop(), .locked)
        XCTAssertTrue(AppDelegate.ruleQuitNeedsStop(.locked, passwordGiven: true), "even with a password typed")
        XCTAssertFalse(AppDelegate.honoursTerminationSignal(runtime: runtime, sessionEnding: false, senderPID: nil, installOverride: false))
        XCTAssertFalse(AppDelegate.signalQuitAsks(prompt: .quit, ruleStop: .locked, jevStep: .allow))
    }

    /// During the range the same password is asked, now through the lists prompt (which covers the rules prompt).
    func testDuringTheRangeSameRule() throws {
        let (runtime, c) = try runtime(.password, at: paris(21, 10))
        XCTAssertEqual(c.activeBlocks.first?.lock, .password)
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: runtime), .password)
        XCTAssertFalse(AppDelegate.ruleQuitNeedsStop(.password, passwordGiven: true), "one password for both prompts")
        let (locked, _) = try self.runtime(.locked, at: paris(21, 10))
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: locked), .locked(redScreen: false))
    }

    /// Current rule (T-059 P3): a protected range is protected all day, not only in the last 30 min. A plain range
    /// (« Libre ») never asks anything: free Quit.
    func testProtectionHoldsAllDayAndFreeRangeQuitsFreely() throws {
        let (far, _) = try runtime(.password, at: paris(10, 0))
        XCTAssertEqual(far.protectedRuleStop(), .password, "11 h before: still asked (T-059 lot 2)")
        let (free, _) = try runtime(.free, at: paris(20, 50))
        XCTAssertNil(free.protectedRuleStop())
        XCTAssertEqual(AppDelegate.quitPrompt(runtime: free), .quit)
        XCTAssertTrue(AppDelegate.honoursTerminationSignal(runtime: free, sessionEnding: false, senderPID: nil, installOverride: false))
    }
}
#endif
