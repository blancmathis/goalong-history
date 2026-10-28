#if os(macOS)
    import AppleScreenTime
    import XCTest
    @testable import LocalHistoryApp

    /// T-045 T2: the Screen Time dashboard export. The save panel is never reached: only the "nothing to export" guard
    /// and the pure payload helpers run.
    final class T045T2ScreenTimeModelTests: XCTestCase {
        private let day = T045T2Fixtures.date(2026, 3, 10)

        @MainActor
        func testExportSharePayloadWithoutSummaryAlertsInsteadOfOpeningThePanel() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("t045t2-screentime-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppleScreenTimeDashboardModel(
                rootDirectory: root, deviceID: "test-device", selectedDay: day, accessEnabled: false, refreshInterval: 60
            ) { _ in AppleScreenTimeDashboardModel.storageUnavailableCollectionForTesting(message: "unused") }
            XCTAssertNil(model.summary)
            XCTAssertNil(model.alert)
            model.exportSharePayload()
            XCTAssertEqual(model.alert?.title, "Rien à exporter")
            XCTAssertEqual(model.alert?.message, "Aucune donnée Temps d’écran pour ce jour et ces appareils.")
            XCTAssertFalse(model.isBusy, "no export started")
        }

        func testSharePayloadTotalsOnlyHidesDevices() {
            let payload = AppleScreenTimeDashboardModel.systemSharePayloadForTesting(
                from: T045T2Fixtures.summary(day: day), disclosureLevel: .totalsOnly)
            XCTAssertEqual(payload.disclosureLevel, .totalsOnly)
            XCTAssertEqual(payload.totalScreenOnDuration, 9000)
            XCTAssertEqual(payload.includedDeviceCount, 2)
            XCTAssertNil(payload.devices)
        }

        func testSharePayloadPerDeviceHidesApplications() throws {
            let payload = AppleScreenTimeDashboardModel.systemSharePayloadForTesting(
                from: T045T2Fixtures.summary(day: day), disclosureLevel: .perDevice)
            let devices = try XCTUnwrap(payload.devices)
            XCTAssertEqual(devices.map(\.device.name), ["Pocket", "Studio"])
            XCTAssertEqual(devices.map(\.screenOnDuration), [5400, 3600])
            XCTAssertTrue(devices.allSatisfy { $0.applications == nil })
        }

        func testSharePayloadApplicationsLevelIncludesApplications() throws {
            let payload = AppleScreenTimeDashboardModel.systemSharePayloadForTesting(
                from: T045T2Fixtures.summary(day: day), disclosureLevel: .applications)
            let devices = try XCTUnwrap(payload.devices)
            XCTAssertEqual(devices.first?.applications?.map(\.displayName), ["Safari", "Mail"])
            XCTAssertEqual(devices.last?.applications?.map(\.displayName), ["Xcode", "Notes"])
        }

        func testTrustNoticeFollowsTheProvenance() {
            let direct = AppleScreenTimeDashboardModel.systemSharePayloadForTesting(
                from: T045T2Fixtures.summary(day: day), disclosureLevel: .totalsOnly)
            XCTAssertTrue(direct.trustNotice.hasPrefix("These values were read directly from Apple’s local knowledgeC, Biome, or private ScreenTimeAgent stores."))
            let visible = AppleScreenTimeDashboardModel.systemSharePayloadForTesting(
                from: T045T2Fixtures.summary(day: day, api: AppleScreenTimeProvenance.appleSettingsAccessibilityAPI),
                disclosureLevel: .totalsOnly)
            XCTAssertTrue(visible.trustNotice.hasPrefix("These values were copied locally from the Apple Screen Time presentation visible in System Settings."))
            XCTAssertNotEqual(direct.trustNotice, visible.trustNotice)
        }

        func testDayStringIsLocalCalendarDay() {
            XCTAssertEqual(AppleScreenTimeDashboardModel.dayStringForTesting(day), "2026-03-10")
            XCTAssertEqual(
                AppleScreenTimeDashboardModel.dayStringForTesting(T045T2Fixtures.date(2026, 12, 31, hour: 23, minute: 59)), "2026-12-31")
            XCTAssertEqual(
                AppleScreenTimeDashboardModel.dayStringForTesting(T045T2Fixtures.date(2027, 1, 1, hour: 0, minute: 0)), "2027-01-01")
        }

        func testStorageUnavailableCollectionCarriesTheReason() {
            let collection = AppleScreenTimeDashboardModel.storageUnavailableCollectionForTesting(message: "disque plein")
            XCTAssertNil(collection.storedExport)
            XCTAssertTrue(collection.availableDevices.isEmpty)
            XCTAssertEqual(collection.status.kind, .noAppleData)
            XCTAssertEqual(collection.status.title, "Le stockage quotidien Temps d’écran est indisponible")
            XCTAssertEqual(
                collection.status.message,
                "Goalong n’a pas lu le Temps d’écran car l’enregistrement local du jour n’a pas pu être ouvert : disque plein")
            XCTAssertTrue(collection.deviceSourceLabels.isEmpty)
            XCTAssertEqual(collection.knowledgeIntervalCount, 0)
            XCTAssertEqual(collection.biomeIntervalCount, 0)
        }
    }
#endif
