#if os(macOS)
    import AgentActivity
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
            XCTAssertTrue(computerHistory.contains("Source data"))
            XCTAssertTrue(computerHistory.contains("Stored on this Mac"))
            XCTAssertTrue(computerHistory.contains("Retained Computer History"))
            XCTAssertTrue(computerHistory.contains("Detailed timeline no longer available"))
            XCTAssertTrue(computerHistory.contains("Other days are unchanged"))
            XCTAssertTrue(computerHistory.contains(".disabled(!canRevealSourceData)"))
            XCTAssertTrue(computerHistory.contains("@StateObject private var timelineModel"))
            XCTAssertTrue(timeline.contains("Delete session…"))
            XCTAssertTrue(privacy.contains("Most recent app session"))
            XCTAssertTrue(activity.contains("openSourceJSON: model.revealTodayJSON"))
            XCTAssertTrue(activity.contains("snapshotGeneration: model.snapshotGeneration"))
            XCTAssertTrue(activity.contains("isSnapshotLoading: model.isRefreshing"))
            XCTAssertTrue(computerHistory.contains(".task(id: timelineRefreshID)"))
            XCTAssertTrue(computerHistory.contains("isSnapshotLoading || timelineModel.isLoading"))
            XCTAssertTrue(dashboardModel.contains("activateFileViewerSelecting([file])"))
        }

        func testSidebarKeepsThreePrimaryDestinationsAndOpensCLIFromSettings() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardRootView.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(
                source.contains(
                    "private let primarySections: [DashboardSection] = [.overview, .history, .settings]"
                )
            )
            XCTAssertTrue(source.contains("case .history:\n                UnifiedHistoryPage(model: model)"))
            XCTAssertTrue(source.contains("case .cli:\n                CLIHelpPage()"))
            XCTAssertFalse(source.contains("analysisSourceSections"))
            XCTAssertFalse(source.contains("utilitySections"))
            XCTAssertFalse(source.contains("Menu {"))
            XCTAssertFalse(source.contains("\"More\""))

            let history = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/UnifiedHistoryPage.swift"),
                encoding: .utf8
            )
            XCTAssertFalse(history.contains("case all"))
            XCTAssertTrue(history.contains("case computer"))
            XCTAssertTrue(history.contains("case screenTime"))
            XCTAssertTrue(history.contains("case conversations"))
            XCTAssertTrue(history.contains("@State private var source: HistorySource = .computer"))
            XCTAssertTrue(history.contains("presentation: .history"))
            XCTAssertTrue(history.contains("Label(\"Share day\", systemImage: \"square.and.arrow.up\")"))

            let settings = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/SettingsPage.swift"),
                encoding: .utf8
            )
            XCTAssertTrue(settings.contains("case .home:"))
            XCTAssertTrue(settings.contains("title: \"Goalong CLI\""))
            XCTAssertTrue(settings.contains("model.selectSection(.cli)"))
            XCTAssertTrue(settings.contains("title: \"Recording\""))
            XCTAssertTrue(settings.contains("title: \"Sources\""))
            XCTAssertTrue(settings.contains("model.selectSection(.agentActivity)"))
            XCTAssertTrue(settings.contains("title: \"Privacy & permissions\""))
            XCTAssertTrue(settings.contains("title: \"Advanced\""))

            let agentActivity = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/AgentActivity/AgentActivityPage.swift"),
                encoding: .utf8
            )
            XCTAssertTrue(agentActivity.contains("case history"))
            XCTAssertTrue(agentActivity.contains("conversationHistoryList"))
            XCTAssertFalse(agentActivity.contains("Text(\"Conversations\")"))
            XCTAssertTrue(agentActivity.contains("Original sources"))
            XCTAssertTrue(agentActivity.contains("final repl"))
            XCTAssertTrue(agentActivity.contains("availableProviders.count > 1"))

            let components = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardComponents.swift"),
                encoding: .utf8
            )
            XCTAssertTrue(components.contains("Button(\"Today\")"))
            XCTAssertTrue(components.contains(".help(\"Return to today\")"))
        }

        func testCLIPageProvidesOneCompleteSafeAgentBrief() {
            let instructions = CLIHelpPage.agentInstructions

            XCTAssertTrue(instructions.contains("goalong status"))
            XCTAssertTrue(instructions.contains("goalong days"))
            XCTAssertTrue(instructions.contains("goalong help"))
            XCTAssertTrue(instructions.contains("goalong computer-history DAY"))
            XCTAssertTrue(instructions.contains("goalong screen-time DAY"))
            XCTAssertTrue(instructions.contains("goalong ai-conversations DAY"))
            XCTAssertTrue(instructions.contains("untrusted observed data"))
            XCTAssertTrue(instructions.contains("Missing or inaccessible data means unknown coverage"))
            XCTAssertTrue(instructions.contains("Do not modify Goalong settings"))
            XCTAssertTrue(instructions.contains("$HOME/.local/bin/goalong"))
        }

        func testScreenTimeRefreshUpdatesBothSourcesAndLongListsStayLazy() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let history = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/UnifiedHistoryPage.swift"),
                encoding: .utf8
            )
            let screenTime = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent(
                        "Sources/LocalHistoryApp/AppleScreenTime/GoalongScreenTimePage.swift"
                    ),
                encoding: .utf8
            )
            let overview = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/OverviewPage.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(
                history.contains(
                    "case .screenTime:\n                model.refreshEverything()\n                screenTime.refresh()"
                )
            )
            XCTAssertGreaterThanOrEqual(
                screenTime.components(separatedBy: "LazyVStack(spacing: 0)").count - 1,
                2
            )
            XCTAssertTrue(screenTime.contains("Where your screen time went"))
            XCTAssertTrue(screenTime.contains("Group sites by browser"))
            XCTAssertTrue(screenTime.contains("Same usage and total; only the grouping changes."))
            XCTAssertTrue(screenTime.contains("isOn: groupsSitesByBrowser"))
            XCTAssertFalse(screenTime.contains("Picker(\"Screen Time breakdown\""))
            XCTAssertTrue(screenTime.contains("DisclosureGroup"))
            XCTAssertTrue(screenTime.contains("Show \\(hiddenCount) more"))
            XCTAssertFalse(screenTime.contains("Apps & website breakdown"))
            XCTAssertFalse(screenTime.contains("Inside browser apps · This Mac only · never added"))
            XCTAssertFalse(screenTime.contains("with input"))
            XCTAssertFalse(overview.contains("with input"))
            XCTAssertTrue(overview.contains("Where your screen time went"))
            XCTAssertTrue(overview.contains("Group sites by browser"))
            XCTAssertTrue(overview.contains("Same usage and total; only the grouping changes."))
            XCTAssertTrue(overview.contains("isOn: groupsSitesByBrowser"))
            XCTAssertFalse(overview.contains("Picker(\"Screen Time breakdown\""))
            XCTAssertTrue(overview.contains("DisclosureGroup"))
            XCTAssertTrue(overview.contains("Show \\(hiddenCount) more"))
            XCTAssertFalse(overview.contains("Website breakdown"))
            XCTAssertFalse(overview.contains("Inside browser apps · This Mac only · never added"))
            XCTAssertTrue(overview.contains("Include login and lock-screen time"))
            XCTAssertTrue(
                overview.contains(
                    "Apple may record these periods while the device is not actively being used."
                )
            )
            XCTAssertFalse(overview.contains("Show all apps"))
            XCTAssertFalse(overview.contains("combinedAppUsage.prefix"))
        }

        func testAIConversationListOrdersNewestFirstAndCompactsLongFallbackTitles() {
            let older = makeAgentConversation(
                id: "older",
                title: "Older conversation",
                startedAt: Date(timeIntervalSince1970: 200),
                activityAt: Date(timeIntervalSince1970: 100)
            )
            let newer = makeAgentConversation(
                id: "newer",
                title: "Newer conversation",
                startedAt: Date(timeIntervalSince1970: 50),
                activityAt: Date(timeIntervalSince1970: 300)
            )

            let ordered = AgentConversationListPresentation.newestFirst([older, newer])

            XCTAssertEqual(ordered.map(\.summary.title), ["Newer conversation", "Older conversation"])
            XCTAssertEqual(AgentConversationListPresentation.date(for: newer), Date(timeIntervalSince1970: 300))
            XCTAssertEqual(
                AgentConversationListPresentation.compactTitle(
                    "A deliberately long fallback title that should remain understandable",
                    maximumCharacters: 24
                ),
                "A deliberately long fal…"
            )
            var lightweight = newer
            lightweight.summary.visibleMessages = []
            lightweight.summary.userMessageCount = 7
            lightweight.summary.assistantMessageCount = 5
            XCTAssertEqual(
                AgentConversationListPresentation.visibleMessageCounts(for: lightweight).prompts,
                7
            )
            XCTAssertEqual(
                AgentConversationListPresentation.visibleMessageCounts(for: lightweight).replies,
                5
            )
        }

        private func makeAgentConversation(
            id: String,
            title: String,
            startedAt: Date,
            activityAt: Date
        ) -> AgentCaptureRecord {
            let reference = AgentSourceReference(kind: .file, path: "/tmp/\(id).jsonl")
            let entry = AgentSourceIndexEntry(
                id: id,
                stableConversationID: id,
                watchedFolderID: "folder-\(id)",
                watchedFolderName: "Codex",
                provider: .codex,
                reference: reference,
                relativePath: "\(id).jsonl",
                sourceCreatedAt: startedAt,
                sourceModifiedAt: activityAt,
                conversationStartedAt: startedAt,
                conversationEndedAt: activityAt,
                firstIndexedAt: startedAt,
                lastObservedAt: activityAt,
                byteCount: 1,
                sha256: String(repeating: "a", count: 64)
            )
            return AgentCaptureRecord(
                index: entry,
                summary: AgentDocumentSummary(title: title, startedAt: startedAt, endedAt: activityAt)
            )
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

        func testComputerHistoryTimelineRebuildsWhenSessionsArriveInSameSnapshotGeneration() {
            let firstBuild = expectation(description: "empty timeline build")
            let secondBuild = expectation(description: "populated timeline build")
            let lock = NSLock()
            var observedSessionCounts: [Int] = []
            let model = ComputerHistoryTimelineModel(
                queue: DispatchQueue(label: "computer-history-timeline-session-count-test")
            ) { sessions, _ in
                lock.lock()
                observedSessionCounts.append(sessions.count)
                let count = observedSessionCounts.count
                lock.unlock()
                if count == 1 { firstBuild.fulfill() }
                if count == 2 { secondBuild.fulfill() }
                return []
            }
            let day = Date(timeIntervalSince1970: 0)

            model.refresh(sessions: [], day: day, revision: 1)
            wait(for: [firstBuild], timeout: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            model.refresh(
                sessions: [
                    makeSession(
                        id: "late-session",
                        start: day,
                        end: day.addingTimeInterval(60),
                        appName: "TextEdit",
                        bundleIdentifier: "com.apple.TextEdit"
                    )
                ],
                day: day,
                revision: 1
            )
            wait(for: [secondBuild], timeout: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            lock.lock()
            XCTAssertEqual(observedSessionCounts, [0, 1])
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

        func testComputerHistoryGroupsSessionsIntoLatestFirstTenMinuteWindows() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let textEdit = makeSession(
                id: "textedit",
                start: date(hour: 10, minute: 2, day: day, calendar: calendar),
                end: date(hour: 10, minute: 8, day: day, calendar: calendar),
                appName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                eventCount: 8,
                inputEventCount: 5
            )
            let chrome = makeSession(
                id: "chrome",
                start: date(hour: 10, minute: 11, day: day, calendar: calendar),
                end: date(hour: 10, minute: 15, day: day, calendar: calendar),
                appName: "Chrome",
                bundleIdentifier: "com.google.Chrome",
                eventCount: 11,
                inputEventCount: 7
            )
            let codex = makeSession(
                id: "codex",
                start: date(hour: 10, minute: 21, day: day, calendar: calendar),
                end: date(hour: 10, minute: 25, day: day, calendar: calendar),
                appName: "Codex",
                bundleIdentifier: "com.openai.codex",
                eventCount: 4,
                inputEventCount: 2
            )

            let groups = ComputerHistoryTenMinuteGroup.build(
                sessions: [textEdit, chrome, codex],
                day: day,
                calendar: calendar
            )

            XCTAssertEqual(groups.count, 3)
            XCTAssertEqual(
                groups.map { calendar.component(.minute, from: $0.start) },
                [20, 10, 0]
            )
            XCTAssertEqual(groups[0].apps.map(\.name), ["Codex"])
            XCTAssertEqual(groups[1].apps.map(\.name), ["Chrome"])
            XCTAssertEqual(groups[1].appChangeCount, 0)
            XCTAssertEqual(groups[1].recordedEventCount, 11)
            XCTAssertEqual(groups[1].inputEventCount, 7)
        }

        func testComputerHistorySortsAppsByUsageThenName() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let sessions = [
                makeSession(
                    id: "alpha",
                    start: date(hour: 10, minute: 0, day: day, calendar: calendar),
                    end: date(hour: 10, minute: 1, day: day, calendar: calendar),
                    appName: "Alpha",
                    bundleIdentifier: "com.example.alpha"
                ),
                makeSession(
                    id: "bravo",
                    start: date(hour: 10, minute: 2, day: day, calendar: calendar),
                    end: date(hour: 10, minute: 6, day: day, calendar: calendar),
                    appName: "Bravo",
                    bundleIdentifier: "com.example.bravo"
                ),
                makeSession(
                    id: "charlie",
                    start: date(hour: 10, minute: 7, day: day, calendar: calendar),
                    end: date(hour: 10, minute: 8, day: day, calendar: calendar),
                    appName: "Charlie",
                    bundleIdentifier: "com.example.charlie"
                ),
            ]

            let group = try XCTUnwrap(
                ComputerHistoryTenMinuteGroup.build(
                    sessions: sessions,
                    day: day,
                    calendar: calendar
                ).first
            )

            XCTAssertEqual(group.apps.map(\.name), ["Bravo", "Alpha", "Charlie"])
            XCTAssertGreaterThan(group.apps[0].activeSeconds, group.apps[1].activeSeconds)
            XCTAssertEqual(group.apps[1].activeSeconds, group.apps[2].activeSeconds)
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

            let groups = ComputerHistoryTenMinuteGroup.build(
                sessions: [first, overlapping],
                day: day,
                calendar: calendar
            )
            let tenTwenty = try XCTUnwrap(
                groups.first { calendar.component(.minute, from: $0.start) == 20 }
            )
            let tenTen = try XCTUnwrap(
                groups.first { calendar.component(.minute, from: $0.start) == 10 }
            )
            let tenOClock = try XCTUnwrap(
                groups.first { calendar.component(.minute, from: $0.start) == 0 }
            )

            XCTAssertEqual(tenOClock.activeSeconds, 3 * 60, accuracy: 0.01)
            XCTAssertEqual(tenTen.activeSeconds, 10 * 60, accuracy: 0.01)
            XCTAssertEqual(tenTwenty.activeSeconds, 6.5 * 60, accuracy: 0.01)
            XCTAssertEqual(tenTen.sessions.count, 2)
            XCTAssertEqual(
                tenTen.apps.reduce(0) { $0 + $1.activeSeconds },
                tenTen.activeSeconds,
                accuracy: 0.01
            )
            XCTAssertLessThanOrEqual(tenTen.activeSeconds, 10 * 60)
        }

        func testComputerHistoryTenMinuteIndexIsBoundedToOneDay() throws {
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

            let groups = ComputerHistoryTenMinuteGroup.build(
                sessions: sessions,
                day: day,
                calendar: calendar
            )

            XCTAssertEqual(groups.count, 144)
            XCTAssertTrue(groups.allSatisfy { $0.activeSeconds <= 10 * 60 })
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
                end: date(hour: 10, minute: 19, day: day, calendar: calendar),
                appName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit"
            )

            let group = try XCTUnwrap(
                ComputerHistoryTenMinuteGroup.build(
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

        func testComputerHistoryPreservesDistinctContextsInsideOneAppTransition() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
            )
            let sessions = [
                makeSession(
                    id: "first-document",
                    start: date(hour: 10, minute: 1, day: day, calendar: calendar),
                    end: date(hour: 10, minute: 2, day: day, calendar: calendar),
                    appName: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    windowTitle: "Plan.md"
                ),
                makeSession(
                    id: "second-document",
                    start: date(hour: 10, minute: 2, day: day, calendar: calendar),
                    end: date(hour: 10, minute: 3, day: day, calendar: calendar),
                    appName: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    windowTitle: "Notes.txt"
                ),
            ]

            let group = try XCTUnwrap(
                ComputerHistoryTenMinuteGroup.build(
                    sessions: sessions,
                    day: day,
                    calendar: calendar
                ).first
            )

            XCTAssertEqual(group.sessions.count, 1)
            XCTAssertEqual(group.sessions[0].contexts, ["Plan.md", "Notes.txt"])
            XCTAssertEqual(group.sessions[0].context, "Plan.md → Notes.txt")
        }

        private func makeSession(
            id: String,
            start: Date,
            end: Date,
            appName: String,
            bundleIdentifier: String?,
            eventCount: Int = 1,
            inputEventCount: Int = 0,
            windowTitle: String = "Document"
        ) -> ActivitySession {
            ActivitySession(
                id: id,
                start: start,
                end: end,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
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
