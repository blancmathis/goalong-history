#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

final class C044R10C2EdgeTests: XCTestCase {
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func commitment(_ key: String, created: Date, stakeUntil: String? = nil, target: Int = 60) -> FocusCommitment {
        var c = FocusCommitment(period: .init(kind: .day, key: key), kind: .work, target: target, createdAt: created)
        if let stakeUntil { c.stake = FocusStake(listIds: [UUID()], until: stakeUntil) }
        return c
    }

    // MARK: stake day bounds
    func testStakeEndOnFallBackDayUsesFirstOccurrence() {
        let stake = FocusStake(listIds: [UUID()], until: "02:30")
        let end = FocusCommitmentRules.stakeEnd(stake, settledAt: utc("2026-10-24T22:10:00Z"), calendar: paris)
        XCTAssertEqual(end, utc("2026-10-25T00:30:00Z"), "02:30 on 2026-10-25 is ambiguous; first = CEST")
    }
    func testStakeEndInSpringGapIsNextValidTime() {
        let stake = FocusCommitmentRules.stakeEnd(FocusStake(listIds: [UUID()], until: "02:30"), settledAt: utc("2026-03-28T23:10:00Z"), calendar: paris)
        let d = stake.map { paris.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        XCTAssertEqual(d?.day, 29); XCTAssertEqual(d?.hour, 3, "gap 02:30 must land at 03:xx the same day, got \(String(describing: d))")
    }
    func testStakeEndSameDayAfterNoonSettle() {
        // settled 13:00 with a 12:00 stake: end must be 12:00 the same day (so it is already late), never tomorrow 12:00.
        let end = FocusCommitmentRules.stakeEnd(FocusStake(listIds: [UUID()], until: "12:00"), settledAt: utc("2026-10-20T11:00:00Z"), calendar: paris)
        XCTAssertEqual(end, utc("2026-10-20T10:00:00Z"))
    }
    func testStakeAtMidnightBoundaryIsAlwaysLate() {
        let s = FocusStake(listIds: [UUID()], until: "00:00")
        XCTAssertEqual(s.minute, 0)
        // A stake ending at 00:00 can never apply: settle (>= period end = midnight) is always late. The CLI and the
        // JSON body refuse it (testCLIStakeRefusesMalformedIDsAndMidnightAndBlockListsReportsFrozenLists); stored ones stay readable.
        let c = commitment("2026-10-20", created: utc("2026-10-20T06:00:00Z"), stakeUntil: "00:00")
        let r = FocusCommitmentRules.settle(c, progress: .init(measured: 0, unmeasuredMinutes: 0), at: utc("2026-10-20T22:00:00Z"),
                                            blockingOn: true, listIDs: Set(c.stake!.listIds), calendar: paris)
        XCTAssertEqual(r?.stake.reason, .late)
    }
    func testSettleStakeOnFallBackDay() {
        var c = commitment("2026-10-24", created: utc("2026-10-24T06:00:00Z"), stakeUntil: "02:30"); c.target = 60
        let list = c.stake!.listIds[0]
        let at1 = utc("2026-10-24T22:30:00Z") // 00:30 CEST on the 25th, before the first 02:30
        let r = FocusCommitmentRules.settle(c, progress: .init(measured: 0, unmeasuredMinutes: 0), at: at1, blockingOn: true, listIDs: [list], calendar: paris)
        XCTAssertEqual(r?.stake.state, .applied)
        let at2 = utc("2026-10-25T01:15:00Z") // 02:15 CET (second pass), after first 02:30 CEST
        let r2 = FocusCommitmentRules.settle(c, progress: .init(measured: 0, unmeasuredMinutes: 0), at: at2, blockingOn: true, listIDs: [list], calendar: paris)
        XCTAssertEqual(r2?.stake.reason, .late)
    }
    func testStakeWindowFallbackIsNextCivilMidnightAcross25hDay() {
        var c = commitment("2026-10-24", created: utc("2026-10-24T06:00:00Z"))
        var res = FocusCommitmentResult(settledAt: utc("2026-10-25T10:00:00Z"), measured: 0, unmeasuredMinutes: 0, outcome: .missed)
        res.stake = .init(state: .skipped, reason: .late); c.result = res
        XCTAssertEqual(FocusCommitmentRules.stakeWindow(c, calendar: paris), utc("2026-10-25T23:00:00Z"))
    }
    func testEditWindowNeverOutlivesThePeriod() {
        // Created at 23:55: createdAt + 10 min lands after midnight, inside the NEXT day.
        let created = utc("2026-10-20T21:55:00Z") // 23:55 Paris
        let c = commitment("2026-10-20", created: created)
        var lower = c; lower.target = 30
        let after = utc("2026-10-20T22:02:00Z") // 00:02 next day: the period is over
        XCTAssertNotEqual(FocusCommitRule.check(old: c, new: lower, now: after, calendar: paris), .free,
                          "a target of an ended day can still be lowered freely after midnight")
    }
    func testEditUntilNotAfterPeriodEnd() {
        let c = commitment("2026-10-20", created: utc("2026-10-20T21:59:59Z"))
        let end = c.period.interval(calendar: paris)!.end
        XCTAssertLessThanOrEqual(FocusCommitRule.editUntil(c, calendar: paris)!, end)
    }
    func testMayCreateDayOnDSTDays() {
        for (now, key) in [("2026-10-24T22:30:00Z", "2026-10-25"), ("2026-10-25T01:30:00Z", "2026-10-25"), ("2026-10-25T10:00:00Z", "2026-10-26"), ("2026-03-29T00:30:00Z", "2026-03-29")] {
            XCTAssertTrue(FocusCommitmentRules.mayCreate(.init(kind: .day, key: key), at: utc(now), calendar: paris), "\(key) at \(now)")
        }
        XCTAssertFalse(FocusCommitmentRules.mayCreate(.init(kind: .day, key: "2026-10-24"), at: utc("2026-10-25T10:00:00Z"), calendar: paris))
    }
    func testProgressOnFallBackDayUsesTwentyFiveHours() {
        let c = commitment("2026-10-25", created: utc("2026-10-24T06:00:00Z"))
        let p = FocusCommitmentRules.progress(c, days: [], sessions: [], plans: [], at: utc("2026-10-25T23:00:00Z"), hasDefinition: true, calendar: paris)
        XCTAssertEqual(p.unmeasuredMinutes, 1500)
        XCTAssertEqual(p.measured, 0)
    }
    func testProgressBeforePeriodStartAndEmptyDays() {
        let c = commitment("2026-10-25", created: utc("2026-10-24T06:00:00Z"))
        let p = FocusCommitmentRules.progress(c, days: [], sessions: [], plans: [], at: utc("2026-10-24T22:00:00Z"), hasDefinition: true, calendar: paris)
        XCTAssertEqual(p.measured, 0); XCTAssertEqual(p.unmeasuredMinutes, 0)
    }
    func testExitOpenAtExactEndIsClosed() {
        var c = commitment("2026-10-20", created: utc("2026-10-20T06:00:00Z"))
        var res = FocusCommitmentResult(settledAt: utc("2026-10-20T22:30:00Z"), measured: 0, unmeasuredMinutes: 0, outcome: .missed)
        res.stake = .init(state: .skipped, reason: .late); c.result = res
        let end = FocusCommitmentRules.stakeWindow(c, calendar: paris)!
        XCTAssertTrue(FocusCommitmentRules.exitOpen(c, now: end.addingTimeInterval(-1), clock: nil, calendar: paris))
        XCTAssertFalse(FocusCommitmentRules.exitOpen(c, now: end, clock: nil, calendar: paris))
    }

    // MARK: dashboard numbers
    func testPercentageEdges() {
        XCTAssertEqual(DashboardFormatters.percentage(0, 0), "0\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(1, 3), "33\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(2, 3), "67\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(1, 200), "1\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(1, 1000), "0\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(Int.max, Int.max), "100\u{00A0}%")
    }
    func testDurationRoundingBoundaries() {
        let nb = "\u{00A0}"
        XCTAssertEqual(DashboardFormatters.duration(seconds: 59.9), "<\(nb)1\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 60), "1\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 89.9), "1\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 90), "2\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 3569.9), "59\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: 3570), "1\(nb)h")
        XCTAssertEqual(DashboardFormatters.duration(seconds: -5), "0\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: .nan), "0\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(seconds: .infinity), "0\(nb)min")
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(-1), "—")
        XCTAssertEqual(GoalongAnalyticsFormatting.duration(0), "0\(nb)min")
        XCTAssertEqual(DashboardFormatters.duration(minutes: Int.max / 60), DashboardFormatters.duration(minutes: Int.max / 60))
    }
    func testRemainingEdges() {
        XCTAssertEqual(BlockingFormat.remaining(-100), "moins d’une minute")
        XCTAssertEqual(BlockingFormat.remaining(0), "moins d’une minute")
        XCTAssertEqual(BlockingFormat.remaining(60), "1 min")
        XCTAssertEqual(BlockingFormat.remaining(3600), "1\u{00A0}h")
        XCTAssertEqual(BlockingFormat.remaining(3600.5), "1\u{00A0}h\u{00A0}01")
        XCTAssertEqual(BlockingFormat.remaining(86_400), "1 jour")
        XCTAssertEqual(BlockingFormat.remaining(86_460), "1 jour 1\u{00A0}min")
    }
    func testCommitmentAmountEdges() {
        XCTAssertEqual(FocusCommitmentFormat.amount(29.999, kind: .work), "29\u{00A0}min")
        XCTAssertEqual(FocusCommitmentFormat.amount(-3, kind: .work), "0\u{00A0}min")
        XCTAssertEqual(FocusCommitmentFormat.amount(2.9, kind: .sessions), "2")
    }
    func testChartScaleEdges() {
        for v in [0.0, 0.5, 59.99, 60, 3599.99, 3600, -5, .nan, .infinity] {
            let s = GoalongAnalyticsChartScale(maximumSeconds: v)
            XCTAssertTrue(s.upperBound.isFinite && s.upperBound > 0, "\(v)")
            XCTAssertGreaterThanOrEqual(s.upperBound * s.unitSeconds, v.isFinite ? max(0, v) : 0, "bound below value for \(v)")
        }
    }
    func testEstimateRatioEdges() {
        func m(_ meas: Double?, _ est: Int?) -> FocusItemMeasure { .init(id: UUID(), sessionMinutes: 0, projectWorkMinutes: nil, measuredMinutes: meas, estimateMinutes: est) }
        XCTAssertNil(FocusMeasurement.estimateRatio([m(10, 0), m(nil, 30), m(-1, 30), m(.nan, 30)]))
        XCTAssertEqual(FocusMeasurement.estimateRatio([m(0, 30)]), 0)
        XCTAssertEqual(FocusMeasurement.estimateRatio([m(60, 30), m(30, 30)])!, 1.5, accuracy: 1e-9)
    }
    func testUnionSecondsNegativeAndEmpty() {
        XCTAssertEqual(FocusMeasurement.unionSeconds([]), 0)
        let d = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(FocusMeasurement.unionSeconds([DateInterval(start: d, duration: 0), DateInterval(start: d, duration: 10), DateInterval(start: d.addingTimeInterval(5), duration: 10)]), 15)
    }
}
#endif
