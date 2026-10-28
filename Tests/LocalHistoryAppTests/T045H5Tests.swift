#if os(macOS)
    import Foundation
    import XCTest
    import LocalHistoryCore
    @testable import LocalHistoryApp

    /// T-045 H5: Concentration engagement, reclassification and data deletion journeys.
    final class T045H5Tests: XCTestCase {
        /// H5-01: deleting Concentration data also deletes its commitments, open ones included,
        /// but the confirmation listed only sessions, plans, reviews and settings.
        @MainActor func testConcentrationDeleteConfirmationNamesTheCommitments() {
            let message = GoalongModulesSettings.concentrationDeleteMessage
            XCTAssertTrue(message.contains("engagements"), message)
            XCTAssertTrue(message.contains("en cours"), message)
        }

        /// H5-02: « Tout reclasser » forgets the agent verdicts; only today is classified again, past days only
        /// when opened in Activité. An open « travail » commitment then counted that time as unclassified,
        /// could be missed and run its stake, and the confirmation said nothing.
        func testReclassifyAllWarnsAboutAnOpenWorkCommitment() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            // Thursday of the week of the DST end (Sunday 2026-10-25 is the previous week's last day).
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15)))
            let week = FocusCommitmentPeriod(kind: .week, key: "2026-W44")
            var work = FocusCommitment(period: week, kind: .work, target: 1_200, createdAt: now)
            let plain = try XCTUnwrap(FocusCommitmentRules.reclassifyWarning([work], at: now, calendar: calendar))
            XCTAssertTrue(plain.contains("Activité"), plain)
            XCTAssertFalse(plain.contains("enjeu"), plain)
            work.stake = FocusStake(listIds: [UUID()])
            XCTAssertTrue(FocusCommitmentRules.reclassifyWarning([work], at: now, calendar: calendar)?.contains("enjeu") == true)
            XCTAssertNotNil(FocusCommitmentRules.reclassifyWarning(nil, at: now, calendar: calendar),
                            "Unreadable commitments: warn anyway")

            let task = FocusCommitment(period: week, kind: .task, target: 60, task: "Goalong", createdAt: now)
            let next = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-30"), kind: .work, target: 60, createdAt: now)
            XCTAssertNil(FocusCommitmentRules.reclassifyWarning([task, next], at: now, calendar: calendar),
                         "A « tâche » commitment keeps its contexts; a future period has nothing classified yet")
            work.result = FocusCommitmentResult(settledAt: now, measured: 1_200, unmeasuredMinutes: 0, outcome: .held)
            XCTAssertNil(FocusCommitmentRules.reclassifyWarning([work], at: now, calendar: calendar))
        }

        /// H5-03: changing the work definition drops the past « travail » verdicts without a word; an open
        /// « travail » commitment could then be missed. Same warning as « Tout reclasser ».
        func testDefinitionChangeWarnsAboutAnOpenWorkCommitment() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15)))
            let week = FocusCommitmentPeriod(kind: .week, key: "2026-W44")
            var work = FocusCommitment(period: week, kind: .work, target: 1_200, createdAt: now)
            let plain = try XCTUnwrap(FocusCommitmentRules.definitionChangeWarning([work], at: now, calendar: calendar))
            XCTAssertTrue(plain.contains("définition"), plain)
            XCTAssertFalse(plain.contains("enjeu"), plain)
            work.stake = FocusStake(listIds: [UUID()])
            XCTAssertTrue(FocusCommitmentRules.definitionChangeWarning([work], at: now, calendar: calendar)?.contains("enjeu") == true)
            XCTAssertNotNil(FocusCommitmentRules.definitionChangeWarning(nil, at: now, calendar: calendar))
            let task = FocusCommitment(period: week, kind: .task, target: 60, task: "Goalong", createdAt: now)
            XCTAssertNil(FocusCommitmentRules.definitionChangeWarning([task], at: now, calendar: calendar))
            work.result = FocusCommitmentResult(settledAt: now, measured: 1_200, unmeasuredMinutes: 0, outcome: .held)
            XCTAssertNil(FocusCommitmentRules.definitionChangeWarning([work], at: now, calendar: calendar))
        }

        /// H5-04: a Plan du jour item linked to a project finds its minutes by the task name. Renaming
        /// (or merging) the task left it on the old name, so the project minutes read 0.
        @MainActor func testRenamingATaskRenamesLinkedPlanItems() throws {
            let root = URL(fileURLWithPath: "/private/tmp/t045h5-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let focus = FocusStore(directory: root.appendingPathComponent("focus"))
            var plan = FocusPlan(day: "2026-10-28")
            plan.items = [FocusPlanItem(title: "A", project: "Goalong"), FocusPlanItem(title: "B", project: "Atlas"), FocusPlanItem(title: "C")]
            try focus.savePlans([plan])
            let file = root.appendingPathComponent("work.json")
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") },
                                         committedTasks: { [] },
                                         renamedTask: { old, new in _ = try? focus.renamePlanProject(from: old, to: new) })
            XCTAssertNil(store.renameTask("Goalong", to: "Goalong – app macOS"))
            let saved = try XCTUnwrap(focus.plan("2026-10-28"))
            XCTAssertEqual(saved.items.map(\.project), ["Goalong – app macOS", "Atlas", nil])
            XCTAssertNil(store.renameTask("Atlas", to: "Goalong – app macOS"), "Merge into an existing name")
            XCTAssertEqual(try XCTUnwrap(focus.plan("2026-10-28")).items.map(\.project), ["Goalong – app macOS", "Goalong – app macOS", nil])
        }
    }
#endif
