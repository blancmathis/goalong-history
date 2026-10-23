#if os(macOS)
import AppKit
import Ambiance
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Models and data of the gallery, built with the domain types (spec C §5.7). Fixed clock, preferences of the
/// entry, simulated permissions and free space; never the real HOME (the runner refuses it).
@MainActor enum GalleryFixtures {
    struct DashboardOptions {
        var section: DashboardSection = .overview
        var settingsPane: SettingsPane = .home
        var globallyPaused = false
        var showWelcome = false
    }

    /// The design audit's dashboard model, with the gallery's seams, made visible so its data loads.
    /// Réglages › Applications and the analysis sheet list these instead of the host Mac's apps (C1-couverture-03).
    static let installedApplications: [GoalongApplicationChoice] = [
        ("com.apple.dt.Xcode", "Xcode"), ("com.apple.Safari", "Safari"), ("com.apple.Terminal", "Terminal"),
        ("com.apple.Notes", "Notes"), ("com.apple.mail", "Mail"), ("com.apple.MobileSMS", "Messages"),
        ("com.apple.iCal", "Calendrier"), ("com.apple.Music", "Musique"), ("com.apple.Preview", "Aperçu"),
        ("com.exemple.atlas", "Atlas"), ("org.keepassxc.keepassxc", "KeePassXC"),
    ].map { GoalongApplicationChoice(id: $0.0, name: $0.1) }

