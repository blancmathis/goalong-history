#if os(macOS)
import XCTest
import Combine
import AppleScreenTime
import AppleSystemScreenTime
@testable import LocalHistoryApp

final class GoalongAppleUsagePresentationTests: XCTestCase {
    private var provenance: AppleScreenTimeProvenance {
        .init(api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
            collectorBundleIdentifier: "fixture", collectorVersion: "1", collectorPlatform: "fixture",
            authorization: .unknown, fetchPolicy: .live, euCustomerRequirementAcknowledged: false)
    }
    private var date: Date { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)) }
    private var applications: [AppleScreenTimeApplicationUsage] {
        [.init(bundleIdentifier: "com.apple.Safari", displayName: "Safari", duration: 600),
         .init(bundleIdentifier: "website:example.org", displayName: "example.org", duration: 300),
         .init(bundleIdentifier: "example.editor", displayName: "Éditeur", duration: 120)]
    }
    private var summary: AppleScreenTimeDaySummary {
        AppleScreenTimeAnalyzer.summary(from: collection(date).storedExport!,
            interval: DateInterval(start: date, end: Calendar.current.date(byAdding: .day, value: 1, to: date)!),
            scope: .allDevices)!
    }
    func testNoAppleSummaryMeansNoReplacementUsage() {
        XCTAssertEqual(GoalongAppleUsageProjection.rows(nil), [])
    }
    func testAppleApplicationsAndWebsitesRemainSeparateWithoutReallocation() {
        let rows = GoalongAppleUsageProjection.rows(summary)
        let apps = GoalongAppleUsageProjection.visibleRows(rows, filter: .applications, search: "")
        let sites = GoalongAppleUsageProjection.visibleRows(rows, filter: .websites, search: "")
        XCTAssertEqual(apps.map(\.seconds), [600, 120])
        XCTAssertEqual(sites.map(\.seconds), [300])
        XCTAssertEqual(sites.first?.host, "example.org")
        XCTAssertNil(sites.first?.bundleIdentifier)
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(summary.totalScreenOnDuration, 720, "The 300 website seconds are included, not added to Apple total")
    }
    func testAppleSearchDoesNotChangeSourceKindOrDuration() {
        let rows = GoalongAppleUsageProjection.rows(summary)
        XCTAssertEqual(GoalongAppleUsageProjection.visibleRows(rows, filter: .applications, search: "editeur").first?.seconds, 120)
        XCTAssertEqual(GoalongAppleUsageProjection.visibleRows(rows, filter: .applications, search: "com.apple").count, 1)
        XCTAssertTrue(GoalongAppleUsageProjection.visibleRows(rows, filter: .applications, search: "example.org").isEmpty)
    }
    func testReconstructionCannotBePresentedAsAnOfficialTotal() {
        let partial = GoalongScreenTimeSourcePresentation(assurance: .reconstructedAppleUsage)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.durationTitle, "Durée reconstituée")
        XCTAssertTrue(partial.detail.contains("pas le total officiel"))
        XCTAssertFalse(GoalongScreenTimeSourcePresentation(assurance: .privateAppleAggregateStore).isPartial)
    }

    private func collection(_ day: Date) -> AppleSystemScreenTimeCollection {
        let device = AppleScreenTimeDevice(id: "apple-system-current-mac:test-device", name: "Mac fixture", kind: .mac)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let stored = AppleScreenTimeStoredExport(verification: .unsigned,
            envelope: .init(requestedStart: day, requestedEnd: end, requestedScope: .allDevices,
                provenance: provenance, reports: [.init(device: device, lastUpdatedAt: end,
                    segments: [.init(start: day, end: day.addingTimeInterval(720), totalScreenOnDuration: 720,
                                     applications: applications)])]))
        return .init(storedExport: stored, availableDevices: [device],
            status: .init(kind: .ready, title: "Fixture", message: "Fixture only"),
            deviceSourceLabels: [:], latestAppleUpdate: end, knowledgeIntervalCount: 0, biomeIntervalCount: 0)
    }

    @MainActor func testDayAndScopeChangesImmediatelyInvalidateOldDisplayedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-selection-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppleScreenTimeDashboardModel(rootDirectory: root, deviceID: "test-device", selectedDay: date,
            refreshInterval: 600, includesUnfilteredSummary: true, collectionProvider: { self.collection($0) })
        defer { model.setActive(false) }
        func awaitSummary() {
            let ready = expectation(description: "summary displayed")
            let observation = model.$isBusy.dropFirst().filter { !$0 }.sink { _ in ready.fulfill() }
            model.setActive(true)
            wait(for: [ready], timeout: 3)
            observation.cancel()
            XCTAssertNotNil(model.summary)
            model.setActive(false)
        }
        awaitSummary()
        XCTAssertNotNil(model.unfilteredSummary)
        model.selectDay(date.addingTimeInterval(-86400))
        XCTAssertNil(model.summary)
        XCTAssertNil(model.unfilteredSummary)
        XCTAssertNil(model.lastRefreshAt)
        XCTAssertNil(model.latestAppleUpdate)
        awaitSummary()
        model.setScopeMode(.macOnly)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.unfilteredSummary)
        awaitSummary()
        model.toggleDevice(model.currentMacDevice)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.unfilteredSummary)
    }
}
#endif
