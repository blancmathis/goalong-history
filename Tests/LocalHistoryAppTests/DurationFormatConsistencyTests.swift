#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// One French duration format on every surface: « 1 h 08 », « 45 min » (non-breaking spaces), rounded to the minute.
final class DurationFormatConsistencyTests: XCTestCase {
    private let nb = "\u{00A0}"

    func testSharedFormatterRoundsToTheMinute() {
        XCTAssertEqual(DashboardFormatters.duration(seconds: 4_020), "1\(nb)h\(nb)07")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 4_050), "1\(nb)h\(nb)08")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 5_280), "1\(nb)h\(nb)28")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 2_700), "45\(nb)min")
    }

    func testEverySurfaceReadsTheSameDuration() {
        // 1 h 07 min 30 s: a formatter that truncates says 07, one that rounds says 08.
        let seconds = 4_050
        let expected = DashboardFormatters.duration(seconds: TimeInterval(seconds))
        XCTAssertEqual(GoalongReadableSharePreview.duration(seconds), expected)
        XCTAssertEqual(GoalongHealthImportSheet.duration(Double(seconds)), expected)
        XCTAssertEqual(BlockingFormat.duration(minutes: 68), expected)
        XCTAssertEqual(FocusDistractionFormat.minutes(seconds), expected)
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(Double(seconds)), expected)
    }

    func testNoPageKeepsItsOwnCompactHoursMinutesFormat() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "ChatGPTRecapContext.swift" {  // that one writes the model prompt, not UI
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("h \\(minutes)m\""), "\(url.lastPathComponent) has its own « 1h 28m » format")
        }
    }

    func testScreenTimeRefreshTextFollowsTheRealInterval() {
        XCTAssertEqual(AppleScreenTimeDashboardModel.refreshCadenceLabel(30), "toutes les 30 s")
        XCTAssertEqual(AppleScreenTimeDashboardModel.refreshCadenceLabel(600), "toutes les 10 min")
        XCTAssertEqual(AppleScreenTimeDashboardModel.refreshCadenceLabel(3_600), "toutes les heures")
        XCTAssertEqual(AppleScreenTimeDashboardModel.refreshCadenceLabel(7_200), "toutes les 2 h")
    }
}
#endif
