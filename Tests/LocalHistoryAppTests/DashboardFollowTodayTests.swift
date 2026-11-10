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
        XCTAssertEqual(model.navigationStore.selectedDay, calendar.startOfDay(for: at(day: 10, 0, 0)))
        model.followToday()
        XCTAssertEqual(model.navigationStore.selectedDay, calendar.startOfDay(for: at(day: 10, 0, 0)), "Same day: nothing moves")
        clock = at(day: 11, 0, 1)
        model.followToday()
        XCTAssertEqual(model.navigationStore.selectedDay, calendar.startOfDay(for: at(day: 11, 0, 0)))
        XCTAssertTrue(model.navigationStore.isTodaySelected)
    }

    @MainActor func testDayChangeNotificationMovesTheDayAndPastDayStays() throws {
        clock = at(day: 10, 23, 59)
        let model = try model()
        clock = at(day: 11, 0, 1)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(model.navigationStore.selectedDay, calendar.startOfDay(for: at(day: 11, 0, 0)))

        model.selectDay(at(day: 8, 12, 0))
        clock = at(day: 12, 0, 1)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(model.navigationStore.selectedDay, calendar.startOfDay(for: at(day: 8, 0, 0)), "A past day chosen by the user stays")
    }

    /// C13-11 (T-044 r13). Paris → New York while the member looks at a past day (25 October): the page keeps
    /// the 25th, at its New York midnight. An instant kept from Paris would read 24 October on every day page.
    @MainActor func testPastDayKeepsItsDateAfterATimeZoneChange() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        NSTimeZone.default = paris
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-27T11:00:00Z")) // 12:00 Paris, 07:00 New York
        let model = try model()
        var parisCalendar = Calendar(identifier: .gregorian); parisCalendar.timeZone = paris
        model.selectDay(try XCTUnwrap(parisCalendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))))

        for zone in [newYork, tokyo, paris] {
            NSTimeZone.default = zone
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            NSTimeZone.default = zone // the observer resets the system zone; keep the test zone
            model.followToday()
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            XCTAssertEqual(local.component(.day, from: model.navigationStore.selectedDay), 25, "\(zone.identifier): \(model.navigationStore.selectedDay)")
            XCTAssertEqual(model.navigationStore.selectedDay, local.startOfDay(for: model.navigationStore.selectedDay), "\(zone.identifier): not a midnight")
            // The Screen Time page reads this interval (AppleScreenTimeDashboardModel).
            let interval = try XCTUnwrap(Calendar.current.dateInterval(of: .day, for: model.navigationStore.selectedDay))
            XCTAssertEqual(local.component(.day, from: interval.start), 25, zone.identifier)
            XCTAssertFalse(model.navigationStore.isTodaySelected)
        }
    }

    /// C13-11: a page left on today still follows the new zone's today.
    @MainActor func testTodayFollowsTheNewZoneAfterATimeZoneChange() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        NSTimeZone.default = paris
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-27T02:00:00Z")) // 03:00 Paris, 22:00 New York (26th)
        let model = try model()
        NSTimeZone.default = newYork
        model.followToday()
        var local = Calendar(identifier: .gregorian); local.timeZone = newYork
        XCTAssertEqual(local.component(.day, from: model.navigationStore.selectedDay), 26)
        XCTAssertEqual(model.navigationStore.selectedDay, local.startOfDay(for: clock))
        XCTAssertTrue(model.navigationStore.isTodaySelected)
    }

    /// « Mon travail » is no page (docs/spec-blocages-20261110.md § 6): its destination opens the pane
    /// « Définition du travail » of Réglages, and Jev's destination stays a destination of the page « Blocages ».
    @MainActor func testTheWorkDestinationOpensItsSettingsPane() throws {
        let model = try model()
        model.selectSection(.history)
        model.selectSection(.work)
        XCTAssertEqual(model.navigationStore.selectedSection, .settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .work)
        model.selectSection(.settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .home, "the sidebar entry still opens the Settings home")
        model.selectSection(.monitoring)
        XCTAssertEqual(model.navigationStore.selectedSection, .monitoring)
        XCTAssertEqual(BlocagesTarget(model.navigationStore.selectedSection), .jev)
        // The rule closes: the page is the plain one again, so showing it again does not reopen the rule.
        model.blockRuleEditorClosed()
        XCTAssertEqual(model.navigationStore.selectedSection, .blocking)
        XCTAssertEqual(BlocagesTarget(model.navigationStore.selectedSection), .top)
        // A rule closed by a link that leaves the page changes nothing more.
        model.openRecordingSettings()
        model.blockRuleEditorClosed()
        XCTAssertEqual(model.navigationStore.selectedSection, .settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .recording)
    }
}
#endif
