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

        /// D-154b: a file repaired after it was unreadable, saved under an older definition, kept only the
        /// owner's corrections: the contexts of an open « tâche » commitment went with the agent verdicts.
        @MainActor func testAdoptingARepairedFileKeepsTheContextsOfAnOpenCommitment() throws {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("work-adopt-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); try? fm.removeItem(at: folder) }
            let file = folder.appendingPathComponent("work-classification.json")
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            let commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            let mail = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil, title: "Boîte")
            let old = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") })
            old.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "goalong", byOwner: false),
                       mail.key: GoalongWorkAssignment(verdict: .work, task: "Courriels", byOwner: false)],
                      revision: old.revision, day: "2026-10-28")
            let saved = try Data(contentsOf: file)

            // Unreadable and left in place (folder read-only), under a newer definition.
            try Data("{tronqué".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            let blocked = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong et Atlas") },
                                           committedTasks: { FocusCommitmentRules.openTaskNames([commitment]) })
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try saved.write(to: file)

            blocked.merge(["fixture-other": GoalongWorkAssignment(verdict: .other, task: nil, byOwner: false)],
                          revision: blocked.revision, day: "2026-10-28")
            XCTAssertNil(blocked.lastError)
            XCTAssertEqual(blocked.verdicts.assignment(for: xcode.key)?.task, "goalong",
                           "The open commitment must keep finding its task")
            XCTAssertNil(blocked.verdicts.assignment(for: mail.key), "Other verdicts of the older definition go")
        }

        /// D-154d: after a definition change, the verdicts kept for an open « tâche » commitment stayed for good
        /// once it settled: nothing asks the agent again about a context that has a verdict, so the older
        /// definition kept counting those contexts as work (Activité, next commitments).
        @MainActor func testKeptVerdictsGoOnceTheCommitmentSettles() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let period = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            var commitment = FocusCommitment(period: period, kind: .task, target: 60, task: "Goalong",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            var goals = "Goalong"
            let committed: @MainActor () -> [String] = { FocusCommitmentRules.openTaskNames([commitment]) }
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: goals) }, committedTasks: committed)
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "goalong", byOwner: false)],
                        revision: store.revision, day: "2026-10-28")
            goals = "Atlas"
            store.reconcileDefinition()
            NotificationCenter.default.post(name: .goalongFocusCommitmentsDidChange, object: nil)
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "goalong", "Kept while the commitment is open")

            commitment.result = FocusCommitmentResult(settledAt: Date(timeIntervalSince1970: 1_800_090_000), measured: 60,
                                                      unmeasuredMinutes: 0, outcome: .held)
            let relaunched = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: goals) }, committedTasks: committed)
            XCTAssertNil(relaunched.verdicts.assignment(for: xcode.key), "At launch, a settled commitment no longer holds it")
            NotificationCenter.default.post(name: .goalongFocusCommitmentsDidChange, object: nil)
            XCTAssertNil(store.verdicts.assignment(for: xcode.key), "Once settled, the context is classified again")
        }

        /// D-154d: with Concentration off, no controller: the kept verdicts filter saw no commitment, so a definition
        /// change or « Tout reclasser » dropped them, and the commitment settled low once Concentration was on again.
        @MainActor func testOpenTaskNamesAreReadFromDiskWhenConcentrationIsOff() throws {
            let root = URL(fileURLWithPath: "/private/tmp/t045-d154d-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let focus = FocusStore(directory: root)
            var settled = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-27"), kind: .task, target: 60,
                                          task: "Atlas", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            settled.result = FocusCommitmentResult(settledAt: Date(timeIntervalSince1970: 1_800_090_000), measured: 60,
                                                   unmeasuredMinutes: 0, outcome: .held)
            let open = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-28"), kind: .task, target: 60,
                                       task: "Goalong", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            try focus.saveCommitments([settled, open])
            XCTAssertEqual(GoalongWorkStore.openTaskNames(controller: nil, store: focus), ["Goalong"])
        }

        /// D-154d review: an unreadable Concentration file read as no commitment, so the kept verdicts went
        /// and the commitment, once readable again, measured too little. « Tout reclasser » kept its verdicts for good.
        @MainActor func testKeptVerdictsStayWhileCommitmentsAreUnreadable() throws {
            let root = URL(fileURLWithPath: "/private/tmp/t045-d154d-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("{tronqué".utf8).write(to: root.appendingPathComponent("commitments.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("commitments.json").path)
            XCTAssertNil(GoalongWorkStore.openTaskNames(controller: nil, store: FocusStore(directory: root)))

            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            var open: [String]? = nil
            var goals = "Goalong"
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: goals) }, committedTasks: { open })
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            let mail = GoalongWorkContext.Label(application: "Mail", bundleIdentifier: "fixture.Mail", host: nil, title: "Boîte")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "goalong", byOwner: false),
                         mail.key: GoalongWorkAssignment(verdict: .work, task: "Courriels", byOwner: false)],
                        revision: store.revision, day: "2026-10-28")
            goals = "Atlas"
            store.reconcileDefinition()
            store.releaseSettledVerdicts()
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "goalong", "Unknown commitments keep every verdict")
            XCTAssertEqual(store.verdicts.assignment(for: mail.key)?.task, "Courriels")

            open = ["Goalong"]
            store.releaseSettledVerdicts()
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "goalong", "Kept while the commitment is open")
            XCTAssertNil(store.verdicts.assignment(for: mail.key), "Readable again: the other context is classified again")

            store.merge([mail.key: GoalongWorkAssignment(verdict: .work, task: "Courriels", byOwner: false)],
                        revision: store.revision, day: "2026-10-28")
            store.forgetAgentVerdicts()
            open = []
            store.releaseSettledVerdicts()
            XCTAssertNil(store.verdicts.assignment(for: xcode.key), "Kept by « Tout reclasser », it goes once settled")
        }

        /// D-154c: clearing history during an open « travail » or « tâche » commitment erases what it measures,
        /// so it could be missed and its stake applied without a word in the confirmation.
        func testHistoryClearWarnsAboutAnOpenCommitment() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15)))
            let today = FocusCommitmentPeriod(kind: .day, key: "2026-10-28")
            var task = FocusCommitment(period: today, kind: .task, target: 60, task: "Goalong", createdAt: now)
            task.stake = FocusStake(listIds: [UUID()])
            let warning = try XCTUnwrap(FocusCommitmentRules.historyClearWarning([task], since: nil, at: now, calendar: calendar))
            XCTAssertTrue(warning.contains("enjeu"), warning)
            XCTAssertNotNil(FocusCommitmentRules.historyClearWarning([task], since: now.addingTimeInterval(-3600), at: now, calendar: calendar))
            task.stake = nil
            XCTAssertFalse(FocusCommitmentRules.historyClearWarning([task], since: nil, at: now, calendar: calendar)?.contains("enjeu") ?? true)

            let sessions = FocusCommitment(period: today, kind: .sessions, target: 2, createdAt: now)
            let tomorrow = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-29"), kind: .work, target: 60, createdAt: now)
            let yesterday = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-27"), kind: .work, target: 60, createdAt: now)
            XCTAssertNil(FocusCommitmentRules.historyClearWarning([sessions, tomorrow], since: nil, at: now, calendar: calendar),
                         "Sessions are not measured from history; a future period has nothing to erase")
            XCTAssertNil(FocusCommitmentRules.historyClearWarning([yesterday], since: now.addingTimeInterval(-600), at: now, calendar: calendar),
                         "The last 10 minutes do not touch yesterday")
            XCTAssertNotNil(FocusCommitmentRules.historyClearWarning([yesterday], since: now.addingTimeInterval(-86_400), at: now, calendar: calendar))
            task.result = FocusCommitmentResult(settledAt: now, measured: 60, unmeasuredMinutes: 0, outcome: .held)
            XCTAssertNil(FocusCommitmentRules.historyClearWarning([task], since: nil, at: now, calendar: calendar))
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
