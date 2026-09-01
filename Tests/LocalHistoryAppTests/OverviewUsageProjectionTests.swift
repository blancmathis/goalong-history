#if os(macOS)
    import AppleScreenTime
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class OverviewUsageProjectionTests: XCTestCase {
        func testDefaultHidesInactiveSystemRowsAndOptInRestoresRawTotalAndList() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let filtered = try summary(
                start: start,
                end: end,
                device: mac,
                total: 2 * 3_600,
                applications: [
                    usage("com.openai.codex", "ChatGPT", 3_600),
                    usage("com.apple.Safari", "Safari", 20 * 60),
                ]
            )
            let allReported = try summary(
                start: start,
                end: end,
                device: mac,
                total: 10 * 3_600,
                applications: [
                    usage("com.apple.loginwindow", "loginwindow", 8 * 3_600),
                    usage("com.openai.codex", "ChatGPT", 3_600),
                    usage("com.apple.Safari", "Safari", 20 * 60),
                ]
            )
            let goalong = [
                trackedApplication(
                    name: "loginwindow",
                    bundleIdentifier: "com.apple.loginwindow",
                    seconds: 60,
                    eventCount: 1
                ),
                trackedApplication(
                    name: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    seconds: 30 * 60,
                    eventCount: 30
                ),
                trackedApplication(
                    name: "Aside",
                    bundleIdentifier: "at.studio.AsideBrowser",
                    seconds: 90 * 60,
                    eventCount: 90
                ),
            ]

            let visibleSummary = try XCTUnwrap(
                OverviewUsageProjection.summary(
                    filtered: filtered,
                    allReported: allReported,
                    includesInactiveSystemTime: false
                )
            )
            XCTAssertEqual(visibleSummary.totalScreenOnDuration, 2 * 3_600, accuracy: 0.001)

            let visible = OverviewUsageProjection.applications(
                filteredSummary: filtered,
                allReportedSummary: allReported,
                goalongUsage: goalong,
                currentMacDeviceID: mac.id,
                includesInactiveSystemTime: false
            )
            XCTAssertEqual(visible.map(\.name), ["Aside", "ChatGPT", "Safari"])
            XCTAssertFalse(visible.contains { $0.name == "loginwindow" })
            XCTAssertEqual(
                visible.first { $0.name == "Safari" }?.displaySeconds ?? -1,
                30 * 60,
                accuracy: 0.001
            )

            let completeSummary = try XCTUnwrap(
                OverviewUsageProjection.summary(
                    filtered: filtered,
                    allReported: allReported,
                    includesInactiveSystemTime: true
                )
            )
            XCTAssertEqual(completeSummary.totalScreenOnDuration, 10 * 3_600, accuracy: 0.001)

            let complete = OverviewUsageProjection.applications(
                filteredSummary: filtered,
                allReportedSummary: allReported,
                goalongUsage: goalong,
                currentMacDeviceID: mac.id,
                includesInactiveSystemTime: true
            )
            XCTAssertEqual(complete.first?.name, "loginwindow")
            XCTAssertEqual(complete.first?.displaySeconds ?? -1, 8 * 3_600, accuracy: 0.001)
            XCTAssertTrue(OverviewUsageProjection.hasHiddenInactiveSystemTime(
                filtered: filtered,
                allReported: allReported
            ))
        }

        func testActiveUseProjectionIsNotCappedAtSixApplications() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let applications = (1 ... 8).map { index in
                usage("com.example.app\(index)", "App \(index)", TimeInterval((9 - index) * 60))
            }
            let report = try summary(
                start: start,
                end: end,
                device: mac,
                total: applications.reduce(0) { $0 + $1.duration },
                applications: applications
            )

            let complete = OverviewUsageProjection.applications(
                filteredSummary: report,
                allReportedSummary: report,
                goalongUsage: [],
                currentMacDeviceID: mac.id,
                includesInactiveSystemTime: false
            )

            XCTAssertEqual(complete.count, 8)
            XCTAssertEqual(complete.map(\.name), (1 ... 8).map { "App \($0)" })
        }

        func testAppleAndGoalongOverlapOnlyOnThisMacWhileRemoteUsageIsAdded() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let iPhone = AppleScreenTimeDevice(id: "phone", name: "iPhone", kind: .iPhone)
            let report = try multiDeviceSummary(
                start: start,
                end: end,
                values: [
                    (mac, [usage("com.example.browser", "Browser", 5 * 60)]),
                    (iPhone, [usage("com.example.browser", "Browser", 10 * 60)]),
                ]
            )
            let local = trackedApplication(
                name: "Browser",
                bundleIdentifier: "com.example.browser",
                seconds: 20 * 60,
                eventCount: 20
            )

            let projected = OverviewUsageProjection.applications(
                filteredSummary: report,
                allReportedSummary: report,
                goalongUsage: [local],
                currentMacDeviceID: mac.id,
                includesInactiveSystemTime: false
            )
            let browser = try XCTUnwrap(projected.first)

            XCTAssertEqual(browser.appleCurrentMacSeconds, 5 * 60, accuracy: 0.001)
            XCTAssertEqual(browser.appleOtherDeviceSeconds, 10 * 60, accuracy: 0.001)
            XCTAssertEqual(browser.goalongSeconds, 20 * 60, accuracy: 0.001)
            XCTAssertEqual(browser.screenTimeSeconds, 15 * 60, accuracy: 0.001)
            XCTAssertEqual(
                browser.displaySeconds,
                30 * 60,
                accuracy: 0.001,
                "Remote Apple usage is distinct, while Apple and Goalong on this Mac overlap."
            )
            XCTAssertNotEqual(browser.displaySeconds, 35 * 60)
            XCTAssertFalse(browser.sourceDetail.contains("+"))
            XCTAssertEqual(
                browser.sourceDetail,
                "Apple 15m · Goalong 20m observed on this Mac"
            )
        }

        func testWebsitesAreFilteredAndSortedForPresentation() {
            let values = [
                trackedWebsite(name: "z.example", seconds: 25),
                trackedWebsite(name: "-", seconds: 500),
                trackedWebsite(name: "beta.example", seconds: 35),
                trackedWebsite(name: "alpha.example", seconds: 25),
            ]

            let result = OverviewUsageProjection.websites(values)

            XCTAssertEqual(result.map(\.name), ["beta.example", "alpha.example", "z.example"])
            XCTAssertEqual(result.map(\.foregroundSeconds), [35, 25, 25])
        }

        func testConciseUsageShowsOnlySixEntriesAtOrAboveFiveMinutes() {
            let applications = [12, 11, 10, 9, 8, 7, 6, 4, 0].enumerated().map { index, minutes in
                DailyAppUsage(
                    id: "app:\(index)",
                    name: "App \(index)",
                    bundleIdentifier: "com.example.app\(index)",
                    appleCurrentMacSeconds: TimeInterval(minutes * 60),
                    appleOtherDeviceSeconds: 0,
                    goalongSeconds: 0
                )
            }
            let websites = [12, 11, 10, 9, 8, 7, 6, 4, 0].enumerated().map { index, minutes in
                trackedWebsite(
                    name: "site-\(index).example",
                    seconds: TimeInterval(minutes * 60)
                )
            }

            let conciseApplications = OverviewUsageProjection.presentedApplications(
                applications,
                showsAll: false
            )
            let conciseWebsites = OverviewUsageProjection.presentedWebsites(
                websites,
                showsAll: false
            )

            XCTAssertEqual(conciseApplications.map(\.name), (0 ..< 6).map { "App \($0)" })
            XCTAssertEqual(
                conciseWebsites.map(\.name),
                (0 ..< 6).map { "site-\($0).example" }
            )
            XCTAssertTrue(conciseApplications.allSatisfy {
                $0.displaySeconds >= OverviewUsageProjection.conciseMinimumDuration
            })
            XCTAssertTrue(conciseWebsites.allSatisfy {
                $0.foregroundSeconds >= OverviewUsageProjection.conciseMinimumDuration
            })
        }

        func testExpandedUsageRestoresEveryPositiveEntryWithoutCreatingZeroMinuteRows() {
            let applications = [8, 4, 1, 0].enumerated().map { index, minutes in
                DailyAppUsage(
                    id: "app:\(index)",
                    name: "App \(index)",
                    bundleIdentifier: "com.example.app\(index)",
                    appleCurrentMacSeconds: TimeInterval(minutes * 60),
                    appleOtherDeviceSeconds: 0,
                    goalongSeconds: 0
                )
            }
            let websites = [8, 4, 1, 0].enumerated().map { index, minutes in
                trackedWebsite(
                    name: "site-\(index).example",
                    seconds: TimeInterval(minutes * 60)
                )
            }

            XCTAssertEqual(
                OverviewUsageProjection.presentedApplications(
                    applications,
                    showsAll: true
                ).map(\.name),
                ["App 0", "App 1", "App 2"]
            )
            XCTAssertEqual(
                OverviewUsageProjection.presentedWebsites(
                    websites,
                    showsAll: true
                ).map(\.name),
                ["site-0.example", "site-1.example", "site-2.example"]
            )
        }

        func testConciseUsageUsesAnExactFiveMinuteBoundary() {
            let below = DailyAppUsage(
                id: "below",
                name: "Below",
                bundleIdentifier: "com.example.below",
                appleCurrentMacSeconds: 299,
                appleOtherDeviceSeconds: 0,
                goalongSeconds: 0
            )
            let boundary = DailyAppUsage(
                id: "boundary",
                name: "Boundary",
                bundleIdentifier: "com.example.boundary",
                appleCurrentMacSeconds: 300,
                appleOtherDeviceSeconds: 0,
                goalongSeconds: 0
            )

            XCTAssertEqual(
                OverviewUsageProjection.presentedApplications(
                    [boundary, below],
                    showsAll: false
                ).map(\.name),
                ["Boundary"]
            )
            XCTAssertEqual(
                OverviewUsageProjection.presentedWebsites(
                    [
                        trackedWebsite(name: "boundary.example", seconds: 300),
                        trackedWebsite(name: "below.example", seconds: 299),
                    ],
                    showsAll: false
                ).map(\.name),
                ["boundary.example"]
            )
            XCTAssertEqual(
                OverviewUsageProjection.presentedAppleApplications(
                    [
                        usage("com.example.boundary", "Boundary", 300),
                        usage("com.example.below", "Below", 299),
                    ],
                    showsAll: false
                ).map(\.resolvedName),
                ["Boundary"]
            )
        }

        func testDurationLabelMakesSubMinuteUsageExplicit() {
            XCTAssertEqual(OverviewUsageProjection.durationLabel(seconds: 0), "0m")
            XCTAssertEqual(OverviewUsageProjection.durationLabel(seconds: 1), "<1m")
            XCTAssertEqual(OverviewUsageProjection.durationLabel(seconds: 59.9), "<1m")
            XCTAssertEqual(OverviewUsageProjection.durationLabel(seconds: 60), "1m")
        }

        func testUnifiedBreakdownReplacesBrowsersWithSitesAndReconcilesTotal() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let report = try summary(
                start: start,
                end: end,
                device: mac,
                total: 120 * 60,
                applications: [
                    usage("at.studio.AsideBrowser", "Aside", 60 * 60),
                    usage("com.openai.codex", "ChatGPT", 30 * 60),
                    usage("com.google.Chrome", "Google Chrome", 20 * 60),
                    usage("com.apple.finder", "Finder", 10 * 60),
                ]
            )
            let websites = [
                trackedWebsite(
                    name: "x.com",
                    seconds: 45 * 60,
                    sources: [
                        websiteSource("Aside", "at.studio.AsideBrowser", 40 * 60),
                        websiteSource("Google Chrome", "com.google.Chrome", 5 * 60),
                    ]
                ),
                trackedWebsite(
                    name: "chatgpt.com",
                    seconds: 10 * 60,
                    sources: [
                        websiteSource("Aside", "at.studio.AsideBrowser", 10 * 60)
                    ]
                ),
            ]

            let result = UsageBreakdownProjection.build(
                summary: report,
                trackedUsage: websites
            )

            XCTAssertEqual(result.totalSeconds, 120 * 60, accuracy: 0.001)
            XCTAssertEqual(result.websiteAttributedSeconds, 55 * 60, accuracy: 0.001)
            XCTAssertFalse(result.appsAndWebsites.contains { ["Aside", "Google Chrome"].contains($0.name) })
            XCTAssertEqual(
                result.appsAndWebsites.first { $0.name == "x.com" }?.seconds,
                45 * 60
            )
            XCTAssertEqual(
                result.appsAndWebsites.first { $0.kind == .otherWeb }?.seconds,
                25 * 60
            )
            XCTAssertEqual(
                result.appsAndWebsites.reduce(0) { $0 + $1.seconds },
                result.totalSeconds,
                accuracy: 0.001
            )
            XCTAssertEqual(
                result.appsAndBrowsers.reduce(0) { $0 + $1.seconds },
                result.totalSeconds,
                accuracy: 0.001
            )

            let aside = try XCTUnwrap(result.appsAndBrowsers.first { $0.name == "Aside" })
            XCTAssertEqual(aside.kind, .browser)
            XCTAssertEqual(aside.children.map(\.name), [
                "x.com", "chatgpt.com", "Other or unidentified browsing",
            ])
            XCTAssertEqual(
                aside.children.map(\.seconds),
                [40 * 60, 10 * 60, 10 * 60].map(TimeInterval.init)
            )
        }

        func testUnifiedBreakdownMakesCompactRemainderExplicit() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let applications = (1 ... 10).map { index in
                usage(
                    "com.example.app\(index)",
                    "App \(index)",
                    TimeInterval((11 - index) * 60)
                )
            }
            let report = try summary(
                start: start,
                end: end,
                device: mac,
                total: applications.reduce(0) { $0 + $1.duration },
                applications: applications
            )
            let result = UsageBreakdownProjection.build(summary: report, trackedUsage: [])

            let compact = UsageBreakdownProjection.presentedItems(
                result.appsAndWebsites,
                showsAll: false
            )

            XCTAssertEqual(compact.count, 6)
            XCTAssertEqual(
                UsageBreakdownProjection.hiddenSeconds(
                    totalSeconds: result.totalSeconds,
                    presentedItems: compact
                ),
                10 * 60,
                accuracy: 0.001
            )
            XCTAssertEqual(
                UsageBreakdownProjection.presentedItems(
                    result.appsAndWebsites,
                    showsAll: true
                ).reduce(0) { $0 + $1.seconds },
                result.totalSeconds,
                accuracy: 0.001
            )
        }

        func testUnifiedBreakdownStillShowsShortDayInsteadOfFalseEmptyState() throws {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(86_400)
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let report = try summary(
                start: start,
                end: end,
                device: mac,
                total: 6 * 60,
                applications: [
                    usage("com.example.one", "One", 3 * 60),
                    usage("com.example.two", "Two", 2 * 60),
                    usage("com.example.three", "Three", 60),
                ]
            )
            let result = UsageBreakdownProjection.build(summary: report, trackedUsage: [])

            XCTAssertEqual(
                UsageBreakdownProjection.presentedItems(
                    result.appsAndWebsites,
                    showsAll: false
                ).map(\.name),
                ["One", "Two", "Three"]
            )
        }

        private func summary(
            start: Date,
            end: Date,
            device: AppleScreenTimeDevice,
            total: TimeInterval,
            applications: [AppleScreenTimeApplicationUsage]
        ) throws -> AppleScreenTimeDaySummary {
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: start,
                requestedEnd: end,
                requestedScope: .allDevices,
                provenance: AppleScreenTimeProvenance(
                    collectorBundleIdentifier: "test",
                    collectorVersion: "1",
                    collectorPlatform: "test",
                    authorization: .approvedWithDataAccess,
                    fetchPolicy: .live,
                    euCustomerRequirementAcknowledged: true
                ),
                reports: [
                    AppleScreenTimeDeviceReport(
                        device: device,
                        lastUpdatedAt: end,
                        segments: [
                            AppleScreenTimeSegment(
                                start: start,
                                end: end,
                                totalScreenOnDuration: total,
                                applications: applications
                            )
                        ]
                    )
                ]
            )
            return try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(
                    from: AppleScreenTimeStoredExport(
                        verification: .unsigned,
                        envelope: envelope
                    ),
                    interval: DateInterval(start: start, end: end),
                    scope: .allDevices,
                    includingSystemInactivity: true
                )
            )
        }

        private func multiDeviceSummary(
            start: Date,
            end: Date,
            values: [(AppleScreenTimeDevice, [AppleScreenTimeApplicationUsage])]
        ) throws -> AppleScreenTimeDaySummary {
            let reports = values.map { device, applications in
                AppleScreenTimeDeviceReport(
                    device: device,
                    lastUpdatedAt: end,
                    segments: [
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: applications.reduce(0) { $0 + $1.duration },
                            applications: applications
                        )
                    ]
                )
            }
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: start,
                requestedEnd: end,
                requestedScope: .allDevices,
                provenance: AppleScreenTimeProvenance(
                    collectorBundleIdentifier: "test",
                    collectorVersion: "1",
                    collectorPlatform: "test",
                    authorization: .approvedWithDataAccess,
                    fetchPolicy: .live,
                    euCustomerRequirementAcknowledged: true
                ),
                reports: reports
            )
            return try XCTUnwrap(
                AppleScreenTimeAnalyzer.summary(
                    from: AppleScreenTimeStoredExport(
                        verification: .unsigned,
                        envelope: envelope
                    ),
                    interval: DateInterval(start: start, end: end),
                    scope: .allDevices,
                    includingSystemInactivity: true
                )
            )
        }

        private func usage(
            _ bundleIdentifier: String,
            _ displayName: String,
            _ duration: TimeInterval
        ) -> AppleScreenTimeApplicationUsage {
            AppleScreenTimeApplicationUsage(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                duration: duration
            )
        }

        private func trackedApplication(
            name: String,
            bundleIdentifier: String,
            seconds: TimeInterval,
            eventCount: Int
        ) -> TrackedUsageItem {
            return TrackedUsageItem(
                id: "app:\(bundleIdentifier.lowercased())",
                kind: .application,
                name: name,
                appName: nil,
                sourceApplications: [],
                sourceUsage: [],
                bundleIdentifier: bundleIdentifier,
                host: nil,
                category: nil,
                foregroundSeconds: seconds,
                activeMinutes: Int(seconds / 60),
                eventCount: eventCount,
                identityProofAvailable: true
            )
        }

        private func trackedWebsite(
            name: String,
            seconds: TimeInterval,
            sources: [DailyWebsiteSourceUsage]? = nil
        ) -> TrackedUsageItem {
            let resolvedSources = sources ?? [
                websiteSource("Browser", "com.example.browser", seconds)
            ]
            return TrackedUsageItem(
                id: "site:\(name)",
                kind: .website,
                name: name,
                appName: resolvedSources.first?.applicationName,
                sourceApplications: resolvedSources.map(\.applicationName),
                sourceUsage: resolvedSources,
                bundleIdentifier: resolvedSources.first?.bundleIdentifier,
                host: name,
                category: nil,
                foregroundSeconds: seconds,
                activeMinutes: Int(ceil(seconds / 60)),
                eventCount: 1,
                identityProofAvailable: true
            )
        }

        private func websiteSource(
            _ name: String,
            _ bundleIdentifier: String,
            _ seconds: TimeInterval
        ) -> DailyWebsiteSourceUsage {
            DailyWebsiteSourceUsage(
                applicationName: name,
                bundleIdentifier: bundleIdentifier,
                foregroundSeconds: seconds,
                eventCount: 1,
                identityProofAvailable: true
            )
        }
    }
#endif
