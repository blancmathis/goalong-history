import XCTest
@testable import LocalHistoryApp

/// T-052 lot 3a: one shared day, kept Ambiance and Temps d’écran, one page width, « Abandonner » confirmed.
final class Lot3aDayAndStateTests: XCTestCase {
    private let calendar = Calendar.current
    private var now: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    // 1: Activité follows the day Historique chose, and keeps its period.
    func testActivityFollowsTheSharedDayAndKeepsItsPeriod() {
        var navigation = GoalongActivityNavigation(day: now, period: 7, now: now)
        XCTAssertFalse(navigation.followShared(day: now, now: now), "same day: nothing moves")
        XCTAssertTrue(navigation.followShared(day: day(-3), now: now))
        XCTAssertEqual(navigation.day, day(-3))
        XCTAssertEqual(navigation.period, 7)
        XCTAssertTrue(navigation.followShared(day: day(5), now: now), "never after today")
        XCTAssertEqual(navigation.day, now)
    }

    // 1 (en plus): « Vérifier et corriger » follows the shared day only when it differs.
    func testReviewCardFollowsTheSharedDay() {
        XCTAssertNil(GoalongWorkReviewCard.dayFollowing(shared: now.addingTimeInterval(3600), current: now))
        XCTAssertEqual(GoalongWorkReviewCard.dayFollowing(shared: day(-1), current: now), day(-1))
    }

    // 6: only these two secondary pages are kept.
    func testAmbianceAndScreenTimeAreKept() {
        XCTAssertTrue(DashboardSection.ambiance.keepsPage)
        XCTAssertTrue(DashboardSection.screenTime.keepsPage)
        for section in [DashboardSection.agentActivity, .chatGPTRecap, .share, .privacy, .cli] {
            XCTAssertFalse(section.keepsPage, "\(section) stays released")
        }
    }

    // 18: Activité and Réglages draw the same width.
    func testActivityAndSettingsShareThePageWidth() throws {
        XCTAssertEqual(LHTheme.pageWidth, 1080)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp")
        for file in ["SettingsPage.swift", "GoalongAnalyticsPage.swift"] {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("maxWidth: LHTheme.pageWidth"), "\(file) uses the shared page width")
        }
    }

    // 22: « Abandonner » asks only when more than one change would be lost.
    func testDiscardAsksOnlyForSeveralChanges() {
        let saved = DashboardSettingsDraft(config: .default)
        var draft = saved
        XCTAssertFalse(DashboardSection.discardNeedsConfirmation(saved: saved, draft: draft))
        draft.captureClicks.toggle()
        XCTAssertFalse(DashboardSection.discardNeedsConfirmation(saved: saved, draft: draft))
        draft.captureScroll.toggle()
        XCTAssertTrue(DashboardSection.discardNeedsConfirmation(saved: saved, draft: draft))
    }
}
