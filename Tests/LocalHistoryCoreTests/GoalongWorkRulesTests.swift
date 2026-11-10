import Foundation
import XCTest
@testable import LocalHistoryCore

/// Lot B1 (T-049): user rules, groups, the three states, the background schedule and the
/// local token ledger. Fixtures only: no history base, no capture, no call.
final class GoalongWorkRulesTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))! }
    private func at(_ hour: Int, _ minute: Int) -> Date { day.addingTimeInterval(Double(hour * 3_600 + minute * 60)) }

    private func event(_ seconds: Double, app: String, host: String? = nil, title: String?) -> HistoryEvent {
        HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: day.addingTimeInterval(seconds), kind: .heartbeat,
            app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1),
            window: WindowSnapshot(title: title, role: nil, subrole: nil),
            url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
            classification: .init(category: "fixture", isWork: nil, confidence: 0.99, classifierVersion: "legacy"))
    }
    private func minutes(_ range: ClosedRange<Int>, from start: Double, app: String, host: String? = nil, title: String?) -> [HistoryEvent] {
        range.map { event(start + Double($0 * 60), app: app, host: host, title: title) }
    }
    private func label(_ app: String, _ host: String? = nil, _ title: String? = nil) -> GoalongWorkContext.Label {
        GoalongWorkContext.Label(application: app, bundleIdentifier: "fixture." + app, host: host, title: title)
    }
    private func observe(_ events: [HistoryEvent]) -> GoalongWorkClassification.Observation {
        GoalongWorkClassification.observation(events: events, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
    }

    // MARK: Rules (spec 2)

    func testRulesBeatTheAgentAndTheMorePreciseRuleWins() throws {
        let mail = label("Mail", nil, "Inbox"), doc = label("Browser", "docs.example.org", "Spec"), other = label("Browser", "news.example.org", "Une")
        let rules = GoalongWorkRules([
            try XCTUnwrap(GoalongWorkRule(scope: .application, target: "fixture.browser", label: "Browser", verdict: .other)),
            try XCTUnwrap(GoalongWorkRule(scope: .site, target: "www.Docs.example.org", label: "docs", verdict: .work, task: "Spec")),
        ])
        let verdicts = GoalongWorkVerdicts([
            doc.key: .init(verdict: .other), other.key: .init(verdict: .work),
            mail.key: .init(verdict: .work, task: "Courrier", byOwner: true),
        ], rules: rules)
        XCTAssertEqual(verdicts.resolution(key: doc.key, label: doc)?.source, .site, "A site rule beats the agent and the app rule")
        XCTAssertEqual(verdicts.resolution(key: doc.key, label: doc)?.assignment.verdict, .work)
        XCTAssertEqual(verdicts.resolution(key: other.key, label: other)?.source, .application, "The app rule beats the agent")
        XCTAssertEqual(verdicts.resolution(key: other.key, label: other)?.assignment.verdict, .other)
        let mailOnBrowserRules = GoalongWorkVerdicts([mail.key: .init(verdict: .work, byOwner: true)],
            rules: GoalongWorkRules([try XCTUnwrap(GoalongWorkRule(scope: .application, target: "fixture.mail", label: "Mail", verdict: .other))]))
        XCTAssertEqual(mailOnBrowserRules.resolution(key: mail.key, label: mail)?.source, .context, "An answer on a context beats its app rule")
        XCTAssertEqual(mailOnBrowserRules.resolution(key: mail.key, label: mail)?.assignment.verdict, .work)
    }

    func testARuleAlwaysDecidesAndNeverComesFromTheAgent() {
        XCTAssertNil(GoalongWorkRule(scope: .application, target: "fixture.x", label: "X", verdict: .unclear))
        XCTAssertNil(GoalongWorkRule(scope: .agent, target: "fixture.x", label: "X", verdict: .work))
        XCTAssertNil(GoalongWorkRule(scope: .site, target: "  ", label: "X", verdict: .work))
        XCTAssertEqual(GoalongWorkRule.siteTarget("WWW.Example.org"), "example.org")
    }

    func testRulesApplyToTheDayLocally() throws {
        let observation = observe(minutes(0...9, from: 36_000, app: "Pages", title: "Rapport"))
        let rules = GoalongWorkRules([try XCTUnwrap(GoalongWorkRule(scope: .application, target: "fixture.pages", label: "Pages", verdict: .work))])
        let applied = observation.day.applying(GoalongWorkVerdicts(rules: rules))
        XCTAssertEqual(applied.seconds(.unclassified), 0)
        XCTAssertGreaterThan(applied.seconds(.work), 0)
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels,
                                                        verdicts: GoalongWorkVerdicts(rules: rules), calendar: calendar)
        XCTAssertTrue(pending.keys.isEmpty, "A context a rule decides is never sent")
    }

    // MARK: Groups (spec 3)

    func testOneSendPerNormalisedTitleGroup() {
        let a = GoalongWorkContext.groupKey(label("Mail", nil, "Boîte de réception (12) — Mail"))
        let b = GoalongWorkContext.groupKey(label("Mail", nil, "Boîte de réception (3)"))
        XCTAssertEqual(a, b, "Counters and the app suffix do not split a group")
        XCTAssertNotEqual(a, GoalongWorkContext.groupKey(label("Mail", nil, "Brouillons")))
        let events = minutes(0...5, from: 36_000, app: "Mail", title: "Boîte de réception (12)")
            + minutes(6...10, from: 36_000, app: "Mail", title: "Boîte de réception (13)")
        let observation = observe(events)
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: .init(), calendar: calendar)
        XCTAssertEqual(pending.keys.count, 1)
        let request = GoalongWorkClassification.request(date: "2026-09-10", definition: .init(goals: "Courrier"), pending: pending,
            batch: pending.keys, day: observation.day, verdicts: .init(), knownTasks: [], examples: [], calendar: calendar)
        XCTAssertEqual(request.contexts.count, 1)
        let id = try! XCTUnwrap(request.contexts.first?.id)
        XCTAssertEqual(request.members[id]?.count, 2)
        let response = try! GoalongWorkClassification.parse(Data(#"{"r":"\#(request.request_id)","c":[{"i":"\#(id)","v":"w","k":"Courrier"}]}"#.utf8))
        let applied = try! GoalongWorkClassification.apply(response, to: request)
        XCTAssertEqual(applied.count, 2, "One answer classifies the whole group")
    }

    func testAKnownGroupAnswersItsNewMembersWithoutACall() {
        let old = label("Mail", nil, "Boîte de réception (4)"), new = label("Mail", nil, "Boîte de réception (9)")
        let inherited = GoalongWorkClassification.inherited(labels: [old.key: old, new.key: new],
            verdicts: GoalongWorkVerdicts([old.key: .init(verdict: .work, task: "Courrier")]),
            groups: [GoalongWorkContext.groupKey(old): .init(verdict: .work, task: "Courrier")])
        XCTAssertEqual(Array(inherited.keys), [new.key])
    }

    // MARK: States (spec 1, 4)

    func testEveryContextHasExactlyOneState() throws {
        let events = minutes(0...10, from: 36_000, app: "Pages", title: "Rapport")
            + minutes(11...20, from: 36_000, app: "Mail", title: "Inbox")
            + minutes(21...30, from: 36_000, app: "Secret", title: "Coffre")
            + minutes(31...40, from: 36_000, app: "Notes", title: "Idées")
            + [event(36_000 + 41 * 60, app: "Calc", title: "1+1"), event(36_000 + 41 * 60 + 5, app: "Pages", title: "Rapport")]
        let observation = observe(events)
        let pages = label("Pages", nil, "Rapport"), mail = label("Mail", nil, "Inbox"), notes = label("Notes", nil, "Idées")
        let calc = label("Calc", nil, "1+1")
        let verdicts = GoalongWorkVerdicts([pages.key: .init(verdict: .work, task: "Rapport"), mail.key: .init(verdict: .unclear)])
        let summary = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: verdicts,
                                                       permits: { $0.application != "Secret" })
        XCTAssertEqual(summary.states[pages.key], .classified(.work, .agent))
        XCTAssertEqual(summary.states[mail.key], .toClarify(.agentUnsure))
        XCTAssertEqual(summary.states[label("Secret", nil, "Coffre").key], .toClarify(.neverSent))
        XCTAssertEqual(summary.states[notes.key], .waiting(.notYetPassed))
        if let calcState = summary.states[calc.key] { XCTAssertEqual(calcState, .tooShort, "Under 15 s without a rule: shown apart") }
        XCTAssertEqual(summary.states.count, summary.counts.values.reduce(0, +))
        let blocked = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: verdicts, blocker: .paused)
        XCTAssertEqual(blocked.states[notes.key], .waiting(.paused), "A blocked agent says why the context waits")
        XCTAssertFalse(GoalongWorkState.Waiting.allCases.contains { $0.message.isEmpty })
    }

    func testAShortContextInheritsAnAppRule() throws {
        let observation = observe([event(36_000, app: "Calc", title: "1+1"), event(36_005, app: "Pages", title: "R")])
        let calc = label("Calc", nil, "1+1")
        let rules = GoalongWorkRules([try XCTUnwrap(GoalongWorkRule(scope: .application, target: "fixture.calc", label: "Calc", verdict: .other))])
        let summary = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(rules: rules))
        if let state = summary.states[calc.key] { XCTAssertEqual(state, .classified(.other, .application)) }
    }

    // MARK: Schedule (spec 7)

    func testBackgroundPassRhythmAndCap() {
        var usage = GoalongWorkUsage.Day()
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(9, 0), pendingGroups: 0, usage: usage, manual: true, calendar: calendar), .skip(nil))
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(9, 0), pendingGroups: 5, usage: usage, manual: false, calendar: calendar), .skip(nil),
                       "Before 12:30 with a small backlog: no call")
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(9, 0), pendingGroups: 40, usage: usage, manual: false, calendar: calendar), .call(.backlog))
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(12, 31), pendingGroups: 1, usage: usage, manual: false, calendar: calendar), .call(.slot))
        usage.backgroundCalls = 1; usage.lastCallAt = at(12, 31)
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(13, 0), pendingGroups: 3, usage: usage, manual: false, calendar: calendar), .skip(nil),
                       "The 12:30 slot is used once")
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(18, 45), pendingGroups: 3, usage: usage, manual: false, calendar: calendar), .call(.slot))
        usage.backgroundCalls = 2
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(20, 0), pendingGroups: 80, usage: usage, manual: false, calendar: calendar),
                       .skip(.dailyCapReached), "Two background calls a day at most")
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(20, 0), pendingGroups: 3, usage: usage, manual: true, calendar: calendar), .call(.manual))
        usage.tokens = GoalongWorkSchedule.dailyTokenCap - GoalongWorkSchedule.minimumCallTokens + 1
        XCTAssertEqual(GoalongWorkSchedule.decide(now: at(20, 0), pendingGroups: 3, usage: usage, manual: true, calendar: calendar),
                       .skip(.dailyCapReached), "The manual pass counts in the daily cap")
        XCTAssertEqual(GoalongWorkSchedule.dailyTokenCap, 24_000)
        XCTAssertEqual(GoalongWorkSchedule.backgroundCallsPerDay, 2)
    }

    func testAccountLimitNear() {
        XCTAssertFalse(GoalongAccountLimits(primaryPercent: 40, weeklyPercent: 60).isNear)
        XCTAssertTrue(GoalongAccountLimits(primaryPercent: 40, weeklyPercent: 91).isNear)
        XCTAssertTrue(GoalongAccountLimits(reached: true).isNear)
    }

    // MARK: Usage ledger (spec 9)

    func testUsageLedgerKeepsDayAndWeekTotalsAndMarksEstimates() throws {
        var usage = GoalongWorkUsage()
        usage.record(day: "2026-09-10", at: at(12, 31), tokens: 6_000, estimated: false, background: true, weeklyBefore: 10, weeklyAfter: 11)
        usage.record(day: "2026-09-10", at: at(18, 31), tokens: 5_000, estimated: true, background: false)
        usage.record(day: "2026-09-08", at: at(9, 0), tokens: 4_000, estimated: false, background: true)
        usage.record(day: "2026-09-01", at: at(9, 0), tokens: 9_999, estimated: false, background: true)
        let today = usage.day("2026-09-10")
        XCTAssertEqual(today.tokens, 11_000); XCTAssertEqual(today.calls, 2); XCTAssertEqual(today.backgroundCalls, 1)
        XCTAssertTrue(today.isEstimate)
        XCTAssertEqual(today.weeklyPercentBefore, 10); XCTAssertEqual(today.weeklyPercentAfter, 11)
        XCTAssertEqual(usage.week(endingOn: "2026-09-10", calendar: calendar).tokens, 15_000)
        for offset in 0..<20 { usage.record(day: String(format: "2026-10-%02d", offset + 1), at: day, tokens: 1, estimated: false, background: true) }
        XCTAssertEqual(usage.days.count, GoalongWorkUsage.keptDays)
        let decoded = try JSONDecoder().decode(GoalongWorkUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(decoded, usage)
    }

    // MARK: Prompt (spec 6)

    func testPromptStaysSmall() {
        var events: [HistoryEvent] = []
        for index in 0..<60 { events += minutes((index * 2)...(index * 2 + 1), from: 30_000, app: "App\(index)", title: "Document \(index) projet") }
        let observation = observe(events)
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: .init(), calendar: calendar)
        let examples = (0..<30).map { GoalongWorkClassification.Example(label: label("App\($0)", nil, "Ancien \($0)"),
                                                                       assignment: .init(verdict: .work, task: "Projet", byOwner: true)) }
        let request = GoalongWorkClassification.request(date: "2026-09-10", definition: .init(goals: "Projet client", notWork: "Vidéos"),
            pending: pending, batch: pending.keys, day: observation.day, verdicts: .init(), knownTasks: ["Projet"],
            examples: Array(examples.prefix(GoalongWorkClassification.maximumExamples)), calendar: calendar)
        let prompt = GoalongWorkClassification.prompt(request, definition: .init(goals: "Projet client", notWork: "Vidéos"))
        XCTAssertEqual(request.contexts.count, 60)
        XCTAssertTrue(request.contexts.allSatisfy { $0.neighbours.count == 2 })
        let estimate = GoalongWorkClassification.estimatedTokens(prompt: prompt, contexts: request.contexts.count)
        XCTAssertLessThan(estimate, GoalongWorkSchedule.dailyTokenCap / 2, "A full call fits twice in the daily cap")
        let candidates = (0..<30).map { (label: label($0 == 7 ? "App3" : "Autre\($0)", nil, "x"),
                                         assignment: GoalongWorkAssignment(verdict: $0 == 5 ? .unclear : .work, byOwner: true)) }
        let nearest = GoalongWorkClassification.nearestExamples(candidates, for: [label("App3", nil, "y")])
        XCTAssertEqual(nearest.count, GoalongWorkClassification.maximumExamples)
        XCTAssertEqual(nearest.first?.application, "App3", "The same app comes first")
    }
}
