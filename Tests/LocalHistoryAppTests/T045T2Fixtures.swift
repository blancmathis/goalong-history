#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import Foundation
    import XCTest
    import LocalHistoryCore
    @testable import LocalHistoryApp

    /// Shared fixtures of the T-045 T2 tests. Every date comes from `Calendar.current` components, so the
    /// expected values hold in any time zone (checked under Europe/Paris and Asia/Tokyo).
    enum T045T2Fixtures {
        static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
            Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }

        static let mac = AppleScreenTimeDevice(id: "mac-1", name: "Studio", kind: .mac)
        static let phone = AppleScreenTimeDevice(id: "phone-1", name: "Pocket", kind: .iPhone)

        static func provenance(api: String = "Apple DeviceActivityData.activityData") -> AppleScreenTimeProvenance {
            AppleScreenTimeProvenance(
                api: api, collectorBundleIdentifier: "test", collectorVersion: "1", collectorPlatform: "test",
                authorization: .unknown, fetchPolicy: .live, euCustomerRequirementAcknowledged: false)
        }

        /// Mac: 3 600 s (Xcode 2 400, Notes 1 200.5). iPhone: 5 400 s (Safari 3 000, Mail 2 200). Total 9 000 s.
        static func storedExport(day: Date, api: String = "Apple DeviceActivityData.activityData") -> AppleScreenTimeStoredExport {
            let start = Calendar.current.startOfDay(for: day)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            let macStart = start.addingTimeInterval(9 * 3600)
            let phoneStart = start.addingTimeInterval(11 * 3600)
            func app(_ bundle: String, _ name: String, _ seconds: TimeInterval) -> AppleScreenTimeApplicationUsage {
                AppleScreenTimeApplicationUsage(bundleIdentifier: bundle, displayName: name, duration: seconds)
            }
            return AppleScreenTimeStoredExport(
                importedAt: start.addingTimeInterval(20 * 3600),
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: start.addingTimeInterval(21 * 3600),
                    requestedStart: start, requestedEnd: end, requestedScope: .allDevices,
                    provenance: provenance(api: api),
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac, lastUpdatedAt: macStart.addingTimeInterval(3600),
                            segments: [
                                AppleScreenTimeSegment(
                                    start: macStart, end: macStart.addingTimeInterval(3600), totalScreenOnDuration: 3600,
                                    applications: [
                                        app("com.example.xcode", "Xcode", 2400), app("com.example.notes", "Notes", 1200.5),
                                    ])
                            ]),
                        AppleScreenTimeDeviceReport(
                            device: phone, lastUpdatedAt: phoneStart.addingTimeInterval(5400),
                            segments: [
                                AppleScreenTimeSegment(
                                    start: phoneStart, end: phoneStart.addingTimeInterval(5400), totalScreenOnDuration: 5400,
                                    applications: [
                                        app("com.example.safari", "Safari", 3000), app("com.example.mail", "Mail", 2200),
                                    ])
                            ]),
                    ])
            )
        }

        static func summary(day: Date, api: String = "Apple DeviceActivityData.activityData") -> AppleScreenTimeDaySummary {
            let start = Calendar.current.startOfDay(for: day)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            return AppleScreenTimeAnalyzer.summary(
                from: storedExport(day: day, api: api), interval: DateInterval(start: start, end: end), scope: .allDevices)!
        }

        static func analysis(
            day: Date, headline: String = "Fixture", activeSeconds: Int = 0, workSeconds: Int = 0,
            applications: [ActivityApplicationSummary] = [], focusBlocks: [ActivityFocusBlock] = [],
            sourceEvents: Int = 0, privateMinutes: Int = 0
        ) -> ActivityDayAnalysis {
            let start = Calendar.current.startOfDay(for: day)
            return ActivityDayAnalysis(
                dayStart: start, dayEnd: Calendar.current.date(byAdding: .day, value: 1, to: start)!,
                generatedAt: start.addingTimeInterval(7200), headline: headline,
                activeSeconds: activeSeconds, workSeconds: workSeconds, focusBlocks: focusBlocks, sites: [],
                applications: applications, requests: [], contextHighlights: [],
                coverage: ActivityAnalysisCoverage(
                    sourceEventCount: sourceEvents, representativeMinuteCount: 0, privateMinuteCount: privateMinutes,
                    semanticSnapshotCount: 0, semanticContextEnabledInData: false, sourceFirstSequence: nil,
                    sourceLastSequence: nil, sourceLastEventHash: nil),
                agentMarkdown: "", estimatedAgentTokens: 0)
        }

        static func counts(
            agentCaptures: Int = 0, agentMessages: Int = 0, agentToolCalls: Int = 0, agentErrors: Int = 0,
            analyzedAgentCaptures: Int = 0
        ) -> ChatGPTRecapSourceCounts {
            ChatGPTRecapSourceCounts(
                localEvents: 0, activeMinutes: 0, semanticSnapshots: 0, screenTimeDevices: 0, screenTimeApplications: 0,
                agentCaptures: agentCaptures, agentMessages: agentMessages, agentToolCalls: agentToolCalls,
                agentErrors: agentErrors, analyzedAgentCaptures: analyzedAgentCaptures, importedChatMessages: 0,
                computerHistoryEpisodes: nil, computerHistoryResources: nil, workflowSuggestions: nil)
        }

        /// Turns one capability off for the test and restores it afterwards. Only in the throwaway HOME: the shared
        /// consent store lives under the data root.
        static func disableConsent(_ capability: GoalongCapability, in test: XCTestCase) throws {
            let path = AppPaths.applicationSupportDirectory.path
            guard path.hasPrefix("/tmp/goalong-") || path.hasPrefix("/private/tmp/goalong-") else {
                throw XCTSkip("data root \(path) is not a throwaway HOME")
            }
            let store = GoalongCapabilityConsentStore.shared
            let was = store.isEnabled(capability)
            XCTAssertTrue(store.set(capability, enabled: false, surface: .settings))
            test.addTeardownBlock { _ = store.set(capability, enabled: was, surface: .settings) }
        }
    }
#endif
