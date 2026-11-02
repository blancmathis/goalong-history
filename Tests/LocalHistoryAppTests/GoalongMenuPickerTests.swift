#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// `GoalongMenuPicker` gives VoiceOver the current choice as its value, like the native `Picker` (DESIGN §9).
/// Moved out of BackgroundContinuityTests (R29 F3, UI-12B).
final class GoalongMenuPickerTests: XCTestCase {
    func testGoalongMenuPickerValueIsTheCurrentChoice() {
        let options = [(1, "Codex"), (2, "Claude Code")]
        XCTAssertEqual(GoalongMenuPicker<Int>.selectedLabel(2, in: options), "Claude Code")
        XCTAssertNil(GoalongMenuPicker<Int>.selectedLabel(3, in: options))
    }
}
#endif
