#if os(macOS)
    import AppleScreenTime
    import Foundation
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
            TrackedUsageItem(
                id: "app:\(bundleIdentifier.lowercased())",
                kind: .application,
                name: name,
                appName: nil,
                sourceApplications: [],
                bundleIdentifier: bundleIdentifier,
                host: nil,
                category: nil,
                foregroundSeconds: seconds,
                activeMinutes: Int(seconds / 60),
                eventCount: eventCount,
                identityProofAvailable: true
            )
        }

        private func trackedWebsite(name: String, seconds: TimeInterval) -> TrackedUsageItem {
            TrackedUsageItem(
                id: "site:\(name)",
                kind: .website,
                name: name,
                appName: "Browser",
                sourceApplications: ["Browser"],
                bundleIdentifier: "com.example.browser",
                host: name,
                category: nil,
                foregroundSeconds: seconds,
                activeMinutes: Int(ceil(seconds / 60)),
                eventCount: 1,
                identityProofAvailable: true
            )
        }
    }
#endif
