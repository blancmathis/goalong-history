#if os(macOS)
import Ambiance
import BraiseCore
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Concentration (Maintenant, Distractions, panels), Braise and Ambiance contents. Taken from the opt-in render tests,
/// moved to the gallery clock: Friday 23 October 2026, 15:10 for the afternoon states.
extension GalleryCatalog {
    static var concentrationEntries: [GalleryEntry] {
        let width: CGFloat = 900
        func page(_ id: String, height: CGFloat, themes: [GalleryTheme] = GalleryTheme.standard,
                  _ make: @escaping @MainActor (GalleryConcentrationFixtures) throws -> AnyView) -> GalleryEntry {
            panel(id, width: width, height: height, themes: themes, clock: .injected) { _ in
                try make(GalleryConcentrationFixtures())
            }
        }
        var draft = FocusComposerDraft(); draft.free = .minutes(50)
        var pomodoroDraft = FocusComposerDraft()
        pomodoroDraft.kind = .pomodoro; pomodoroDraft.cycles = 4
        pomodoroDraft.intent = "Relire les épreuves"; pomodoroDraft.blockListIds = [GalleryConcentrationFixtures.socialID]
        pomodoroDraft.lock = true
        let now = GalleryConcentrationFixtures.now
        func tab(_ section: DashboardSection, _ content: some View) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 0) {
                ConcentrationHubHeader(tab: .constant(section))
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            })
        }
        return [
            // UI-15C (2): 1100 so the frame does not cut « Réglages » at the bottom.
            page("concentration-maintenant/vide", height: 1_100, themes: GalleryTheme.withContrast) { f in
                tab(.concentration, ConcentrationPageContent(controller: try f.empty(), now: now, measures: [], draft: draft))
            },
            page("concentration-maintenant/plan-du-jour", height: 1_700) { f in
                let planned = try f.planned()
                return tab(.concentration, ConcentrationPageContent(controller: planned.controller, now: now,
                                                                    measures: planned.measures, draft: pomodoroDraft))
            },
            page("concentration-maintenant/pomodoro-en-cours", height: 1_350) { f in
                tab(.concentration, ConcentrationPageContent(controller: try f.pomodoro(), now: now, measures: [], draft: draft))
            },
            page("concentration-maintenant/verrouille", height: 1_000) { f in
                tab(.concentration, ConcentrationPageContent(controller: try f.locked(), now: now, measures: [], draft: draft))
            },
            page("concentration-maintenant/seance-libre", height: 1_000) { f in
                tab(.concentration, ConcentrationPageContent(controller: try f.open(), now: now, measures: [], draft: draft))
            },
            page("concentration-maintenant/reglages", height: 2_250) { f in
                let planned = try f.planned()
                return AnyView(ConcentrationPageContent(controller: planned.controller, now: now, measures: planned.measures,
                                                        draft: draft, settingsOpen: true))
            },
            page("concentration-maintenant/module-coupe", height: 300) { _ in
                tab(.concentration, GoalongModuleOffNote(module: .concentration,
                    text: "Activez-le pour lancer des séances et des Pomodoro, préparer le plan du jour et lire le bilan."))
            },
            page("concentration-distractions/vide", height: 760) { f in
                tab(.distractions, DistractionsPage(runtime: BlockingRuntime(controller: f.blocking), now: now))
            },
            page("concentration-distractions/listes", height: 820) { f in
                tab(.distractions, DistractionsPage(runtime: BlockingRuntime(controller: f.blockingWithLists()), now: now))
            },
            panel("concentration-panneaux/phase-travail", width: 380, clock: .injected) { _ in
                AnyView(FocusPhaseNotice(isWork: true, intent: "Rédiger le chapitre 2", endsAt: now.addingTimeInterval(1_500)))
            },
            panel("concentration-panneaux/phase-pause", width: 380, clock: .injected) { _ in
                AnyView(FocusPhaseNotice(isWork: false, intent: "Rédiger le chapitre 2", endsAt: now.addingTimeInterval(300)))
            },
            panel("concentration-panneaux/revue-de-fin", width: 460) { _ in
                AnyView(FocusReviewPanelView(intent: "Rédiger le chapitre 2", seconds: 50 * 60, facts: GalleryConcentrationFixtures.facts,
                                             onAnswer: { _, _ in }, onClose: {}))
            },
            panel("concentration-panneaux/revue-sans-mesure", width: 460) { _ in
                AnyView(FocusReviewPanelView(intent: "Lire l’article", seconds: 25 * 60, facts: FocusFacts(),
                                             onAnswer: { _, _ in }, onClose: {}))
            },
            panel("concentration-panneaux/matin", width: 420) { _ in
                AnyView(FocusPromptPanelView(morning: true, onNow: {}, onLater: {}))
            },
            panel("concentration-panneaux/soir", width: 420) { _ in
                AnyView(FocusPromptPanelView(morning: false, onNow: {}, onLater: {}))
            },
            panel("concentration-panneaux/limite", width: 420) { _ in
                AnyView(FocusLimitPanelView(text: "45 h de travail cette semaine — votre limite.", onClose: {}))
            },
            panel("concentration-panneaux/feuille-bilan", width: 640, clock: .injected) { _ in
                let planned = try GalleryConcentrationFixtures().planned().controller
                return AnyView(ConcentrationReviewSheet(controller: planned, plan: planned.plan, review: nil, onClose: {}))
            },
            panel("concentration-engagements/vide", width: 824, clock: .injected) { _ in
                AnyView(FocusCommitmentsSection(controller: try GalleryConcentrationFixtures().empty(), now: now,
                                                onEdit: { _ in }).padding(32))
            },
            panel("concentration-engagements/nouvel-engagement", width: 600, clock: .injected) { _ in
                let empty = try GalleryConcentrationFixtures().empty()
                let today = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(now))
                let tomorrow = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(now.addingTimeInterval(86_400)))
                var newDraft = FocusCommitmentDraft(period: today)
                newDraft.target = 420; newDraft.stakeLists = [GalleryConcentrationFixtures.socialID]
                return AnyView(FocusCommitmentEditor(controller: empty, request: .init(periods: [today, tomorrow]), now: now,
                                                     draft: newDraft, onClose: {}))
            },
            panel("ralentissement/site-attente", width: 1_100, height: 720, clock: .injected) { _ in
                AnyView(SlowDownVeil(presentation: GalleryConcentrationFixtures.slowDown(ready: false),
                                     item: .site("instagram.com"), now: now))
            },
            panel("ralentissement/site-pret", width: 1_100, height: 720, clock: .injected) { _ in
                AnyView(SlowDownVeil(presentation: GalleryConcentrationFixtures.slowDown(ready: true),
                                     item: .site("instagram.com"), now: now))
            },
            panel("ralentissement/app", width: 420, height: 168, clock: .injected) { _ in
                var app = GalleryConcentrationFixtures.slowDown(ready: false); app.name = "Messages"; app.occurrence = 1
                return AnyView(SlowDownAppCard(presentation: app,
                    item: .app(BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")), now: now))
            },
        ]
    }

    static var ambianceEntries: [GalleryEntry] {
        func page(_ id: String, width: CGFloat = 900, height: CGFloat, sources: [AmbianceSource], packs: [AmbiancePackState],
                  state: @escaping ([AmbianceSource]) -> AmbianceController.State = { _ in .idle }, lastSource: String? = nil) -> GalleryEntry {
            panel(id, width: width, height: height) { _ in
                var volume = 0.6
                let binding = Binding(get: { volume }, set: { volume = $0 })
                return AnyView(AmbiancePageContent(sources: sources, packs: packs, state: state(sources), lastSource: lastSource,
                                                   volume: binding, actions: GalleryFixtures.ambianceActions))
            }
        }
        let none = GalleryFixtures.ambianceSources(orchestra: false, textures: false, files: false)
        let all = GalleryFixtures.ambianceSources(orchestra: true, textures: true, files: true)
        return [
            page("ambiance/a-installer", height: 1_250, sources: none,
                 packs: GalleryFixtures.ambiancePacks(.notInstalled, .notInstalled)),
            page("ambiance/telechargement", height: 560, sources: none,
                 packs: GalleryFixtures.ambiancePacks(.downloading(0.42), .notInstalled)),
            page("ambiance/prete", height: 1_300, sources: GalleryFixtures.ambianceSources(orchestra: true, textures: false, files: false),
                 packs: GalleryFixtures.ambiancePacks(.installed, .downloading(0.67)), lastSource: "confluence"),
            page("ambiance/lecture", height: 1_500, sources: all, packs: GalleryFixtures.ambiancePacks(.installed, .installed),
                 state: { .playing($0[0]) }),
            page("ambiance/etroit", width: 640, height: 900, sources: all, packs: GalleryFixtures.ambiancePacks(.installed, .installed),
                 state: { .playing($0[0]) }),
            panel("braise/page", width: 900, height: 1_050) { ctx in AnyView(BraisePageContent(controller: try braise(ctx))) },
            panel("braise/panneau-compact", width: 480, height: 820) { ctx in
                AnyView(BraisePageContent(controller: try braise(ctx), compact: true))
            },
            panel("braise/echec-demarrage", width: 900, height: 420) { _ in
                AnyView(BraiseUnavailableView(error: "Braise n’a pas pu démarrer. Aucun filtre n’a été appliqué.",
                                              onRetry: {}, onOpenModules: {}, onEnable: {}))
            },
            panel("braise/editeur-de-regle", width: 650, height: 400) { ctx in
                let controller = try braise(ctx)
                return AnyView(BraiseRuleEditor(controller: controller, initial: controller.preferences.rules[0]))
            },
        ]
    }

    @MainActor static func braise(_ ctx: GalleryContext) throws -> BraiseController {
        let root = AppPaths.applicationSupportDirectory.appendingPathComponent("gallery-braise", isDirectory: true)
        let store = BraiseStore(directory: root, legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false,
                                             clock: { GalleryClock.at(15, 10) })
        controller.setMode(.on)
        try controller.saveRule(ScheduleRule(weekdays: Set(2...6), startMinute: 21 * 60, endMinute: 7 * 60))
        ctx.keep(controller)
        ctx.cleanups.append { controller.shutdown() }
        return controller
    }
}

