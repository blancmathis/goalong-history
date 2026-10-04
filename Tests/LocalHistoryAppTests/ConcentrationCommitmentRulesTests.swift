#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

final class ConcentrationCommitmentRulesTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hours: Double = 0) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(hours * 3600) }
    private func value(_ key: String = "2026-10-04", kind: FocusCommitment.Kind = .work, target: Int = 30) -> FocusCommitment {
        FocusCommitment(period: .init(kind: .day, key: key), kind: kind, target: target, createdAt: date(key, 8))
    }
    func testISOWeekIgnoresSundayRegionAndUsesISOYearAndDST() {
        let sunday = date("2026-10-04")
        XCTAssertEqual(FocusCalendar.weekKey(sunday, calendar: calendar), "2026-W40")
        XCTAssertEqual(FocusCalendar.weekInterval(sunday, calendar: calendar).start, date("2026-09-28"))
        XCTAssertEqual(FocusCalendar.weekKey(date("2021-01-01"), calendar: calendar), "2020-W53")
        XCTAssertNotNil(FocusCalendar.weekInterval("2020-W53", calendar: calendar))
        for key in ["2021-W53", "2026-W00", "2026-W54", "2026-W4", "2026-W+4", "0000-W01"] { XCTAssertNil(FocusCalendar.weekInterval(key)) }
        XCTAssertEqual(FocusCalendar.weekInterval("2026-W13", calendar: calendar)?.duration, 167 * 3600)
        XCTAssertEqual(FocusCalendar.dayInterval("2026-10-25", calendar: calendar)?.duration, 25 * 3600)
    }
    func testWeeklyLimitUsesMondayAndOnlyOneMarkAcrossSunday() {
        let sunday = date("2026-10-04", 12), limits = FocusLimits(weeklyHours: 10)
        let mark = FocusLimitRules.crossings(limits: limits, dailySeconds: 0, weeklySeconds: 36000, hasDefinition: true, at: sunday, calendar: calendar, marks: [])
        XCTAssertEqual(mark.first?.period, "2026-W40")
        XCTAssertTrue(FocusLimitRules.crossings(limits: limits, dailySeconds: 0, weeklySeconds: 36000, hasDefinition: true, at: sunday.addingTimeInterval(3600), calendar: calendar, marks: mark).isEmpty)
        XCTAssertEqual(FocusLimitRules.crossings(limits: limits, dailySeconds: 0, weeklySeconds: 36000, hasDefinition: true, at: date("2026-10-05"), calendar: calendar, marks: mark).first?.period, "2026-W41")
    }
    func testTargetBoundsStepsStakeAndSettingsBackwardCompatibility() throws {
        for (kind, period, lower, upper) in [(FocusCommitment.Kind.work, FocusCommitmentPeriod.Kind.day, 30, 960), (.work, .week, 60, 4800), (.task, .day, 15, 960), (.task, .week, 30, 4800), (.sessions, .day, 1, 12), (.sessions, .week, 1, 60), (.plan, .day, 1, 10), (.plan, .week, 1, 70)] {
            XCTAssertTrue(FocusCommitment.validTarget(lower, kind: kind, period: period)); XCTAssertTrue(FocusCommitment.validTarget(upper, kind: kind, period: period))
            XCTAssertFalse(FocusCommitment.validTarget(lower - 1, kind: kind, period: period)); XCTAssertFalse(FocusCommitment.validTarget(upper + 1, kind: kind, period: period))
        }
        var task = value(kind: .task); XCTAssertFalse(task.valid); task.task = "Goalong"; XCTAssertTrue(task.valid)
        task.task = "a\nb"; XCTAssertFalse(task.valid)
        let id = UUID(); XCTAssertTrue(FocusStake(listIds: [id]).valid)
        for until in ["24:00", "12:60", "1:00", "12:00\n"] { XCTAssertFalse(FocusStake(listIds: [id], until: until).valid) }
        XCTAssertFalse(FocusStake(listIds: [id, id]).valid)
        XCTAssertFalse(FocusJokerSettings(day: 6).valid); XCTAssertFalse(FocusJokerSettings(week: 3).valid)
        let original = try FocusJSON.encode(FocusSettings())
        XCTAssertEqual(try FocusJSON.decode(FocusSettings.self, from: original).jokerSettings, .init())
    }
    func testCreationHorizonAndCommitBoundaryHarderOnlyAllReductions() {
        let now = date("2026-10-04", 8)
        XCTAssertTrue(FocusCommitmentRules.mayCreate(.init(kind: .day, key: "2026-10-11"), at: now, calendar: calendar))
        XCTAssertFalse(FocusCommitmentRules.mayCreate(.init(kind: .day, key: "2026-10-12"), at: now, calendar: calendar))
        XCTAssertFalse(FocusCommitmentRules.mayCreate(.init(kind: .day, key: "2026-10-03"), at: now, calendar: calendar))
        XCTAssertTrue(FocusCommitmentRules.mayCreate(.init(kind: .week, key: "2026-W41"), at: now, calendar: calendar))
        XCTAssertFalse(FocusCommitmentRules.mayCreate(.init(kind: .week, key: "2026-W42"), at: now, calendar: calendar))
        let old = value(); var next = old; next.target = 60
        XCTAssertEqual(FocusCommitRule.check(old: old, new: nil, now: now.addingTimeInterval(599), calendar: calendar), .free)
        XCTAssertEqual(FocusCommitRule.check(old: old, new: next, now: now.addingTimeInterval(600), calendar: calendar), .harderOnly)
        for change in [0, 1, 2, 3] {
            next = old
            if change == 0 { next.target = 15 }; if change == 1 { next.kind = .sessions }; if change == 2 { next.period.key = "2026-10-05" }; if change == 3 { next.task = "other" }
            guard case .locked = FocusCommitRule.check(old: old, new: next, now: now.addingTimeInterval(600), calendar: calendar) else { return XCTFail("easier change allowed") }
        }
        var future = value("2026-10-05"); future.createdAt = now
        XCTAssertEqual(FocusCommitRule.check(old: future, new: nil, now: date("2026-10-04", 23), calendar: calendar), .free)
        guard case .locked = FocusCommitRule.check(old: future, new: nil, now: date("2026-10-05"), calendar: calendar) else { return XCTFail() }
    }
    func testStakeCanOnlyGrowAfterCommitAndSettledCannotBeEdited() {
        var old = value(); let first = UUID(), second = UUID()
        old.stake = FocusStake(listIds: [first]); var next = old
        next.stake = FocusStake(listIds: [first, second], until: "23:59")
        XCTAssertEqual(FocusCommitRule.check(old: old, new: next, now: date("2026-10-04", 9), calendar: calendar), .harderOnly)
        for stake in [nil, FocusStake(listIds: [second]), FocusStake(listIds: [first], until: "11:59")] {
            next.stake = stake
            guard case .locked = FocusCommitRule.check(old: old, new: next, now: date("2026-10-04", 9), calendar: calendar) else { return XCTFail() }
        }
        old.result = .init(settledAt: date("2026-10-05"), measured: 30, unmeasuredMinutes: 0, outcome: .held)
        guard case .locked = FocusCommitRule.check(old: old, new: old, now: old.createdAt, calendar: calendar) else { return XCTFail() }
    }
    func testWorkTaskProgressClipsCoverageAndActiveFallback() {
        let start = date("2026-10-04"), end = date("2026-10-05")
        let segments = [(GoalongLocalAnalytics.Kind.work, "GOALONG" as String?), (.other, nil), (.unclassified, nil), (.idle, nil), (.concealed, nil), (.unobserved, nil)].enumerated().map { i, entry in
            GoalongLocalAnalytics.Segment(start: start.addingTimeInterval(Double(i * 3600)), end: start.addingTimeInterval(Double((i + 1) * 3600)), kind: entry.0, application: "Editor", bundleIdentifier: "editor", host: nil, task: entry.1)
        }
        let day = GoalongLocalAnalytics.Day(date: start, end: end, state: .ready, segments: segments, eventCount: 1, classifierVersions: [])
        var v = value()
        let work = FocusCommitmentRules.progress(v, days: [day], sessions: [], plans: [], at: end, hasDefinition: true, calendar: calendar)
        XCTAssertEqual(work.measured, 60); XCTAssertEqual(work.unmeasuredMinutes, 21 * 60); XCTAssertFalse(work.usesActiveTime)
        let active = FocusCommitmentRules.progress(v, days: [day], sessions: [], plans: [], at: end, hasDefinition: false, calendar: calendar)
        XCTAssertEqual(active.measured, 180); XCTAssertTrue(active.usesActiveTime)
        v.kind = .task; v.task = "Goalong"
        XCTAssertEqual(FocusCommitmentRules.progress(v, days: [day], sessions: [], plans: [], at: end, hasDefinition: true, calendar: calendar).measured, 60)
        XCTAssertEqual(FocusCommitmentRules.progress(v, days: [], sessions: [], plans: [], at: end, hasDefinition: true, calendar: calendar).unmeasuredMinutes, 1440)
        XCTAssertEqual(FocusCommitmentRules.progress(v, days: [day, day], sessions: [], plans: [], at: start.addingTimeInterval(1800), hasDefinition: true, calendar: calendar).measured, 30)
    }
    func testSleepLockAndDayEdgesAreKnownAndDeclarationNeedsTheShortfall() {
        let start = date("2026-10-04"), end = date("2026-10-05")
        let reasons: [GoalongCoverageReason] = [.beforeFirstObservation, .sleep, .locked, .recorderStopped, .afterLastObservation]
        let segments = reasons.enumerated().map { i, reason in
            GoalongLocalAnalytics.Segment(start: start.addingTimeInterval(Double(i * 3600)), end: start.addingTimeInterval(Double((i + 1) * 3600)),
                kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil, coverageReason: reason)
        } + [GoalongLocalAnalytics.Segment(start: start.addingTimeInterval(5 * 3600), end: end, kind: .idle, application: nil, bundleIdentifier: nil, host: nil)]
        let day = GoalongLocalAnalytics.Day(date: start, end: end, state: .ready, segments: segments, eventCount: 1, classifierVersions: [])
        var v = value(target: 120)
        // Only the hour after Goalong stopped is uncertain; sleep, lock and the day's edges are not.
        XCTAssertEqual(FocusCommitmentRules.progress(v, days: [day], sessions: [], plans: [], at: end, hasDefinition: true, calendar: calendar).unmeasuredMinutes, 60)
        v.result = .init(settledAt: end, measured: 30, unmeasuredMinutes: 60, outcome: .missed)
        XCTAssertFalse(FocusCommitmentRules.mayDeclare(v))
        v.result?.unmeasuredMinutes = 90; XCTAssertTrue(FocusCommitmentRules.mayDeclare(v))
        v.kind = .plan; v.target = 1; v.result?.unmeasuredMinutes = 0; XCTAssertTrue(FocusCommitmentRules.mayDeclare(v))
    }
    func testSessionsCountWorkPhasesInsidePeriodAndPlanCountsOnlyDone() {
        let start = date("2026-10-04"), end = date("2026-10-05")
        func session(_ at: Date, _ minutes: Int) -> FocusSession { FocusSession(intent: "Lire", mode: FocusMode(minutes: minutes), startedAt: at, events: [.init(kind: .start, at: at)]) }
        let before = session(start.addingTimeInterval(-600), 30), short = session(start.addingTimeInterval(3600), 10), after = session(end.addingTimeInterval(-600), 30)
        let v = value(kind: .sessions, target: 1)
        XCTAssertEqual(FocusCommitmentRules.progress(v, days: [], sessions: [before, before, short, after], plans: [], at: end, hasDefinition: true, calendar: calendar).measured, 1)
        var p = value(kind: .plan, target: 1); p.period = .init(kind: .week, key: "2026-W40")
        let plans = [FocusPlan(day: "2026-09-27", items: [.init(title: "Outside", status: .done)]), FocusPlan(day: "2026-09-28", items: [.init(title: "Yes", status: .done), .init(title: "Open"), .init(title: "No", status: .dropped)]), FocusPlan(day: "2026-10-04", items: [.init(title: "Yes", status: .done)]), FocusPlan(day: "2026-10-05", items: [.init(title: "Outside", status: .done)])]
        XCTAssertEqual(FocusCommitmentRules.progress(p, days: [], sessions: [], plans: plans, at: end, hasDefinition: true, calendar: calendar).measured, 2)
    }
    func testSettleHeldMissedAndEverySkipReason() {
        let id = UUID(); var v = value(); v.stake = .init(listIds: [id])
        let end = date("2026-10-05", 8)
        XCTAssertNil(FocusCommitmentRules.settle(v, progress: .init(), at: date("2026-10-04", 23), blockingOn: true, listIDs: [id], calendar: calendar))
        let held = FocusCommitmentRules.settle(v, progress: .init(measured: 30), at: end, blockingOn: true, listIDs: [id], calendar: calendar)
        XCTAssertEqual(held?.outcome, .held); XCTAssertEqual(held?.stake.state, FocusCommitmentResult.Stake.State.none)
        let missed = FocusCommitmentRules.settle(v, progress: .init(measured: 29, unmeasuredMinutes: 42), at: end, blockingOn: true, listIDs: [id], calendar: calendar)
        XCTAssertEqual(missed?.outcome, .missed); XCTAssertEqual(missed?.stake.blockId, v.id); XCTAssertEqual(missed?.unmeasuredMinutes, 42)
        XCTAssertEqual(FocusCommitmentRules.settle(v, progress: .init(), at: date("2026-10-05", 12), blockingOn: true, listIDs: [id], calendar: calendar)?.stake.reason, .late)
        XCTAssertEqual(FocusCommitmentRules.settle(v, progress: .init(), at: end, blockingOn: false, listIDs: [], calendar: calendar)?.stake.reason, .blockingOff)
        XCTAssertEqual(FocusCommitmentRules.settle(v, progress: .init(), at: end, blockingOn: true, listIDs: [], calendar: calendar)?.stake.reason, .noList)
        v.result = missed; XCTAssertNil(FocusCommitmentRules.settle(v, progress: .init(measured: 100), at: end, blockingOn: true, listIDs: [id], calendar: calendar))
    }
    func testSeriesAndMonthlyJokersUsePeriodMonthSeparateKindsAndIgnoreAbsentPeriods() {
        var values = [value("2026-09-30"), value("2026-10-02"), value("2026-10-04")]
        for i in values.indices { values[i].result = .init(settledAt: date("2026-10-05", 8), measured: 30, unmeasuredMinutes: 0, outcome: .held) }
        values[0].result?.outcome = .missed; values[0].result?.jokerAt = date("2026-10-05", 9)
        values[1].result?.outcome = .missed; values[1].result?.jokerAt = date("2026-10-05", 9)
        var week = value(); week.period = .init(kind: .week, key: "2026-W40"); week.target = 60
        week.result = .init(settledAt: date("2026-10-05", 8), measured: 0, unmeasuredMinutes: 1, outcome: .missed, jokerAt: date("2026-10-05", 9))
        values.append(week)
        XCTAssertEqual(FocusCommitmentRules.series(values, kind: .day, calendar: calendar), 3)
        XCTAssertEqual(FocusCommitmentRules.series(values, kind: .week, calendar: calendar), 1)
        XCTAssertEqual(FocusCommitmentRules.jokersLeft(period: values[0].period, commitments: values, settings: .init(), calendar: calendar), 1)
        XCTAssertEqual(FocusCommitmentRules.jokersLeft(period: values[2].period, commitments: values, settings: .init(), calendar: calendar), 1)
        XCTAssertEqual(FocusCommitmentRules.jokersLeft(period: week.period, commitments: values, settings: .init(), calendar: calendar), 0)
        XCTAssertEqual(FocusCommitmentRules.jokerMonth(.init(kind: .week, key: "2026-W14"), calendar: calendar), "2026-04")
        values[2].result?.outcome = .missed; XCTAssertEqual(FocusCommitmentRules.series(values, kind: .day, calendar: calendar), 0)
    }
    func testStakeWindowSkipsUseSettleDayAndClockProtectedEndWins() {
        var v = value(); v.stake = FocusStake(listIds: [UUID()]); v.result = .init(settledAt: date("2026-10-05", 8), measured: 0, unmeasuredMinutes: 1, outcome: .missed, stake: .init(state: .applied, blockId: v.id))
        XCTAssertEqual(FocusCommitmentRules.stakeWindow(v, calendar: calendar), date("2026-10-05", 12))
        XCTAssertEqual(FocusCommitmentRules.stakeWindow(v, blockEnd: date("2026-10-05", 13), calendar: calendar), date("2026-10-05", 13))
        v.result?.stake = .init(state: .skipped, reason: .late)
        XCTAssertEqual(FocusCommitmentRules.stakeWindow(v, calendar: calendar), date("2026-10-06"))
        v.result?.jokerAt = date("2026-10-05", 9); XCTAssertNil(FocusCommitmentRules.stakeWindow(v, calendar: calendar))
    }
    func testStoreModesRelaunchRetentionBoundsAndNoFollow() throws {
        let root = URL(fileURLWithPath: "/private/tmp/commitment-store-" + UUID().uuidString), store = FocusStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try store.commitments().isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let first = value(); try store.saveCommitments([first]); XCTAssertEqual(try FocusStore(directory: root).commitments(), [first])
        let file = root.appendingPathComponent("commitments.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var values = (0...800).map { i -> FocusCommitment in
            let key = FocusCalendar.dayKey(FocusCalendar.civil(calendar).date(byAdding: .day, value: i, to: date("2024-01-01"))!, calendar: calendar)
            return value(key)
        }
        XCTAssertThrowsError(try store.saveCommitments(values)); XCTAssertEqual(try store.commitments(), [first])
        values[0].result = .init(settledAt: date("2024-01-02"), measured: 30, unmeasuredMinutes: 0, outcome: .held)
        let retained = try store.saveCommitments(values); XCTAssertEqual(retained.count, 800); XCTAssertFalse(retained.contains { $0.id == values[0].id })
        XCTAssertThrowsError(try store.saveCommitments([first, first]))
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("outside.json"))
        XCTAssertThrowsError(try store.commitments()); XCTAssertThrowsError(try store.saveCommitments([first]))
    }
}
#endif
