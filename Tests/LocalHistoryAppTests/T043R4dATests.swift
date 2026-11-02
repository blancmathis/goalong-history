#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
import LocalHistoryCore
import Ambiance
@testable import LocalHistoryApp

/// T-043 lot R4d-A: Activité, Agents, Ambiance, Mon travail, Accueil and the pause say what is true, once.
/// Views are hosted off screen (no window ordered front, no focus).
@MainActor
final class T043R4dATests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }()
    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day))! }
    private func day(_ number: Int, from start: Double, minutes: Int, app: String = "Editor") -> GoalongLocalAnalytics.Day {
        let base = date(number)
        let events = minutes < 0 ? [] : (0...minutes).map { minute in
            HistoryEvent(id: "\(number)-\(start)-\(minute)", sessionID: "fixture",
                timestamp: base.addingTimeInterval(start + Double(minute * 60)), kind: .heartbeat,
                app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1), url: nil,
                classification: .init(category: "fixture", isWork: nil, confidence: 0.9, classifierVersion: "fixture-v1"))
        }
        return GoalongLocalAnalytics.build(events: events, day: base, now: base.addingTimeInterval(86400), calendar: calendar)
    }

    // R4d-1: a refused folder is not a full disk, in Activité and in the support report.
    func testStorageCauseNamesTheRealFailure() {
        XCTAssertEqual(GoalongActivityEmptyCopy.storageCause(.permissionDenied), "le dossier refuse l’écriture")
        XCTAssertEqual(GoalongActivityEmptyCopy.storageCause(.diskFull), "le disque est plein")
        let storage = SupportStorage(freeMB: 80_000, lowSpace: false, storesMB: [:], eventDayFiles: 1, enumerationTruncated: false)
        let findings = SupportFindings.detect(live: ["storageInterrupted": .flag(true), "storageFailure": .state(.permissionDenied)],
                                              timeline: [], storage: storage, crashes: [], diagnosticsEnabled: true)
        let detail = findings.first { $0.code == .recordingInterrupted }?.detail ?? ""
        XCTAssertTrue(detail.contains("le dossier refuse l’écriture"), detail)
        XCTAssertFalse(detail.contains("disque est plein"), detail)
    }

    // R4d-5: the « Usage principal » line carries the app's icon; a website keeps its globe.
    func testTopInsightCarriesTheAppIcon() {
        let summary = GoalongActivitySummary(period: .init(days: [day(10, from: 9 * 3600, minutes: 90)]),
                                             previous: .init(days: []), calendar: calendar, now: date(20))
        let app = GoalongActivityUsageItem(id: "a", name: "Editor", bundleIdentifier: "fixture.Editor", isWebsite: false, seconds: 3600)
        let top = summary.insights(topUsage: app, biggestChange: nil).first { $0.id == "top" }
        XCTAssertEqual(top?.app, .init(bundleIdentifier: "fixture.Editor", name: app.displayName))
        let site = GoalongActivityUsageItem(id: "s", name: "example.com", bundleIdentifier: nil, isWebsite: true, seconds: 3600)
        let web = summary.insights(topUsage: site, biggestChange: nil).first { $0.id == "top" }
        XCTAssertNotNil(web); XCTAssertNil(web?.app)
    }

    // R4d-8: « Vérifier les sources » lists the sources in error, five at most, then the count of the rest.
    func testFailedSourcesAreListed() {
        let five = (1...5).map { "/source/\($0)" }
        XCTAssertEqual(AgentActivityPage.failedSourceLines(five), five)
        let seven = (1...7).map { "/source/\($0)" }
        XCTAssertEqual(AgentActivityPage.failedSourceLines(seven), Array(seven.prefix(5)) + ["et 2 autres sources"])
        XCTAssertEqual(AgentActivityPage.failedSourceLines(Array((1...6).map { "/s/\($0)" })).last, "et 1 autre source")
        XCTAssertEqual(AgentActivityPage.failedSourceLines([]), [])
    }

    // R4d-9: a pack download shows « Téléchargement… » on the Ambiance row of the sidebar, and only there.
    func testAmbianceDownloadShowsInTheSidebar() {
        let downloading = [AmbiancePackState(id: "o", title: "O", bytes: 1, status: .downloading(0.4)),
                           AmbiancePackState(id: "t", title: "T", bytes: 1, status: .installed)]
        XCTAssertTrue(AmbianceDownloadSignal.isDownloading(downloading))
        XCTAssertFalse(AmbianceDownloadSignal.isDownloading([AmbiancePackState(id: "o", title: "O", bytes: 1, status: .failed("x"))]))
        XCTAssertEqual(DashboardSection.ambiance.sidebarPill(ambianceDownloading: true), "Téléchargement…")
        XCTAssertNil(DashboardSection.ambiance.sidebarPill(ambianceDownloading: false))
        XCTAssertNil(DashboardSection.activity.sidebarPill(ambianceDownloading: true))
    }

    // R4d-10: each Activité detail has one header; the title is not repeated by its first section.
    func testDetailHeaderTitles() {
        XCTAssertEqual(GoalongActivityDetail.rhythm.headerTitle(isDay: true), "Rythme")
        XCTAssertNotNil(GoalongActivityDetail.screenTime.headerTitle(isDay: false))
        for detail in [GoalongActivityDetail.usage, .sessions, .agenda, .code, .sleep, .reports] {
            XCTAssertNil(detail.headerTitle(isDay: true), "\(detail)")
        }
    }

    // R4d-11: a stable « Explorer » list, a hero while work is unclassified, a reason without comparison, % on sleep.
    func testActivityReadsTheSameEveryDay() {
        let all = GoalongActivityDetail.exploreItems(isPreview: false, isAvailable: { _ in true })
        XCTAssertEqual(all, GoalongActivityDetail.allCases, "the list does not change with the observations")
        XCTAssertFalse(GoalongActivityDetail.exploreItems(isPreview: true, isAvailable: { _ in true }).contains(.screenTime))
        XCTAssertEqual(GoalongActivityDetail.noDurationCaption, "Aucune durée mesurée pour l’instant")
        XCTAssertNotNil(GoalongActivityHeadline.pendingFigure(known: false, seconds: 5400))
        XCTAssertNil(GoalongActivityHeadline.pendingFigure(known: false, seconds: 30))
        XCTAssertNil(GoalongActivityHeadline.pendingFigure(known: true, seconds: 5400))
        XCTAssertEqual(GoalongActivityHeadline.unit(work: false, isDay: false), "à classer par jour")
        XCTAssertEqual(GoalongActivityHeadline.unit(work: true, isDay: true), "de travail")
        XCTAssertEqual(GoalongActivityHeadline.noComparisonReason(isDay: false, hasComparison: false, pending: false, days: 7),
                       "Aucune comparaison : rien n’est observé les 7 jours précédents")
        XCTAssertNil(GoalongActivityHeadline.noComparisonReason(isDay: false, hasComparison: true, pending: false, days: 7))
        XCTAssertNil(GoalongActivityHeadline.noComparisonReason(isDay: true, hasComparison: false, pending: false, days: 1))
        XCTAssertEqual(GoalongSleepSection.share(1800, of: 7200), "25\u{00A0}%")
        XCTAssertEqual(GoalongSleepSection.share(2000, of: 3000), "67\u{00A0}%", "rounded, not cut")
        XCTAssertTrue(GoalongAnalyticsContent.fullDayChangesRange(day(10, from: 9 * 3600, minutes: 90), calendar: calendar))
        XCTAssertFalse(GoalongAnalyticsContent.fullDayChangesRange(nil, calendar: calendar))
        XCTAssertFalse(GoalongAnalyticsContent.fullDayChangesRange(day(11, from: 0, minutes: -1), calendar: calendar),
                       "a day without observations already shows 24 hours: the toggle has nothing to change")
    }

    // R4d-12: each named status of Mon travail has its own icon.
    func testWorkStatusesHaveDistinctIcons() {
        let states: [GoalongWorkAgent.Readiness] = [.ready, .noDefinition, .historyOff, .noConsent, .notConnected, .paused]
        let symbols = states.map { GoalongWorkPage.statusSymbol(running: false, failed: false, readiness: $0, checking: false) }
        XCTAssertEqual(Set(symbols).count, states.count, "\(symbols)")
        XCTAssertNotEqual(GoalongWorkPage.statusSymbol(running: false, failed: false, readiness: .notConnected, checking: true),
                          GoalongWorkPage.statusSymbol(running: false, failed: false, readiness: .notConnected, checking: false))
        XCTAssertEqual(GoalongWorkPage.statusSymbol(running: false, failed: true, readiness: .ready, checking: false), "exclamationmark.triangle")
    }

    // R4d-19: Modules renders the delete state of the runtime it is given. The two runtimes differ from `.shared`
    // (empty under the isolated HOME) on one side each, so ignoring `concentration:` fails the second check.
    func testModulesShowsTheInjectedConcentrationState() throws {
        try requireIsolatedHome()
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("r4da-focus-\(UUID().uuidString)")
        let full = FileManager.default.temporaryDirectory.appendingPathComponent("r4da-focus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty); try? FileManager.default.removeItem(at: full) }
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: full.appendingPathComponent("pending-stop.json"))
        let help = "Aucune donnée de Concentration sur ce Mac."
        let withoutData = ConcentrationRuntime(storeFactory: { FocusStore(directory: empty) }, presentsPanels: false)
        withoutData.refreshHasData()
        XCTAssertTrue(visibleText(GoalongModulesSettings(onOpen: { _ in }, concentration: withoutData), width: 640, height: 900).contains(help))
        let withData = ConcentrationRuntime(storeFactory: { FocusStore(directory: full) }, presentsPanels: false)
        withData.refreshHasData()
        XCTAssertTrue(withData.hasStoredData)
        let texts = visibleText(GoalongModulesSettings(onOpen: { _ in }, concentration: withData), width: 640, height: 900)
        XCTAssertFalse(texts.contains(help), "the runtime given holds data: the button is not explained as empty; \(texts.sorted())")
    }

    // R4d-9 (view side): the sidebar reads the signal. Without that read, the pill never shows.
    func testSidebarReadsTheAmbianceDownloadSignal() throws {
        let model = try dashboardModel()
        model.showWelcome = false
        let modules = GoalongModuleStore.shared, wasOn = modules.isEnabled(.ambiance)
        modules.setEnabled(.ambiance, true)
        defer { modules.setEnabled(.ambiance, wasOn); AmbianceDownloadSignal.shared.setForTesting(false) }
        let pill = "Ambiance, Téléchargement…"
        AmbianceDownloadSignal.shared.setForTesting(true)
        XCTAssertTrue(visibleText(LocalHistoryDashboardView(model: model), width: 900, height: 620).contains(pill))
        AmbianceDownloadSignal.shared.setForTesting(false)
        let off = visibleText(LocalHistoryDashboardView(model: model), width: 900, height: 620)
        XCTAssertFalse(off.contains(pill))
        XCTAssertTrue(off.contains("Ambiance"), "the row itself stays: \(off.sorted())")
    }

    // R4d-24 (view side): a missing own file offers « Localiser… » on its row; a present one does not.
    func testMissingOwnFileOffersLocate() {
        let sources = GalleryFixtures.ambianceSources(orchestra: true, textures: true, files: true)
        let page = AmbiancePageContent(sources: sources, packs: GalleryFixtures.ambiancePacks(.installed, .installed), state: .idle,
                                       volume: .constant(0.5), actions: GalleryFixtures.ambianceActions)
        let texts = visibleText(page, width: 900, height: 1_600)
        XCTAssertTrue(texts.contains("Localiser…"), "\(texts.sorted())")
        XCTAssertTrue(texts.contains("Fichier introuvable"))
        XCTAssertTrue(texts.contains("ambiance-locate-file:/Volumes/Disque/Forêt.wav"))
        XCTAssertFalse(texts.contains("ambiance-locate-file:/Users/exemple/Musique/Pluie du matin.m4a"))
    }

    // R4d-24: an own file reads by its name, without its extension.
    func testAmbianceFileTitleDropsTheExtension() {
        XCTAssertEqual(AmbiancePageContent.fileTitle("Pluie de Kyoto.wav"), "Pluie de Kyoto")
        XCTAssertEqual(AmbiancePageContent.fileTitle("Sans extension"), "Sans extension")
        XCTAssertEqual(AmbiancePageContent.fileTitle(".wav"), ".wav")
    }

    // R4d-25: the withheld-titles notice is two short sentences.
    func testWithheldTitlesNoticeIsTwoSentences() {
        let notice = GoalongWorkPage.withheldTitlesNotice
        XCTAssertEqual(notice.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count, 2, notice)
        XCTAssertTrue(notice.contains("Données pour ChatGPT"))
    }

    // MARK: - Helpers (same as T043R4cTests)

    func dashboardModel() throws -> DashboardViewModel {
        try requireIsolatedHome()
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/r4da-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "r4da-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
    }

    func requireIsolatedHome() throws {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check (writes fixtures under Application Support)")
        }
    }

    func visibleText(_ root: some View, width: CGFloat, height: CGFloat) -> Set<String> {
        let view = NSHostingView(rootView: root.frame(width: width).environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        var found = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 20_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                if let text = read(object, name) as? String, !text.isEmpty { found.insert(text) }
            }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
