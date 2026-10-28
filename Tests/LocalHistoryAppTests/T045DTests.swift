#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-045 D: small defects left open by the H1 and H2 reviews.
    final class T045DTests: XCTestCase {
        // D-149a: after a zone change the Bilan day moves to its midnight in the new zone, but the
        // day overview kept the bounds read in the old zone. It must be read again for the new instant.
        func testDayOverviewIsReadAgainForTheNewZoneAfterATimeZoneChange() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let lock = NSLock()
            var requested: [Date] = []
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(rootDirectory: root.appendingPathComponent("history")),
                recapsDirectory: root.appendingPathComponent("recaps"),
                executableLocator: { nil },
                sessionFactory: { _ in throw NSError(domain: "T045D", code: 1) },
                delayedAutomaticScheduler: { _ in },
                analysisConsentProvider: { true },
                dayOverviewReader: { day in
                    lock.lock(); requested.append(day); lock.unlock()
                    throw NSError(domain: "T045D", code: 2)
                }
            )
            runtime.configure(deviceID: "t045d-device")
            let oct25 = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
            runtime.selectDay(oct25)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            lock.lock(); let last = requested.last; lock.unlock()
            XCTAssertEqual(last, runtime.selectedDay, "The overview still holds the old zone's day bounds")
        }

        // D-150a: a switch exactly a week away named only its weekday, the same one as today.
        func testBraiseSwitchAWeekAwayNamesItsDate() throws {
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let calendar = Calendar.current
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 23)))  // mercredi
            let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 22)))
            let nextWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 22)))
            XCTAssertEqual(BraiseController.whenText(tomorrow, now: now), "jeudi à 22:00")
            XCTAssertEqual(BraiseController.whenText(nextWeek, now: now), "mercredi 4 novembre à 22:00")
        }

        // D-149b: the Bilan page date picker writes the dashboard day too, so Historique and a return keep the choice.
        @MainActor func testBilanDatePickerWritesTheDashboardDay() throws {
            guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
                throw XCTSkip("Dashboard tests require an isolated test HOME")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
            let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
                executableURL: URL(fileURLWithPath: "/nonexistent/t045d-test"), performInitialDiscovery: false,
                sourceDiscovery: { [] }, onCaptured: { _ in })
            let model = DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
                sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
                deviceInfo: DeviceIdentityInfo(deviceID: "t045d-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
                eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
                onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
                onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
                onDeleteTargetedDetails: { _, done in done(.success(0)) })
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(rootDirectory: root.appendingPathComponent("history")),
                recapsDirectory: root.appendingPathComponent("recaps"),
                executableLocator: { nil },
                sessionFactory: { _ in throw NSError(domain: "T045D", code: 1) },
                delayedAutomaticScheduler: { _ in })
            let picked = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date())))
            ChatGPTRecapPage.chooseDay(picked, model: model, runtime: runtime)
            XCTAssertEqual(model.selectedDay, picked)
            XCTAssertEqual(runtime.selectedDay, picked)
        }
    }
#endif
