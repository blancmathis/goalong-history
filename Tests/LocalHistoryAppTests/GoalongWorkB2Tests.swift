#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// Lot B2 (T-049): the status line, the answers of « À préciser », « Vos réponses » and the usage texts.
    final class GoalongWorkB2Tests: XCTestCase {
        private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
        private func date(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        private let none = GoalongWorkUsage.Day()

        func testStatusLineNamesLastAndNextPass() {
            var usage = GoalongWorkUsage.Day(); usage.backgroundCalls = 1; usage.calls = 1; usage.tokens = 7_000; usage.lastCallAt = date(12, 31)
            let line = GoalongWorkPassLine.line(isRunning: false, waiting: nil, lastPass: date(12, 31), usageToday: usage,
                                                pendingGroups: 3, now: date(15), calendar: calendar)
            XCTAssertEqual(line.text, "Dernier passage : aujourd’hui à 12 h 31 · Prochain passage : vers 18 h 30")
            XCTAssertNil(line.linkTitle)
        }

        func testNextPassIsTomorrowWhenTheDayIsDoneOrCapped() {
            XCTAssertEqual(GoalongWorkPassLine.next(now: date(20), usageToday: none, pendingGroups: 2, calendar: calendar),
                           "au prochain contrôle (quelques minutes)", "A slot that passed without a call is caught up")
            var done = GoalongWorkUsage.Day(); done.backgroundCalls = 1; done.lastCallAt = date(19)
            XCTAssertEqual(GoalongWorkPassLine.next(now: date(20), usageToday: done, pendingGroups: 2, calendar: calendar), "demain vers 12 h 30")
            var capped = GoalongWorkUsage.Day(); capped.backgroundCalls = 2
            XCTAssertEqual(GoalongWorkPassLine.next(now: date(9), usageToday: capped, pendingGroups: 2, calendar: calendar), "demain vers 12 h 30")
            XCTAssertEqual(GoalongWorkPassLine.next(now: date(9), usageToday: none, pendingGroups: 0, calendar: calendar), "rien à classer pour l’instant")
        }

        func testWaitingReasonComesWithTheLinkThatLiftsIt() {
            let cases: [(GoalongWorkState.Waiting, String?)] = [
                (.noDefinition, "Écrire ma définition"), (.noConsent, "Autoriser l’envoi"), (.notConnected, "Connecter ChatGPT"),
                (.historyOff, "Voir les réglages"), (.backgroundConsentMissing, "Autoriser le classement automatique"),
                (.dailyCapReached, nil), (.paused, nil), (.accountLimitNear, nil), (.codexBusy, nil), (.sharingBlocked, nil)]
            for (waiting, link) in cases {
                let line = GoalongWorkPassLine.line(isRunning: false, waiting: waiting, lastPass: nil, usageToday: none,
                                                    pendingGroups: 1, now: date(10), calendar: calendar)
                XCTAssertEqual(line.text, waiting.message); XCTAssertEqual(line.linkTitle, link, "\(waiting)")
            }
            XCTAssertEqual(GoalongWorkPassLine.line(isRunning: true, progress: "2 sur 5", waiting: .paused, lastPass: nil,
                                                    usageToday: none, pendingGroups: 1, now: date(10)).text, "2 sur 5")
        }

        func testNoWordOfTheEngineStaysUnexplained() {
            for waiting in GoalongWorkState.Waiting.allCases {
                for text in [waiting.message, GoalongWorkPassLine.link(for: waiting) ?? ""] {
                    XCTAssertFalse(text.contains("LLM")); XCTAssertFalse(text.lowercased().contains("agent"), text)
                }
            }
        }

        @MainActor private func store() throws -> (GoalongWorkStore, URL) {
            let root = URL(fileURLWithPath: "/private/tmp/t049b2-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (GoalongWorkStore(fileURL: root.appendingPathComponent("work.json"), definition: { GoalongWorkDefinition(goals: "Goalong") },
                                     committedTasks: { [] }, renamedTask: { _, _ in [] }), root)
        }
        private func question(_ title: String = "Notes de réunion", host: String? = "notion.so") -> GoalongWorkStateModel.Question {
            let label = GoalongWorkContext.Label(application: "Safari", bundleIdentifier: "com.apple.Safari", host: host, title: title)
            return .init(id: GoalongWorkContext.key(label), label: label, seconds: 2_280, reason: .agentUnsure)
        }

        @MainActor func testAnswerByScopeAndUndo() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            let q = question()
            let undoContext = GoalongWorkAnswering.answer(q, verdict: .work, scope: .context, store: work, day: "2026-11-10")
            XCTAssertEqual(work.verdicts.contexts[q.id]?.verdict, .work); XCTAssertEqual(work.verdicts.contexts[q.id]?.byOwner, true)
            undoContext?.run()
            XCTAssertNil(work.verdicts.contexts[q.id], "Undo removes the answer")

            let undoSite = GoalongWorkAnswering.answer(q, verdict: .other, scope: .site, store: work, day: "2026-11-10")
            XCTAssertEqual(work.rules.map(\.target), ["notion.so"]); XCTAssertEqual(work.rules.first?.assignment.verdict, .other)
            undoSite?.run(); XCTAssertTrue(work.rules.isEmpty)

            let undoApp = GoalongWorkAnswering.answer(q, verdict: .work, scope: .application, store: work, day: "2026-11-10")
            XCTAssertEqual(work.rules.first?.scope, .application); undoApp?.run(); XCTAssertTrue(work.rules.isEmpty)
        }

        @MainActor func testUndoRestoresThePreviousRule() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            let q = question()
            work.setRule(scope: .site, target: "notion.so", label: "notion.so", verdict: .other, day: "2026-11-01")
            let undo = GoalongWorkAnswering.answer(q, verdict: .work, scope: .site, store: work, day: "2026-11-10")
            XCTAssertEqual(work.rules.first?.assignment.verdict, .work)
            undo?.run()
            XCTAssertEqual(work.rules.first?.assignment.verdict, .other); XCTAssertEqual(work.rules.first?.day, "2026-11-01")
        }

        @MainActor func testSiteScopeOnlyWhereThereIsASiteAndUnclearIsNeverSaved() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(GoalongWorkAnswering.scopes(for: question().label), [.context, .application, .site])
            let local = question("Document", host: nil)
            XCTAssertEqual(GoalongWorkAnswering.scopes(for: local.label), [.context, .application])
            XCTAssertNil(GoalongWorkAnswering.answer(local, verdict: .work, scope: .site, store: work, day: "2026-11-10"))
            XCTAssertNil(GoalongWorkAnswering.answer(local, verdict: .unclear, scope: .context, store: work, day: "2026-11-10"))
            XCTAssertTrue(work.answers.isEmpty)
        }

        @MainActor func testYourAnswersCanBeChangedAndRemoved() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            let q = question()
            GoalongWorkAnswering.answer(q, verdict: .work, scope: .application, store: work, day: "2026-11-09")
            GoalongWorkAnswering.answer(q, verdict: .work, scope: .context, store: work, day: "2026-11-10")
            XCTAssertEqual(work.answers.count, 2)
            let rule = try XCTUnwrap(work.answers.first { $0.scope == .application })
            GoalongWorkAnswering.change(rule, to: .other, store: work, day: "2026-11-10")
            XCTAssertEqual(work.rules.first?.assignment.verdict, .other)
            let context = try XCTUnwrap(work.answers.first { $0.scope == .context })
            GoalongWorkAnswering.change(context, to: .other, store: work, day: "2026-11-10")
            XCTAssertEqual(work.verdicts.contexts[q.id]?.verdict, .other)
            for answer in work.answers { GoalongWorkAnswering.change(answer, to: nil, store: work, day: "2026-11-10") }
            XCTAssertTrue(work.answers.isEmpty)
        }

        @MainActor func testScopeTitlesAreInPlainFrench() {
            let label = question().label
            XCTAssertEqual(GoalongWorkAnswering.scopeTitle(.context, label: label), "Ce contexte seul")
            XCTAssertEqual(GoalongWorkAnswering.scopeTitle(.application, label: label), "Toute l’app")
            XCTAssertEqual(GoalongWorkAnswering.scopeTitle(.site, label: label), "Tout le site")
        }

        func testDefinitionSentenceAndEmptyInvite() throws {
            XCTAssertNil(GoalongWorkDefinitionText.sentence(.empty))
            let context = try JevWorkContext(summary: "  Développer Goalong  ")
            XCTAssertEqual(GoalongWorkDefinitionText.sentence(context), "Développer Goalong")
            XCTAssertEqual(GoalongWorkDefinitionText.emptyHint, "Le classement automatique attend cette phrase.")
        }

        func testUsageTexts() {
            var day = GoalongWorkUsage.Day(); day.calls = 2; day.tokens = 12_345; day.estimatedCalls = 2
            XCTAssertTrue(GoalongWorkUsageText.total(day).contains("(estimation)"))
            XCTAssertTrue(GoalongWorkUsageText.total(day).hasSuffix("2 passages"))
            XCTAssertEqual(GoalongWorkUsageText.total(none), "Aucun passage")
            day.weeklyPercentBefore = 10; day.weeklyPercentAfter = 12
            XCTAssertEqual(GoalongWorkUsageText.quota(day: day, limits: nil), "Dernier passage : 10 % puis 12 % du quota de la semaine")
            XCTAssertEqual(GoalongWorkUsageText.quota(day: none, limits: nil), "Part du quota de la semaine : pas encore connue")
            XCTAssertTrue(GoalongWorkUsageText.cap.contains("24"))
        }

        @MainActor func testDaysOfAPeriodAreCapped() {
            let days = GoalongWorkStateModel.days(ending: date(10), period: 28, calendar: calendar)
            XCTAssertEqual(days.count, GoalongWorkStateModel.maximumDays)
            XCTAssertEqual(GoalongWorkStateModel.days(ending: date(10), period: 1, calendar: calendar).count, 1)
        }
    }
#endif
