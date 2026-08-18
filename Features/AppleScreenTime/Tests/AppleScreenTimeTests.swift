import Foundation
import XCTest
@testable import AppleScreenTime

final class AppleScreenTimeTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testScopeFiltersMacAndSelectedPhysicalDevices() {
        let mac = AppleScreenTimeDevice(name: "Mathis’s MacBook Pro", kind: .mac)
        let phone = AppleScreenTimeDevice(name: "Mathis’s iPhone", kind: .iPhone)

        XCTAssertTrue(AppleScreenTimeScope.allDevices.includes(mac))
        XCTAssertTrue(AppleScreenTimeScope.allDevices.includes(phone))
        XCTAssertTrue(AppleScreenTimeScope.macOnly.includes(mac))
        XCTAssertFalse(AppleScreenTimeScope.macOnly.includes(phone))

        let selected = AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: [phone.id])
        XCTAssertFalse(selected.includes(mac))
        XCTAssertTrue(selected.includes(phone))
    }

    func testAnalyzerKeepsPerDeviceScopeAndDoesNotPretendToDeduplicateConcurrentUse() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let interval = DateInterval(start: start, end: end)

        let mac = AppleScreenTimeDevice(name: "MacBook Pro", kind: .mac)
        let phone = AppleScreenTimeDevice(name: "iPhone", kind: .iPhone)
        let provenance = AppleScreenTimeProvenance(
            collectorBundleIdentifier: "ai.goalong.screentime",
            collectorVersion: "1.0",
            collectorPlatform: "iOS 26",
            authorization: .approvedWithDataAccess,
            fetchPolicy: .live,
            euCustomerRequirementAcknowledged: true
        )
        let envelope = AppleScreenTimeExportEnvelope(
            requestedStart: start,
            requestedEnd: end,
            requestedScope: .allDevices,
            provenance: provenance,
            reports: [
                AppleScreenTimeDeviceReport(
                    device: mac,
                    lastUpdatedAt: end,
                    segments: [
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: 2 * 3_600,
                            applications: [
                                AppleScreenTimeApplicationUsage(
                                    bundleIdentifier: "com.apple.dt.Xcode",
                                    displayName: "Xcode",
                                    duration: 90 * 60
                                )
                            ]
                        )
                    ]
                ),
                AppleScreenTimeDeviceReport(
                    device: phone,
                    lastUpdatedAt: end,
                    segments: [
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: 1 * 3_600,
                            applications: [
                                AppleScreenTimeApplicationUsage(
                                    bundleIdentifier: "com.google.ios.youtube",
                                    displayName: "YouTube",
                                    duration: 45 * 60
                                )
                            ]
                        )
                    ]
                ),
            ]
        )
        let stored = AppleScreenTimeStoredExport(verification: .unsigned, envelope: envelope)

        let all = try XCTUnwrap(
            AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .allDevices)
        )
        XCTAssertEqual(all.deviceSummaries.count, 2)
        XCTAssertEqual(all.totalScreenOnDuration, 3 * 3_600, accuracy: 0.001)
        XCTAssertEqual(all.topApplications.map(\.resolvedName), ["Xcode", "YouTube"])

        let macOnly = try XCTUnwrap(
            AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: .macOnly)
        )
        XCTAssertEqual(macOnly.deviceSummaries.map(\.device.kind), [.mac])
        XCTAssertEqual(macOnly.totalScreenOnDuration, 2 * 3_600, accuracy: 0.001)

        let selectedPhone = AppleScreenTimeScope(mode: .selectedDevices, selectedDeviceIDs: [phone.id])
        let phoneOnly = try XCTUnwrap(
            AppleScreenTimeAnalyzer.summary(from: stored, interval: interval, scope: selectedPhone)
        )
        XCTAssertEqual(phoneOnly.deviceSummaries.map(\.device.id), [phone.id])
        XCTAssertEqual(phoneOnly.totalScreenOnDuration, 3_600, accuracy: 0.001)
    }

    func testShareDisclosureLevelsAreActuallySelective() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        let device = AppleScreenTimeDevice(name: "iPhone", kind: .iPhone)
        let provenance = AppleScreenTimeProvenance(
            collectorBundleIdentifier: "ai.goalong.screentime",
            collectorVersion: "1.0",
            collectorPlatform: "iOS 26",
            authorization: .approvedWithDataAccess,
            fetchPolicy: .cached,
            euCustomerRequirementAcknowledged: true
        )
        let summary = AppleScreenTimeDaySummary(
            start: start,
            end: end,
            scope: .allDevices,
            verification: .unsigned,
            provenance: provenance,
            totalScreenOnDuration: 900,
            deviceSummaries: [
                AppleScreenTimeDeviceSummary(
                    device: device,
                    screenOnDuration: 900,
                    lastUpdatedAt: end,
                    applications: [
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: "com.example.app",
                            displayName: "Example",
                            duration: 600
                        )
                    ]
                )
            ],
            topApplications: [],
            latestDataUpdate: end
        )

        let totals = AppleScreenTimeAnalyzer.sharePayload(from: summary, disclosureLevel: .totalsOnly)
        XCTAssertNil(totals.devices)
        XCTAssertEqual(totals.includedDeviceCount, 1)

        let perDevice = AppleScreenTimeAnalyzer.sharePayload(from: summary, disclosureLevel: .perDevice)
        XCTAssertEqual(perDevice.devices?.count, 1)
        XCTAssertNil(perDevice.devices?.first?.applications)

        let apps = AppleScreenTimeAnalyzer.sharePayload(from: summary, disclosureLevel: .applications)
        XCTAssertEqual(apps.devices?.first?.applications?.first?.resolvedName, "Example")
        XCTAssertTrue(apps.trustNotice.contains("not cryptographically verified"))
    }

    func testStoreRoundTripAndConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScreenTimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AppleScreenTimeStore(rootDirectory: root)
        let config = AppleScreenTimeConfiguration(
            enabled: true,
            scope: .macOnly,
            shareLevel: .applications
        )
        try store.saveConfiguration(config)
        XCTAssertEqual(store.loadConfiguration(), config)

        let arbitraryDate = Date(timeIntervalSince1970: 1_700_000_000)
        let start = calendar.startOfDay(for: arbitraryDate)
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let envelope = AppleScreenTimeExportEnvelope(
            requestedStart: start,
            requestedEnd: end,
            requestedScope: .allDevices,
            provenance: AppleScreenTimeProvenance(
                collectorBundleIdentifier: "ai.goalong.screentime",
                collectorVersion: "1",
                collectorPlatform: "iOS",
                authorization: .approvedWithDataAccess,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: true
            ),
            reports: [
                AppleScreenTimeDeviceReport(
                    device: AppleScreenTimeDevice(name: "iPhone", kind: .iPhone),
                    lastUpdatedAt: end,
                    segments: [AppleScreenTimeSegment(start: start, end: end, totalScreenOnDuration: 60)]
                )
            ]
        )
        let data = try AppleScreenTimeJSON.encode(envelope)
        let imported = try store.importExport(data: data)
        XCTAssertEqual(imported.verification, .unsigned)
        XCTAssertEqual(store.storedExports().count, 1)

        let summary = try XCTUnwrap(store.summary(for: start, scope: .allDevices, calendar: calendar))
        XCTAssertEqual(summary.totalScreenOnDuration, 60, accuracy: 0.001)
    }

    func testValidatorRejectsDuplicatePhysicalDeviceRows() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)
        let device = AppleScreenTimeDevice(id: "same-device", name: "iPhone", kind: .iPhone)
        let report = AppleScreenTimeDeviceReport(
            device: device,
            lastUpdatedAt: end,
            segments: [AppleScreenTimeSegment(start: start, end: end, totalScreenOnDuration: 30)]
        )
        let envelope = AppleScreenTimeExportEnvelope(
            requestedStart: start,
            requestedEnd: end,
            requestedScope: .allDevices,
            provenance: AppleScreenTimeProvenance(
                collectorBundleIdentifier: "test",
                collectorVersion: "1",
                collectorPlatform: "test",
                authorization: .approvedWithDataAccess,
                fetchPolicy: .cached,
                euCustomerRequirementAcknowledged: true
            ),
            reports: [report, report]
        )

        XCTAssertThrowsError(try AppleScreenTimeValidator.validate(envelope)) { error in
            XCTAssertEqual(error as? AppleScreenTimeValidationError, .duplicateDeviceID("same-device"))
        }
    }
}
