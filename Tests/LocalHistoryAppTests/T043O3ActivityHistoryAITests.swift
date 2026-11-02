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
        let full = ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: .diskFull, since: since, bannerNamesStorage: false)
        XCTAssertEqual(full?.hasPrefix("Enregistrement interrompu depuis \(GoalongUIFormat.time(since))"), true)
        XCTAssertEqual(full?.contains("le disque est plein"), true)
        XCTAssertEqual(ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: .permissionDenied, since: nil, bannerNamesStorage: false)?
            .contains("refuse l’écriture"), true)
        XCTAssertNil(ComputerHistoryPageCopy.storageStopNote(isToday: false, failure: .diskFull, since: since, bannerNamesStorage: false))
        XCTAssertNil(ComputerHistoryPageCopy.storageStopNote(isToday: true, failure: nil, since: nil, bannerNamesStorage: false))
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
        XCTAssertEqual(AgentActivityCodexFolder.label(found: false, enabled: false), "Dossier des conversations non détecté")
        XCTAssertEqual(AgentActivityCodexFolder.label(found: true, enabled: true), "Dossier des conversations lu")
        XCTAssertEqual(AgentActivityCodexFolder.label(found: true, enabled: false), "Dossier des conversations détecté, désactivé")
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
        XCTAssertEqual(ChatGPTRecapMetricCopy.screenTime(enabled: true, read: false, seconds: 0, devices: 0, duration: { _ in "0 min" }).value,
                       "—", "allowed but never read: absent, not 0")
        XCTAssertEqual(ChatGPTRecapMetricCopy.aiConversations(enabled: true, read: false, sessions: 0, messages: 0),
                       .init(value: "—", detail: "Non lues"))
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
        navigation.step(-1, earliest: nil, now: now, calendar: calendar)
        XCTAssertEqual(navigation.day, date(0), "no bound: a full period back")
        XCTAssertTrue(DateSelectionControl.isAtEarliest(date(7), earliest: date(1), periodDays: 7, calendar: calendar))
        XCTAssertFalse(DateSelectionControl.isAtEarliest(date(8), earliest: date(1), periodDays: 7, calendar: calendar))
        XCTAssertFalse(DateSelectionControl.isAtEarliest(date(7), earliest: date(1), calendar: calendar), "a day keeps its own rule")
    }

    /// HL-45 (écran 45): never zero banner, only one. A stopped recording comes first; outside Activité the top
    /// banner shows that cause instead of the storage alert; in Activité the page's notice is the one banner.
    func testStorageBannerWaitsForAStoppedRecording() {
        typealias Banner = GoalongAttentionBanner
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: nil, recordingNoticeOnPage: false), .storage)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .input, recordingNoticeOnPage: true), .storage)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .permissions, recordingNoticeOnPage: false), .recordingCause,
                       "history page, permission missing + disk full: one banner, never none")
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .paused, recordingNoticeOnPage: true), .none)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: false, recording: .off, recordingNoticeOnPage: false), .recordingCause)
        XCTAssertEqual(Banner.storageSlot(globallyPaused: true, recording: nil, recordingNoticeOnPage: false), .none,
                       "the global pause banner is the one banner")
        XCTAssertEqual(Banner.pagesWithRecordingNotice, [.overview, .analytics])
    }

    /// R-265 + UI-17A M3, through the files on disk: the bound is the oldest day of every source (Mac, Temps d’écran,
    /// Santé). An older imported day stays reachable; in 7 days the last step back ends on first day + 6.
    func testActivityBoundIsTheOldestDayOfEverySource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t043o3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = root.appendingPathComponent("apple-screen-time/days", isDirectory: true)
        let health = root.appendingPathComponent("health", isDirectory: true)
        try FileManager.default.createDirectory(at: screen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        let mac = [date(12), date(10)]
        XCTAssertNil(GoalongActivityFirstDay.importedEarliest(root: root, calendar: calendar))
        XCTAssertEqual(GoalongActivityFirstDay.earliest(macDays: mac, imported: nil, calendar: calendar), date(10),
                       "no import: Activité keeps the Mac's first day (UI-17A M3)")
        for (folder, name) in [(screen, "2026-10-05.json"), (health, "2026-10-03.json"), (health, "source-1234.json"),
                               (health, "2026-13-01.json"), (screen, "notes.txt")] {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
        let imported = GoalongActivityFirstDay.importedEarliest(root: root, calendar: calendar)
        XCTAssertEqual(imported, date(3))
        let first = try XCTUnwrap(GoalongActivityFirstDay.earliest(macDays: mac, imported: imported, calendar: calendar))
        XCTAssertEqual(first, date(3))

        let now = date(20, 12)
        var day = GoalongActivityNavigation(day: date(20), period: 1, now: now, calendar: calendar)
        for _ in 0..<30 { day.step(-1, earliest: first, now: now, calendar: calendar) }
        XCTAssertEqual(day.day, date(3), "the imported Santé day is reachable, nothing before it")
        XCTAssertTrue(DateSelectionControl.isAtEarliest(day.day, earliest: first, calendar: calendar))

        var week = GoalongActivityNavigation(day: date(20), period: 1, now: now, calendar: calendar)
        week.selectPeriod(7)
        for _ in 0..<10 { week.step(-1, earliest: first, now: now, calendar: calendar) }
        XCTAssertEqual(week.day, date(9), "last 7-day step back: 3–9 oct.")
        XCTAssertTrue(DateSelectionControl.isAtEarliest(week.day, earliest: first, periodDays: 7, calendar: calendar))
    }

    /// P-3: an empty definition must not hide a history turned off: the switch reads the history consent too.
    func testClassificationNeedsTheHistoryConsentToo() {
        XCTAssertFalse(GoalongWorkPage.canClassify(analysisConsent: true, historyConsent: false, historyOff: false))
        XCTAssertFalse(GoalongWorkPage.canClassify(analysisConsent: false, historyConsent: true, historyOff: false))
        XCTAssertFalse(GoalongWorkPage.canClassify(analysisConsent: true, historyConsent: true, historyOff: true))
        XCTAssertTrue(GoalongWorkPage.canClassify(analysisConsent: true, historyConsent: true, historyOff: false))
    }
}
#endif
