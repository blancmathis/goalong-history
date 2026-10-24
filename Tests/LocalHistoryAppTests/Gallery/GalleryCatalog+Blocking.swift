#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Programme (blocking page, list sheet, range popover, password) and the blocking surfaces (veil, app notice, freeze,
/// timer capsule). Taken from BlockingPageRenderingTests and BlockingTimerTests, on the gallery clock.
extension GalleryCatalog {
    static var blockingEntries: [GalleryEntry] {
        let F = GalleryFixtures.self
        func page(_ id: String, height: CGFloat, themes: [GalleryTheme] = GalleryTheme.standard,
                  at date: @escaping @MainActor () -> Date = { @MainActor in GalleryFixtures.blockingNow },
                  _ controller: @escaping @MainActor () -> BlockingController) -> GalleryEntry {
            panel(id, width: 900, height: height, themes: themes, clock: .injected) { _ in
                AnyView(BlockingPageContent(controller: controller(), now: date(), expanded: nil))
            }
        }
        let weekdays: Set<Int> = [1, 2, 3, 4, 5]
        var entries: [GalleryEntry] = [
            page("programme/vide", height: 900, themes: GalleryTheme.withContrast) { F.blockingEmpty() },
            page("programme/pret", height: 1_500, at: { F.sunday }) { F.blockingIdle() },
            page("programme/blocage-actif", height: 1_500) { F.blockingActive() },
            page("programme/declenche", height: 1_500) { F.blockingTriggered() },
            page("programme/mot-de-passe", height: 1_500) { F.blockingGuarded() },
            panel("programme/feuille-liste", width: 600, height: 900, clock: .injected) { _ in
                AnyView(BlockListSheet(controller: F.blockingIdle(), listID: F.socialID, now: F.sunday, onDone: {}))
            },
            panel("programme/feuille-liste-verrouillee", width: 600, height: 900, clock: .injected) { _ in
                AnyView(BlockListSheet(controller: F.blockingActive(), listID: F.videoID, now: F.blockingNow, onDone: {}))
            },
            panel("programme/selecteur-de-plage", width: 440, clock: .injected) { _ in
                AnyView(BlockingRangePopover(controller: F.blockingIdle(),
                    draft: BlockingRangeDraft(existing: nil, listIDs: [F.socialID], days: weekdays, start: 540, end: 720),
                    now: F.sunday, onClose: {}))
            },
            panel("programme/selecteur-mot-de-passe", width: 440, clock: .injected) { _ in
                AnyView(BlockingRangePopover(controller: F.blockingGuarded(),
                    draft: BlockingRangeDraft(existing: nil, listIDs: [F.socialID], days: weekdays, start: 540, end: 720,
                                              lock: .password),
                    now: F.blockingNow, onClose: {}))
            },
            panel("programme/protection", width: 440, clock: .injected) { _ in
                AnyView(BlockingProtectionDetails(controller: F.blockingIdle()).padding(18))
            },
            panel("programme/protection-mot-de-passe", width: 440, clock: .injected) { _ in
                AnyView(BlockingProtectionDetails(controller: F.blockingGuarded()).padding(18))
            },
            // A locked block runs and the background service that reopens Goalong is waiting, failed or running.
            panel("programme/protection-a-autoriser", width: 440, clock: .injected) { _ in
                AnyView(BlockingProtectionDetails(controller: F.blockingProtected(.awaitingApproval)).padding(18))
            },
            panel("programme/protection-indisponible", width: 440, clock: .injected) { _ in
                AnyView(BlockingProtectionDetails(controller: F.blockingProtected(.failed("Service de protection indisponible."))).padding(18))
            },
            panel("programme/protection-renforcee", width: 440, clock: .injected) { _ in
                AnyView(BlockingProtectionDetails(controller: F.blockingProtected(.running)).padding(18))
            },
            panel("programme/composer-plus-tard", width: 820, clock: .injected) { _ in
                AnyView(BlockingNowComposer(controller: F.blockingIdle(), now: F.sunday, later: true, lock: .password).padding(24))
            },
            panel("programme/mot-de-passe-a-creer", width: 480, clock: .injected) { _ in
                AnyView(BlockingPasswordSheet(controller: F.blockingIdle(), purpose: .create, onClose: {}))
            },
            panel("programme/mot-de-passe-a-saisir", width: 480, clock: .injected) { _ in
                AnyView(BlockingPasswordSheet(controller: F.blockingGuarded(),
                    purpose: .unlock(F.socialID, what: "Le blocage s’arrête maintenant, avant 16:34."), onClose: {}))
            },
            panel("programme/saisie-de-texte", width: 560) { _ in
                AnyView(BlockingTypingChallengeSheet(text: String(repeating: "aB3kZ", count: 24), onSubmit: { _ in }, onCancel: {}))
            },
            panel("modules/reglages", width: 760) { _ in AnyView(GoalongModulesSettings(onOpen: { _ in }).padding(32)) },
        ]
        let veils: [(String, BlockingVeilPresentation.Reason)] = [
            ("voile-site", .site("youtube.com")),
            ("voile-navigateur", .unsupportedBrowser("Firefox")),
            ("voile-quota", .quotaUsed("instagram.com", minutes: 30)),
        ]
        entries += veils.map { name, reason in
            panel("blocking-surfaces/\(name)", width: 1_100, height: 720, clock: .injected) { _ in
                let now = F.blockingNow
                let veil = BlockingVeilPresentation(reason: reason, listName: "Réseaux sociaux",
                    start: now.addingTimeInterval(-50 * 60), end: now.addingTimeInterval(70 * 60),
                    lock: .locked, breakMinutes: 5, breaksLeft: 2,
                    feedback: BlockingListFeedback(listID: F.socialID, reason: "Finir le mémoire avant vendredi.",
                                                   attemptsToday: 3, earnedMinutesToday: 10))
                return AnyView(BlockedSiteVeil(presentation: veil, now: now))
            }
        }
        entries += [
            panel("blocking-surfaces/avis-app", width: 420, clock: .injected) { _ in
                let now = F.blockingNow
                return AnyView(BlockedAppNotice(app: BlockAppRule(bundleIdentifier: "com.apple.Music", name: "Musique"),
                    end: now.addingTimeInterval(4_200), lock: .locked, listName: "Distractions",
                    feedback: BlockingListFeedback(listID: F.videoID, reason: "Finir le mémoire avant vendredi.",
                                                   attemptsToday: 2, earnedMinutesToday: 0))
                    .padding(20))
            },
            panel("blocking-surfaces/gel-du-mac", width: 1_280, height: 800, clock: .injected) { _ in
                AnyView(FrozenMacShield(freeze: F.freeze, now: F.blockingNow))
            },
        ]
        let timers: [(String, BlockingVisibleTimer)] = [
            ("minuteur-normal", .init(kind: .quota, listID: F.socialID, listName: "Échecs", remaining: 1_712)),
            ("minuteur-orange", .init(kind: .quota, listID: F.socialID, listName: "Échecs", remaining: 247)),
            ("minuteur-rouge", .init(kind: .quota, listID: F.socialID, listName: "Échecs", remaining: 42)),
            ("minuteur-arrete", .init(kind: .quota, listID: F.socialID, listName: "Échecs", remaining: 1_712, counting: false)),
            ("minuteur-pause", .init(kind: .breakTime, listID: F.socialID, listName: "Échecs", remaining: 268)),
        ]
        entries += timers.map { name, timer in
            // The capsule keeps its own colours over any desktop: one theme is enough.
            GalleryEntry("blocking-surfaces/\(name)", sizes: [.fixed(320, 64)], themes: [.light], clock: .none,
                         pageBackground: false, note: "Même rendu en clair et en sombre (couleurs propres)") { _ in
                // A flat desktop tone: a gradient would look like part of the capsule (UI-clair-36).
                AnyView(ZStack {
                    Color(white: 0.88)
                    BlockingTimerCapsule(timer: timer, pulse: 0)
                })
            }
        }
        return entries
    }
}
#endif