    static func dashboardModel(_ ctx: GalleryContext, _ options: DashboardOptions = DashboardOptions()) throws -> DashboardViewModel {
        let config = ConfigManager()
        let status = ctx.environment.permissions
        let permissions = PermissionManager(statusProbe: { status }, probeOnBackground: false, clock: { GalleryClock.now })
        let health = CaptureHealthStore(permissions: permissions)
        if ctx.environment.inputTapWorks {
            // A recorder that started and saw input a moment ago (the sidebar says « suivi actif »).
            let seen = GalleryClock.now.addingTimeInterval(-20)
            health.markTapEnabled()
            health.markInputCallback(at: seen)
            health.markRecordedEvent(.heartbeat, at: seen)
            health.markAXSuccess(urlAvailable: true, at: seen)
        }
        if let kind = ctx.environment.storageFailure {
            health.markStorageInterrupted(kind, at: GalleryClock.now.addingTimeInterval(-60))
        }
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/goalong-gallery"),
            performInitialDiscovery: false, sourceDiscovery: { [] }, onCaptured: { _ in })
        let paused = options.globallyPaused
        if paused { try GalleryFixtureHome.writeGlobalPause() }
        let freeBytes = ctx.environment.freeBytes
        let usedBytes = ctx.environment.usedBytes
        let model = DashboardViewModel(state: CaptureState(isGloballyPaused: { paused }), permissions: permissions,
            configManager: config, sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "galerie", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { true }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) },
            dataReader: DashboardDataReader(now: { GalleryClock.now }, storageBytes: { usedBytes }),
            now: { GalleryClock.now }, defaults: ctx.defaults, availableBytes: { freeBytes },
            analyticsReader: GoalongAnalyticsReader(root: AppPaths.applicationSupportDirectory, now: { GalleryClock.now }))
        model.showWelcome = options.showWelcome
        if options.section == .monitoring {
            // Jev has no page of its own: the app routes it to Réglages › Jev.
            model.selectSection(.monitoring)
        } else {
            model.selectedSection = options.section
            model.settingsPane = options.settingsPane
        }
        model.dashboardDidBecomeVisible()
        ctx.keep(model)
        ctx.keep(agents)
        ctx.cleanups.append { model.dashboardDidBecomeHidden() }
        return model
    }

    /// Default predicate of a page with data: a snapshot arrived, no refresh runs, the queues are empty.
    static func dashboardReady(_ model: DashboardViewModel) -> (GalleryContext) -> Bool {
        { _ in
            guard model.snapshotGeneration > 0, !model.isRefreshing,
                  ComputerHistoryPageModel.refreshesInFlight == 0,
                  GoalongAnalyticsModel.loadsInFlight == 0, GoalongWorkReviewModel.loadsInFlight == 0 else { return false }
            model.waitForPendingWorkForTesting()
            return model.snapshotGeneration > 0 && !model.isRefreshing
        }
    }

    /// A content panel: the view rendered alone on the page background, padded like a sheet.
    static func panel(_ view: some View) -> AnyView { AnyView(view) }

    // MARK: Blocking

    static let socialID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let videoID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let focusID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static var socialList: BlockList {
        BlockList(id: socialID, name: "Réseaux sociaux",
                  sites: ["x.com", "instagram.com", "facebook.com", "tiktok.com", "reddit.com"].map { BlockSiteRule(pattern: $0) },
                  apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")],
                  program: BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...5), startMinute: 540, endMinute: 1_080)],
                                        lockedUntil: nil),
                  quotaMinutesPerDay: 20, breaks: BlockBreaks(count: 3, minutes: 5),
                  exceptions: [BlockSiteRule(pattern: "reddit.com/r/swift")], keywords: ["match en direct", "transfert"],
                  reason: "Finir le mémoire avant vendredi.",
                  triggers: BlockTriggers(apps: [BlockAppRule(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")]),
                  earn: BlockEarn())
    }
    static var videoList: BlockList {
        BlockList(id: videoID, name: "Vidéo",
                  sites: ["youtube.com", "netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) },
                  apps: [BlockAppRule(bundleIdentifier: "com.apple.TV", name: "TV"),
                         BlockAppRule(bundleIdentifier: "com.apple.Music", name: "Musique")],
                  program: BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 1_290, endMinute: 420)],
                                        lockedUntil: GalleryClock.now.addingTimeInterval(20 * 86_400)),
                  exceptions: [BlockSiteRule(pattern: "youtube.com/@cs50")], keywords: ["bande-annonce"])
    }
    static var focusList: BlockList {
        BlockList(id: focusID, name: "Écriture", mode: .allowOnly,
                  sites: ["docs.google.com", "notion.so"].map { BlockSiteRule(pattern: $0) },
                  apps: [BlockAppRule(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                         BlockAppRule(bundleIdentifier: "com.apple.iWork.Pages", name: "Pages")])
    }

    /// The day before the gallery day, outside every program window for the idle states.
    static var sunday: Date { GalleryClock.at(15, 10, dayOffset: -5) }
    /// Monday afternoon of the gallery week: inside the social list's program.
    static var blockingNow: Date { GalleryClock.at(15, 10) }

    static func blockingEmpty() -> BlockingController {
        let now = blockingNow
        return BlockingController(clock: { now })
    }

    static func blockingIdle() -> BlockingController {
        var document = BlockingDocument()
        document.lists = [socialList, videoList, focusList]
        let sunday = sunday
        return BlockingController(document: document, clock: { sunday })
    }

    static func blockingActive() -> BlockingController {
        let now = blockingNow
        var document = BlockingDocument()
        document.lists = [socialList, videoList, focusList]
        document.sessions = [BlockSession(listIDs: [socialID, focusID], start: now.addingTimeInterval(-50 * 60),
                                          end: now.addingTimeInterval(84 * 60), lock: .locked)]
        var usage = BlockDayUsage(day: BlockingController.dayKey(now))
        usage.quotaSecondsUsed[socialID] = 13 * 60
        usage.breaksTaken[socialID] = 1
        usage.blocked = [socialID: 4, focusID: 3]
        usage.earnedSeconds = [socialID: 600.0]
        document.usage = usage
        return BlockingController(document: document, clock: { now })
    }

    static func blockingTriggered() -> BlockingController {
        let now = blockingNow
        var document = BlockingDocument()
        document.lists = [socialList, videoList, focusList]
        document.sessions = [BlockSession(listIDs: [socialID], start: now.addingTimeInterval(-25 * 60), end: .distantFuture,
                                          lock: .free, origin: .trigger(socialID))]
        return BlockingController(document: document, clock: { now })
    }

    /// A block protected by the password (stored in the document, never in the keychain) and one set for tonight.
    static func blockingGuarded() -> BlockingController {
        let now = blockingNow
        var document = BlockingDocument()
        document.lists = [socialList, videoList, focusList]
        let controller = BlockingController(document: document, clock: { now })
        controller.setPassword("rendu-fixe")
        controller.start(listIDs: [socialID], until: now.addingTimeInterval(84 * 60), lock: .password)
        controller.schedule(listIDs: [videoID, focusID], start: now.addingTimeInterval(18 * 3_600 + 50 * 60),
                            end: now.addingTimeInterval(21 * 3_600 + 50 * 60), lock: .typing)
        return controller
    }

    static var freeze: BlockFreeze {
        let now = blockingNow
        return BlockFreeze(start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(64 * 60 + 12), mode: .shield,
                           allowedApps: [BlockAppRule(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                                         BlockAppRule(bundleIdentifier: "com.apple.iCal", name: "Calendrier")])
    }

    // MARK: Ambiance

    static let focusSources = [("ambre", "Ambre"), ("canopee", "Canopée"), ("meridien", "Méridien"), ("sillage", "Sillage"),
                               ("filigrane", "Filigrane"), ("confluence", "Confluence"), ("sanctuaire", "Sanctuaire"),
                               ("gravite", "Gravité"), ("orbit", "Orbite"), ("sonar", "Sonar")]
    static let relaxSources = [("lagoon", "Lagon"), ("stillwater", "Eau calme"), ("hearth", "Foyer"), ("reverie", "Rêverie"),
                               ("driftwood", "Bois flotté")]
    static let textureSources = [("rain", "Pluie douce"), ("ocean", "Marée"), ("brown", "Velours brun"), ("pink", "Air rose"),
                                 ("aube", "Aube")]

    static func ambianceSources(orchestra: Bool, textures: Bool, files: Bool) -> [AmbianceSource] {
        var result = focusSources.map { AmbianceSource(id: $0.0, title: $0.1, kind: .focus, isAvailable: orchestra) }
            + relaxSources.map { AmbianceSource(id: $0.0, title: $0.1, kind: .relax, isAvailable: orchestra) }
        if textures { result += textureSources.map { AmbianceSource(id: $0.0, title: $0.1, kind: .texture, isAvailable: true) } }
        if files {
            result += [
                AmbianceSource(id: "file:/Users/exemple/Musique/Pluie du matin.m4a", title: "Pluie du matin.m4a", kind: .ownFile,
                               isAvailable: true, path: "/Users/exemple/Musique/Pluie du matin.m4a"),
                AmbianceSource(id: "file:/Volumes/Disque/Forêt.wav", title: "Forêt.wav", kind: .ownFile,
                               isAvailable: false, path: "/Volumes/Disque/Forêt.wav"),
            ]
        }
        return result
    }

    static func ambiancePacks(_ orchestra: AmbiancePackState.Status, _ textures: AmbiancePackState.Status) -> [AmbiancePackState] {
        [AmbiancePackState(id: "orchestra", title: "Orchestre acoustique", bytes: 77_158_400, status: orchestra),
         AmbiancePackState(id: "textures", title: "Textures et Aube", bytes: 83_363_840, status: textures)]
    }

    static let ambianceActions = AmbianceActions(play: { _ in }, stop: {}, download: { _ in }, cancel: { _ in },
                                                 remove: { _ in }, addFiles: { _ in }, removeFile: { _ in })
}

/// Puts the process-wide state read by the views back to its initial value before every image (spec C §5.6).
@MainActor enum GalleryStateReset {
    /// `resetData: false` in the smoke test: `make test` shares its HOME with the other tests of the process.
    static func all(home: URL, resetData: Bool = true) throws {
        GoalongToastCenter.shared.setForTesting(nil)
        GoalongToastCenter.suppressedForTesting = true
        ProductIdentity.galleryOverride = ProductIdentity.GalleryIdentity()
        GoalongWorkPage.galleryReviewFocusTask = nil
        GoalongWorkReviewModel.lastLoadedRowCount = nil
        guard resetData else { return }
        try resetHome(home)
        JevWorkContextStore.shared.resetForTesting()
        GoalongWorkStore.shared.resetForTesting()
        // The consent file left with the HOME: every capability is off again.
        GoalongCapabilityConsentStore.shared.reload()
    }

    /// About one reset in 300 met « Operation not permitted » while removing the data folder (cause not found,
    /// C-impl.md). Two more tries, then the folder moves aside inside the shard HOME, which the script deletes.
    static func removeOrMoveAside(_ folder: URL, home: URL) throws {
        let manager = FileManager.default
        var lastError: Error?
        for attempt in 0..<3 {
            do { try manager.removeItem(at: folder); return } catch { lastError = error }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05 * Double(attempt + 1)))
        }
        do {
            try manager.moveItem(at: folder, to: home.appendingPathComponent(".gallery-trash-" + UUID().uuidString))
        } catch {
            throw lastError ?? error
        }
    }

    /// Removes the entry's data under the shard HOME. `Library/Preferences` stays: the hook deletes the suites' plists.
    static func resetHome(_ home: URL) throws {
        let manager = FileManager.default
        guard home.path.hasPrefix("/tmp/goalong-") || home.path.hasPrefix("/private/tmp/goalong-") else {
            throw GalleryError.guardRefused("HOME \(home.path) is not a gallery HOME")
        }
        let support = AppPaths.applicationSupportDirectory
        guard support.path.hasPrefix(home.path + "/") || support.path.hasPrefix(home.resolvingSymlinksInPath().path + "/") else {
            throw GalleryError.guardRefused("data root \(support.path) is outside HOME")
        }
        // The previous entry's background reads and analysis passes may still run: wait for the history page's
        // refreshes, then close the derived-write barrier like a history clear does, so no late summary or
        // checkpoint of the previous data lands in this entry's HOME.
        let deadline = Date().addingTimeInterval(5)
        while (ComputerHistoryPageModel.refreshesInFlight > 0 || GoalongAnalyticsModel.loadsInFlight > 0
                || GoalongWorkReviewModel.loadsInFlight > 0) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let barrier = DerivedHistoryWriteBarrier.shared
        let suspension = barrier.suspend()
        defer { barrier.resume(suspension) }
        var drained = false
        barrier.notifyWhenDrained(suspension) { drained = true }
        while !drained && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard drained else { throw GalleryError.render("background history work did not finish in 5 s") }
        if manager.fileExists(atPath: support.path) { try removeOrMoveAside(support, home: home) }
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
    }
}
#endif
