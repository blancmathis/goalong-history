#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-046 L9 lot 2 : « Vérifier et corriger » de Mon travail, par le magasin et le modèle de relecture.
@MainActor final class T046UnitWorkReviewTests: XCTestCase {
    private let label = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
    private func store(committed: [String]? = [], file: URL) -> GoalongWorkStore {
        GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }, committedTasks: { committed })
    }
    private func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("t046-work-\(UUID().uuidString).json") }

    func testNewTaskNameIsCleanedAndABlankNameIsRefused() {
        XCTAssertNil(GoalongWorkClassification.cleanTask(""))
        XCTAssertNil(GoalongWorkClassification.cleanTask("   "))
        XCTAssertEqual(GoalongWorkClassification.cleanTask("  Préparer le cours  "), "Préparer le cours")
    }
    func testClassingARowUnderANewTaskMakesItKnownAndOwnerCorrected() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(file: file)
        s.correct(key: label.key, label: label, verdict: .work, task: "Atlas", day: "2026-10-29")
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.task, "Atlas")
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.byOwner, true)
        XCTAssertTrue(s.knownTasks.contains("Atlas"))
    }
    func testOtherVerdictHasNoTaskAndLetTheAgentDecideRemovesTheCorrection() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(file: file)
        s.correct(key: label.key, label: label, verdict: .other, task: nil, day: "2026-10-29")
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.verdict, .other)
        XCTAssertNil(s.verdicts.assignment(for: label.key)?.task)
        s.correct(key: label.key, label: label, verdict: nil, task: nil, day: "2026-10-29")
        XCTAssertNil(s.verdicts.assignment(for: label.key))
    }
    func testRenameToTheSameOrABlankNameChangesNothing() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(file: file)
        s.correct(key: label.key, label: label, verdict: .work, task: "Atlas", day: "2026-10-29")
        XCTAssertNil(s.renameTask("Atlas", to: "Atlas"))
        XCTAssertNil(s.renameTask("Atlas", to: "  "))
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.task, "Atlas")
        XCTAssertNil(s.renameNotice)
    }
    func testRenameRefusedWhileACommitmentFollowsTheTaskByName() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(committed: ["atlas"], file: file)
        s.correct(key: label.key, label: label, verdict: .work, task: "Atlas", day: "2026-10-29")
        let refusal = s.renameTask("Atlas", to: "Atlas 2")
        XCTAssertTrue(refusal?.contains("engagement Concentration en cours") == true)
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.task, "Atlas", "refusé : rien ne change")
    }
    func testRenameRefusedWhenCommitmentsAreUnreadable() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(committed: nil, file: file)
        s.correct(key: label.key, label: label, verdict: .work, task: "Atlas", day: "2026-10-29")
        XCTAssertTrue(s.renameTask("Atlas", to: "Autre")?.contains("n’ont pas pu être lus") == true)
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.task, "Atlas")
    }
    func testRenameCaseOnlyAndSuccessClearsRefusalAndKeepsOneName() {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let s = store(file: file)
        s.correct(key: label.key, label: label, verdict: .work, task: "atlas", day: "2026-10-29")
        XCTAssertNil(s.renameTask("atlas", to: "Atlas"))
        XCTAssertEqual(s.verdicts.assignment(for: label.key)?.task, "Atlas")
    }
    func testSkippedDaysNoticeIsSingularOrPluralAndEmptyWhenNone() {
        XCTAssertNil(GoalongWorkStore.skippedDaysNotice([]))
        XCTAssertTrue(GoalongWorkStore.skippedDaysNotice(["2026-10-29"])?.contains("29/10/2026") == true)
        XCTAssertTrue(GoalongWorkStore.skippedDaysNotice(["2026-10-28", "2026-10-29"])?.contains("28/10/2026, 29/10/2026") == true)
    }
    func testReviewLoadOfAnEmptyDayEndsLoadedWithNoRowsOrAnError() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/t046-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GoalongWorkReviewModel()
        model.load(day: Date(), root: root)
        XCTAssertTrue(model.loading)
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.loadedDay)
        XCTAssertTrue(model.rows.isEmpty)
    }
}
#endif
