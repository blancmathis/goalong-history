#if os(macOS)
import AgentActivity
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore
import LocalHistoryQueryCLI

/// Navigation, landing-page guidance and French presentation added by the October 2026 UX pass.
final class GoalongUXOptimizationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day))! }

    private func day(_ number: Int, from start: Double, minutes: Int, app: String = "Editor") -> GoalongLocalAnalytics.Day {
        let base = date(number)
        let events = (0...minutes).map { minute in
            HistoryEvent(id: "\(number)-\(start)-\(minute)", sessionID: "fixture",
                timestamp: base.addingTimeInterval(start + Double(minute * 60)), kind: .heartbeat,
                app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1))
        }
        return GoalongLocalAnalytics.build(events: events, day: base, now: base.addingTimeInterval(86400), calendar: calendar)
    }

    // MARK: - Activité

    func testWorkPeakNeedsMeasurableWorkAndPointsAtTheWorkHours() throws {
        let morning = day(10, from: 9 * 3600, minutes: 50, app: "Editor")
        let unclassified = GoalongActivitySummary(period: .init(days: [morning]), previous: .init(days: []),
                                                  calendar: calendar, now: date(20))
        XCTAssertNil(unclassified.workPeakWindow, "Unclassified time is never presented as work")
        XCTAssertFalse(unclassified.insights(topUsage: nil, biggestChange: nil).contains { $0.id == "work-peak" })

        let rules = GoalongUsageClassificationRules(applications: ["fixture.Editor": .work])
        let classified = GoalongActivitySummary(period: GoalongLocalAnalytics.Period(days: [morning]).applying(rules),
                                                previous: .init(days: []), calendar: calendar, now: date(20))
        let peak = try XCTUnwrap(classified.workPeakWindow)
        XCTAssertEqual(peak.hour, 9)
        XCTAssertEqual(peak.length, 1)
        let insights = classified.insights(topUsage: nil, biggestChange: nil)
        let insight = try XCTUnwrap(insights.first { $0.id == "work-peak" })
        XCTAssertTrue(insight.text.contains("entre 9 h et 10 h"), insight.text)
        XCTAssertFalse(insights.contains { $0.id == "peak" }, "Same window: only the work sentence remains")
    }

    func testKeyTakeawaysDoNotRepeatTheMetricTiles() {
        let all = ["bounds", "best-day", "peak", "work-peak", "top", "switches", "comparison", "mover", "work", "classify"]
            .map { GoalongActivitySummary.Insight(id: $0, symbol: "circle", text: $0) }
        let day = GoalongAnalyticsContent.additionalInsights(all, isDay: true, showsClassification: true).map(\.id)
        XCTAssertEqual(day, ["best-day", "peak", "work-peak", "top", "mover"])
        let period = GoalongAnalyticsContent.additionalInsights(all, isDay: false, showsClassification: false).map(\.id)
        XCTAssertEqual(period, ["bounds", "best-day", "peak", "work-peak", "top", "mover", "classify"])
    }

    func testLandingPageExplainsWhyNothingIsRecorded() {
        typealias Notice = GoalongRecordingStateNotice
        XCTAssertEqual(Notice.kind(localEnabled: false, globallyPaused: false, dashboardVisible: false, runtime: .recording), .off)
        XCTAssertNil(Notice.kind(localEnabled: false, globallyPaused: true, dashboardVisible: true, runtime: .recording),
                     "The privacy stop keeps its own banner")
        XCTAssertEqual(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true, runtime: .paused), .paused)
        XCTAssertEqual(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true,
                                   runtime: .suppressed(.manualPause)), .paused)
        XCTAssertEqual(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true,
                                   runtime: .permissionsMissing), .permissions)
        XCTAssertNil(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: false,
                                 runtime: .permissionsMissing), "A stale runtime never raises an alarm")
        XCTAssertNil(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true, runtime: .recording))
        XCTAssertNil(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true, runtime: .inputTapUnavailable),
                     "Waiting for the first input is transient, not a failure")
    }

    // MARK: - Navigation

    func testSecondaryPagesAreDeclaredAndHaveASensibleDefaultOrigin() {
        for section in [DashboardSection.screenTime, .agentActivity, .chatGPTRecap, .share, .privacy, .cli] {
            XCTAssertTrue(section.isSecondary, section.rawValue)
        }
        for section in DashboardSection.primarySections { XCTAssertFalse(section.isSecondary, section.rawValue) }
        XCTAssertEqual(DashboardSection.screenTime.defaultReturnSection, .overview)
        XCTAssertEqual(DashboardSection.chatGPTRecap.defaultReturnSection, .overview)
        XCTAssertEqual(DashboardSection.share.defaultReturnSection, .settings)
        XCTAssertEqual(SettingsPane.tools.parent, .advanced)
        XCTAssertEqual(SettingsPane.website.parent, .home)
        XCTAssertEqual(Set(SettingsPane.primary.map(\.identifier)).count, SettingsPane.primary.count)
    }

    @MainActor func testSecondaryPageReturnsToTheExactPageItWasOpenedFrom() throws {
        let model = try isolatedModel()
        model.selectSection(.settings); model.settingsPane = .advanced
        model.selectSection(.privacy)
        XCTAssertEqual(model.highlightedSidebarSection, .settings)
        XCTAssertEqual(model.secondaryReturnTitle, "Retour aux réglages")
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.selectedSection, .settings)
        XCTAssertEqual(model.settingsPane, .advanced, "Back returns to Avancé, not to the Settings home")

        model.selectSection(.history)
        model.selectSection(.agentActivity)
        XCTAssertEqual(model.highlightedSidebarSection, .history)
        XCTAssertEqual(model.secondaryReturnTitle, "Retour à l’historique")
        model.selectSection(.agentActivity) // e.g. reopening the window keeps the origin
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.selectedSection, .history)

        model.selectSection(.overview)
        model.selectSection(.screenTime)
        XCTAssertEqual(model.secondaryReturnTitle, "Retour à Activité")
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.selectedSection, .overview)
        XCTAssertNil(model.secondaryReturn)
    }

    // MARK: - French presentation

    func testEveryCaptureHealthStateHasAFrenchExplanation() {
        for state in CaptureHealthState.allCases {
            XCTAssertFalse(state.frenchTitle.isEmpty)
            XCTAssertFalse(state.frenchDetail.isEmpty)
            XCTAssertNotEqual(state.frenchTitle, state.title, "\(state) must not show the CLI's English title")
        }
    }

    func testConversationLabelsAreFrenchWithoutChangingTheSharedModule() {
        XCTAssertEqual(AgentProvider.custom.frenchName, "Autre agent")
        XCTAssertEqual(AgentProvider.codex.frenchName, "Codex")
        XCTAssertEqual(AgentSourceAvailability.missing.frenchName, "Source absente")
        XCTAssertEqual(AgentCaptureMode.everyFile.frenchName, "Tous les fichiers pris en charge")
        XCTAssertEqual(AgentProvider.custom.displayName, "Other agent", "CLI and stored metadata keep stable names")
    }

    func testDefaultProtectedApplicationsHaveReadableNames() {
        for identifier in RecorderConfig.default.excludedBundleIdentifiers where identifier != "ai.goalong.localhistory" {
            XCTAssertNotNil(GoalongKnownApplications.name(for: identifier), identifier)
            XCTAssertTrue(GoalongKnownApplications.isDefaultExclusion(identifier))
        }
        XCTAssertEqual(GoalongKnownApplications.name(for: "COM.BITWARDEN.DESKTOP"), "Bitwarden")
        XCTAssertFalse(GoalongKnownApplications.isDefaultExclusion("com.apple.Safari"))
    }

    func testSharingLabelsAndSectionTitlesAreFrench() {
        XCTAssertEqual(SharingVisibility.identity.title, "Afficher le nom")
        XCTAssertEqual(SharingVisibility.hidden.title, "Masqué")
        XCTAssertEqual(DashboardSection.privacy.title, "Confidentialité et sécurité")
        XCTAssertEqual(ShareLevel.privateOnly.dashboardTitle, "Entièrement privé")
    }

    func testSearchingForStartupShowsTheStartupSettings() {
        XCTAssertTrue(SettingsPane.matchesStartup("démarrage"))
        XCTAssertTrue(SettingsPane.matchesStartup(" ouverture de session "))
        XCTAssertTrue(SettingsPane.matchesStartup("Arrière-plan"))
        XCTAssertFalse(SettingsPane.matchesStartup(""))
        XCTAssertFalse(SettingsPane.matchesStartup("typesafe"))
        XCTAssertFalse(SettingsPane.matches("démarrage").contains(.recording), "The login switch is not in Enregistrement")
    }

    @MainActor func testWebsitePlanSummaryNeverShowsAnUnfilteredSelectionAsZero() {
        var options = GoalongSiteExportOptions(deviceIDs: ["mac"], includeApplications: true, includeWebsites: true)
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "1 appareil · toutes les applications · tous les sites")
        options.selectedApplicationIDs = ["a", "b"]; options.selectedWebsiteDomains = []
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "1 appareil · 2 applications · 0 site")
        options.includeWebsites = false; options.deviceIDs = []
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "tous les appareils · 2 applications · sans sites")
    }

    private func isolatedModel() throws -> DashboardViewModel {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("Navigation tests build a dashboard model only inside an isolated test HOME")
        }
        let config = ConfigManager()
        let permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/ux-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "ux-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
    }
}
#endif
