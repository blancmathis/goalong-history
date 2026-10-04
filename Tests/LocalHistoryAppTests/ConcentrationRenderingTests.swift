#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// Opt-in renders of the Concentration page, its panels and the « Ralentir » veil, with fixed data only.
/// `GOALONG_CONCENTRATION_SNAPSHOTS=<dir> swift test --filter ConcentrationRenderingTests`
final class ConcentrationRenderingTests: XCTestCase {
    /// Monday 5 October 2026, 15:10.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15, minute: 10))!

    private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    @MainActor func testRenderConcentrationSurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_CONCENTRATION_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with fixed data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let blockingWasOn = GoalongModuleStore.shared.isEnabled(.blocking)
        GoalongModuleStore.shared.setEnabled(.blocking, true)
        defer { GoalongModuleStore.shared.setEnabled(.blocking, blockingWasOn) }

        func render(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: some View) throws {
            let root = view.frame(width: width).fixedSize(horizontal: false, vertical: height == nil)
                .frame(height: height)
                .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                .environment(\.goalongReduceMotion, true).goalongControls()
            let controller = NSHostingController(rootView: root)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: height ?? 900))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let host = controller.view
            let fitted = height ?? max(60, host.fittingSize.height)
            window.setContentSize(NSSize(width: width, height: fitted))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2_000)
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("CONCENTRATION_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        let f = try Fixtures(now: now, root: temporaryRoot())
        var draft = FocusComposerDraft()
        draft.free = .minutes(50)
        var pomodoroDraft = FocusComposerDraft()
        pomodoroDraft.kind = .pomodoro; pomodoroDraft.cycles = 4
        pomodoroDraft.intent = "Relire les épreuves"; pomodoroDraft.blockListIds = [f.social.id]; pomodoroDraft.lock = true

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            let s = dark ? "dark" : "light"
            try render("page-empty-\(s)", width: 900, height: 980,
                       ConcentrationPageContent(controller: f.empty, now: now, measures: [], draft: draft))
            try render("page-plan-\(s)", width: 900, height: 1_700,
                       ConcentrationPageContent(controller: f.planned, now: now, measures: f.measures, draft: pomodoroDraft))
            try render("page-active-pomodoro-\(s)", width: 900, height: 1_350,
                       ConcentrationPageContent(controller: f.pomodoro, now: now, measures: f.measures, draft: draft))
            try render("page-active-locked-\(s)", width: 900, height: 1_000,
                       ConcentrationPageContent(controller: f.locked, now: now, measures: [], draft: draft))
            try render("page-active-open-\(s)", width: 900, height: 1_000,
                       ConcentrationPageContent(controller: f.open, now: now, measures: [], draft: draft))
            try render("page-settings-\(s)", width: 900, height: 2_250,
                       ConcentrationPageContent(controller: f.planned, now: now, measures: f.measures, draft: draft, settingsOpen: true))
            try render("panel-phase-work-\(s)", width: 380,
                       FocusPhaseNotice(isWork: true, intent: "Rédiger le chapitre 2", endsAt: now.addingTimeInterval(1_500)))
            try render("panel-phase-break-\(s)", width: 380,
                       FocusPhaseNotice(isWork: false, intent: "Rédiger le chapitre 2", endsAt: now.addingTimeInterval(300)))
            try render("panel-review-\(s)", width: 460,
                       FocusReviewPanelView(intent: "Rédiger le chapitre 2", seconds: 50 * 60, facts: f.facts,
                                            onAnswer: { _, _ in }, onClose: {}))
            try render("panel-review-unmeasured-\(s)", width: 460,
                       FocusReviewPanelView(intent: "Lire l’article", seconds: 25 * 60, facts: FocusFacts(),
                                            onAnswer: { _, _ in }, onClose: {}))
            try render("panel-morning-\(s)", width: 420, FocusPromptPanelView(morning: true, onNow: {}, onLater: {}))
            try render("panel-evening-\(s)", width: 420, FocusPromptPanelView(morning: false, onNow: {}, onLater: {}))
            try render("panel-limit-\(s)", width: 420,
                       FocusLimitPanelView(text: "45 h de travail cette semaine — votre limite.", onClose: {}))
            try render("review-sheet-\(s)", width: 640,
                       ConcentrationReviewSheet(controller: f.planned, plan: f.planned.plan, review: nil, onClose: {}))
            let waiting = BlockingFrictionPresentation(listID: f.social.id, key: "k", name: "instagram.com",
                                                       shownAt: now.addingTimeInterval(-4), readyAt: now.addingTimeInterval(6), occurrence: 3)
            var ready = waiting; ready.shownAt = now.addingTimeInterval(-12); ready.readyAt = now.addingTimeInterval(-2)
            try render("slowdown-site-\(s)", width: 1_100, height: 720,
                       SlowDownVeil(presentation: waiting, item: .site("instagram.com"), now: now))
            try render("slowdown-site-ready-\(s)", width: 1_100, height: 720,
                       SlowDownVeil(presentation: ready, item: .site("instagram.com"), now: now))
            var appWaiting = waiting; appWaiting.name = "Messages"; appWaiting.occurrence = 1
            try render("slowdown-app-\(s)", width: 420, height: 168,
                       SlowDownAppCard(presentation: appWaiting,
                                       item: .app(BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")), now: now))
            try render("blocking-list-ralentir-\(s)", width: 900, height: 2_500,
                       BlockingPageContent(controller: f.blocking, now: now, expanded: f.social.id))
            try render("modules-\(s)", width: 760, GoalongModulesSettings(onOpen: { _ in }).padding(32))
            try render("commitments-\(s)", width: 824,
                       FocusCommitmentsSection(controller: f.committed, now: now, onEdit: { _ in }).padding(32))
            try render("commitments-empty-\(s)", width: 824,
                       FocusCommitmentsSection(controller: f.empty, now: now, onEdit: { _ in }).padding(32))
            try render("panel-commitment-\(s)", width: 420,
                       FocusCommitmentPanelView(cards: f.settledCards, lists: [f.social, f.video], now: f.settledAt,
                                                onJoker: { _ in }, onDeclare: { _ in }, onClose: {}))
            let today = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(now))
            let tomorrow = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(now.addingTimeInterval(86_400)))
            var newDraft = FocusCommitmentDraft(period: today)
            newDraft.target = 420; newDraft.stakeLists = [f.social.id]
            try render("commitment-editor-new-\(s)", width: 600,
                       FocusCommitmentEditor(controller: f.empty, request: .init(periods: [today, tomorrow]), now: now,
                                             draft: newDraft, onClose: {}))
            try render("commitment-editor-harder-\(s)", width: 600,
                       FocusCommitmentEditor(controller: f.committed, request: .init(periods: [today], existing: f.committed.todayCommitment?.commitment),
                                             now: now, onClose: {}))
            try render("review-sheet-commit-\(s)", width: 640,
                       ConcentrationReviewSheet(controller: f.committed, plan: f.committed.plan, review: nil, commitTomorrow: true,
                                                now: now, onClose: {}))
        }
    }

    private func temporaryRoot() -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/focus-render-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private struct Fixtures {
        let social: BlockList
        let video: BlockList
        let blocking: BlockingController
        let empty: ConcentrationController
        let planned: ConcentrationController
        let pomodoro: ConcentrationController
        let locked: ConcentrationController
        let open: ConcentrationController
        let committed: ConcentrationController
        var settledCards: [FocusCommitmentCard] = []
        var settledAt = Date()
        var measures: [FocusItemMeasure] = []
        let facts = FocusFacts(activeSeconds: 47 * 60, workSeconds: 38 * 60, otherSeconds: 6 * 60, unclassifiedSeconds: 3 * 60,
                               appSwitches: 14, longestStretchSeconds: 22 * 60, available: true)

        init(now: Date, root: URL) throws {
            let clock = Clock(now)
            social = BlockList(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Réseaux sociaux",
                               sites: ["instagram.com", "x.com", "tiktok.com", "reddit.com"].map { BlockSiteRule(pattern: $0) },
                               apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")],
                               quotaMinutesPerDay: 20, action: .slowDown, slowDownSeconds: 10, continueMinutes: 10)
            video = BlockList(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Vidéo",
                              sites: ["youtube.com", "netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) },
                              apps: [BlockAppRule(bundleIdentifier: "com.apple.TV", name: "TV")])
            var document = BlockingDocument(lists: [social, video])
            var usage = BlockDayUsage(day: BlockingController.dayKey(now))
            usage.slowDownShown = [social.id: 5]; usage.renounced = [social.id: 3]; usage.continued = [social.id: 2]
            usage.quotaSecondsUsed[social.id] = 7 * 60
            document.usage = usage
            let blocking = BlockingController(document: document, clock: { clock.now }, continuous: { clock.now.timeIntervalSince1970 })
            self.blocking = blocking

            func controller(_ name: String) throws -> ConcentrationController {
                try ConcentrationController(store: FocusStore(directory: root.appendingPathComponent(name)),
                                            clock: { clock.now }, blocking: { blocking })
            }
            func at(_ hour: Int, _ minute: Int) -> Date {
                Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
            }
            let day = BlockingController.dayKey(now)

            empty = try controller("empty")

            clock.now = at(8, 50)
            planned = try controller("planned")
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
            measures = [FocusItemMeasure(id: chapter.id, sessionMinutes: 50, projectWorkMinutes: 95, measuredMinutes: 95, estimateMinutes: 90),
                        FocusItemMeasure(id: quote.id, sessionMinutes: 50, projectWorkMinutes: 12, measuredMinutes: 52, estimateMinutes: 30),
                        FocusItemMeasure(id: mails.id, sessionMinutes: 21, projectWorkMinutes: nil, measuredMinutes: nil, estimateMinutes: 20)]

            clock.now = at(14, 38)
            self.pomodoro = try controller("pomodoro")
            let linked = try self.pomodoro.addPlanItem(title: "Rédiger le chapitre 2", day: day, project: "Livre", estimateMinutes: 90)
            _ = try self.pomodoro.addPlanItem(title: "Relire les épreuves", day: day)
            var classic = FocusMode(); classic.kind = .pomodoro; classic.cycles = 4
            try self.pomodoro.startSession(intent: linked.title, mode: classic, planItemId: linked.id, blockListIds: [social.id, video.id])

            clock.now = at(14, 40)
            locked = try controller("locked")
            var long = FocusMode(); long.minutes = 90
            try locked.startSession(intent: "Préparer la soutenance", mode: long, blockListIds: [video.id], lock: true)

            clock.now = at(14, 28)
            open = try controller("open")
            var endless = FocusMode(); endless.minutes = nil
            try open.startSession(intent: "Lire la documentation de l’API", mode: endless)

            // Engagements: yesterday missed with a stake, last week missed without; today and this week taken.
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            func on(_ base: Date, _ hour: Int, _ minute: Int = 0) -> Date {
                Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
            }
            func segment(_ base: Date, _ from: (Int, Int), _ to: (Int, Int), _ kind: GoalongLocalAnalytics.Kind,
                         _ reason: GoalongCoverageReason? = nil) -> GoalongLocalAnalytics.Segment {
                let start = on(base, from.0, from.1), end = to.0 == 24 ? Calendar.current.startOfDay(for: base).addingTimeInterval(86_400) : on(base, to.0, to.1)
                return .init(start: start, end: end, kind: kind, application: kind.isActive ? "Xcode" : nil, bundleIdentifier: nil, host: nil, coverageReason: reason)
            }
            let sunday = GoalongLocalAnalytics.Day(date: Calendar.current.startOfDay(for: yesterday), end: on(now, 0), state: .ready, segments: [
                segment(yesterday, (0, 0), (9, 0), .unobserved, .beforeFirstObservation), segment(yesterday, (9, 0), (12, 30), .work),
                segment(yesterday, (12, 30), (13, 30), .unobserved, .recorderStopped), segment(yesterday, (13, 30), (16, 10), .work),
                segment(yesterday, (16, 10), (17, 0), .other), segment(yesterday, (17, 0), (24, 0), .unobserved, .afterLastObservation)],
                eventCount: 1, classifierVersions: [])
            let monday = GoalongLocalAnalytics.Day(date: Calendar.current.startOfDay(for: now), end: now, state: .ready, segments: [
                segment(now, (0, 0), (8, 30), .unobserved, .beforeFirstObservation), segment(now, (8, 30), (12, 0), .work),
                segment(now, (12, 0), (13, 0), .idle), segment(now, (13, 0), (13, 40), .work), segment(now, (13, 40), (15, 10), .other)],
                eventCount: 1, classifierVersions: [])
            let stakes = BlockingController(document: BlockingDocument(lists: [social, video]), clock: { clock.now },
                                            continuous: { clock.now.timeIntervalSince1970 })
            clock.now = on(yesterday, 21)
            committed = try ConcentrationController(store: FocusStore(directory: root.appendingPathComponent("committed")),
                                                    clock: { clock.now }, blocking: { stakes })
            _ = try committed.setCommitment(period: .init(kind: .day, key: FocusCalendar.dayKey(yesterday)), kind: .work, target: 420,
                                            stake: FocusStake(listIds: [social.id], until: "18:00"))
            _ = try committed.setCommitment(period: .init(kind: .week, key: FocusCalendar.weekKey(yesterday)), kind: .sessions, target: 10)
            clock.now = on(now, 8, 40); settledAt = clock.now
            committed.applyMeasurements([sunday], hasDefinition: true)
            settledCards = committed.commitmentCards.filter { $0.commitment.result != nil }
            committed.dismissPanel()
            clock.now = on(now, 8, 50)
            _ = try committed.setCommitment(period: .init(kind: .day, key: day), kind: .work, target: 420,
                                            stake: FocusStake(listIds: [social.id, video.id], until: "12:00"))
            _ = try committed.setCommitment(period: .init(kind: .week, key: FocusCalendar.weekKey(now)), kind: .plan, target: 10)
            let first = try committed.addPlanItem(title: "Rédiger le chapitre 2", day: day, project: "Livre", estimateMinutes: 90)
            _ = try committed.addPlanItem(title: "Envoyer le devis à Martin", day: day, project: "Clients", estimateMinutes: 30)
            try committed.setItemStatus(first.id, day: day, status: .done)

            clock.now = now
            committed.applyMeasurements([sunday, monday], hasDefinition: true)
            committed.dismissPanel()
            for value in [empty, planned, self.pomodoro, locked, open, committed] { value.refresh() }
            planned.dismissPanel()
        }
    }
}
#endif
