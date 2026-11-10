#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// Lot B3 (T-049): the fixes of the review of PR #320, one test per finding. Fixtures only, no call.
    final class GoalongWorkB3Tests: XCTestCase {
        private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
        private func date(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        private func source(_ name: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/\(name)"), encoding: .utf8)
        }
        @MainActor private func store(in root: URL) -> GoalongWorkStore {
            GoalongWorkStore(fileURL: root.appendingPathComponent("work-classification.json"),
                             definition: { GoalongWorkDefinition(goals: "Goalong") }, committedTasks: { [] }, renamedTask: { _, _ in [] })
        }
        private func temporaryRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/private/tmp/t049b3-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        // 1. A call counts when sent: one that fails still counts in the cap and in the 2 a day.
        func testCallCountsWhenSentAndAFailureStillCounts() throws {
            var usage = GoalongWorkUsage()
            usage.record(day: "2026-11-10", at: date(12, 31), tokens: 6_000, estimated: true, background: true, weeklyBefore: 10)
            // The first call failed: no settle. The second answered with its real tokens.
            usage.record(day: "2026-11-10", at: date(18, 31), tokens: 6_000, estimated: true, background: true, weeklyBefore: 11)
            usage.settle(day: "2026-11-10", estimate: 6_000, tokens: 4_000, weeklyAfter: 12)
            let today = usage.day("2026-11-10")
            XCTAssertEqual(today.backgroundCalls, 2); XCTAssertEqual(today.tokens, 10_000)
            XCTAssertEqual(today.estimatedCalls, 1); XCTAssertEqual(today.measuredCalls, 1); XCTAssertEqual(today.measuredTokens, 4_000)
            XCTAssertEqual(today.weeklyPercentBefore, 11); XCTAssertEqual(today.weeklyPercentAfter, 12)
            XCTAssertEqual(GoalongWorkSchedule.decide(now: date(19), pendingGroups: 50, usage: today, manual: false, calendar: calendar),
                           .skip(.dailyCapReached), "Two calls sent, one failed: no third background call")
            let agent = try source("GoalongWorkAgent.swift")
            let recorded = try XCTUnwrap(agent.range(of: "store.recordUsage(")), sent = try XCTUnwrap(agent.range(of: "session.generateWorkClassification("))
            XCTAssertLessThan(recorded.lowerBound, sent.lowerBound, "Counted before the call is sent")
        }

        func testANewCallDropsTheStaleAfterShare() {
            var usage = GoalongWorkUsage()
            usage.record(day: "d", at: date(12), tokens: 5_000, estimated: false, background: true, weeklyBefore: 10, weeklyAfter: 11)
            usage.record(day: "d", at: date(18), tokens: 5_000, estimated: true, background: true, weeklyBefore: 11)
            XCTAssertNil(usage.day("d").weeklyPercentAfter)
            XCTAssertEqual(GoalongWorkUsageText.quota(day: usage.day("d"), limits: nil), "Part du quota de la semaine : pas encore connue",
                           "The 11 % after the first call is not shown as the after of the second")
        }

        func testAnOldUsageFileWithoutMeasuredFieldsStillLoads() throws {
            let json = #"{"days":{"2026-11-09":{"calls":1,"backgroundCalls":1,"tokens":6000,"estimatedCalls":0}}}"#
            let usage = try JSONDecoder().decode(GoalongWorkUsage.self, from: Data(json.utf8))
            XCTAssertEqual(usage.day("2026-11-09").tokens, 6_000); XCTAssertEqual(usage.day("2026-11-09").measuredCalls, 0)
        }

        // 2. Past days: the last 7, oldest first; the call goes to the oldest day with groups waiting.
        func testPassCoversSevenDaysOldestFirst() throws {
            let days = GoalongWorkSchedule.days(endingOn: date(15), calendar: calendar)
            XCTAssertEqual(days.count, 7)
            XCTAssertEqual(days.first, calendar.startOfDay(for: date(0, day: 4))); XCTAssertEqual(days.last, calendar.startOfDay(for: date(0)))
            XCTAssertEqual(GoalongWorkSchedule.target([(day: "lun", groups: 0), (day: "mar", groups: 3), (day: "mer", groups: 9)]), "mar")
            XCTAssertNil(GoalongWorkSchedule.target([(day: "lun", groups: 0)]))
            let agent = try source("GoalongWorkAgent.swift")
            XCTAssertTrue(agent.contains("classify(days: GoalongWorkSchedule.days(endingOn: now), userInitiated: false)"), "Background pass")
            XCTAssertTrue(agent.contains("classify(days: GoalongWorkSchedule.days(endingOn: now), userInitiated: true)"), "Manual pass")
            XCTAssertTrue(try source("GoalongWorkPage.swift").contains("Button(\"Lancer un passage maintenant\") { agent.startManualPass("))
        }

        // 3. Nothing is sent on its own after « Connecter ChatGPT ».
        func testConnectingSendsNothingOnItsOwn() throws {
            let page = try source("GoalongWorkPage.swift")
            XCTAssertFalse(page.contains("classifyWhenConnected"))
            XCTAssertFalse(page.contains("onChange(of: runtime.connectionState)"))
        }

        // 4. Both consents name every data a call carries; the background consent must be given again.
        @MainActor func testConsentsNameEveryDataAndTheOldConsentIsAskedAgain() throws {
            for text in [GoalongWorkPage.backgroundConsentText, GoalongWorkPage.manualConsentText] {
                for part in ["nom de l’app", "site", "titre de la fenêtre", "durée", "deux moments voisins", "leur classement, leur tâche et leur durée", "pas de titre", "définition du travail",
                             "réponses (app, site, titre et tâche)", "20 noms de vos tâches", "note de la journée", "240 caractères", "Données pour ChatGPT",
                             "Jamais vos frappes au clavier, ni de capture d’écran"] {
                    XCTAssertTrue(text.contains(part), part)
                }
                XCTAssertFalse(text.contains("titres de deux fenêtres"), "The neighbours carry no title")
            }
            XCTAssertEqual(GoalongWorkStore.backgroundConsentVersion, 2)
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let first = store(in: root); first.backgroundConsent = true
            let file = root.appendingPathComponent("work-classification.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["backgroundConsent"] = 1
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            XCTAssertFalse(store(in: root).backgroundConsent, "A consent given to the old text does not count")
        }

        // 5. The word « agent » is gone from the texts of the work classification.
        func testNoAgentWordInTheClassificationTexts() throws {
            let agent = try source("GoalongWorkAgent.swift")
            XCTAssertTrue(agent.contains("progress = \"Classement automatique de \\(batch.count) groupe"))
            for name in ["GoalongWorkAgent.swift", "JevWorkContextControls.swift", "GoalongAnalysisSelectionSheet.swift", "GoalongWorkPage.swift"] {
                let strings = try source(name).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for line in strings { XCTAssertFalse(line.contains("’agent") || line.contains("L’agent"), "\(name): \(line)") }
            }
        }

        // 6. « Tout reclasser » says when the contexts go again.
        func testReclassifyTextNamesTheNextPass() {
            XCTAssertTrue(GoalongWorkPage.reclassifyText.contains("au prochain passage automatique (ou avec « Lancer un passage maintenant »)"))
            XCTAssertFalse(GoalongWorkPage.reclassifyText.contains("consultations d’Activité"))
        }

        // 7. A failed read of the account limits leaves nothing shown.
        func testFailedLimitsReadResetsTheShownLimits() throws {
            let agent = try source("GoalongWorkAgent.swift")
            XCTAssertTrue(agent.contains("lastLimits = before\n")); XCTAssertTrue(agent.contains("lastLimits = after\n"))
            XCTAssertFalse(agent.contains("if let before { lastLimits = before }")); XCTAssertFalse(agent.contains("if let after { lastLimits = after }"))
        }

        // 8. The margin follows the real mean of a call, so the real count stays under the cap.
        func testMarginFollowsTheMeasuredMean() {
            var week = GoalongWorkUsage.Day()
            XCTAssertEqual(GoalongWorkSchedule.callMargin(week), GoalongWorkSchedule.minimumCallTokens)
            week.measuredCalls = 2; week.measuredTokens = 15_001
            XCTAssertEqual(GoalongWorkSchedule.callMargin(week), 7_501)
            var today = GoalongWorkUsage.Day(); today.tokens = 17_000
            XCTAssertFalse(GoalongWorkSchedule.capReached(today), "5 000 still fit")
            XCTAssertTrue(GoalongWorkSchedule.capReached(today, margin: 7_501), "A real call of 7 500 would pass 24 000")
            XCTAssertEqual(GoalongWorkSchedule.decide(now: date(13), pendingGroups: 3, usage: today, manual: true, margin: 7_501, calendar: calendar),
                           .skip(.dailyCapReached))
            XCTAssertEqual(GoalongWorkPassLine.next(now: date(9), usageToday: today, pendingGroups: 3, margin: 7_501, calendar: calendar),
                           "demain vers 12 h 30")
        }

        // 9. « À classer » of one day comes from the same states as the card.
        func testUnclassifiedOfOneDayComesFromTheWorkStates() {
            let seconds: [GoalongWorkState.Bucket: TimeInterval] = [.classified: 3_600, .waiting: 600, .toClarify: 300, .tooShort: 60]
            XCTAssertEqual(GoalongWorkStatus.unclassifiedSeconds(seconds, dayCount: 1), 960)
            XCTAssertNil(GoalongWorkStatus.unclassifiedSeconds(seconds, dayCount: 7))
            XCTAssertNil(GoalongWorkStatus.unclassifiedSeconds(nil, dayCount: 1))
        }

        // 10. The policy is read off the main thread; a click during a pass says it was not started.
        @MainActor func testBusyClickSaysSoAndErasesNothing() throws {
            XCTAssertTrue(try source("GoalongWorkClarify.swift").contains("agent.waitingReason(background: true, sharingBlocked: filter.policy.blocked)"))
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let agent = GoalongWorkAgent(store: store(in: root), root: root)
            agent.setRunningForTesting(date(12))
            var erased = false
            XCTAssertFalse(agent.startManualPass(now: date(12), prepare: { erased = true }))
            XCTAssertFalse(erased, "« Tout reclasser » erases nothing when the pass cannot start")
            XCTAssertEqual(agent.busyNotice, GoalongWorkAgent.busyText)
            agent.cancel()
            XCTAssertNil(agent.busyNotice)
        }

        // (b) One way in to write the definition; (c) the weekly share reads before and after.
        func testOneDefinitionLinkAndClearQuotaText() {
            XCTAssertNil(GoalongWorkPassLine.link(for: .noDefinition))
            var day = GoalongWorkUsage.Day(); day.weeklyPercentBefore = 11; day.weeklyPercentAfter = 12
            XCTAssertEqual(GoalongWorkUsageText.quota(day: day, limits: nil), "Quota de la semaine : \(GoalongUIFormat.percent(11)) avant le dernier passage, \(GoalongUIFormat.percent(12)) après")
        }

        // 1 (review 2). A call that fails counts at max(estimate, margin), on disk, and the cap of 24 000 holds.
        private struct SendFailure: Error {}
        @MainActor func testFailedManualCallsKeepTheDailyCapAcrossARestart() async throws {
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            // Calls measured at 9 000 tokens: the margin is 9 000, the estimate of the next call only 5 000.
            let seed = store(in: root)
            seed.recordUsage(day: "2026-11-09", at: date(12, day: 9), tokens: 9_000, estimated: false, background: true, weeklyBefore: nil, weeklyAfter: nil)
            var sent = 0
            for _ in 0..<5 {
                let fresh = store(in: root)   // read back from disk, as after a restart
                let agent = GoalongWorkAgent(store: fresh, root: root)
                let margin = agent.callMargin(now: date(13), calendar: calendar)
                XCTAssertEqual(margin, 9_000)
                guard case .call = GoalongWorkSchedule.decide(now: date(13), pendingGroups: 5, usage: fresh.usage.day("2026-11-10"),
                                                              manual: true, margin: margin, calendar: calendar) else { break }
                do {
                    _ = try await GoalongWorkAgent.sendCounted(store: fresh, day: "2026-11-10", at: date(13), estimate: 5_000, margin: margin,
                                                               background: false, weeklyBefore: nil) { () async throws -> Int in sent += 1; throw SendFailure() }
                    XCTFail("The failure must pass through")
                } catch is SendFailure {}
                // The count is on disk right after the failure, before any settle.
                XCTAssertEqual(store(in: root).usage.day("2026-11-10").tokens, sent * 9_000)
            }
            let final = store(in: root).usage.day("2026-11-10")
            XCTAssertEqual(sent, 2, "A third call would pass 24 000 (3 x 9 000 real)")
            XCTAssertEqual(final.tokens, 18_000); XCTAssertEqual(final.calls, 2)
            XCTAssertLessThanOrEqual(final.tokens, GoalongWorkSchedule.dailyTokenCap)
            XCTAssertTrue(GoalongWorkSchedule.capReached(final, margin: 9_000))
        }

        func testClassifySendsThroughTheCountedPath() throws {
            let agent = try source("GoalongWorkAgent.swift")
            XCTAssertTrue(agent.contains("try await Self.sendCounted(store: store"))
            XCTAssertTrue(agent.contains("settleUsage(day: today, estimate: counted"))
            XCTAssertFalse(agent.contains("store.recordUsage(day: today"), "classify counts only through sendCounted")
        }

        // 6 (review 2). A background pass that ends without a call drops the notice of a refused click.
        @MainActor func testBackgroundSkipClearsTheBusyNotice() throws {
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let agent = GoalongWorkAgent(store: store(in: root), root: root)
            agent.setRunningForTesting(date(12))
            XCTAssertFalse(agent.startManualPass(now: date(12)))
            XCTAssertEqual(agent.busyNotice, GoalongWorkAgent.busyText)
            agent.endBackgroundSkip(nil, resolvedLocally: 2)
            XCTAssertNil(agent.busyNotice); XCTAssertNil(agent.runningDay)
            XCTAssertNotNil(agent.lastOutcome)
        }

        // 4 (review 2). The 7-day read of the pass uses the serial queue of the states of the page.
        func testPassReadsOnTheSerialQueue() throws {
            let agent = try source("GoalongWorkAgent.swift")
            XCTAssertTrue(agent.contains("GoalongWorkStateModel.readQueue.async"))
            XCTAssertFalse(agent.contains("let observations = await Self.detachedForwardingCancellation"))
        }
    }
#endif
