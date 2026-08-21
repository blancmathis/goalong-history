#if os(macOS)
    import AppleScreenTime
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AppleScreenTimeDeviceNormalizerTests: XCTestCase {
        func testDropsStalePeersAndCollapsesGenericAliasForSameUsage() {
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let iphone = AppleScreenTimeDevice(id: "phone-a", name: "iPhone15,4 · phone-a", kind: .iPhone)
            let alias = AppleScreenTimeDevice(id: "phone-b", name: "Apple device · phone-b", kind: .unknown)
            let stale = AppleScreenTimeDevice(id: "old-peer", name: "Apple device · old-peer", kind: .unknown)

            let start = Date(timeIntervalSince1970: 1_786_000_000)
            let end = start.addingTimeInterval(600)
            let segment = AppleScreenTimeSegment(
                start: start,
                end: end,
                totalScreenOnDuration: 600,
                applications: [
                    AppleScreenTimeApplicationUsage(
                        bundleIdentifier: "com.example.app",
                        displayName: "Example",
                        duration: 600
                    )
                ]
            )
            let reports = [
                AppleScreenTimeDeviceReport(device: iphone, lastUpdatedAt: end, segments: [segment]),
                AppleScreenTimeDeviceReport(device: alias, lastUpdatedAt: end, segments: [segment]),
            ]
            let provenance = AppleScreenTimeProvenance(
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: start,
                requestedEnd: end,
                requestedScope: .allDevices,
                provenance: provenance,
                reports: reports
            )
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: envelope
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac, iphone, alias, stale],
                status: AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Official Apple Screen Time connected",
                    message: "ready"
                ),
                deviceSourceLabels: [
                    mac.id: "Apple knowledgeC",
                    iphone.id: "Apple Biome · iCloud sync",
                    alias.id: "Apple Biome · iCloud sync",
                    stale.id: "Discovered in Apple iCloud sync",
                ],
                latestAppleUpdate: end,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 2
            )

            let normalized = AppleScreenTimeDeviceNormalizer.normalize(collection, currentMac: mac)

            XCTAssertEqual(normalized.availableDevices.count, 2)
            XCTAssertTrue(normalized.availableDevices.contains { $0.id == mac.id })
            XCTAssertTrue(normalized.availableDevices.contains { $0.kind == .iPhone })
            XCTAssertFalse(normalized.availableDevices.contains { $0.id == stale.id })
            XCTAssertEqual(normalized.storedExport?.envelope.reports.count, 1)
        }
    }
#endif
