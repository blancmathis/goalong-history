#if os(macOS)
    import AppleScreenTime
    import AppleSystemScreenTime
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-044 r14 volet C: time zone change regressions (C14-02, C14-03).
    final class C044R14EdgeTests: XCTestCase {
        // C14-02: a westward time zone change while the Apple read runs files today's data under yesterday.
        func testTimeZoneChangeDuringCollectionKeepsTheDayName() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NSTimeZone.default = paris
            var parisCalendar = Calendar(identifier: .gregorian)
            parisCalendar.timeZone = paris
            // 2026-09-05 15:00 Paris = 09:00 New York, same calendar day in both zones.
            let now = try XCTUnwrap(parisCalendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 15)))
            let today = parisCalendar.startOfDay(for: now)
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: root, currentMacDevice: mac, calendar: .autoupdatingCurrent,
                nowProvider: { now },
                liveCollectionProvider: { requestedDay in
                    let read = self.collection(day: requestedDay, device: mac, calendar: parisCalendar)
                    NSTimeZone.default = newYork  // the Mac lands while Apple stores are read
                    return read
                }
            )
            _ = repository.collect(for: today)
            repository.waitForPendingCollection()
            XCTAssertEqual(repository.storedDayStrings(), ["2026-09-05"], "Sept 5 data must not be filed as Sept 4")
        }

        private func collection(day: Date, device: AppleScreenTimeDevice, calendar: Calendar)
            -> AppleSystemScreenTimeCollection
        {
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let provenance = AppleScreenTimeProvenance(
                collectorBundleIdentifier: "test", collectorVersion: "1", collectorPlatform: "test",
                authorization: .unknown, fetchPolicy: .live, euCustomerRequirementAcknowledged: false)
            let segmentEnd = start.addingTimeInterval(60)
            let seconds: TimeInterval = 60
            let stored = AppleScreenTimeStoredExport(
                importedAt: segmentEnd,
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    createdAt: segmentEnd,
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: device,
                            lastUpdatedAt: segmentEnd,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: start,
                                    end: segmentEnd,
                                    totalScreenOnDuration: seconds,
                                    applications: [
                                        AppleScreenTimeApplicationUsage(
                                            bundleIdentifier: "com.example.work",
                                            displayName: "Work",
                                            duration: seconds
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                )
            )
            return AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [device],
                status: AppleSystemScreenTimeStatus(kind: .ready, title: "Ready", message: "Ready"),
                deviceSourceLabels: [device.id: "Test"],
                latestAppleUpdate: segmentEnd,
                knowledgeIntervalCount: 1,
                biomeIntervalCount: 0
            )
        }
    }
#endif
