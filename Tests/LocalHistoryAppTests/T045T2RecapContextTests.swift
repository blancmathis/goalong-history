#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    /// T-045 T2: the pure parts of the daily recap context (day overview, device scope, agent metrics).
    final class T045T2RecapContextTests: XCTestCase {
        private let day = T045T2Fixtures.date(2026, 3, 10)

        private func context(
            activity: ActivityDayAnalysis, screenTime: AppleScreenTimeDaySummary? = nil,
            agents: AgentActivityOverview? = nil
        ) -> ChatGPTRecapContext {
            ChatGPTRecapContext(
                day: day, activity: activity, computerHistory: nil, screenTime: screenTime,
                agentActivity: agents ?? AgentActivityOverview(day: day), importedChats: [],
                localJournalSourceAbsent: false, renderedData: "", sourceCounts: T045T2Fixtures.counts(), digest: "")
        }

        func testDayOverviewOrdersComputerApplicationsAndKeepsTwelve() {
            func summary(_ name: String, _ seconds: Int) -> ActivityApplicationSummary {
                ActivityApplicationSummary(name: name, bundleIdentifier: nil, activeSeconds: seconds, focusBlockCount: 0)
            }
            var apps = [summary("zulu", 500), summary("Alpha", 500), summary("mid", 400)]
            apps += (1...12).map { summary(String(format: "Low%02d", $0), 100 - $0) }
            let overview = ChatGPTRecapContextBuilder.dayOverview(
                from: context(activity: T045T2Fixtures.analysis(day: day, activeSeconds: 4000, workSeconds: 1500, applications: apps,
                    sourceEvents: 42, privateMinutes: 3)))
            XCTAssertEqual(overview.day, day)
            XCTAssertEqual(overview.activeSeconds, 4000)
            XCTAssertEqual(overview.workSeconds, 1500)
            XCTAssertEqual(overview.sourceEventCount, 42)
            XCTAssertEqual(overview.privateMinutes, 3)
            XCTAssertEqual(overview.computerApplications.count, 12)
            // Equal seconds: case-insensitive name order puts "Alpha" before "zulu".
            XCTAssertEqual(
                overview.computerApplications.map(\.name),
                ["Alpha", "zulu", "mid"] + (1...9).map { String(format: "Low%02d", $0) })
            XCTAssertEqual(overview.computerApplications.map(\.seconds), [500, 500, 400] + (1...9).map { 100 - $0 })
            XCTAssertEqual(overview.computerApplications[0].id, "name:Alpha")
            XCTAssertNil(overview.computerApplications[0].detail)
            XCTAssertTrue(overview.hasMeaningfulData)
        }

        func testDayOverviewCountsFocusBlocksAndAgentMetrics() {
            let block = ActivityFocusBlock(
                id: "b1", start: day, end: day.addingTimeInterval(600), activeSeconds: 600, title: "t", applications: [],
                hosts: [], pageTitles: [], URLs: [], category: nil, isWork: nil, eventCount: 1, inputEventCount: 0,
                contextSnippets: [], requestSnippets: [])
            let agents = AgentActivityOverview(
                day: day, sessionCount: 4, analyzedSessionCount: 3, messageCount: 20, toolCallCount: 7, errorCount: 2)
            let overview = ChatGPTRecapContextBuilder.dayOverview(
                from: context(activity: T045T2Fixtures.analysis(day: day, focusBlocks: [block, block]), agents: agents))
            XCTAssertEqual(overview.focusBlockCount, 2)
            XCTAssertEqual(overview.agentSessions, 4)
            XCTAssertEqual(overview.analyzedAgentSessions, 3)
            XCTAssertEqual(overview.agentMessages, 20)
            XCTAssertEqual(overview.agentToolCalls, 7)
            XCTAssertEqual(overview.agentErrors, 2)
            XCTAssertTrue(overview.computerApplications.isEmpty)
            XCTAssertEqual(overview.screenTimeSeconds, 0)
            XCTAssertTrue(overview.screenTimeDevices.isEmpty)
            XCTAssertTrue(overview.hasMeaningfulData, "agent sessions alone count as data")
        }

        func testDayOverviewMapsScreenTimeDevicesAndApplications() {
            let overview = ChatGPTRecapContextBuilder.dayOverview(
                from: context(activity: T045T2Fixtures.analysis(day: day), screenTime: T045T2Fixtures.summary(day: day)))
            XCTAssertEqual(overview.screenTimeSeconds, 9000)
            // The iPhone (5 400 s) comes before the Mac (3 600 s); the detail is the device kind.
            XCTAssertEqual(overview.screenTimeDevices.map(\.name), ["Pocket", "Studio"])
            XCTAssertEqual(overview.screenTimeDevices.map(\.seconds), [5400, 3600])
            XCTAssertEqual(overview.screenTimeDevices.map(\.detail), ["iPhone", "Mac"])
            XCTAssertEqual(overview.screenTimeDevices.map(\.id), ["phone-1", "mac-1"])
            XCTAssertEqual(overview.screenTimeApplications.map(\.name), ["Safari", "Xcode", "Mail", "Notes"])
            // 1 200.5 s rounds half away from zero.
            XCTAssertEqual(overview.screenTimeApplications.map(\.seconds), [3000, 2400, 2200, 1201])
            XCTAssertTrue(overview.screenTimeApplications.allSatisfy { $0.detail == nil })
            XCTAssertTrue(overview.hasMeaningfulData, "Screen Time alone counts as data")
        }

        func testDayOverviewClampsNegativeValuesToZero() {
            let negative = ActivityApplicationSummary(name: "Neg", bundleIdentifier: "x.neg", activeSeconds: -50, focusBlockCount: 0)
            let agents = AgentActivityOverview(
                day: day, sessionCount: -1, analyzedSessionCount: -2, messageCount: -3, toolCallCount: -4, errorCount: -5)
            let overview = ChatGPTRecapContextBuilder.dayOverview(
                from: context(
                    activity: T045T2Fixtures.analysis(
                        day: day, activeSeconds: -10, workSeconds: -5, applications: [negative], sourceEvents: -7, privateMinutes: -1),
                    agents: agents))
            XCTAssertEqual(overview.activeSeconds, 0)
            XCTAssertEqual(overview.workSeconds, 0)
            XCTAssertEqual(overview.sourceEventCount, 0)
            XCTAssertEqual(overview.privateMinutes, 0)
            XCTAssertEqual(overview.computerApplications.map(\.seconds), [0])
            XCTAssertEqual(overview.computerApplications.map(\.id), ["x.neg"])
            XCTAssertEqual([overview.agentSessions, overview.analyzedAgentSessions, overview.agentMessages,
                overview.agentToolCalls, overview.agentErrors], [0, 0, 0, 0, 0])
            XCTAssertFalse(overview.hasMeaningfulData)
        }

        func testReplacingAgentMetricsOverridesOnlyTheAgentFields() {
            let base = ChatGPTRecapContextBuilder.dayOverview(
                from: context(
                    activity: T045T2Fixtures.analysis(day: day, activeSeconds: 4000, workSeconds: 1500, sourceEvents: 42, privateMinutes: 3),
                    screenTime: T045T2Fixtures.summary(day: day),
                    agents: AgentActivityOverview(day: day, sessionCount: 1, analyzedSessionCount: 1, messageCount: 1, toolCallCount: 1, errorCount: 1)))
            let replaced = base.replacingAgentMetrics(
                with: T045T2Fixtures.counts(
                    agentCaptures: 9, agentMessages: 40, agentToolCalls: 11, agentErrors: -3, analyzedAgentCaptures: 5))
            XCTAssertEqual(replaced.agentSessions, 9)
            XCTAssertEqual(replaced.agentMessages, 40)
            XCTAssertEqual(replaced.agentToolCalls, 11)
            XCTAssertEqual(replaced.agentErrors, 0, "a negative count is clamped")
            XCTAssertEqual(replaced.analyzedAgentSessions, 5)
            XCTAssertEqual(replaced.day, base.day)
            XCTAssertEqual(replaced.activeSeconds, 4000)
            XCTAssertEqual(replaced.workSeconds, 1500)
            XCTAssertEqual(replaced.sourceEventCount, 42)
            XCTAssertEqual(replaced.privateMinutes, 3)
            XCTAssertEqual(replaced.screenTimeSeconds, 9000)
            XCTAssertEqual(replaced.screenTimeDevices, base.screenTimeDevices)
            XCTAssertEqual(replaced.screenTimeApplications, base.screenTimeApplications)
        }

        func testScopedExportFiltersReportsByScopeAndKeepsTheEnvelope() throws {
            let stored = T045T2Fixtures.storedExport(day: day)
            func ids(_ scope: AppleScreenTimeScope, mac: String = "mac-1") -> [String]? {
                ChatGPTRecapContextBuilder.scopedExportForTesting(stored, scope: scope, currentMacID: mac)?
                    .envelope.reports.map(\.device.id)
            }
            // The stored export keeps its reports sorted by device id: phone-1 before mac-1.
            XCTAssertEqual(ids(.allDevices), ["phone-1", "mac-1"])
            XCTAssertEqual(ids(.macOnly), ["mac-1"])
            XCTAssertEqual(ids(.macOnly, mac: "phone-1"), ["phone-1"], "the Mac is matched by id, not by kind")
            XCTAssertNil(ids(.macOnly, mac: "other"))
            XCTAssertEqual(ids(AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: ["phone-1"])), ["phone-1"])
            XCTAssertEqual(ids(AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: ["phone-1", "mac-1"])), ["phone-1", "mac-1"])
            XCTAssertNil(ids(AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: ["unknown"])))
            XCTAssertNil(ids(AppleScreenTimeScope(mode: .selectedDevices)), "no selected device: nothing is shared")

            let scoped = try XCTUnwrap(ChatGPTRecapContextBuilder.scopedExportForTesting(stored, scope: .macOnly, currentMacID: "mac-1"))
            XCTAssertEqual(scoped.envelope.requestedScope, .macOnly, "the envelope records the scope applied")
            XCTAssertEqual(scoped.importedAt, stored.importedAt)
            XCTAssertEqual(scoped.verification, stored.verification)
            XCTAssertEqual(scoped.envelope.createdAt, stored.envelope.createdAt)
            XCTAssertEqual(scoped.envelope.requestedStart, stored.envelope.requestedStart)
            XCTAssertEqual(scoped.envelope.requestedEnd, stored.envelope.requestedEnd)
            XCTAssertEqual(scoped.envelope.provenance, stored.envelope.provenance)
            XCTAssertEqual(scoped.envelope.reports, stored.envelope.reports.filter { $0.device.id == "mac-1" })
        }
    }
#endif
