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
    }
#endif
