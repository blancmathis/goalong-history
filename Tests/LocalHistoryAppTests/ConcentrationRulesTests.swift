#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

final class ConcentrationRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_180_000)
    private func session(_ mode: FocusMode) -> FocusSession {
        FocusSession(intent: "Écrire", mode: mode, startedAt: start, events: [.init(kind: .start, at: start)])
    }
    func testPomodoroLongBreakAndFiniteCycles() {
        var mode = FocusMode(); mode.kind = .pomodoro
        let s = session(mode)
        XCTAssertEqual(FocusPhases.phase(s, at: start.addingTimeInterval(1500)).kind, .shortBreak)
        XCTAssertEqual(FocusPhases.phase(s, at: start.addingTimeInterval(6900)).kind, .longBreak)
        mode.cycles = 4
        XCTAssertEqual(FocusPhases.plannedEnd(session(mode)), start.addingTimeInterval(6900))
        XCTAssertEqual(FocusPhases.phase(session(mode), at: start.addingTimeInterval(20000)).kind, .ended)
        XCTAssertEqual(FocusPhases.phase(session(mode), at: start.addingTimeInterval(20000)).startedAt, start.addingTimeInterval(6900))
    }
    func testSkipMovesImmediatelyAndShortensEnd() {
        var mode = FocusMode(); mode.kind = .pomodoro; mode.cycles = 1
        var s = session(mode); s.events.append(.init(kind: .skip, at: start.addingTimeInterval(300)))
        XCTAssertEqual(FocusPhases.phase(s, at: start.addingTimeInterval(300)).kind, .ended)
        XCTAssertEqual(FocusPhases.plannedEnd(s), start.addingTimeInterval(300))
        mode.cycles = 2; s = session(mode); s.events.append(.init(kind: .skip, at: start.addingTimeInterval(300)))
        XCTAssertEqual(FocusPhases.phase(s, at: start.addingTimeInterval(300)).kind, .shortBreak)
        XCTAssertEqual(FocusPhases.plannedEnd(s), start.addingTimeInterval(2100))
    }
    func testFreeOpenAndDSTElapsedDuration() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!
        let dst = c.date(from: .init(year: 2026, month: 10, day: 25, hour: 2))!
        var s = FocusSession(intent: "Lire", mode: FocusMode(minutes: 120), startedAt: dst, events: [.init(kind: .start, at: dst)])
        XCTAssertEqual(FocusPhases.phase(s, at: dst.addingTimeInterval(7199)).kind, .work)
        XCTAssertEqual(FocusPhases.phase(s, at: dst.addingTimeInterval(7200)).kind, .ended)
        s.mode.minutes = nil; XCTAssertNil(FocusPhases.plannedEnd(s)); s.lock = true; XCTAssertFalse(s.valid)
    }
    func testDetectionNeedsFullObservedWindowAndUnknownIsEligible() {
        var d = FocusDetection()
        for n in 0..<40 { XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: "a"))) }
        XCTAssertTrue(d.observe(.init(at: start.addingTimeInterval(1200), input: true, context: "a")))
        XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(1230), available: false)))
    }
    func testDetectionHysteresisOtherNoisyAndAway() {
        var d = FocusDetection()
        for n in 0...40 { _ = d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: "a")) }
        for n in 41..<50 { XCTAssertTrue(d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: "x", verdict: .other))) }
        XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(1500), input: true, context: "x", verdict: .other)))
        d.reset()
        for n in 0...50 { _ = d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: "a")) }
        for n in 1...18 { _ = d.observe(.init(at: start.addingTimeInterval(1500 + Double(n * 10)), input: true, context: "\(n)")) }
        XCTAssertNil(d.enteredAt)
        XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(1700), idleSeconds: 120)))
    }
    func testDetectionRejectsOtherSwitchesAndObservationGaps() {
        for noisy in [false, true] {
            var d = FocusDetection()
            for n in 0...40 { XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: noisy ? "\(n)" : "a", verdict: noisy ? nil : .other))) }
        }
        var d = FocusDetection()
        for n in 0...40 { _ = d.observe(.init(at: start.addingTimeInterval(Double(n * 30)), input: true, context: "a")) }
        XCTAssertFalse(d.observe(.init(at: start.addingTimeInterval(1300), input: true, context: "a")))
    }
    func testPlanMeasureUnionAndMedianLastTwenty() {
        let item = FocusPlanItem(title: "Écrire", project: "Livre", estimateMinutes: 5)
        var s = session(FocusMode(minutes: 5)); s.planItemId = item.id
        let seg = GoalongLocalAnalytics.Segment(start: start, end: start.addingTimeInterval(600), kind: .work, application: "Editor", bundleIdentifier: "editor", host: nil, task: "Livre")
        let day = GoalongLocalAnalytics.Day(date: start, end: start.addingTimeInterval(86400), state: .ready, segments: [seg], eventCount: 1, classifierVersions: [])
        let m = FocusMeasurement.item(item, sessions: [s], day: day, now: start.addingTimeInterval(600))
        XCTAssertEqual(m.sessionMinutes, 5); XCTAssertEqual(m.projectWorkMinutes, 10); XCTAssertEqual(m.measuredMinutes, 10)
        XCTAssertEqual(FocusMeasurement.estimateRatio([m]), 2)
        let values = (1...21).map { FocusItemMeasure(id: UUID(), sessionMinutes: 0, measuredMinutes: Double($0 * 5), estimateMinutes: 5) }
        XCTAssertEqual(FocusMeasurement.estimateRatio(values), 11.5)
        XCTAssertNil(FocusMeasurement.estimateRatio([]))
        XCTAssertNil(FocusMeasurement.item(item, sessions: [], day: nil, now: start).measuredMinutes)
    }
    func testLimitsOncePerDayWeekAndNoDefaults() {
        XCTAssertEqual(FocusLimits(), FocusLimits(weeklyHours: nil, dailyHours: nil, endMinute: nil, weekdays: []))
        let limits = FocusLimits(weeklyHours: 50, dailyHours: 8)
        let first = FocusLimitRules.crossings(limits: limits, dailySeconds: 28800, weeklySeconds: 180000, hasDefinition: false, at: start, marks: [])
        XCTAssertEqual(first.count, 2); XCTAssertTrue(first.allSatisfy(\.usesActiveTime))
        XCTAssertTrue(FocusLimitRules.crossings(limits: limits, dailySeconds: 30000, weeklySeconds: 181000, hasDefinition: false, at: start, marks: first).isEmpty)
    }
    func testStoreMissingBoundsAtomicAndModes() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-store-" + UUID().uuidString)
        let store = FocusStore(directory: root); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try store.sessions("2026-10-04").isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let plan = FocusPlan(day: "2026-10-04", items: [.init(title: "Écrire")])
        try store.savePlans([plan]); XCTAssertEqual(try store.plan(plan.day), plan)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let file = root.appendingPathComponent("plans/2026-10-04.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.json").path))
        XCTAssertThrowsError(try store.saveSessions(Array(repeating: session(FocusMode()), count: 201), day: plan.day))
        XCTAssertThrowsError(try store.savePlans([FocusPlan(day: plan.day, items: Array(repeating: .init(title: "a"), count: 11))]))
        XCTAssertThrowsError(try store.sessions("../secret"))
    }
    func testStoreRejectsSymlinksAndUnsafeInput() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try FocusStore(directory: root).settings())
        XCTAssertFalse(FocusValidation.text("a\nb", maximum: 140))
        XCTAssertFalse(FocusValidation.day("2026-02-30"))
    }
    func testBurstSamplesStayBoundedWithoutLosingSwitches() {
        var d = FocusDetection(); d.rule.windowSeconds = 120; d.rule.inputSeconds = 96
        for n in 0..<10000 {
            _ = d.observe(.init(at: start.addingTimeInterval(Double(n) * 0.05), input: true, context: "\(n)"))
        }
        XCTAssertLessThan(d.retainedSliceCount, 1602); XCTAssertNil(d.enteredAt)
    }
    func testStoreReplaysInterruptedMultiDayTransaction() throws {
        let root = URL(fileURLWithPath: "/private/tmp/focus-recover-" + UUID().uuidString), store = FocusStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveSettings(FocusSettings())
        let a = FocusPlan(day: "2026-10-04", items: [.init(title: "A")]), b = FocusPlan(day: "2026-10-05", items: [.init(title: "B")])
        let pending = root.appendingPathComponent("pending.json")
        try FocusJSON.encode(FocusStore.Transaction(plans: [a, b], review: FocusReview(day: a.day))).write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        try store.recover(); XCTAssertEqual(try store.plan(a.day), a); XCTAssertEqual(try store.plan(b.day), b)
        XCTAssertNotNil(try store.review(a.day)); XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

}
#endif
