#if os(macOS)
    import XCTest

    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class ComputerHistoryPublicControlParityTests: XCTestCase {
        func testSettingsDraftPersistsIncludeOnlyScopes() {
            var draft = DashboardSettingsDraft(config: .default)
            draft.includedDomainsText = "work.example.com\nWORK.EXAMPLE.COM\ndocs.example.org"
            draft.includedApplicationsText = "com.apple.TextEdit\ncom.apple.TextEdit"

            let applied = draft.applying(to: .default)

            XCTAssertEqual(applied.includedDomains, ["work.example.com", "docs.example.org"])
            XCTAssertEqual(applied.includedBundleIdentifiers, ["com.apple.TextEdit"])
            XCTAssertTrue(applied.allowsWebsite(host: "docs.work.example.com"))
            XCTAssertFalse(applied.allowsWebsite(host: "outside.example.net"))
            XCTAssertTrue(applied.allowsApplication(bundleIdentifier: "com.apple.textedit"))
            XCTAssertFalse(applied.allowsApplication(bundleIdentifier: "com.apple.finder"))
        }

        func testMenuOffersAllDocumentedBulkClearWindows() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/MenuBarController.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(source.contains("Last 10 minutes…"))
            XCTAssertTrue(source.contains("Last hour…"))
            XCTAssertTrue(source.contains("Last day…"))
            XCTAssertTrue(source.contains("All detailed history…"))
            XCTAssertTrue(source.contains("Date().addingTimeInterval(-24 * 60 * 60)"))
        }

        func testUIOffersExactTimelineItemAndRecentAppSessionDeletion() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let computerHistory = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/ComputerHistoryPage.swift"),
                encoding: .utf8
            )
            let timeline = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/ActivityPageExplorer.swift"),
                encoding: .utf8
            )
            let privacy = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/PrivacyPage.swift"),
                encoding: .utf8
            )
            let activity = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/ActivityPage.swift"),
                encoding: .utf8
            )
            let dashboardModel = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardViewModel.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(computerHistory.contains("Delete this item…"))
            XCTAssertTrue(computerHistory.contains("exact source events"))
            XCTAssertTrue(computerHistory.contains("Reveal source JSONL"))
            XCTAssertTrue(computerHistory.contains("@StateObject private var timelineModel"))
            XCTAssertTrue(timeline.contains("Delete session…"))
            XCTAssertTrue(privacy.contains("Most recent app session"))
            XCTAssertTrue(activity.contains("openSourceJSON: model.revealTodayJSON"))
            XCTAssertTrue(activity.contains("snapshotGeneration: model.snapshotGeneration"))
            XCTAssertTrue(dashboardModel.contains("activateFileViewerSelecting([file])"))
        }

        func testComputerHistoryTimelineBuildsOnlyOncePerSnapshotRevision() {
            let firstBuild = expectation(description: "first timeline build")
            let secondBuild = expectation(description: "second timeline build")
            let lock = NSLock()
            var buildCount = 0
            let model = ComputerHistoryTimelineModel(
                queue: DispatchQueue(label: "computer-history-timeline-test")
            ) { _, _ in
                lock.lock()
                buildCount += 1
                let count = buildCount
                lock.unlock()
                if count == 1 { firstBuild.fulfill() }
                if count == 2 { secondBuild.fulfill() }
                return []
            }

            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 1)
            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 1)
            wait(for: [firstBuild], timeout: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            lock.lock()
            XCTAssertEqual(buildCount, 1)
            lock.unlock()
            XCTAssertFalse(model.isLoading)

            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            lock.lock()
            XCTAssertEqual(buildCount, 1)
            lock.unlock()

            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 2)
            wait(for: [secondBuild], timeout: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            lock.lock()
            XCTAssertEqual(buildCount, 2)
            lock.unlock()
        }

        func testComputerHistoryTimelineCoalescesRapidSnapshotRevisions() {
            let build = expectation(description: "latest timeline build")
            let lock = NSLock()
            var buildCount = 0
            let model = ComputerHistoryTimelineModel(
                queue: DispatchQueue(label: "computer-history-timeline-coalescing-test")
            ) { _, _ in
                lock.lock()
                buildCount += 1
                lock.unlock()
                build.fulfill()
                return []
            }

            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 1)
            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 2)
            wait(for: [build], timeout: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            lock.lock()
            XCTAssertEqual(buildCount, 1)
            lock.unlock()
            XCTAssertFalse(model.isLoading)
        }

        func testComputerHistoryTimelineClearCancelsPendingBuild() {
            let build = expectation(description: "cancelled timeline build")
            build.isInverted = true
            let model = ComputerHistoryTimelineModel(
                queue: DispatchQueue(label: "computer-history-timeline-cancel-test")
            ) { _, _ in
                build.fulfill()
                return []
            }

            model.refresh(sessions: [], day: Date(timeIntervalSince1970: 0), revision: 1)
            model.clear()
            wait(for: [build], timeout: 0.15)

            XCTAssertTrue(model.groups.isEmpty)
            XCTAssertFalse(model.isLoading)
        }

        func testComputerHistoryGroupsSessionsIntoLatestFirstQuarterHours() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let textEdit = makeSession(
                id: "textedit",
                start: date(hour: 10, minute: 7, day: day, calendar: calendar),
                end: date(hour: 10, minute: 20, day: day, calendar: calendar),
                appName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                eventCount: 8,
                inputEventCount: 5
            )
            let chrome = makeSession(
                id: "chrome",
                start: date(hour: 10, minute: 17, day: day, calendar: calendar),
                end: date(hour: 10, minute: 26, day: day, calendar: calendar),
                appName: "Chrome",
                bundleIdentifier: "com.google.Chrome",
                eventCount: 11,
                inputEventCount: 7
            )
            let codex = makeSession(
                id: "codex",
                start: date(hour: 10, minute: 31, day: day, calendar: calendar),
                end: date(hour: 10, minute: 35, day: day, calendar: calendar),
                appName: "Codex",
                bundleIdentifier: "com.openai.codex",
                eventCount: 4,
                inputEventCount: 2
            )

            let groups = ComputerHistoryQuarterHourGroup.build(
                sessions: [textEdit, chrome, codex],
                day: day,
                calendar: calendar
            )

            XCTAssertEqual(groups.count, 3)
            XCTAssertEqual(
                groups.map { calendar.component(.minute, from: $0.start) },
                [30, 15, 0]
            )
            XCTAssertEqual(groups[0].apps.map(\.name), ["Codex"])
            XCTAssertEqual(Set(groups[1].apps.map(\.name)), ["Chrome", "TextEdit"])
            XCTAssertEqual(groups[1].appChangeCount, 1)
            XCTAssertEqual(groups[1].recordedEventCount, 11)
            XCTAssertEqual(groups[1].inputEventCount, 7)
        }

        func testComputerHistoryUsesUnionDurationAndSplitsBoundarySessions() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let first = makeSession(
                id: "first",
                start: date(hour: 10, minute: 7, day: day, calendar: calendar),
                end: date(hour: 10, minute: 20, day: day, calendar: calendar),
                appName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit"
            )
            let overlapping = makeSession(
                id: "overlapping",
                start: date(hour: 10, minute: 17, day: day, calendar: calendar),
                end: date(hour: 10, minute: 26, day: day, calendar: calendar),
                appName: "Chrome",
                bundleIdentifier: "com.google.Chrome"
            )

            let groups = ComputerHistoryQuarterHourGroup.build(
                sessions: [first, overlapping],
                day: day,
                calendar: calendar
            )
            let tenFifteen = try XCTUnwrap(
                groups.first { calendar.component(.minute, from: $0.start) == 15 }
            )
            let tenOClock = try XCTUnwrap(
                groups.first { calendar.component(.minute, from: $0.start) == 0 }
            )

            XCTAssertEqual(tenOClock.activeSeconds, 8 * 60, accuracy: 0.01)
            XCTAssertEqual(tenFifteen.activeSeconds, 11.5 * 60, accuracy: 0.01)
            XCTAssertEqual(tenFifteen.sessions.count, 2)
            XCTAssertEqual(
                tenFifteen.apps.reduce(0) { $0 + $1.activeSeconds },
                tenFifteen.activeSeconds,
                accuracy: 0.01
            )
            XCTAssertLessThanOrEqual(tenFifteen.activeSeconds, 15 * 60)
        }

        func testComputerHistoryQuarterHourIndexIsBoundedToOneDay() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let sessions = (0 ..< 1_440).map { minute in
                let start = calendar.date(byAdding: .minute, value: minute, to: day) ?? day
                return makeSession(
                    id: "session-\(minute)",
                    start: start,
                    end: start,
                    appName: minute.isMultiple(of: 2) ? "Codex" : "TextEdit",
                    bundleIdentifier: minute.isMultiple(of: 2)
                        ? "com.openai.codex"
                        : "com.apple.TextEdit"
                )
            }

            let groups = ComputerHistoryQuarterHourGroup.build(
                sessions: sessions,
                day: day,
                calendar: calendar
            )

            XCTAssertEqual(groups.count, 96)
            XCTAssertTrue(groups.allSatisfy { $0.activeSeconds <= 15 * 60 })
        }

        func testComputerHistoryCompressesConsecutiveDetailsIntoAppTransitions() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let chromeSessions = (16 ... 18).map { minute in
                makeSession(
                    id: "chrome-\(minute)",
                    start: date(hour: 10, minute: minute, day: day, calendar: calendar),
                    end: date(hour: 10, minute: minute, day: day, calendar: calendar),
                    appName: "Chrome",
                    bundleIdentifier: "com.google.Chrome"
                )
            }
            let textEdit = makeSession(
                id: "textedit",
                start: date(hour: 10, minute: 19, day: day, calendar: calendar),
                end: date(hour: 10, minute: 20, day: day, calendar: calendar),
                appName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit"
            )

            let group = try XCTUnwrap(
                ComputerHistoryQuarterHourGroup.build(
                    sessions: chromeSessions + [textEdit],
                    day: day,
                    calendar: calendar
                ).first
            )

            XCTAssertEqual(group.sessions.count, 2)
            XCTAssertEqual(group.sessions[0].appName, "Chrome")
            XCTAssertEqual(group.sessions[0].sourceSessionCount, 3)
            XCTAssertEqual(group.sessions[1].appName, "TextEdit")
            XCTAssertEqual(group.appChangeCount, 1)
        }

        private func makeSession(
            id: String,
            start: Date,
            end: Date,
            appName: String,
            bundleIdentifier: String?,
            eventCount: Int = 1,
            inputEventCount: Int = 0
        ) -> ActivitySession {
            ActivitySession(
                id: id,
                start: start,
                end: end,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: "Document",
                host: nil,
                category: "productivity",
                isWork: true,
                confidence: 1,
                suppressionReason: nil,
                eventCount: eventCount,
                inputEventCount: inputEventCount,
                softwareAttributedEventCount: 0,
                kindCounts: [:],
                latestMessage: nil
            )
        }

        private func date(
            hour: Int,
            minute: Int,
            day: Date,
            calendar: Calendar
        ) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
    }
#endif
