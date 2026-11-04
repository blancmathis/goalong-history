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

        let editor = GoalongWorkContext.Label(application: "Editor", bundleIdentifier: "fixture.Editor", host: nil, title: nil)
        let classified = GoalongActivitySummary(period: GoalongLocalAnalytics.Period(days: [morning])
                                                    .applying(GoalongWorkVerdicts([editor.key: GoalongWorkAssignment(verdict: .work, task: "Projet")])),
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
        XCTAssertNil(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true, runtime: .inputTapUnavailable,
                                 captureHealth: .awaitingInputEvidence), "Waiting for the first input is transient, not a failure")
        XCTAssertEqual(Notice.kind(localEnabled: true, globallyPaused: false, dashboardVisible: true, runtime: .inputTapUnavailable,
                                   captureHealth: .inputTapUnavailable), .input, "A failed input tap says so on the page (UI-parcours-02)")
    }

    func testActivityShowsOneRecordingBannerAtATime() {
        typealias Coverage = GoalongRecordingCoverageNotice
        XCTAssertTrue(Coverage.showsOnActivity(recording: nil, globallyPaused: false))
        for kind: GoalongRecordingStateNotice.Kind in [.off, .paused, .permissions, .input] {
            XCTAssertFalse(Coverage.showsOnActivity(recording: kind, globallyPaused: false), "\(kind) outranks the details choice")
        }
        XCTAssertFalse(Coverage.showsOnActivity(recording: nil, globallyPaused: true))
    }

    func testEmptyTodayNamesTheStoppedRecordingInsteadOfAReadError() {
        typealias Empty = GoalongActivityEmptyCopy
        func today(_ recording: GoalongRecordingStateNotice.Kind?, events: Int = 0, incomplete: Int = 0) -> Empty.Copy {
            Empty.copy(isDay: true, isToday: true, eventCount: events, incompleteDays: incomplete, purged: false, recording: recording)
        }
        let off = today(.off)
        XCTAssertEqual(off.title, "Aucune activité enregistrée aujourd’hui")
        XCTAssertTrue(off.message.contains("désactivé"))
        XCTAssertFalse(off.offersHistory)
        let offUnreadable = today(.off, incomplete: 1)
        XCTAssertEqual(offUnreadable.title, "Lecture incomplète", "R7-B-02: an unreadable day never reads as « nothing recorded »")
        XCTAssertTrue(offUnreadable.message.contains("désactivé"), "the stopped cause stays named")
        XCTAssertFalse(offUnreadable.title.contains("Aucune activité"))
        let permissions = today(.permissions)
        XCTAssertFalse(permissions.message.contains("premières minutes"), "UI-sombre-02: no promise while nothing is recorded")
        XCTAssertTrue(today(.paused).message.contains("pause"))
        XCTAssertEqual(today(nil).title, "Pas encore d’activité aujourd’hui")
        XCTAssertEqual(today(.input).title, "Pas encore d’activité aujourd’hui", "Input loss alone does not stop recording")
        XCTAssertEqual(today(nil, incomplete: 1).title, "Lecture incomplète")
        // DEF-06: traces before a stop never promise more; the stop stays named.
        XCTAssertEqual(today(.off, events: 3).title, "Aucune durée mesurable aujourd’hui")
        XCTAssertTrue(today(.off, events: 3).message.contains("désactivé"))
        XCTAssertEqual(today(nil, events: 3).title, "Les premières traces sont reçues", "recording on: more traces will come")
        let past = Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 1, purged: false, recording: .off)
        XCTAssertEqual(past.title, "Lecture incomplète", "A past day keeps its own reading state")
        XCTAssertEqual(Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 0, purged: false, recording: nil).title,
                       "Pas encore d’enregistrement")
        XCTAssertEqual(Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 0, purged: true, recording: .off).title,
                       "Détail effacé")
    }

    func testEmptyTodayNamesAStorageStopAndItsTime() {
        typealias Empty = GoalongActivityEmptyCopy
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let full = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: nil,
                              storage: .init(kind: .diskFull, since: since))
        XCTAssertEqual(full.title, "Aucune donnée depuis \(GoalongUIFormat.time(since))", "UI-21: the stop and its time")
        // R8-6: the top banner names the cause and holds the action; the page says only the effect.
        XCTAssertFalse(full.message.contains("disque est plein"), full.message)
        XCTAssertFalse(full.message.contains("premières minutes"), "UI-21: no promise while nothing is recorded")
        XCTAssertFalse(full.offersHistory)
        let refused = Empty.copy(isDay: true, isToday: true, eventCount: 4, incompleteDays: 0, purged: false, recording: nil,
                                 storage: .init(kind: .permissionDenied, since: nil))
        XCTAssertEqual(refused.title, "Aucune nouvelle donnée")
        // P-1: a stopped recording comes before the storage failure, as in the top banner.
        let offFirst = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: .off,
                                  storage: .init(kind: .permissionDenied, since: nil))
        XCTAssertEqual(offFirst.title, "Aucune activité enregistrée aujourd’hui")
        XCTAssertTrue(offFirst.message.contains("désactivé"))
        // P-2: storage stop + unreadable day still says « Lecture incomplète », with the stop.
        let unread = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 1, purged: false, recording: nil,
                                storage: .init(kind: .diskFull, since: since))
        XCTAssertEqual(unread.title, "Lecture incomplète")
        XCTAssertFalse(unread.message.contains("disque est plein"), unread.message)
        XCTAssertTrue(unread.message.hasPrefix("Aucune donnée depuis"))
        // P-4: an unavailable storage cannot write; it refuses nothing.
        let unavailable = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: nil,
                                     storage: .init(kind: .unavailable, since: nil))
        XCTAssertFalse(unavailable.message.contains("refuse"))
        XCTAssertEqual(GoalongActivityEmptyCopy.storageCause(.unavailable), "Goalong ne peut pas écrire dans son dossier d’historique")
        let fullWithTraces = Empty.copy(isDay: true, isToday: true, eventCount: 2, incompleteDays: 0, purged: false, recording: nil,
                                        storage: .init(kind: .diskFull, since: since))
        XCTAssertNotEqual(fullWithTraces.title, "Les premières traces sont reçues", "DEF-06: disk full, no promise")
        // R8-6: one announcement of the cause per screen, the banner's; never repeated by the page.
        for copy in [full, refused, unread, unavailable, fullWithTraces] {
            for kind in [CaptureStorageFailureKind.diskFull, .permissionDenied, .unavailable] {
                XCTAssertFalse(copy.title.contains(GoalongActivityEmptyCopy.storageCause(kind))
                    || copy.message.contains(GoalongActivityEmptyCopy.storageCause(kind)), "\(copy.title) / \(copy.message)")
            }
            XCTAssertFalse(copy.title.contains("interrompu"), "the banner says « interrompu », the page says the effect")
        }
        let past = Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 0, purged: false, recording: nil,
                              storage: .init(kind: .diskFull, since: since))
        XCTAssertEqual(past.title, "Pas encore d’enregistrement", "a past day keeps its own state")
    }

    /// DEF-02 (T-046): « Classement non autorisé » never sits next to a switch shown on. Consent is read
    /// directly: an empty definition or history off must not hide a missing consent (review of PR #205).
    func testAutomaticClassificationSwitchIsOffWhileNotAllowed() {
        XCTAssertFalse(GoalongWorkPage.automaticSwitchShowsOn(automatic: true, consented: false))
        XCTAssertTrue(GoalongWorkPage.automaticSwitchShowsOn(automatic: true, consented: true))
        XCTAssertFalse(GoalongWorkPage.automaticSwitchShowsOn(automatic: false, consented: true))
    }

    func testUnknownWorkIsSaidInWordsNotAsADash() {
        XCTAssertNil(GoalongActivityHeadline.workFigure(known: false, seconds: 0), "UI-clair-02: no giant « — »")
        XCTAssertNil(GoalongActivityHeadline.workFigure(known: true, seconds: nil))
        XCTAssertEqual(GoalongActivityHeadline.workFigure(known: true, seconds: 4680), GoalongAnalyticsFormatting.duration(4680))
        XCTAssertFalse(GoalongActivityHeadline.unknownWork.contains("—"))
    }

    func testMonthWeaveNamesEveryRow() {
        // 2026-09-28 is a Monday.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))!
        XCTAssertEqual(GoalongThreadWeave.label(monday, dense: true, isFirst: false, calendar: calendar), "lun. 28")
        XCTAssertEqual(GoalongThreadWeave.label(tuesday, dense: true, isFirst: false, calendar: calendar), "29",
                       "UI-clair-04: no blank row label")
        XCTAssertEqual(GoalongThreadWeave.label(tuesday, dense: true, isFirst: true, calendar: calendar), "mar. 29")
        XCTAssertEqual(GoalongThreadWeave.label(tuesday, dense: false, isFirst: false, calendar: calendar), "mar. 29")
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        XCTAssertEqual(GoalongThreadWeave.label(first, dense: true, isFirst: false, calendar: calendar), "1 oct.")
    }

    func testMonthWeaveNamesTheMonthOnTheFirstOnEveryBranch() {
        // 2026-06-01 is a Monday: the Monday branch must not hide the month (R7-A-01).
        let mondayFirst = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let fridayFirst = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        XCTAssertEqual(GoalongThreadWeave.label(mondayFirst, dense: true, isFirst: false, calendar: calendar), "lun. 1 juin")
        XCTAssertEqual(GoalongThreadWeave.label(mondayFirst, dense: true, isFirst: true, calendar: calendar), "lun. 1 juin")
        XCTAssertEqual(GoalongThreadWeave.label(mondayFirst, dense: false, isFirst: false, calendar: calendar), "lun. 1 juin")
        XCTAssertEqual(GoalongThreadWeave.label(fridayFirst, dense: false, isFirst: false, calendar: calendar), "ven. 1 mai")
        XCTAssertEqual(GoalongThreadWeave.label(fridayFirst, dense: true, isFirst: true, calendar: calendar), "ven. 1 mai")
    }

    func testSidebarStatusForAFailedInputTapFitsTheSidebar() {
        let title = RuntimePresentation(state: .inputTapUnavailable, accessibilityGranted: true, inputMonitoringGranted: false,
            eventTapRunning: false, verificationEnabled: false, verificationServer: nil, captureHealth: nil).displayTitle
        XCTAssertLessThanOrEqual(title.count, 18, "UI-parcours-02: the sidebar row is not truncated")
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
        model.selectSection(.settings); model.navigationStore.settingsPane = .advanced
        model.selectSection(.privacy)
        XCTAssertEqual(model.navigationStore.highlightedSidebarSection, .settings)
        XCTAssertEqual(model.navigationStore.secondaryReturnTitle, "Retour aux réglages")
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.navigationStore.selectedSection, .settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .advanced, "Back returns to Avancé, not to the Settings home")

        model.selectSection(.history)
        model.selectSection(.agentActivity)
        XCTAssertEqual(model.navigationStore.highlightedSidebarSection, .history)
        XCTAssertEqual(model.navigationStore.secondaryReturnTitle, "Retour à l’historique")
        model.selectSection(.agentActivity) // e.g. reopening the window keeps the origin
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.navigationStore.selectedSection, .history)

        model.selectSection(.overview)
        model.selectSection(.screenTime)
        XCTAssertEqual(model.navigationStore.secondaryReturnTitle, "Activité")
        model.returnFromSecondaryPage()
        XCTAssertEqual(model.navigationStore.selectedSection, .overview)
        XCTAssertNil(model.navigationStore.secondaryReturn)
    }

    // MARK: - French presentation

    func testSecureInputDetailDoesNotBlameOnlyTheUsersExclusions() {
        let detail = CaptureHealthState.excludedPrivateOrSecure.frenchDetail
        XCTAssertFalse(detail.contains("selon vos exclusions"))
        XCTAssertTrue(detail.contains("sécurisée") && detail.contains("privée"))
    }

    @MainActor func testExclusionsShortcutOpensTheApplicationsPane() throws {
        let model = try isolatedModel()
        model.openApplicationsSettings()
        XCTAssertEqual(model.navigationStore.selectedSection, .settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .applications)
        XCTAssertEqual(SettingsPane.applications.title, "Apps et sites")
    }

    @MainActor func testTargetedDeletionMessagesAreFrenchAndNeverRawErrors() async throws {
        let request = TargetedHistoryDeletionRequest.computerHistoryEpisode(id: "episode", day: Date())
        let success = try isolatedModel(deleteTargeted: { _, done in done(.success(3)) })
        success.deleteTargetedDetails(request, successMessage: "Supprimé.")
        try await waitForAlert(success)
        XCTAssertEqual(success.alertStore.alert?.message, "Supprimé. 3 éléments locaux supprimés.")
        XCTAssertFalse(success.alertStore.alert?.message.contains("Removed") ?? true)

        let failure = try isolatedModel(deleteTargeted: { _, done in done(.failure(TargetedHistoryDeletionError.selectionExceedsLimit(10, 5))) })
        failure.deleteTargetedDetails(request, successMessage: "Supprimé.")
        try await waitForAlert(failure)
        XCTAssertEqual(failure.alertStore.alert?.message, TargetedHistoryDeletionError.selectionExceedsLimit(10, 5).errorDescription)
        XCTAssertFalse(failure.alertStore.alert?.message.contains("selectionExceedsLimit") ?? true)

        let wide = try isolatedModel(deleteDetails: { _, done in done(.failure(TargetedHistoryDeletionError.sourceIncomplete)) })
        wide.deleteDetails(since: nil)
        try await waitForAlert(wide)
        XCTAssertEqual(wide.alertStore.alert?.message, TargetedHistoryDeletionError.sourceIncomplete.errorDescription)
    }

    @MainActor private func waitForAlert(_ model: DashboardViewModel) async throws {
        for _ in 0..<100 where model.alertStore.alert == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(model.alertStore.alert)
    }

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
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "1 appareil, toutes les applications, tous les sites")
        options.selectedApplicationIDs = ["a", "b"]; options.selectedWebsiteDomains = []
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "1 appareil, 2 applications, 0 site")
        options.includeWebsites = false; options.deviceIDs = []
        XCTAssertEqual(GoalongWebsiteSettings.planSummary(options), "tous les appareils, 2 applications, sans sites")
    }

    private func isolatedModel(
        deleteDetails: @escaping DashboardViewModel.DeleteDetails = { _, done in done(.success(0)) },
        deleteTargeted: @escaping DashboardViewModel.DeleteTargetedDetails = { _, done in done(.success(0)) }
    ) throws -> DashboardViewModel {
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
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: deleteDetails,
            onDeleteTargetedDetails: deleteTargeted)
    }
}
#endif
