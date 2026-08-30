#if os(macOS)
    import AppleScreenTime
    @testable import AppleSystemScreenTime
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class AppleScreenTimeDeviceNormalizerTests: XCTestCase {
        func testPreservesIdleSourceVettedDeviceAndCollapsesGenericAliasForSameUsage() {
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let iphone = AppleScreenTimeDevice(id: "phone-a", name: "iPhone15,4 · phone-a", kind: .iPhone)
            let alias = AppleScreenTimeDevice(id: "phone-b", name: "Apple device · phone-b", kind: .unknown)
            let idleIPad = AppleScreenTimeDevice(id: "tablet", name: "iPad de Mathis", kind: .iPad)

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
                availableDevices: [mac, iphone, idleIPad],
                status: AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Official Apple Screen Time connected",
                    message: "ready"
                ),
                deviceSourceLabels: [
                    mac.id: "Apple knowledgeC",
                    iphone.id: "Apple Biome · iCloud sync",
                    alias.id: "Apple Biome · iCloud sync",
                    idleIPad.id: "Discovered in Apple iCloud sync",
                ],
                latestAppleUpdate: end,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 2
            )

            let normalized = AppleScreenTimeDeviceNormalizer.normalize(collection, currentMac: mac)

            XCTAssertEqual(normalized.availableDevices.count, 3)
            XCTAssertTrue(normalized.availableDevices.contains { $0.id == mac.id })
            XCTAssertTrue(normalized.availableDevices.contains { $0.kind == .iPhone })
            XCTAssertTrue(normalized.availableDevices.contains { $0.id == idleIPad.id })
            XCTAssertEqual(normalized.storedExport?.envelope.reports.count, 1)
        }

        func testPreservesSourceVettedDevicesWhenSelectedDayHasNoUsage() {
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let idleIPad = AppleScreenTimeDevice(id: "tablet", name: "iPad de Mathis", kind: .iPad)
            let collection = AppleSystemScreenTimeCollection(
                storedExport: nil,
                availableDevices: [mac, idleIPad],
                status: AppleSystemScreenTimeStatus(
                    kind: .noAppleData,
                    title: "No usage",
                    message: "No usage for this day"
                ),
                deviceSourceLabels: [
                    mac.id: "Apple knowledgeC",
                    idleIPad.id: "Discovered in Apple iCloud sync",
                ],
                latestAppleUpdate: nil,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let normalized = AppleScreenTimeDeviceNormalizer.normalize(collection, currentMac: mac)

            XCTAssertEqual(normalized.availableDevices.map(\.id), [mac.id, idleIPad.id])
            XCTAssertEqual(
                normalized.deviceSourceLabels[idleIPad.id],
                "Discovered in Apple iCloud sync"
            )
        }

        func testPreservesFriendlyNamesAndUsesStablePeerTagsInsteadOfOrdinals() {
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let friendly = AppleScreenTimeDevice(
                id: "phone",
                name: "iPhone Mathis",
                kind: .iPhone
            )
            let a = AppleScreenTimeDevice(id: "AAAAAAAA-1111", name: "Apple device", kind: .unknown)
            let b = AppleScreenTimeDevice(id: "BBBBBBBB-2222", name: "Apple device", kind: .unknown)

            let forward = AppleScreenTimeDeviceNormalizer.presentedDevices(
                [mac, friendly, b, a],
                currentMacID: mac.id
            )
            let reversed = AppleScreenTimeDeviceNormalizer.presentedDevices(
                [a, b, friendly, mac],
                currentMacID: mac.id
            )
            let forwardNames = Dictionary(uniqueKeysWithValues: forward.map { ($0.id, $0.displayName) })
            let reversedNames = Dictionary(uniqueKeysWithValues: reversed.map { ($0.id, $0.displayName) })

            XCTAssertEqual(forwardNames, reversedNames)
            XCTAssertEqual(forwardNames[friendly.id], "iPhone Mathis")
            XCTAssertEqual(forwardNames[a.id], "Apple device · AAAAAAAA")
            XCTAssertEqual(forwardNames[b.id], "Apple device · BBBBBBBB")
            XCTAssertFalse(forwardNames.values.contains("Apple device 1"))
            XCTAssertFalse(forwardNames.values.contains("Apple device 2"))
        }
    }
#endif
