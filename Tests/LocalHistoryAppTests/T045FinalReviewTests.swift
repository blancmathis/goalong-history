#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    import LocalHistoryCore
    @testable import LocalHistoryApp

    /// T-045 final review (D-FR1..5): commitments unknown or unsaved must fail closed, and no system text in English.
    final class T045FinalReviewTests: XCTestCase {
        private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }

        private func focusRoot(_ tag: String) throws -> URL {
            let root = URL(fileURLWithPath: "/private/tmp/t045-fr-\(tag)-" + UUID().uuidString)
            addTeardownBlock { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return root
        }

        private func unreadableCommitments() throws -> FocusStore {
            let root = try focusRoot("unreadable")
            try Data("{tronqué".utf8).write(to: root.appendingPathComponent("commitments.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("commitments.json").path)
            return FocusStore(directory: root)
        }

        /// D-FR1: with Concentration off, the clear read no commitment, so an open « travail » commitment
        /// with a stake failed on the erased history without any warning. Unreadable commitments warn too.
        @MainActor func testHistoryClearWarnsWhenConcentrationIsOff() throws {
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15)))
            let focus = FocusStore(directory: try focusRoot("off"))
            var work = FocusCommitment(period: FocusCommitmentPeriod(kind: .day, key: "2026-10-28"), kind: .work, target: 60, createdAt: now)
            work.stake = FocusStake(listIds: [UUID()])
            try focus.saveCommitments([work])

            let commitments = GoalongWorkStore.openCommitments(controller: nil, store: focus)
            let warning = try XCTUnwrap(FocusCommitmentRules.historyClearWarning(commitments, since: now.addingTimeInterval(-86_400),
                                                                                 at: now, calendar: calendar))
            XCTAssertTrue(warning.contains("enjeu"), warning)

            let damaged = try unreadableCommitments()
            let unknown = GoalongWorkStore.openCommitments(controller: nil, store: damaged)
            XCTAssertNil(unknown)
            let blind = try XCTUnwrap(FocusCommitmentRules.historyClearWarning(unknown, since: nil, at: now, calendar: calendar),
                                      "Unknown commitments warn: one may measure this history")
            XCTAssertTrue(blind.contains("n’ont pas pu être lus"), blind)
        }

        /// D-FR2: with an unreadable commitments file, a rename of the committed task went through and the
        /// commitment, read again, measured 0.
        @MainActor func testRenameIsRefusedWhileCommitmentsAreUnreadable() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            var open: [String]? = nil
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }, committedTasks: { open })
            let docs = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            store.correct(key: docs.key, label: docs, verdict: .work, task: "Goalong", day: "2026-10-28")

            let refusal = store.renameTask("Goalong", to: "Atlas")
            XCTAssertNotNil(refusal, "Unknown commitments: the task may be measured by name")
            XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "Goalong")
            XCTAssertNil(store.renameTask("Goalong", to: "goalong"), "A change of case keeps any match")
            open = []
            XCTAssertNil(store.renameTask("goalong", to: "Atlas"))
            XCTAssertEqual(store.verdicts.assignment(for: docs.key)?.task, "Atlas")
        }

        /// D-FR3: pruning read unknown commitments as none and could drop the verdicts of a committed task.
        @MainActor func testPruningKeepsEveryVerdictWhileCommitmentsAreUnreadable() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let store = GoalongWorkStore(fileURL: file, definition: { GoalongWorkDefinition(goals: "Goalong") }, committedTasks: { nil })
            let xcode = GoalongWorkContext.Label(application: "Xcode", bundleIdentifier: "fixture.Xcode", host: nil, title: "Goalong")
            store.merge([xcode.key: GoalongWorkAssignment(verdict: .work, task: "Goalong", byOwner: false)],
                        revision: store.revision, day: "2026-10-01")
            var others: [String: GoalongWorkAssignment] = [:]
            for index in 0..<GoalongWorkStore.maximumEntries {
                others["fixture-\(index)"] = GoalongWorkAssignment(verdict: .other, task: nil, byOwner: false)
            }
            store.merge(others, revision: store.revision, day: "2026-10-28")
            XCTAssertEqual(store.verdicts.assignment(for: xcode.key)?.task, "Goalong", "Unknown commitments keep every verdict")
        }

        /// D-FR4: the boot clock correction was accepted although the commitment locks failed to save, so a
        /// free window closed under the clock ahead reopened under the corrected time.
        @MainActor func testClockCorrectionWaitsForTheCommitmentLocks() throws {
            let root = try focusRoot("latch")
            let s = FocusStore(directory: root)
            var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
            let start = FocusCalendar.dayInterval("2026-10-06", calendar: calendar)!.start
            var now = start.addingTimeInterval(23 * 3_600 + 55 * 60), uptime = 5_000.0, boot = "before"
            let first = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { boot })
            try first.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .work, target: 60)   // free until 00:05
            // Reboot with the clock 35 min ahead: the window is closed by the wall clock, not latched yet.
            boot = "after"; uptime = 10; now = start.addingTimeInterval(24 * 3_600 + 30 * 60)
            chmod(root.path, 0o500)                                             // the lock cannot be saved
            let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar, continuous: { uptime }, boot: { boot })
            now = start.addingTimeInterval(23 * 3_600 + 58 * 60); uptime += 120; c.refresh()   // set right within the boot window
            chmod(root.path, 0o700)
            XCTAssertTrue(c.retryStorage())
            c.refresh()
            XCTAssertThrowsError(try c.deleteCommitment(period: .init(kind: .day, key: "2026-10-06")),
                                 "The window closed under the clock ahead must stay closed")
            XCTAssertThrowsError(try c.setCommitment(period: .init(kind: .day, key: "2026-10-06"), kind: .work, target: 30))
        }

        /// D-FR5: a failed install showed the system's English text (« Permission denied », « You don’t have… »).
        func testCLIInstallFailureIsInFrench() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("goalong-cli-fr-\(UUID().uuidString)", isDirectory: true)
            let locked = root.appendingPathComponent("locked", isDirectory: true)
            addTeardownBlock { chmod(locked.path, 0o700); try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("App", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Goalong History", isDirectory: false)
            try Data("fixture".utf8).write(to: executable)
            XCTAssertEqual(chmod(executable.path, 0o700), 0)
            XCTAssertEqual(chmod(locked.path, 0o500), 0)

            let outcome = GoalongCLIInstallation.install(linkURL: locked.appendingPathComponent("bin/goalong"), executableURL: executable,
                                                         directoryOnPath: { _ in true }, isDevelopment: false)
            XCTAssertFalse(outcome.succeeded)
            let text = outcome.message.replacingOccurrences(of: root.path, with: "").lowercased()
            for english in ["permission", "denied", "folder", "file", "couldn"] {
                XCTAssertFalse(text.contains(english), outcome.message)
            }
            XCTAssertTrue(outcome.message.contains("n’a pas été installée"), outcome.message)
        }
    }
#endif
