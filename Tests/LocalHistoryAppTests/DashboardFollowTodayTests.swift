#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

/// R35: pages on `DashboardViewModel.selectedDay` (Historique, Temps d’écran, Partage…) follow « aujourd’hui » at midnight.
final class DashboardFollowTodayTests: XCTestCase {
    private var clock = Date()
    private let calendar = Calendar.current

    @MainActor private func model() throws -> DashboardViewModel {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("Dashboard follow-today tests require an isolated test HOME")
        }
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/follow-today-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "follow-today-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) },
            now: { [unowned self] in clock })
    }

    private func at(day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @MainActor func testPageLeftOnTodayMovesToTheNewDayAfterMidnight() throws {
        clock = at(day: 10, 23, 59)
        let model = try model()
        XCTAssertEqual(model.selectedDay, calendar.startOfDay(for: at(day: 10, 0, 0)))
        model.followToday()
        XCTAssertEqual(model.selectedDay, calendar.startOfDay(for: at(day: 10, 0, 0)), "Same day: nothing moves")
        clock = at(day: 11, 0, 1)
        model.followToday()
        XCTAssertEqual(model.selectedDay, calendar.startOfDay(for: at(day: 11, 0, 0)))
        XCTAssertTrue(model.isTodaySelected)
    }

    @MainActor func testDayChangeNotificationMovesTheDayAndPastDayStays() throws {
        clock = at(day: 10, 23, 59)
        let model = try model()
        clock = at(day: 11, 0, 1)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(model.selectedDay, calendar.startOfDay(for: at(day: 11, 0, 0)))

        model.selectDay(at(day: 8, 12, 0))
        clock = at(day: 12, 0, 1)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(model.selectedDay, calendar.startOfDay(for: at(day: 8, 0, 0)), "A past day chosen by the user stays")
    }
}
#endif
