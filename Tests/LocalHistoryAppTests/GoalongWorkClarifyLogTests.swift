#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// T-055: « Précédent » in « À préciser » shows an earlier answer, which can be kept, changed or removed.
    final class GoalongWorkClarifyLogTests: XCTestCase {
        @MainActor private func store() throws -> (GoalongWorkStore, URL) {
            let root = URL(fileURLWithPath: "/private/tmp/t055-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (GoalongWorkStore(fileURL: root.appendingPathComponent("work.json"), definition: { GoalongWorkDefinition(goals: "Atlas") },
                                     committedTasks: { [] }, renamedTask: { _, _ in [] }), root)
        }
        private func question(_ title: String) -> GoalongWorkStateModel.Question {
            let label = GoalongWorkContext.Label(application: "Safari", bundleIdentifier: "com.apple.Safari", host: "notion.so", title: title)
            return .init(id: GoalongWorkContext.key(label), label: label, seconds: 600, reason: .agentUnsure)
        }
        private let day = "2026-11-12"

        @MainActor func testPreviousShowsEachAnswerBackToTheFirst() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            var log = GoalongWorkClarifyLog()
            let a = question("Plan Atlas"), b = question("Recettes")
            XCTAssertFalse(log.canGoBack, "Nothing answered yet: no « Précédent »")
            XCTAssertTrue(log.answer(a, .work, scope: .context, store: work, day: day))
            XCTAssertTrue(log.answer(b, .other, scope: .context, store: work, day: day))
            log.back()
            XCTAssertEqual(log.shown?.question.id, b.id); XCTAssertEqual(log.shown?.verdict, .other)
            log.back()
            XCTAssertEqual(log.shown?.question.id, a.id); XCTAssertEqual(log.shown?.verdict, .work)
            XCTAssertFalse(log.canGoBack)
            log.forward(); XCTAssertEqual(log.shown?.question.id, b.id)
            log.forward(); XCTAssertNil(log.shown, "Past the last answer: the next question again")
            XCTAssertEqual(work.verdicts.contexts[a.id]?.verdict, .work, "Looking back changes nothing")
        }

        @MainActor func testChangingAnEarlierAnswerReplacesItEverywhere() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            var log = GoalongWorkClarifyLog()
            let a = question("Plan Atlas"), b = question("Recettes")
            _ = log.answer(a, .work, scope: .context, store: work, day: day)
            _ = log.answer(b, .other, scope: .context, store: work, day: day)
            log.back(); log.back()
            log.change(to: .other, scope: .context, store: work, day: day)
            XCTAssertEqual(work.verdicts.contexts[a.id]?.verdict, .other)
            XCTAssertEqual(log.shown?.question.id, b.id, "After a change, the next answer is shown")
            // A wider scope: the context answer goes, a site rule replaces it.
            log.change(to: .work, scope: .site, store: work, day: day)
            XCTAssertNil(work.verdicts.contexts[b.id]?.verdict)
            XCTAssertEqual(work.rules.first?.target, "notion.so"); XCTAssertEqual(work.rules.first?.assignment.verdict, .work)
            XCTAssertNil(log.shown)
            XCTAssertEqual(log.entries.map(\.verdict), [.other, .work]); XCTAssertEqual(log.entries.last?.scope, .site)
        }

        @MainActor func testRemovingAnAnswerPutsTheQuestionBack() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            var log = GoalongWorkClarifyLog()
            let a = question("Plan Atlas")
            _ = log.answer(a, .work, scope: .context, store: work, day: day)
            log.back()
            XCTAssertEqual(log.remove(), a.id)
            XCTAssertNil(work.verdicts.contexts[a.id]); XCTAssertTrue(log.entries.isEmpty); XCTAssertNil(log.shown)
            XCTAssertTrue(work.answers.isEmpty)
        }

        /// Review M5: a change that cannot be saved takes the old answer back; its question must return, not vanish.
        @MainActor func testFailedChangeReturnsTheQuestion() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            var log = GoalongWorkClarifyLog()
            let label = GoalongWorkContext.Label(application: "Pages", bundleIdentifier: "com.apple.iWork.Pages", host: nil, title: "Rapport")
            let a = GoalongWorkStateModel.Question(id: GoalongWorkContext.key(label), label: label, seconds: 600, reason: .agentUnsure)
            _ = log.answer(a, .work, scope: .context, store: work, day: day)
            log.back()
            XCTAssertEqual(log.change(to: .work, scope: .site, store: work, day: day), a.id, "No site: nothing saved, the key comes back")
            XCTAssertNil(work.verdicts.contexts[a.id]); XCTAssertTrue(log.entries.isEmpty)
            XCTAssertNil(log.change(to: .work, scope: .context, store: work, day: day), "Nothing shown: nothing to change")
        }

        /// Review B1 and M1, app side: the honest reason, the flag kept by the store, the badge in « Vos réponses ».
        @MainActor func testContentFlagReasonAndBadge() throws {
            let (work, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertTrue(GoalongWorkAnswering.reasonNote(.contentUnseen).contains("pas pu lire"))
            XCTAssertEqual(GoalongWorkAnswering.reasonNote(.agentUnsure), "")
            work.merge(["k1": .init(verdict: .other)], revision: work.revision, day: day)
            work.merge(["k2": .init(verdict: .other)], revision: work.revision, day: day, onContent: false)
            XCTAssertEqual(work.verdicts.judgedOnContent, ["k1"])
            let chat = GoalongWorkContext.Label(application: "Safari", bundleIdentifier: "com.apple.Safari", host: "chatgpt.com", title: "ChatGPT Home")
            work.correct(key: GoalongWorkContext.key(chat), label: chat, verdict: .work, task: nil, day: day)
            work.setRule(scope: .site, target: "chatgpt.com", label: "chatgpt.com", verdict: .work, day: day)
            work.setRule(scope: .site, target: "notion.so", label: "notion.so", verdict: .work, day: day)
            let covered = Dictionary(uniqueKeysWithValues: work.answers.map { ($0.target, work.coversVaryingContent($0)) })
            XCTAssertEqual(covered[GoalongWorkContext.key(chat)], true); XCTAssertEqual(covered["chatgpt.com"], true)
            XCTAssertEqual(covered["notion.so"], false)
        }

        /// Review B1, sheet side: with visible text not shared, an unsure ChatGPT page is a question again.
        func testSnapshotAsksAboutUnreadableContentVaryingPage() {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
            let events = (0...10).map { index in
                HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: start.addingTimeInterval(36_000 + Double(index * 60)), kind: .heartbeat,
                    app: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 1),
                    window: WindowSnapshot(title: "ChatGPT Home", role: nil, subrole: nil),
                    url: .init(value: "https://chatgpt.com", host: "chatgpt.com", redactionApplied: true),
                    classification: .init(category: "fixture", isWork: nil, confidence: 0.99, classifierVersion: "legacy"))
            }
            let observation = GoalongWorkClassification.observation(events: events, day: start, now: start.addingTimeInterval(86_400), calendar: calendar)
            let key = try! XCTUnwrap(observation.labels.keys.first)
            let verdicts = GoalongWorkVerdicts([key: .init(verdict: .unclear)], judgedOnContent: [key])
            let readable = GoalongWorkStateModel.snapshot(observations: [observation], verdicts: verdicts, blocker: nil)
            XCTAssertTrue(readable.questions.isEmpty)
            let unreadable = GoalongWorkStateModel.snapshot(observations: [observation], verdicts: verdicts, permitsContent: { _ in false }, blocker: nil)
            XCTAssertEqual(unreadable.questions.map(\.reason), [.contentUnseen])
        }
    }
#endif
