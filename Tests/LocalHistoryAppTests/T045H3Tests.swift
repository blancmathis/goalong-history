#if os(macOS)
    import Foundation
    import XCTest
    import LocalHistoryCore
    @testable import LocalHistoryApp

    /// T-045 H3: defects found in zones no earlier round audited.
    final class T045H3Tests: XCTestCase {
        /// H3-02: a « tâche » commitment measures its task by name. Renaming that task in « Vérifier et
        /// corriger » relabelled every context, so the open commitment counted zero and its stake ran.
        @MainActor func testRenamingATaskOfAnOpenCommitmentIsRefused() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            var commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") },
                                         committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            let docs = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            store.correct(key: docs.key, label: docs, verdict: .work, task: "Goalong", day: "2026-10-28")

            let refusal = store.renameTask("Goalong", to: "Goalong – app macOS")
            XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "Goalong",
                           "The open commitment would no longer find its task")
            XCTAssertTrue(refusal?.contains("engagement") == true, refusal ?? "nil")
            XCTAssertNil(store.renameTask("Goalong", to: "goalong"), "A change of case keeps the commitment's match")
            XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "goalong")

            commitment.result = FocusCommitmentResult(settledAt: Date(timeIntervalSince1970: 1_800_090_000), measured: 60,
                                                      unmeasuredMinutes: 0, outcome: .held)
            XCTAssertNil(store.renameTask("goalong", to: "Atlas"), "A settled commitment no longer measures the task")
            XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "Atlas")
        }
    }
#endif
