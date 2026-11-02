#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-043 lot O3: Activité, IA, Historique.
final class T043O3ActivityHistoryAITests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// DEF-07: a history day with traces names the storage stop and its cause; nothing on other days.
    func testHistoryNamesTheStorageStopAboveTraces() {
        let since = date(23, 9, 40)
        let full = ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: .diskFull, since: since)
        XCTAssertEqual(full?.hasPrefix("Enregistrement interrompu depuis \(GoalongUIFormat.time(since))"), true)
        XCTAssertEqual(full?.contains("le disque est plein"), true)
        XCTAssertEqual(ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: .permissionDenied, since: nil)?
            .contains("refuse l’écriture"), true)
        XCTAssertNil(ComputerHistoryPageCopy.storageStopNote(isToday: false, failure: .diskFull, since: since))
        XCTAssertNil(ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: nil, since: nil))
    }

    /// UI16-23 (écran 23): the hourly axis covers whole hours; the current hour (ending « now ») is not cut.
    func testHourlyRangeCoversWholeHours() {
        let range = GoalongHourlyClassChart.wholeHours(starts: [date(23, 8), date(23, 9)], ends: [date(23, 9), date(23, 9, 41)],
                                                       calendar: calendar)
        XCTAssertEqual(range, date(23, 8)...date(23, 10))
        XCTAssertEqual(GoalongHourlyClassChart.hourTicks(range!, stride: 1, calendar: calendar), [date(23, 8), date(23, 9)])
        XCTAssertNil(GoalongHourlyClassChart.wholeHours(starts: [], ends: [], calendar: calendar))
    }

    /// 6-CODEX: Codex has one row; its folder state is one line of it.
    func testCodexFolderStateIsOneLine() {
        XCTAssertEqual(AgentActivityCodexFolder.label(found: false, enabled: false), "Dossier des sessions non détecté")
        XCTAssertEqual(AgentActivityCodexFolder.label(found: true, enabled: true), "Dossier des sessions suivi")
        XCTAssertEqual(AgentActivityCodexFolder.label(found: true, enabled: false), "Dossier des sessions détecté, désactivé")
    }

    /// R-266: « — / Non lues » only for a source not allowed; a read source with nothing that day says 0.
    func testRecapBandSaysZeroForAReadSource() {
        let read = ChatGPTRecapMetricCopy.aiConversations(enabled: true, sessions: 0, messages: 0)
        XCTAssertEqual(read.value, "0")
        XCTAssertNotEqual(read.detail, "Non lues")
        XCTAssertEqual(ChatGPTRecapMetricCopy.aiConversations(enabled: false, sessions: 0, messages: 0),
                       .init(value: "—", detail: "Non lues"))
        let screen = ChatGPTRecapMetricCopy.screenTime(enabled: true, seconds: 0, devices: 0, duration: { "\($0 / 60) min" })
        XCTAssertEqual(screen.value, "0 min")
        XCTAssertEqual(ChatGPTRecapMetricCopy.screenTime(enabled: false, seconds: 0, devices: 0, duration: { _ in "x" }).value, "—")
        XCTAssertEqual(ChatGPTRecapMetricCopy.spoken(title: "Temps d’écran", value: "—", detail: "Non lu"), "Temps d’écran : non lu")
    }

    /// R-265: in 7 or 28 days, « précédent » never shows a period mostly before the first day.
    func testPreviousPeriodStopsAtTheFirstDay() {
        let now = date(20, 12)
        var navigation = GoalongActivityNavigation(day: date(10), period: 1, now: now, calendar: calendar)
        navigation.selectPeriod(7)
        navigation.step(-1, earliest: date(1), now: now, calendar: calendar)
        XCTAssertEqual(navigation.day, date(7), "the last step back shows 1–7, not 28 sept. – 3 oct.")
        navigation.step(-1, earliest: date(1), now: now, calendar: calendar)
        XCTAssertEqual(navigation.day, date(7), "nothing older to show")
        navigation.step(-1, now: now, calendar: calendar)
        XCTAssertEqual(navigation.day, date(0), "no bound: a full period back")
        XCTAssertTrue(DateSelectionControl.isAtEarliest(date(7), earliest: date(1), periodDays: 7, calendar: calendar))
        XCTAssertFalse(DateSelectionControl.isAtEarliest(date(8), earliest: date(1), periodDays: 7, calendar: calendar))
        XCTAssertFalse(DateSelectionControl.isAtEarliest(date(7), earliest: date(1), calendar: calendar), "a day keeps its own rule")
    }

    /// HL-45 (écran 45): one banner at a time; a stopped recording comes before the storage alert.
    func testStorageBannerWaitsForAStoppedRecording() {
        typealias Banner = GoalongAttentionBanner
        XCTAssertTrue(Banner.storageAlertsShown(localEnabled: true, globallyPaused: false, recording: nil))
        XCTAssertTrue(Banner.storageAlertsShown(localEnabled: true, globallyPaused: false, recording: .input))
        XCTAssertFalse(Banner.storageAlertsShown(localEnabled: true, globallyPaused: false, recording: .paused))
        XCTAssertFalse(Banner.storageAlertsShown(localEnabled: true, globallyPaused: false, recording: .permissions))
        XCTAssertFalse(Banner.storageAlertsShown(localEnabled: false, globallyPaused: false, recording: .off))
        XCTAssertFalse(Banner.storageAlertsShown(localEnabled: true, globallyPaused: true, recording: nil))
    }
}
#endif