/// The Concentration render fixtures (ConcentrationRenderingTests), on the gallery clock and in the shard HOME.
@MainActor final class GalleryConcentrationFixtures {
    final class Clock { var now: Date; init(_ now: Date) { self.now = now } }
    static let socialID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let videoID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static var now: Date { GalleryClock.at(15, 10) }
    static let facts = FocusFacts(activeSeconds: 47 * 60, workSeconds: 38 * 60, otherSeconds: 6 * 60, unclassifiedSeconds: 3 * 60,
                                  appSwitches: 14, longestStretchSeconds: 22 * 60, available: true)

    let clock = Clock(GalleryConcentrationFixtures.now)
    /// `FocusStore` opens each path part with `O_NOFOLLOW`: the HOME under `/tmp` (a symlink) goes through `realpath`.
    let root: URL = {
        let support = AppPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let real = realpath(support.path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) }
        return URL(fileURLWithPath: real ?? support.path, isDirectory: true).appendingPathComponent("gallery-focus", isDirectory: true)
    }()
    let social: BlockList
    let video: BlockList
    let blocking: BlockingController
    var day: String { BlockingController.dayKey(Self.now) }

    init() {
        social = BlockList(id: Self.socialID, name: "Réseaux sociaux",
                           sites: ["instagram.com", "x.com", "tiktok.com", "reddit.com"].map { BlockSiteRule(pattern: $0) },
                           apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")],
                           quotaMinutesPerDay: 20, action: .slowDown, slowDownSeconds: 10, continueMinutes: 10)
        video = BlockList(id: Self.videoID, name: "Vidéo",
                          sites: ["youtube.com", "netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) },
                          apps: [BlockAppRule(bundleIdentifier: "com.apple.TV", name: "TV")])
        let clock = self.clock
        var document = BlockingDocument(lists: [social, video])
        var usage = BlockDayUsage(day: BlockingController.dayKey(Self.now))
        usage.slowDownShown = [social.id: 5]; usage.renounced = [social.id: 3]; usage.continued = [social.id: 2]
        usage.quotaSecondsUsed[social.id] = 7 * 60
        document.usage = usage
        blocking = BlockingController(document: document, clock: { clock.now },
                                      continuous: { clock.now.timeIntervalSince1970 })
    }

    func blockingWithLists() -> BlockingController {
        let clock = self.clock
        let blocking = BlockingController(document: BlockingDocument(), clock: { clock.now },
                                          continuous: { clock.now.timeIntervalSince1970 })
        blocking.save(BlockList(name: "Réseaux sociaux", sites: ["instagram.com", "x.com", "tiktok.com"].map { BlockSiteRule(pattern: $0) },
                                apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")]))
        blocking.save(BlockList(name: "Vidéo", sites: ["netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) }))
        return blocking
    }

    /// A fresh store each call. The HOME is reset once per image, but `GalleryRenderer.render` builds the view again
    /// when a field is mis-measured: a store left by the render before would add its plan items a second time (the
    /// third `planned()` in one image threw `planFull`, R41).
    private func controller(_ name: String) throws -> ConcentrationController {
        let clock = self.clock, blocking = self.blocking
        let directory = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        return try ConcentrationController(store: FocusStore(directory: directory),
                                           clock: { clock.now }, blocking: { blocking })
    }

    private func at(_ hour: Int, _ minute: Int) -> Date { GalleryClock.at(hour, minute) }

    func empty() throws -> ConcentrationController {
        let value = try controller("empty"); value.refresh(); return value
    }

    func planned() throws -> (controller: ConcentrationController, measures: [FocusItemMeasure]) {
        clock.now = at(8, 50)
        let planned = try controller("planned")
        let chapter = try planned.addPlanItem(title: "Rédiger le chapitre 2", day: day, project: "Livre", estimateMinutes: 90)
        let quote = try planned.addPlanItem(title: "Envoyer le devis à Martin", day: day, project: "Clients", estimateMinutes: 30)
        let mails = try planned.addPlanItem(title: "Répondre aux mails en retard", day: day, estimateMinutes: 20)
        _ = try planned.addPlanItem(title: "Relire les épreuves", day: day)
        var plan = planned.plan; plan.intention = "Finir le premier jet du chapitre 2."
        try planned.setPlan(plan)
        var free = FocusMode(); free.minutes = 50
        clock.now = at(9, 12)
        try planned.startSession(intent: chapter.title, mode: free, planItemId: chapter.id)
        clock.now = at(10, 3); planned.refresh()
        try planned.recordOutcome(sessionID: planned.sessions.last!.id, outcome: .done)
        var pomodoro = FocusMode(); pomodoro.kind = .pomodoro; pomodoro.cycles = 2
        clock.now = at(11, 0)
        try planned.startSession(intent: quote.title, mode: pomodoro, planItemId: quote.id, blockListIds: [social.id])
        clock.now = at(11, 56); planned.refresh()
        try planned.recordOutcome(sessionID: planned.sessions.last!.id, outcome: .partly, note: "Il manque les prix de la phase 2.")
        var short = FocusMode(); short.minutes = 25
        clock.now = at(14, 0)
        try planned.startSession(intent: mails.title, mode: short, planItemId: mails.id)
        clock.now = at(14, 21)
        try planned.stopSession()
        try planned.setItemStatus(mails.id, day: day, status: .done)
        planned.dismissPanel()
        clock.now = Self.now
        planned.refresh(); planned.dismissPanel()
        let measures = [
            FocusItemMeasure(id: chapter.id, sessionMinutes: 50, projectWorkMinutes: 95, measuredMinutes: 95, estimateMinutes: 90),
            FocusItemMeasure(id: quote.id, sessionMinutes: 50, projectWorkMinutes: 12, measuredMinutes: 52, estimateMinutes: 30),
            FocusItemMeasure(id: mails.id, sessionMinutes: 21, projectWorkMinutes: nil, measuredMinutes: nil, estimateMinutes: 20),
        ]
        return (planned, measures)
    }

    func pomodoro() throws -> ConcentrationController {
        clock.now = at(14, 38)
        let value = try controller("pomodoro")
        let linked = try value.addPlanItem(title: "Rédiger le chapitre 2", day: day, project: "Livre", estimateMinutes: 90)
        _ = try value.addPlanItem(title: "Relire les épreuves", day: day)
        var classic = FocusMode(); classic.kind = .pomodoro; classic.cycles = 4
        try value.startSession(intent: linked.title, mode: classic, planItemId: linked.id, blockListIds: [social.id, video.id])
        clock.now = Self.now; value.refresh()
        return value
    }

    func locked() throws -> ConcentrationController {
        clock.now = at(14, 40)
        let value = try controller("locked")
        var long = FocusMode(); long.minutes = 90
        try value.startSession(intent: "Préparer la soutenance", mode: long, blockListIds: [video.id], lock: true)
        clock.now = Self.now; value.refresh()
        return value
    }

    func open() throws -> ConcentrationController {
        clock.now = at(14, 28)
        let value = try controller("open")
        var endless = FocusMode(); endless.minutes = nil
        try value.startSession(intent: "Lire la documentation de l’API", mode: endless)
        clock.now = Self.now; value.refresh()
        return value
    }

    static func slowDown(ready: Bool) -> BlockingFrictionPresentation {
        let now = Self.now
        var value = BlockingFrictionPresentation(listID: socialID, key: "k", name: "instagram.com",
                                                 shownAt: now.addingTimeInterval(-4), readyAt: now.addingTimeInterval(6), occurrence: 3)
        if ready { value.shownAt = now.addingTimeInterval(-12); value.readyAt = now.addingTimeInterval(-2) }
        return value
    }
}
#endif
