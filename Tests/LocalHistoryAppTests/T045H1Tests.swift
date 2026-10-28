#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    /// T-045 H1: bugs in zones never audited before (selectedDay pages, dashboard numbers, bet bounds).
    final class T045H1Tests: XCTestCase {
        // H1-01: « Bilan quotidien » keeps its chosen day as an instant. After Paris → New York,
        // « 25 oct. 00:00 Paris » reads as Oct 24 and the page loads the Oct 24 recap.
        func testRecapChosenPastDayKeepsItsDateAfterATimeZoneChange() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(rootDirectory: root.appendingPathComponent("history")),
                recapsDirectory: root.appendingPathComponent("recaps"),
                executableLocator: { nil },
                sessionFactory: { _ in throw NSError(domain: "T045H1", code: 1) },
                delayedAutomaticScheduler: { _ in }
            )
            let oct25 = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
            runtime.selectDay(oct25)
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(Calendar.current.component(.day, from: runtime.selectedDay), 25, "Bilan page shows Oct 24")
        }
        // MARK: - Activité summary (dashboard numbers)

        private var paris: Calendar {
            var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
        }

        /// One heartbeat a minute from `hour`:`minute` (Paris clock) for `minutes`, alternating apps every `switchEvery` minutes.
        private func parisDay(_ day: Int, month: Int = 10, hour: Int, minute: Int = 0, minutes: Int,
                              switchEvery: Int = 0, now: Date? = nil) -> GoalongLocalAnalytics.Day {
            let base = paris.date(from: DateComponents(year: 2026, month: month, day: day))!
            let first = paris.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
            let events = (0...minutes).map { index -> HistoryEvent in
                let app = switchEvery > 0 && (index / switchEvery) % 2 == 1 ? "Mail" : "Editor"
                return HistoryEvent(id: "\(day)-\(index)", sessionID: "fixture",
                    timestamp: first.addingTimeInterval(Double(index * 60)), kind: .heartbeat,
                    app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1),
                    url: nil, classification: nil)
            }
            return GoalongLocalAnalytics.build(events: events, day: base,
                now: now ?? base.addingTimeInterval(3 * 86400), calendar: paris)
        }

        // H1-03: on the day the clocks go back (Paris, 25 Oct.), « hier à la même heure » cut yesterday
        // at midnight + elapsed time, one hour too late: 10:00 today was compared with 11:00 yesterday.
        func testTodayAtTheSameClockTimeOnTheDayClocksGoBack() throws {
            let yesterday = parisDay(24, hour: 9, minutes: 120)            // 09:00 → 11:00
            let now = paris.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
            let today = parisDay(25, hour: 9, minutes: 30, now: now)
            let summary = GoalongActivitySummary(period: .init(days: [today]), previous: .init(days: [yesterday]),
                                                 calendar: paris, now: now)
            let comparison = try XCTUnwrap(summary.comparison)
            XCTAssertEqual(comparison.label, "hier à la même heure")
            XCTAssertEqual(comparison.previous, 3600, accuracy: 61, "Yesterday must stop at 10:00, not 11:00")
        }

        // H1-04: the typical start time read seconds since midnight; on 25 Oct. (25 h) 09:00 is 10 h after
        // midnight, so two days starting at 09:00 gave « vers 09:30 ».
        func testTypicalStartIsTheClockTimeAcrossTheClockChange() {
            let now = paris.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
            let days = [parisDay(25, hour: 9, minutes: 60), parisDay(26, hour: 9, minutes: 60)]
            let summary = GoalongActivitySummary(period: .init(days: days), previous: .init(days: []), calendar: paris, now: now)
            let text = summary.insights(topUsage: nil, biggestChange: nil).first { $0.id == "bounds" }?.text ?? ""
            XCTAssertTrue(text.contains("vers 09:00"), text)
        }

        // H1-05: one app change in 3 h gave « toutes les 180 min en moyenne (0 fois par heure active) ».
        func testRareSwitchesNeverSayZeroTimesPerHour() {
            let day = parisDay(20, hour: 9, minutes: 180, switchEvery: 90)
            let now = paris.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
            let summary = GoalongActivitySummary(period: .init(days: [day]), previous: .init(days: []), calendar: paris, now: now)
            let text = summary.insights(topUsage: nil, biggestChange: nil).first { $0.id == "switches" }?.text ?? ""
            XCTAssertFalse(text.isEmpty, "fixture must produce a switch insight")
            XCTAssertFalse(text.contains("(0 fois"), text)
        }

        // H1-06: a past commitment not yet settled (Goalong closed at midnight) still shows its stake.
        // Its day count is 0 or negative, so it named today's weekday (« mercredi ») or a past one (« mardi »).
        func testUnsettledPastCommitmentStakeRunsToday() {
            let now = paris.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9))!
            for offset in [-1, -2] {
                let day = paris.date(byAdding: .day, value: offset, to: now)!
                let period = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(day, calendar: paris))
                XCTAssertEqual(FocusCommitmentFormat.stakeDay(period, now: now, calendar: paris), "aujourd’hui", "offset \(offset)")
            }
            let today = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(now, calendar: paris))
            XCTAssertEqual(FocusCommitmentFormat.stakeDay(today, now: now, calendar: paris), "demain")
        }
    }
#endif
