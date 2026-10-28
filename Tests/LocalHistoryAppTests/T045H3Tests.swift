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

        /// D-154a: « Tout reclasser » dropped every agent verdict, so the agent could file the contexts of an
        /// open « tâche » commitment under another name: the commitment counted zero and its stake ran.
        @MainActor func testReclassifyingAllKeepsTheContextsOfAnOpenCommitment() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            var commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") },
                                         committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            let mail = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil, title: "Boîte")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "goalong", byOwner: false),
                         mail.key: GoalongWorkAssignment(verdict: .work, task: "Courriels", byOwner: false)],
                        revision: store.revision, day: "2026-10-28")

            store.forgetAgentVerdicts()
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "goalong",
                           "The open commitment must keep finding its task")
            XCTAssertNil(store.verdicts.assignment(for: mail.key), "Other contexts are classified again")

            commitment.result = FocusCommitmentResult(settledAt: Date(timeIntervalSince1970: 1_800_090_000), measured: 60,
                                                      unmeasuredMinutes: 0, outcome: .held)
            store.forgetAgentVerdicts()
            XCTAssertNil(store.verdicts.assignment(for: xcode.key), "A settled commitment no longer holds the verdict")
        }

        /// D-154b: a changed work definition dropped every agent verdict, so the agent could file the contexts
        /// of an open « tâche » commitment under another name: the commitment counted zero and its stake ran.
        @MainActor func testChangingTheDefinitionKeepsTheContextsOfAnOpenCommitment() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            var commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            var goals = "Goalong"
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: goals) },
                                         committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            let mail = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil, title: "Boîte")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "goalong", byOwner: false),
                         mail.key: GoalongWorkAssignment(verdict: .work, task: "Courriels", byOwner: false)],
                        revision: store.revision, day: "2026-10-28")

            goals = "Goalong et Atlas"
            store.reconcileDefinition()
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "goalong",
                           "The open commitment must keep finding its task")
            XCTAssertNil(store.verdicts.assignment(for: mail.key), "Other contexts are classified again")
            let reopened = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: goals) },
                                            committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            XCTAssertEqual(reopened.verdicts.assignment(for: xcode.key)?.task, "goalong", "The kept verdict is saved")

            commitment.result = FocusCommitmentResult(settledAt: Date(timeIntervalSince1970: 1_800_090_000), measured: 60,
                                                      unmeasuredMinutes: 0, outcome: .held)
            goals = "Atlas"
            store.reconcileDefinition()
            XCTAssertNil(store.verdicts.assignment(for: xcode.key), "A settled commitment no longer holds the verdict")
        }

        /// D-154b: past the entry limit the oldest agent verdicts went first, those of an open commitment too.
        @MainActor func testPruningKeepsTheContextsOfAnOpenCommitment() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            let commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") },
                                         committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "Goalong", byOwner: false)],
                        revision: store.revision, day: "2026-10-01")
            var others: [String: GoalongWorkAssignment] = [:]
            for index in 0..<GoalongWorkStore.maximumEntries {
                others["fixture-\(index)"] = GoalongWorkAssignment(verdict: .other, task: nil, byOwner: false)
            }
            store.merge(others, revision: store.revision, day: "2026-10-28")
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "Goalong",
                           "The open commitment must keep finding its task")
        }

        /// H3-01: the work review starts on `GoalongToday.now`, an instant with its time. Past midnight
        /// « Jour suivant » was enabled (the day is no longer today) yet did nothing until that hour.
        func testNextDayStepsToTodayAfterMidnight() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            let opened = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 30)))
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 0, minute: 10)))
            let next = try XCTUnwrap(DateSelectionControl.steppedDay(from: opened, by: 1, now: now, calendar: calendar))
            XCTAssertTrue(calendar.isDate(next, inSameDayAs: now))
            XCTAssertNil(DateSelectionControl.steppedDay(from: now, by: 1, now: now, calendar: calendar), "Tomorrow stays out of reach")
            XCTAssertNotNil(DateSelectionControl.steppedDay(from: now, by: -1, now: now, calendar: calendar))
        }
        /// H3-03: « Bilan du soir » says the end of day replaces it, but the end of day only runs on its
        /// weekdays. On the other days the evening review never came at all.
        @MainActor func testEveningReviewStillComesOnDaysWithoutEndOfDay() throws {
            let root = URL(fileURLWithPath: "/private/tmp/focus-h3-" + UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let store = FocusStore(directory: root)
            var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = true
            settings.eveningMinute = 21 * 60; settings.limits.endMinute = 18 * 60 + 30; settings.limits.weekdays = Set(1...5)
            try store.saveSettings(settings)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            // Saturday 10 October 2026: outside the end-of-day weekdays, the evening time applies.
            var now = calendar.date(from: .init(year: 2026, month: 10, day: 10, hour: 18, minute: 40))!
            let weekend = try ConcentrationController(store: store, clock: { now }, calendar: calendar)
            weekend.refresh(); XCTAssertNil(weekend.panel, "The end of day does not run on Saturday")
            now = calendar.date(from: .init(year: 2026, month: 10, day: 10, hour: 21, minute: 5))!
            weekend.refresh(); XCTAssertEqual(weekend.panel?.kind, .evening)

            // Monday 12 October: the end of day replaces the evening time (its « limite » panel shows).
            let weekday = FocusStore(directory: root.appendingPathComponent("monday"))
            try weekday.saveSettings(settings)
            now = calendar.date(from: .init(year: 2026, month: 10, day: 12, hour: 18, minute: 35))!
            let monday = try ConcentrationController(store: weekday, clock: { now }, calendar: calendar)
            monday.refresh(); XCTAssertNotNil(monday.panel, "The end of day still prompts at 18:30 on Monday")
        }
    }
#endif
